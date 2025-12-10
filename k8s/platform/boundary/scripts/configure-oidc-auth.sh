#!/bin/bash
set -euo pipefail

# Configure Boundary OIDC authentication with Keycloak
# This script sets up OIDC auth method and managed groups for role-based access

BOUNDARY_NAMESPACE="${1:-boundary}"
KEYCLOAK_NAMESPACE="${2:-keycloak}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
K8S_DIR="$(dirname "$(dirname "$(dirname "$SCRIPT_DIR")")")"

# Source configuration if available
if [[ -f "$K8S_DIR/scripts/.env" ]]; then
    source "$K8S_DIR/scripts/.env"
elif [[ -f "$K8S_DIR/scripts/platform.env.example" ]]; then
    source "$K8S_DIR/scripts/platform.env.example"
fi

echo "=========================================="
echo "  Boundary OIDC Configuration"
echo "=========================================="
echo ""

# Check for boundary CLI
if ! command -v boundary &> /dev/null; then
    echo "⚠️  Boundary CLI not found"
    echo ""
    echo "Install from: https://developer.hashicorp.com/boundary/downloads"
    echo "Or with Homebrew: brew install hashicorp/tap/boundary"
    echo ""
    echo "Alternatively, this script can configure Boundary using kubectl exec..."
    USE_KUBECTL="true"
else
    USE_KUBECTL="false"
fi

# Check Boundary controller is running
echo "Checking Boundary controller status..."
CONTROLLER_STATUS=$(kubectl get pod -l app=boundary-controller -n "$BOUNDARY_NAMESPACE" -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "NotFound")
if [[ "$CONTROLLER_STATUS" != "Running" ]]; then
    echo "❌ Boundary controller not running (status: $CONTROLLER_STATUS)"
    exit 1
fi
echo "✅ Boundary controller running"

# Check Keycloak is running
echo "Checking Keycloak status..."
KEYCLOAK_STATUS=$(kubectl get pod -l app=keycloak -n "$KEYCLOAK_NAMESPACE" -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "NotFound")
if [[ "$KEYCLOAK_STATUS" != "Running" ]]; then
    echo "❌ Keycloak not running (status: $KEYCLOAK_STATUS)"
    echo ""
    echo "Please deploy Keycloak first before configuring OIDC authentication"
    exit 1
fi
echo "✅ Keycloak running"

# Get controller pod
CONTROLLER_POD=$(kubectl get pod -l app=boundary-controller -n "$BOUNDARY_NAMESPACE" -o jsonpath='{.items[0].metadata.name}')

# Try to get admin credentials from the credentials file
CREDS_FILE="$SCRIPT_DIR/boundary-credentials.txt"
if [[ -f "$CREDS_FILE" ]]; then
    ADMIN_PASSWORD=$(grep "Password:" "$CREDS_FILE" 2>/dev/null | awk '{print $2}' || echo "")
else
    echo "⚠️  Credentials file not found at $CREDS_FILE"
    ADMIN_PASSWORD=""
fi

