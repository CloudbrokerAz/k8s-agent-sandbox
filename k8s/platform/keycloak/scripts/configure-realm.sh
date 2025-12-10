#!/bin/bash
set -e

# Keycloak Realm Configuration Script
# Creates the agent-sandbox realm with Boundary client and demo users
#
# Usage:
#   ./configure-realm.sh                    # Uses localhost (requires port-forward)
#   ./configure-realm.sh --in-cluster       # Uses in-cluster service URL
#   KEYCLOAK_URL=http://... ./configure-realm.sh  # Custom URL

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KEYCLOAK_NAMESPACE="${KEYCLOAK_NAMESPACE:-keycloak}"

# URL encode function for special characters in form data
url_encode() {
    local string="$1"
    # Encode special characters: ! @ # $ % & * etc.
    string="${string//\!/\%21}"
    string="${string//@/\%40}"
    string="${string//#/\%23}"
    string="${string//\$/\%24}"
    string="${string//%/\%25}"
    string="${string//&/\%26}"
    string="${string//\*/\%2A}"
    string="${string//+/\%2B}"
    string="${string// /\%20}"
    echo "$string"
}

# Detect in-cluster mode
IN_CLUSTER="${IN_CLUSTER:-false}"
if [[ "$1" == "--in-cluster" ]] || [[ "$1" == "-i" ]]; then
    IN_CLUSTER="true"
fi

# Set Keycloak URL based on mode
if [[ "$IN_CLUSTER" == "true" ]]; then
    KEYCLOAK_URL="${KEYCLOAK_URL:-http://keycloak.${KEYCLOAK_NAMESPACE}.svc.cluster.local:8080}"
else
    KEYCLOAK_URL="${KEYCLOAK_URL:-http://localhost:8080}"
fi

# Get admin credentials from K8s secret if available
if kubectl get secret keycloak-admin -n "$KEYCLOAK_NAMESPACE" &>/dev/null; then
    ADMIN_USER="${KEYCLOAK_ADMIN:-$(kubectl get secret keycloak-admin -n "$KEYCLOAK_NAMESPACE" -o jsonpath='{.data.admin-user}' 2>/dev/null | base64 -d || echo "admin")}"
    ADMIN_PASS="${KEYCLOAK_ADMIN_PASSWORD:-$(kubectl get secret keycloak-admin -n "$KEYCLOAK_NAMESPACE" -o jsonpath='{.data.admin-password}' 2>/dev/null | base64 -d || echo "admin123!@#")}"
else
    ADMIN_USER="${KEYCLOAK_ADMIN:-admin}"
    ADMIN_PASS="${KEYCLOAK_ADMIN_PASSWORD:-admin123!@#}"
fi

# Realm configuration
REALM_NAME="agent-sandbox"
CLIENT_ID="boundary"
CLIENT_SECRET="boundary-client-secret-change-me"

# Boundary redirect URIs (update with your Boundary URLs)
BOUNDARY_URL="${BOUNDARY_URL:-http://boundary-controller-api.boundary.svc.cluster.local:9200}"
REDIRECT_URIS="[\"${BOUNDARY_URL}/v1/auth-methods/oidc:authenticate:callback\"]"

echo "========================================="
echo "Configuring Keycloak Realm"
echo "========================================="
echo ""
echo "Mode: $([ "$IN_CLUSTER" == "true" ] && echo "In-Cluster" || echo "Local (port-forward)")"
echo "Keycloak URL: ${KEYCLOAK_URL}"
echo "Realm: ${REALM_NAME}"
echo "Client ID: ${CLIENT_ID}"
echo ""

# Check if jq is available
if ! command -v jq &> /dev/null; then
    echo "Warning: jq is not installed. Install it for better output formatting."
fi

# -----------------------------------------------------------------------------
# Wrapper function for curl that works both locally and in-cluster
# Uses a persistent curl pod for in-cluster mode to avoid per-call overhead
# -----------------------------------------------------------------------------
CURL_POD_NAME="keycloak-curl-helper"

