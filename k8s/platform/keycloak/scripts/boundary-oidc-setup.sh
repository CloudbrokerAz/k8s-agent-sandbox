#!/bin/bash
set -e

# Boundary OIDC Setup Script
# Automates the configuration of Boundary OIDC auth method with Keycloak

echo "========================================="
echo "Boundary OIDC Configuration"
echo "========================================="
echo ""

# Configuration variables
BOUNDARY_ADDR="${BOUNDARY_ADDR:-http://localhost:9200}"
KEYCLOAK_URL="${KEYCLOAK_URL:-http://localhost:8080}"
KEYCLOAK_REALM="${KEYCLOAK_REALM:-agent-sandbox}"
KEYCLOAK_CLIENT_ID="${KEYCLOAK_CLIENT_ID:-boundary}"
KEYCLOAK_CLIENT_SECRET="${KEYCLOAK_CLIENT_SECRET:-boundary-client-secret-change-me}"

# Check prerequisites
echo "Checking prerequisites..."
echo ""

if ! command -v boundary &> /dev/null; then
    echo "Error: boundary CLI is not installed"
    exit 1
fi

if ! command -v jq &> /dev/null; then
    echo "Error: jq is not installed"
    exit 1
fi

# Verify Boundary connectivity
echo "Testing Boundary connectivity..."
if ! curl -s -f "${BOUNDARY_ADDR}/v1/scopes" > /dev/null 2>&1; then
    echo "Error: Cannot connect to Boundary at ${BOUNDARY_ADDR}"
    echo "Ensure Boundary is running and port-forwarding is active"
    exit 1
fi

# Verify Keycloak connectivity
echo "Testing Keycloak connectivity..."
if ! curl -s -f "${KEYCLOAK_URL}/realms/${KEYCLOAK_REALM}" > /dev/null 2>&1; then
    echo "Error: Cannot connect to Keycloak at ${KEYCLOAK_URL}"
    echo "Ensure Keycloak is running and port-forwarding is active"
    exit 1
fi

echo "Prerequisites satisfied!"
echo ""

# Display configuration
echo "Configuration:"
echo "  Boundary: ${BOUNDARY_ADDR}"
echo "  Keycloak: ${KEYCLOAK_URL}"
echo "  Realm: ${KEYCLOAK_REALM}"
echo "  Client ID: ${KEYCLOAK_CLIENT_ID}"
echo ""

# Prompt for confirmation
read -p "Continue with this configuration? (yes/no): " -r
echo ""

if [[ ! $REPLY =~ ^[Yy][Ee][Ss]$ ]]; then
    echo "Configuration cancelled."
    exit 0
fi

# Check if already authenticated
if ! boundary scopes list > /dev/null 2>&1; then
    echo "You need to authenticate to Boundary first."
    echo "Run: boundary authenticate password -auth-method-id <your-auth-method-id>"
    exit 1
fi

# Get global scope ID
echo "1. Getting global scope..."
GLOBAL_SCOPE=$(boundary scopes list -format json | jq -r '.items[] | select(.type=="global") | .id' | head -1)

if [ -z "$GLOBAL_SCOPE" ]; then
    echo "Error: Could not find global scope"
    exit 1
fi

echo "   Global scope: ${GLOBAL_SCOPE}"
echo ""

# Create OIDC auth method
echo "2. Creating OIDC auth method..."
AUTH_METHOD_RESPONSE=$(boundary auth-methods create oidc \
  -scope-id "$GLOBAL_SCOPE" \
  -name "keycloak-oidc" \
  -description "Keycloak OIDC authentication for Agent Sandbox Platform" \
  -issuer "${KEYCLOAK_URL}/realms/${KEYCLOAK_REALM}" \
  -client-id "${KEYCLOAK_CLIENT_ID}" \
  -client-secret "${KEYCLOAK_CLIENT_SECRET}" \
  -signing-algorithm "RS256" \
  -api-url-prefix "${BOUNDARY_ADDR}" \
  -max-age 0 \
  -format json 2>&1)

if echo "$AUTH_METHOD_RESPONSE" | grep -q "already exists"; then
    echo "   Auth method already exists, fetching ID..."
    AUTH_METHOD_ID=$(boundary auth-methods list -scope-id "$GLOBAL_SCOPE" -format json | \
        jq -r '.items[] | select(.name=="keycloak-oidc") | .id')
else
    AUTH_METHOD_ID=$(echo "$AUTH_METHOD_RESPONSE" | jq -r '.item.id')
fi

echo "   Auth method ID: ${AUTH_METHOD_ID}"
echo ""

# Update OIDC scopes and claims
echo "3. Configuring OIDC scopes and claims..."
boundary auth-methods update oidc \
  -id "$AUTH_METHOD_ID" \
  -allowed-audience "${KEYCLOAK_CLIENT_ID}" \
  -claims-scopes "openid" \
  -claims-scopes "profile" \
  -claims-scopes "email" > /dev/null

boundary auth-methods update oidc \
  -id "$AUTH_METHOD_ID" \
  -account-claim-maps "oid=sub" \
  -account-claim-maps "email=email" > /dev/null