# Authenticate and get token
if [[ -n "$ADMIN_PASSWORD" ]]; then
    echo "Authenticating with Boundary..."
    AUTH_TOKEN=$(kubectl exec -n "$BOUNDARY_NAMESPACE" "$CONTROLLER_POD" -c boundary-controller -- /bin/ash -c "
        export BOUNDARY_ADDR=http://127.0.0.1:9200
        export BOUNDARY_PASSWORD='$ADMIN_PASSWORD'
        boundary authenticate password -login-name=admin -password=env://BOUNDARY_PASSWORD -format=json
    " 2>/dev/null | jq -r '.item.attributes.token // empty' 2>/dev/null || echo "")

    if [[ -n "$AUTH_TOKEN" ]]; then
        echo "✅ Authenticated successfully"
    else
        echo "⚠️  Token auth failed, falling back to recovery key"
        AUTH_TOKEN=""
    fi
else
    AUTH_TOKEN=""
fi

# Get recovery key as fallback
if [[ -z "$AUTH_TOKEN" ]]; then
    RECOVERY_KEY=$(kubectl get secret boundary-kms-keys -n "$BOUNDARY_NAMESPACE" -o jsonpath='{.data.BOUNDARY_RECOVERY_KEY}' 2>/dev/null | base64 -d || echo "")
    if [[ -z "$RECOVERY_KEY" ]]; then
        echo "❌ Cannot find Boundary recovery key or authenticate"
        exit 1
    fi
    echo "✅ Using recovery key"
fi

# Function to run boundary commands with auth token
run_boundary() {
    local cmd="boundary"
    for arg in "$@"; do
        # Escape single quotes in arguments
        arg="${arg//\'/\'\\\'\'}"
        cmd="$cmd '$arg'"
    done
    if [[ -n "$AUTH_TOKEN" ]]; then
        kubectl exec -n "$BOUNDARY_NAMESPACE" "$CONTROLLER_POD" -c boundary-controller -- \
            /bin/ash -c "export BOUNDARY_ADDR=http://127.0.0.1:9200; export BOUNDARY_TOKEN='$AUTH_TOKEN'; $cmd"
    else
        # Use recovery key - write HCL to temp file to avoid quoting issues
        kubectl exec -n "$BOUNDARY_NAMESPACE" "$CONTROLLER_POD" -c boundary-controller -- \
            /bin/ash -c "
                export BOUNDARY_ADDR=http://127.0.0.1:9200
                echo 'kms \"aead\" { purpose = \"recovery\"; aead_type = \"aes-gcm\"; key = \"$RECOVERY_KEY\"; key_id = \"global_recovery\" }' > /tmp/recovery.hcl
                $cmd -recovery-kms-hcl=file:///tmp/recovery.hcl
            "
    fi
}

# Keycloak configuration
KEYCLOAK_URL="http://keycloak.${KEYCLOAK_NAMESPACE}.svc.cluster.local:8080"
KEYCLOAK_REALM="agent-sandbox"
KEYCLOAK_CLIENT_ID="boundary"
OIDC_ISSUER="${KEYCLOAK_URL}/realms/${KEYCLOAK_REALM}"
OIDC_DISCOVERY_URL="${OIDC_ISSUER}/.well-known/openid-configuration"

echo ""
echo "Keycloak Configuration:"
echo "  URL: $KEYCLOAK_URL"
echo "  Realm: $KEYCLOAK_REALM"
echo "  Client ID: $KEYCLOAK_CLIENT_ID"
echo "  Issuer: $OIDC_ISSUER"
echo ""

# Function to get or create Boundary client in Keycloak and return its secret
# Uses port-forward since curl may not be available in the Keycloak container
get_keycloak_client_secret() {
    local KEYCLOAK_LOCAL_PORT=18080

    # Start port-forward to Keycloak
    kubectl port-forward -n "$KEYCLOAK_NAMESPACE" svc/keycloak ${KEYCLOAK_LOCAL_PORT}:8080 >/dev/null 2>&1 &
    local PF_PID=$!
    sleep 2

    # Get admin credentials from Kubernetes secret
    local ADMIN_USER ADMIN_PASS
    ADMIN_USER=$(kubectl get secret keycloak-admin -n "$KEYCLOAK_NAMESPACE" -o jsonpath='{.data.KEYCLOAK_ADMIN}' 2>/dev/null | base64 -d || echo "admin")
    ADMIN_PASS=$(kubectl get secret keycloak-admin -n "$KEYCLOAK_NAMESPACE" -o jsonpath='{.data.KEYCLOAK_ADMIN_PASSWORD}' 2>/dev/null | base64 -d || echo "")

    if [[ -z "$ADMIN_PASS" ]]; then
        kill $PF_PID 2>/dev/null || true
        echo ""
        return 1
    fi

    # Get admin token
    local TOKEN_RESPONSE ADMIN_TOKEN
    TOKEN_RESPONSE=$(curl -s -X POST "http://localhost:${KEYCLOAK_LOCAL_PORT}/realms/master/protocol/openid-connect/token" \
        -H "Content-Type: application/x-www-form-urlencoded" \
        -d "username=${ADMIN_USER}" \
        -d "password=${ADMIN_PASS}" \
        -d "grant_type=password" \
        -d "client_id=admin-cli" 2>/dev/null || echo "{}")

    ADMIN_TOKEN=$(echo "$TOKEN_RESPONSE" | jq -r '.access_token // empty' 2>/dev/null)
    if [[ -z "$ADMIN_TOKEN" ]]; then
        kill $PF_PID 2>/dev/null || true
        echo ""
        return 1
    fi

    # Check if client exists
    local CLIENT_ID_INTERNAL
    CLIENT_ID_INTERNAL=$(curl -s \
        -H "Authorization: Bearer $ADMIN_TOKEN" \
        "http://localhost:${KEYCLOAK_LOCAL_PORT}/admin/realms/${KEYCLOAK_REALM}/clients?clientId=${KEYCLOAK_CLIENT_ID}" 2>/dev/null | jq -r '.[0].id // empty' 2>/dev/null)

    if [[ -z "$CLIENT_ID_INTERNAL" ]]; then
        # Create the client
        echo "Creating Boundary client in Keycloak..." >&2
        curl -s -X POST "http://localhost:${KEYCLOAK_LOCAL_PORT}/admin/realms/${KEYCLOAK_REALM}/clients" \
            -H "Authorization: Bearer $ADMIN_TOKEN" \
            -H "Content-Type: application/json" \
            -d '{
                "clientId": "'"${KEYCLOAK_CLIENT_ID}"'",
                "name": "Boundary",
                "description": "HashiCorp Boundary OIDC Client",
                "enabled": true,
                "protocol": "openid-connect",
                "publicClient": false,
                "clientAuthenticatorType": "client-secret",
                "standardFlowEnabled": true,
                "directAccessGrantsEnabled": false,
                "serviceAccountsEnabled": false,
                "redirectUris": [
                    "http://127.0.0.1:9200/v1/auth-methods/oidc:authenticate:callback",
                    "http://boundary-controller-api.'"${BOUNDARY_NAMESPACE}"'.svc.cluster.local:9200/v1/auth-methods/oidc:authenticate:callback"
                ],
                "webOrigins": ["*"],
                "defaultClientScopes": ["openid", "profile", "email", "groups"]
            }' >/dev/null 2>&1

        # Get the client ID again
        sleep 1
        CLIENT_ID_INTERNAL=$(curl -s \
            -H "Authorization: Bearer $ADMIN_TOKEN" \
            "http://localhost:${KEYCLOAK_LOCAL_PORT}/admin/realms/${KEYCLOAK_REALM}/clients?clientId=${KEYCLOAK_CLIENT_ID}" 2>/dev/null | jq -r '.[0].id // empty' 2>/dev/null)
    fi

    if [[ -z "$CLIENT_ID_INTERNAL" ]]; then
        kill $PF_PID 2>/dev/null || true
        echo ""
        return 1
    fi

    # Get client secret
    local SECRET_RESPONSE CLIENT_SECRET
    SECRET_RESPONSE=$(curl -s \
        -H "Authorization: Bearer $ADMIN_TOKEN" \
        "http://localhost:${KEYCLOAK_LOCAL_PORT}/admin/realms/${KEYCLOAK_REALM}/clients/${CLIENT_ID_INTERNAL}/client-secret" 2>/dev/null)

    CLIENT_SECRET=$(echo "$SECRET_RESPONSE" | jq -r '.value // empty' 2>/dev/null)

    # Cleanup port-forward
    kill $PF_PID 2>/dev/null || true
    echo "$CLIENT_SECRET"
}