cleanup_curl_pod() {
    if [[ "$IN_CLUSTER" == "true" ]]; then
        kubectl delete pod "$CURL_POD_NAME" -n "$KEYCLOAK_NAMESPACE" --ignore-not-found=true &>/dev/null
    fi
}

# Ensure cleanup on exit
trap cleanup_curl_pod EXIT

setup_curl_pod() {
    if [[ "$IN_CLUSTER" == "true" ]]; then
        # Delete any existing pod
        kubectl delete pod "$CURL_POD_NAME" -n "$KEYCLOAK_NAMESPACE" --ignore-not-found=true &>/dev/null

        # Create a persistent helper pod with curl and jq (using dwdraju/alpine-curl-jq)
        kubectl run "$CURL_POD_NAME" -n "$KEYCLOAK_NAMESPACE" \
            --image=dwdraju/alpine-curl-jq:latest \
            --restart=Never \
            --command -- sleep 3600 &>/dev/null

        # Wait for pod to be ready
        kubectl wait --for=condition=Ready pod/"$CURL_POD_NAME" -n "$KEYCLOAK_NAMESPACE" --timeout=60s &>/dev/null
    fi
}

kc_curl() {
    if [[ "$IN_CLUSTER" == "true" ]]; then
        # Use kubectl exec to run curl in the persistent pod
        kubectl exec -n "$KEYCLOAK_NAMESPACE" "$CURL_POD_NAME" -- curl "$@" 2>/dev/null
    else
        # Direct curl for local calls
        curl "$@"
    fi
}

# Helper to run jq in the cluster
kc_jq() {
    if [[ "$IN_CLUSTER" == "true" ]]; then
        kubectl exec -i -n "$KEYCLOAK_NAMESPACE" "$CURL_POD_NAME" -- jq "$@" 2>/dev/null
    else
        jq "$@"
    fi
}

# Function to get admin token
get_admin_token() {
    echo "Authenticating as admin..."
    local response
    local encoded_pass
    encoded_pass=$(url_encode "${ADMIN_PASS}")
    response=$(kc_curl -s -X POST "${KEYCLOAK_URL}/realms/master/protocol/openid-connect/token" \
        -H "Content-Type: application/x-www-form-urlencoded" \
        -d "username=${ADMIN_USER}" \
        -d "password=${encoded_pass}" \
        -d "grant_type=password" \
        -d "client_id=admin-cli")

    # Use kc_jq if in-cluster, otherwise try local jq or fallback to grep
    if [[ "$IN_CLUSTER" == "true" ]]; then
        echo "$response" | kc_jq -r '.access_token'
    elif command -v jq &> /dev/null; then
        echo "$response" | jq -r '.access_token'
    else
        echo "$response" | grep -o '"access_token":"[^"]*' | cut -d'"' -f4
    fi
}

# Setup curl pod for in-cluster mode
if [[ "$IN_CLUSTER" == "true" ]]; then
    echo "Setting up in-cluster curl helper pod..."
    setup_curl_pod
    echo "Curl helper pod ready!"
    echo ""
fi

# Wait for Keycloak to be ready
echo "1. Waiting for Keycloak to be ready..."
MAX_WAIT=120
WAITED=0
while [[ $WAITED -lt $MAX_WAIT ]]; do
    HEALTH=$(kc_curl -sf "${KEYCLOAK_URL}/health/ready" 2>/dev/null || echo "")
    if echo "$HEALTH" | grep -q '"status"'; then
        echo "   Keycloak health check passed"
        break
    fi
    echo "   Waiting for Keycloak... (${WAITED}s)"
    sleep 10
    WAITED=$((WAITED + 10))
done

if [[ $WAITED -ge $MAX_WAIT ]]; then
    echo "Warning: Keycloak health check timed out, attempting to proceed anyway..."
fi