echo "   OIDC scopes configured!"
echo ""

# Create managed groups
echo "4. Creating managed groups..."

create_managed_group() {
    local name=$1
    local description=$2
    local filter=$3

    local response
    response=$(boundary managed-groups create oidc \
        -auth-method-id "$AUTH_METHOD_ID" \
        -name "$name" \
        -description "$description" \
        -filter "$filter" \
        -format json 2>&1)

    if echo "$response" | grep -q "already exists"; then
        echo "   ${name}: Already exists"
        boundary managed-groups list -auth-method-id "$AUTH_METHOD_ID" -format json | \
            jq -r ".items[] | select(.name==\"${name}\") | .id"
    else
        echo "   ${name}: Created"
        echo "$response" | jq -r '.item.id'
    fi
}

ADMIN_GROUP_ID=$(create_managed_group \
    "keycloak-admins" \
    "Keycloak administrators" \
    '"admins" in "/resource/groups"')

DEV_GROUP_ID=$(create_managed_group \
    "keycloak-developers" \
    "Keycloak developers" \
    '"developers" in "/resource/groups"')

READONLY_GROUP_ID=$(create_managed_group \
    "keycloak-readonly" \
    "Keycloak read-only users" \
    '"readonly" in "/resource/groups"')

echo ""

# Get organization scope
echo "5. Setting up roles..."
ORG_SCOPE=$(boundary scopes list -format json | jq -r '.items[] | select(.type=="org") | .id' | head -1)

if [ -z "$ORG_SCOPE" ]; then
    echo "   Warning: No organization scope found, skipping role creation"
else
    echo "   Organization scope: ${ORG_SCOPE}"

    # Helper function to create role
    create_role() {
        local name=$1
        local description=$2
        local principal_id=$3
        shift 3
        local grants=("$@")

        local role_response
        role_response=$(boundary roles list -scope-id "$ORG_SCOPE" -format json | \
            jq -r ".items[] | select(.name==\"${name}\") | .id")

        if [ -n "$role_response" ]; then
            echo "   ${name}: Already exists (${role_response})"
            return
        fi

        local grant_args=""
        for grant in "${grants[@]}"; do
            grant_args="$grant_args -grant-string \"$grant\""
        done

        eval boundary roles create \
            -scope-id "$ORG_SCOPE" \
            -name "$name" \
            -description "$description" \
            -grant-scope-id "$ORG_SCOPE" \
            -principal-id "$principal_id" \
            $grant_args > /dev/null

        echo "   ${name}: Created"
    }

    # Create admin role
    create_role \
        "keycloak-admin-role" \
        "Administrator role for Keycloak admins" \
        "$ADMIN_GROUP_ID" \
        "id=*;type=*;actions=*"

    # Create developer role
    create_role \
        "keycloak-developer-role" \
        "Developer role for Keycloak developers" \
        "$DEV_GROUP_ID" \
        "id=*;type=target;actions=read,authorize-session" \
        "id=*;type=session;actions=read,cancel,list"

    # Create readonly role
    create_role \
        "keycloak-readonly-role" \
        "Read-only role for Keycloak users" \
        "$READONLY_GROUP_ID" \
        "id=*;type=*;actions=read,list"
fi

echo ""
echo "========================================="
echo "Configuration Complete!"
echo "========================================="
echo ""
echo "OIDC Auth Method Details:"
echo "  ID: ${AUTH_METHOD_ID}"
echo "  Issuer: ${KEYCLOAK_URL}/realms/${KEYCLOAK_REALM}"
echo "  Client ID: ${KEYCLOAK_CLIENT_ID}"
echo ""
echo "Managed Groups:"
echo "  Admins: ${ADMIN_GROUP_ID}"
echo "  Developers: ${DEV_GROUP_ID}"
echo "  Read-only: ${READONLY_GROUP_ID}"
echo ""
echo "To authenticate with OIDC:"
echo "  boundary authenticate oidc -auth-method-id ${AUTH_METHOD_ID}"
echo ""
echo "Demo users (from Keycloak):"
echo "  admin@example.com / Admin123!@#"
echo "  developer@example.com / Dev123!@#"
echo "  readonly@example.com / Read123!@#"
echo ""
echo "Configuration saved to: boundary-oidc-config.json"

# Save configuration for reference
cat > boundary-oidc-config.json <<EOF
{
  "auth_method_id": "${AUTH_METHOD_ID}",
  "issuer": "${KEYCLOAK_URL}/realms/${KEYCLOAK_REALM}",
  "client_id": "${KEYCLOAK_CLIENT_ID}",
  "managed_groups": {
    "admins": "${ADMIN_GROUP_ID}",
    "developers": "${DEV_GROUP_ID}",
    "readonly": "${READONLY_GROUP_ID}"
  },
  "boundary_addr": "${BOUNDARY_ADDR}",
  "keycloak_url": "${KEYCLOAK_URL}",
  "realm": "${KEYCLOAK_REALM}"
}
EOF

echo ""