# Get organization ID (should be created by configure-targets.sh)
echo "Looking up organization scope..."
ORG_RESULT=$(run_boundary scopes list -format=json 2>/dev/null || echo "{}")

ORG_ID=$(echo "$ORG_RESULT" | jq -r '.items[]? | select(.name=="DevOps") | .id' 2>/dev/null || echo "")
if [[ -z "$ORG_ID" ]]; then
    echo "❌ DevOps organization not found"
    echo ""
    echo "Please run configure-targets.sh first to create the organization"
    exit 1
fi
echo "✅ Found organization: DevOps ($ORG_ID)"

# Get project ID
PROJECT_ID=$(run_boundary scopes list -scope-id="$ORG_ID" -format=json 2>/dev/null | jq -r '.items[]? | select(.name=="Agent-Sandbox") | .id' 2>/dev/null || echo "")
if [[ -z "$PROJECT_ID" ]]; then
    echo "❌ Agent-Sandbox project not found"
    exit 1
fi
echo "✅ Found project: Agent-Sandbox ($PROJECT_ID)"

# Check if OIDC auth method already exists
echo ""
echo "Checking for existing OIDC auth method..."
EXISTING_OIDC=$(run_boundary auth-methods list -scope-id="$ORG_ID" -format=json 2>/dev/null | jq -r '.items[]? | select(.type=="oidc") | .id' 2>/dev/null || echo "")