# Get admin token
echo "2. Obtaining admin access token..."
ACCESS_TOKEN=$(get_admin_token)

if [ -z "$ACCESS_TOKEN" ] || [ "$ACCESS_TOKEN" == "null" ]; then
    echo "Error: Failed to obtain access token"
    echo "Please ensure:"
    echo "  1. Keycloak is running and accessible at ${KEYCLOAK_URL}"
    echo "  2. Admin credentials are correct"
    echo "  3. Port-forwarding is active: kubectl port-forward -n keycloak svc/keycloak 8080:8080"
    exit 1
fi

echo "Successfully authenticated!"
echo ""

# Create realm
echo "3. Creating realm: ${REALM_NAME}..."
kc_curl -s -X POST "${KEYCLOAK_URL}/admin/realms" \
    -H "Authorization: Bearer ${ACCESS_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "{
        \"realm\": \"${REALM_NAME}\",
        \"enabled\": true,
        \"displayName\": \"Agent Sandbox Platform\",
        \"loginTheme\": \"keycloak\",
        \"accessTokenLifespan\": 3600,
        \"ssoSessionIdleTimeout\": 1800,
        \"ssoSessionMaxLifespan\": 36000
    }" || echo "Realm may already exist"

echo "Realm created/updated!"
echo ""

# Create Boundary OIDC client
echo "4. Creating OIDC client: ${CLIENT_ID}..."
kc_curl -s -X POST "${KEYCLOAK_URL}/admin/realms/${REALM_NAME}/clients" \
    -H "Authorization: Bearer ${ACCESS_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "{
        \"clientId\": \"${CLIENT_ID}\",
        \"name\": \"Boundary OIDC Client\",
        \"description\": \"OIDC client for HashiCorp Boundary authentication\",
        \"enabled\": true,
        \"protocol\": \"openid-connect\",
        \"publicClient\": false,
        \"directAccessGrantsEnabled\": false,
        \"standardFlowEnabled\": true,
        \"implicitFlowEnabled\": false,
        \"serviceAccountsEnabled\": false,
        \"authorizationServicesEnabled\": false,
        \"redirectUris\": ${REDIRECT_URIS},
        \"webOrigins\": [\"${BOUNDARY_URL}\"],
        \"attributes\": {
            \"access.token.lifespan\": \"3600\",
            \"client.secret.creation.time\": \"$(date +%s)\"
        }
    }" || echo "Client may already exist"

echo "OIDC client created/updated!"
echo ""

# Get client UUID for setting secret
echo "5. Setting client secret..."
CLIENT_UUID=$(kc_curl -s -X GET "${KEYCLOAK_URL}/admin/realms/${REALM_NAME}/clients?clientId=${CLIENT_ID}" \
    -H "Authorization: Bearer ${ACCESS_TOKEN}" | kc_jq -r '.[0].id')