if [[ -n "$EXISTING_OIDC" ]]; then
    echo "✅ OIDC auth method already exists ($EXISTING_OIDC)"
    echo ""
    echo "To reconfigure, delete the auth method first:"
    echo "  boundary auth-methods delete -id=$EXISTING_OIDC"
    echo ""
    AUTH_METHOD_ID="$EXISTING_OIDC"
else
    echo ""
    echo "Step 1: Create OIDC Auth Method"
    echo "--------------------------------"

    # Check if client secret is in environment, auto-fetch from Keycloak, or prompt as fallback
    if [[ -z "${KEYCLOAK_CLIENT_SECRET:-}" ]]; then
        echo "Fetching client secret from Keycloak..."
        KEYCLOAK_CLIENT_SECRET=$(get_keycloak_client_secret)

        if [[ -n "$KEYCLOAK_CLIENT_SECRET" ]]; then
            echo "✅ Retrieved client secret from Keycloak"
        else
            # Fallback to manual prompt only if auto-fetch fails and interactive mode
            echo ""
            echo "⚠️  Could not auto-fetch client secret from Keycloak."
            echo "    You need to create a client in Keycloak with the following settings:"
            echo "    - Realm: $KEYCLOAK_REALM"
            echo "    - Client ID: $KEYCLOAK_CLIENT_ID"
            echo "    - Client Protocol: openid-connect"
            echo "    - Access Type: confidential"
            echo "    - Valid Redirect URIs: http://127.0.0.1:9200/v1/auth-methods/oidc:authenticate:callback"
            echo "                           http://boundary-controller-api.${BOUNDARY_NAMESPACE}.svc.cluster.local:9200/v1/auth-methods/oidc:authenticate:callback"
            echo ""

            # Check if we're in non-interactive mode
            if [[ ! -t 0 ]]; then
                echo "❌ Cannot prompt for client secret in non-interactive mode"
                echo "   Set KEYCLOAK_CLIENT_SECRET environment variable or ensure Keycloak is accessible"
                exit 1
            fi

            echo "Please enter the client secret from Keycloak:"
            read -s KEYCLOAK_CLIENT_SECRET
            echo ""
        fi
    else
        echo "Using KEYCLOAK_CLIENT_SECRET from environment"
    fi

    if [[ -z "$KEYCLOAK_CLIENT_SECRET" ]]; then
        echo "❌ Client secret is required"
        exit 1
    fi

    # Create OIDC auth method
    AUTH_RESULT=$(run_boundary auth-methods create oidc \
        -name="keycloak" \
        -description="Keycloak OIDC Authentication" \
        -scope-id="$ORG_ID" \
        -issuer="$OIDC_ISSUER" \
        -client-id="$KEYCLOAK_CLIENT_ID" \
        -client-secret="env://KEYCLOAK_CLIENT_SECRET" \
        -signing-algorithm=RS256 \
        -api-url-prefix="http://127.0.0.1:9200" \
        -format=json \
        \
        <<< "$KEYCLOAK_CLIENT_SECRET" 2>/dev/null || echo "{}")

    AUTH_METHOD_ID=$(echo "$AUTH_RESULT" | jq -r '.item.id // empty')
    if [[ -z "$AUTH_METHOD_ID" ]]; then
        echo "❌ Failed to create OIDC auth method"
        echo "$AUTH_RESULT"
        exit 1
    fi
    echo "✅ Created OIDC auth method: keycloak ($AUTH_METHOD_ID)"

    # Configure claims scopes
    echo "Configuring claims scopes..."
    run_boundary auth-methods update oidc \
        -id="$AUTH_METHOD_ID" \
        -claims-scope="profile" \
        -claims-scope="email" \
        -claims-scope="groups" \
        2>/dev/null || true
    echo "✅ Configured claims scopes"
fi

echo ""
echo "Step 2: Create Managed Groups"
echo "------------------------------"

# Function to create managed group
create_managed_group() {
    local GROUP_NAME=$1
    local GROUP_FILTER=$2
    local DESCRIPTION=$3

    # Check if group already exists
    EXISTING_GROUP=$(run_boundary managed-groups list -auth-method-id="$AUTH_METHOD_ID" -format=json 2>/dev/null | jq -r ".items[]? | select(.name==\"$GROUP_NAME\") | .id" 2>/dev/null || echo "")

    if [[ -n "$EXISTING_GROUP" ]]; then
        echo "  ✅ Managed group '$GROUP_NAME' already exists ($EXISTING_GROUP)"
        echo "$EXISTING_GROUP"
    else
        GROUP_RESULT=$(run_boundary managed-groups create oidc \
            -name="$GROUP_NAME" \
            -description="$DESCRIPTION" \
            -auth-method-id="$AUTH_METHOD_ID" \
            -filter="$GROUP_FILTER" \
            -format=json \
            2>/dev/null || echo "{}")

        GROUP_ID=$(echo "$GROUP_RESULT" | jq -r '.item.id // empty')
        if [[ -z "$GROUP_ID" ]]; then
            echo "  ⚠️  Failed to create managed group '$GROUP_NAME'"
            echo ""
        else
            echo "  ✅ Created managed group: $GROUP_NAME ($GROUP_ID)"
            echo "$GROUP_ID"
        fi
    fi
}

# Create managed groups for each Keycloak group
echo ""
echo "Creating managed groups for Keycloak groups..."

# Admins group - full access
ADMINS_GROUP_ID=$(create_managed_group \
    "keycloak-admins" \
    "\"/token/groups\" contains \"admins\"" \
    "Keycloak admins group - full access")

# Developers group - connect access
DEVELOPERS_GROUP_ID=$(create_managed_group \
    "keycloak-developers" \
    "\"/token/groups\" contains \"developers\"" \
    "Keycloak developers group - connect access")

# Readonly group - list only
READONLY_GROUP_ID=$(create_managed_group \
    "keycloak-readonly" \
    "\"/token/groups\" contains \"readonly\"" \
    "Keycloak readonly group - list access only")

echo ""
echo "Step 3: Create Roles and Grant Permissions"
echo "------------------------------------------"

# Function to create role with grants
create_role() {
    local ROLE_NAME=$1
    local ROLE_DESC=$2
    local GRANT_STRING=$3
    local MANAGED_GROUP_ID=$4
    local SCOPE_ID=$5

    # Check if role already exists
    EXISTING_ROLE=$(run_boundary roles list -scope-id="$SCOPE_ID" -format=json 2>/dev/null | jq -r ".items[]? | select(.name==\"$ROLE_NAME\") | .id" 2>/dev/null || echo "")

    if [[ -n "$EXISTING_ROLE" ]]; then
        echo "  ✅ Role '$ROLE_NAME' already exists ($EXISTING_ROLE)"
        ROLE_ID="$EXISTING_ROLE"
    else
        ROLE_RESULT=$(run_boundary roles create \
            -name="$ROLE_NAME" \
            -description="$ROLE_DESC" \
            -scope-id="$SCOPE_ID" \
            -format=json \
            2>/dev/null || echo "{}")

        ROLE_ID=$(echo "$ROLE_RESULT" | jq -r '.item.id // empty')
        if [[ -z "$ROLE_ID" ]]; then
            echo "  ⚠️  Failed to create role '$ROLE_NAME'"
            return
        fi
        echo "  ✅ Created role: $ROLE_NAME ($ROLE_ID)"
    fi

    # Add grants
    if [[ -n "$GRANT_STRING" ]]; then
        run_boundary roles add-grants \
            -id="$ROLE_ID" \
            -grant="$GRANT_STRING" \
            2>/dev/null || true
        echo "    - Added grant: $GRANT_STRING"
    fi

    # Add managed group as principal
    if [[ -n "$MANAGED_GROUP_ID" ]]; then
        run_boundary roles add-principals \
            -id="$ROLE_ID" \
            -principal="$MANAGED_GROUP_ID" \
            2>/dev/null || true
        echo "    - Added managed group as principal"
    fi
}