if [ -n "$CLIENT_UUID" ] && [ "$CLIENT_UUID" != "null" ]; then
    kc_curl -s -X POST "${KEYCLOAK_URL}/admin/realms/${REALM_NAME}/clients/${CLIENT_UUID}/client-secret" \
        -H "Authorization: Bearer ${ACCESS_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "{\"type\": \"secret\", \"value\": \"${CLIENT_SECRET}\"}"
    echo "Client secret set!"
else
    echo "Warning: Could not retrieve client UUID to set secret"
fi

echo ""

# Create groups
echo "6. Creating user groups..."
for group in "admins" "developers" "readonly"; do
    echo "  - Creating group: ${group}"
    kc_curl -s -X POST "${KEYCLOAK_URL}/admin/realms/${REALM_NAME}/groups" \
        -H "Authorization: Bearer ${ACCESS_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "{
            \"name\": \"${group}\"
        }" || echo "    Group may already exist"
done

echo "Groups created!"
echo ""

# Create demo users
echo "7. Creating demo users..."

# Helper function to create user
create_user() {
    local username=$1
    local email=$2
    local first_name=$3
    local last_name=$4
    local password=$5
    local group=$6

    echo "  - Creating user: ${email}"

    # Create user
    kc_curl -s -X POST "${KEYCLOAK_URL}/admin/realms/${REALM_NAME}/users" \
        -H "Authorization: Bearer ${ACCESS_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "{
            \"username\": \"${username}\",
            \"email\": \"${email}\",
            \"firstName\": \"${first_name}\",
            \"lastName\": \"${last_name}\",
            \"enabled\": true,
            \"emailVerified\": true
        }" 2>&1 | grep -q "409" && echo "    User already exists" || true

    # Get user ID
    local user_id
    user_id=$(kc_curl -s -X GET "${KEYCLOAK_URL}/admin/realms/${REALM_NAME}/users?username=${username}" \
        -H "Authorization: Bearer ${ACCESS_TOKEN}" | kc_jq -r '.[0].id')

    if [ -n "$user_id" ] && [ "$user_id" != "null" ]; then
        # Set password
        kc_curl -s -X PUT "${KEYCLOAK_URL}/admin/realms/${REALM_NAME}/users/${user_id}/reset-password" \
            -H "Authorization: Bearer ${ACCESS_TOKEN}" \
            -H "Content-Type: application/json" \
            -d "{
                \"type\": \"password\",
                \"value\": \"${password}\",
                \"temporary\": false
            }"

        # Add to group
        local group_id
        group_id=$(kc_curl -s -X GET "${KEYCLOAK_URL}/admin/realms/${REALM_NAME}/groups" \
            -H "Authorization: Bearer ${ACCESS_TOKEN}" | kc_jq -r ".[] | select(.name==\"${group}\") | .id")

        if [ -n "$group_id" ] && [ "$group_id" != "null" ]; then
            kc_curl -s -X PUT "${KEYCLOAK_URL}/admin/realms/${REALM_NAME}/users/${user_id}/groups/${group_id}" \
                -H "Authorization: Bearer ${ACCESS_TOKEN}" \
                -H "Content-Type: application/json"
        fi

        echo "    User configured successfully!"
    fi
}

# Create users with different roles
create_user "admin" "admin@example.com" "Admin" "User" "Admin123!@#" "admins"
create_user "developer" "developer@example.com" "Developer" "User" "Dev123!@#" "developers"
create_user "readonly" "readonly@example.com" "ReadOnly" "User" "Read123!@#" "readonly"

echo ""
echo "========================================="
echo "Configuration Complete!"
echo "========================================="
echo ""
echo "Realm: ${REALM_NAME}"
echo "Realm URL: ${KEYCLOAK_URL}/realms/${REALM_NAME}"
echo ""
echo "OIDC Configuration:"
echo "  Client ID: ${CLIENT_ID}"
echo "  Client Secret: ${CLIENT_SECRET}"
echo "  Issuer: ${KEYCLOAK_URL}/realms/${REALM_NAME}"
echo "  Authorization Endpoint: ${KEYCLOAK_URL}/realms/${REALM_NAME}/protocol/openid-connect/auth"
echo "  Token Endpoint: ${KEYCLOAK_URL}/realms/${REALM_NAME}/protocol/openid-connect/token"
echo "  UserInfo Endpoint: ${KEYCLOAK_URL}/realms/${REALM_NAME}/protocol/openid-connect/userinfo"
echo "  JWKS URI: ${KEYCLOAK_URL}/realms/${REALM_NAME}/protocol/openid-connect/certs"
echo ""
echo "Demo Users:"
echo "  admin@example.com / Admin123!@# (admins group)"
echo "  developer@example.com / Dev123!@# (developers group)"
echo "  readonly@example.com / Read123!@# (readonly group)"
echo ""
echo "Next Steps:"
echo "  1. Configure Boundary OIDC auth method with above credentials"
echo "  2. Test login with demo users"
echo "  3. Update CLIENT_SECRET in production deployments"
echo ""