echo ""
echo "Creating roles in project scope ($PROJECT_ID)..."

# Admin role - full access to everything
if [[ -n "$ADMINS_GROUP_ID" ]]; then
    create_role \
        "oidc-admins" \
        "OIDC Admins - Full access" \
        "ids=*;type=*;actions=*" \
        "$ADMINS_GROUP_ID" \
        "$PROJECT_ID"
fi

# Developer role - connect to targets
if [[ -n "$DEVELOPERS_GROUP_ID" ]]; then
    create_role \
        "oidc-developers" \
        "OIDC Developers - Connect access" \
        "ids=*;type=target;actions=read,authorize-session" \
        "$DEVELOPERS_GROUP_ID" \
        "$PROJECT_ID"
fi

# Readonly role - list resources only
if [[ -n "$READONLY_GROUP_ID" ]]; then
    create_role \
        "oidc-readonly" \
        "OIDC Readonly - List access only" \
        "ids=*;type=*;actions=read,list" \
        "$READONLY_GROUP_ID" \
        "$PROJECT_ID"
fi

# Save configuration
CONFIG_FILE="$SCRIPT_DIR/boundary-oidc-config.txt"
cat > "$CONFIG_FILE" << EOF
==========================================
  Boundary OIDC Configuration
==========================================

Auth Method ID:     $AUTH_METHOD_ID
Issuer:             $OIDC_ISSUER
Client ID:          $KEYCLOAK_CLIENT_ID

==========================================
  Managed Groups
==========================================

Admins Group:       $ADMINS_GROUP_ID
Developers Group:   $DEVELOPERS_GROUP_ID
Readonly Group:     $READONLY_GROUP_ID

==========================================
  Group Mappings
==========================================

Keycloak Group      → Boundary Access
-----------------------------------------
admins              → Full access (all operations)
developers          → Connect access (read + authorize-session on targets)
readonly            → List access (read + list on all resources)

==========================================
  Keycloak Configuration Required
==========================================

1. Create client in Keycloak:
   - Realm: $KEYCLOAK_REALM
   - Client ID: $KEYCLOAK_CLIENT_ID
   - Client Protocol: openid-connect
   - Access Type: confidential
   - Valid Redirect URIs:
     * http://127.0.0.1:9200/v1/auth-methods/oidc:authenticate:callback
     * http://boundary-controller-api.${BOUNDARY_NAMESPACE}.svc.cluster.local:9200/v1/auth-methods/oidc:authenticate:callback

2. Configure client scopes to include 'groups' claim

3. Create groups in Keycloak:
   - admins
   - developers
   - readonly

4. Assign users to groups

==========================================
  Usage
==========================================

1. Port forward to Boundary API:
   kubectl port-forward -n $BOUNDARY_NAMESPACE svc/boundary-controller-api 9200:9200

2. Authenticate with OIDC:
   export BOUNDARY_ADDR=http://127.0.0.1:9200
   boundary authenticate oidc -auth-method-id=$AUTH_METHOD_ID

3. Your browser will open for Keycloak login
   - Login with Keycloak credentials
   - You'll be redirected back to Boundary

4. Connect to targets based on your group membership

==========================================
  Testing OIDC Auth
==========================================

Run the test script:
  ./test-oidc-auth.sh

EOF
chmod 600 "$CONFIG_FILE"

echo ""
echo "=========================================="
echo "  ✅ OIDC Configuration Complete"
echo "=========================================="
echo ""
echo "Configuration saved to: $CONFIG_FILE"
echo ""
echo "Next steps:"
echo "  1. Configure the Keycloak client as described in the config file"
echo "  2. Create groups and assign users in Keycloak"
echo "  3. Run ./test-oidc-auth.sh to verify the configuration"
echo ""
echo "Quick test:"
echo "  1. kubectl port-forward -n $BOUNDARY_NAMESPACE svc/boundary-controller-api 9200:9200"
echo "  2. export BOUNDARY_ADDR=http://127.0.0.1:9200"
echo "  3. boundary authenticate oidc -auth-method-id=$AUTH_METHOD_ID"
echo ""
