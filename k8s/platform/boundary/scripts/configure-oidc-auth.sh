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

# Keycloak configuration - use external URLs for user access
# IMPORTANT: Keycloak must have KC_HOSTNAME_URL=https://keycloak.local set
# so that it advertises HTTPS URLs in its OIDC discovery document.
# This is required because users access Keycloak via ingress (HTTPS),
# while Boundary controller accesses it internally via HTTP.
# The issuer URL MUST match what Keycloak advertises in OIDC discovery.
KEYCLOAK_EXTERNAL_URL="https://keycloak.local"
KEYCLOAK_REALM="agent-sandbox"
KEYCLOAK_CLIENT_ID="boundary"
OIDC_ISSUER="${KEYCLOAK_EXTERNAL_URL}/realms/${KEYCLOAK_REALM}"
OIDC_DISCOVERY_URL="${OIDC_ISSUER}/.well-known/openid-configuration"

# Boundary external URL
BOUNDARY_EXTERNAL_URL="https://boundary.local"

echo ""
echo "Keycloak Configuration:"
echo "  URL: $KEYCLOAK_EXTERNAL_URL"
echo "  Realm: $KEYCLOAK_REALM"
echo "  Client ID: $KEYCLOAK_CLIENT_ID"
echo "  Issuer: $OIDC_ISSUER"
echo "  Boundary URL: $BOUNDARY_EXTERNAL_URL"
echo ""

# Function to get or create Boundary client in Keycloak and return its secret
# Uses port-forward since curl may not be available in the Keycloak container
# Note: This function runs in a SUBSHELL to properly scope the trap
get_keycloak_client_secret() (
    set -e
    local KEYCLOAK_LOCAL_PORT=18080
    local PF_PID=""

    # Cleanup function for port-forward
    cleanup_port_forward() {
        if [[ -n "$PF_PID" ]]; then
            kill "$PF_PID" 2>/dev/null || true
            wait "$PF_PID" 2>/dev/null || true
        fi
    }

    # Trap is scoped to this subshell only (won't affect parent)
    trap cleanup_port_forward EXIT

    # Start port-forward to Keycloak
    kubectl port-forward -n "$KEYCLOAK_NAMESPACE" svc/keycloak ${KEYCLOAK_LOCAL_PORT}:8080 >/dev/null 2>&1 &
    PF_PID=$!

    # Wait for port-forward to be ready with health check (up to 10 seconds)
    local WAIT_COUNT=0
    while ! curl -s "http://localhost:${KEYCLOAK_LOCAL_PORT}/health/ready" >/dev/null 2>&1; do
        WAIT_COUNT=$((WAIT_COUNT + 1))
        if [[ $WAIT_COUNT -ge 20 ]]; then
            echo "Timeout waiting for Keycloak port-forward" >&2
            cleanup_port_forward
            return 1
        fi
        sleep 0.5
    done

    # Get admin credentials from Kubernetes secret
    local ADMIN_USER ADMIN_PASS
    ADMIN_USER=$(kubectl get secret keycloak-admin -n "$KEYCLOAK_NAMESPACE" -o jsonpath='{.data.KEYCLOAK_ADMIN}' 2>/dev/null | base64 -d || echo "admin")
    ADMIN_PASS=$(kubectl get secret keycloak-admin -n "$KEYCLOAK_NAMESPACE" -o jsonpath='{.data.KEYCLOAK_ADMIN_PASSWORD}' 2>/dev/null | base64 -d || echo "")

    if [[ -z "$ADMIN_PASS" ]]; then
        cleanup_port_forward
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
        cleanup_port_forward
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
                    "https://boundary.local/v1/auth-methods/oidc:authenticate:callback",
                    "http://127.0.0.1:9200/v1/auth-methods/oidc:authenticate:callback",
                    "http://localhost:9200/v1/auth-methods/oidc:authenticate:callback"
                ],
                "webOrigins": ["*"],
                "defaultClientScopes": ["openid", "profile", "email"]
            }' >/dev/null 2>&1

        # Get the client ID again with retry loop (Keycloak is eventually consistent)
        for i in {1..10}; do
            CLIENT_ID_INTERNAL=$(curl -s \
                -H "Authorization: Bearer $ADMIN_TOKEN" \
                "http://localhost:${KEYCLOAK_LOCAL_PORT}/admin/realms/${KEYCLOAK_REALM}/clients?clientId=${KEYCLOAK_CLIENT_ID}" 2>/dev/null | jq -r '.[0].id // empty' 2>/dev/null)
            [[ -n "$CLIENT_ID_INTERNAL" ]] && break
            sleep 0.5
        done

        # Add groups mapper to include groups claim in OIDC tokens
        # This is required for Boundary managed groups to work
        if [[ -n "$CLIENT_ID_INTERNAL" ]]; then
            echo "Adding groups mapper to client..." >&2
            curl -s -X POST "http://localhost:${KEYCLOAK_LOCAL_PORT}/admin/realms/${KEYCLOAK_REALM}/clients/${CLIENT_ID_INTERNAL}/protocol-mappers/models" \
                -H "Authorization: Bearer $ADMIN_TOKEN" \
                -H "Content-Type: application/json" \
                -d '{
                    "name": "groups",
                    "protocol": "openid-connect",
                    "protocolMapper": "oidc-group-membership-mapper",
                    "consentRequired": false,
                    "config": {
                        "full.path": "false",
                        "id.token.claim": "true",
                        "access.token.claim": "true",
                        "claim.name": "groups",
                        "userinfo.token.claim": "true"
                    }
                }' >/dev/null 2>&1 || echo "  (groups mapper may already exist)" >&2
        fi
        # New client created - Keycloak generates an initial secret automatically
        # Do NOT regenerate - just use the initial secret to avoid sync issues
    fi

    if [[ -z "$CLIENT_ID_INTERNAL" ]]; then
        cleanup_port_forward
        echo ""
        return 1
    fi

    # IMPORTANT: Never regenerate client secret automatically
    # Regeneration causes sync issues between Keycloak, K8s secret, and Boundary
    # If you need to rotate secrets, do it manually and update all consumers

    # Get client secret
    local SECRET_RESPONSE CLIENT_SECRET
    SECRET_RESPONSE=$(curl -s \
        -H "Authorization: Bearer $ADMIN_TOKEN" \
        "http://localhost:${KEYCLOAK_LOCAL_PORT}/admin/realms/${KEYCLOAK_REALM}/clients/${CLIENT_ID_INTERNAL}/client-secret" 2>/dev/null)

    CLIENT_SECRET=$(echo "$SECRET_RESPONSE" | jq -r '.value // empty' 2>/dev/null)

    # Cleanup port-forward (trap will handle it, but explicit call ensures it)
    cleanup_port_forward
    # No need to reset trap - it's scoped to this subshell
    echo "$CLIENT_SECRET"
)

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
    AUTH_METHOD_ID="$EXISTING_OIDC"

    # Sync OIDC config using the shared Kubernetes secret
    # This ensures both Boundary and Keycloak use the same pre-shared secret
    echo "Syncing OIDC config with Keycloak..."

    # Use the shared K8s secret as the authoritative source (created by deploy-all.sh)
    # This avoids secret mismatch issues that can occur when regenerating
    KEYCLOAK_CLIENT_SECRET=$(kubectl get secret boundary-oidc-client-secret -n "$KEYCLOAK_NAMESPACE" -o jsonpath='{.data.client-secret}' 2>/dev/null | base64 -d || echo "")
    if [[ -n "$KEYCLOAK_CLIENT_SECRET" ]]; then
        echo "✅ Using shared client secret from Kubernetes (boundary-oidc-client-secret)"
    else
        # Fallback: fetch from Keycloak API (without regeneration)
        echo "No shared secret found, fetching current secret from Keycloak..."
        KEYCLOAK_CLIENT_SECRET=$(get_keycloak_client_secret)
        if [[ -n "$KEYCLOAK_CLIENT_SECRET" ]]; then
            echo "✅ Retrieved client secret from Keycloak"
            kubectl create secret generic boundary-oidc-client-secret \
                --namespace="$KEYCLOAK_NAMESPACE" \
                --from-literal=client-secret="$KEYCLOAK_CLIENT_SECRET" \
                --dry-run=client -o yaml | kubectl apply -f - 2>/dev/null || true
        fi
    fi

    if [[ -n "$KEYCLOAK_CLIENT_SECRET" ]]; then
        echo "Updating auth method with current Keycloak client secret and CA cert..."

        # Get the CA certificate as base64
        CA_CERT_B64=$(kubectl get secret keycloak-tls -n "$KEYCLOAK_NAMESPACE" -o jsonpath='{.data.tls\.crt}')

        # Prepare update script - file:// doesn't work for idp-ca-cert, so use inline content
        CA_CERT_CONTENT=$(echo "$CA_CERT_B64" | base64 -d)

        if [[ -n "$AUTH_TOKEN" ]]; then
            # Create script to avoid shell escaping issues with certs
            # Note: Using public client (no client-secret required)
            cat > /tmp/boundary_update.sh << EOSCRIPT
#!/bin/ash
export BOUNDARY_ADDR=http://127.0.0.1:9200
export BOUNDARY_TOKEN='$AUTH_TOKEN'
CERT_CONTENT=\$(cat /tmp/keycloak-ca.crt)
boundary auth-methods update oidc \
    -id='$EXISTING_OIDC' \
    -issuer='$OIDC_ISSUER' \
    -idp-ca-cert="\$CERT_CONTENT" \
    -format=json
EOSCRIPT

            # Write CA cert to pod
            echo "$CA_CERT_CONTENT" | kubectl exec -i -n "$BOUNDARY_NAMESPACE" "$CONTROLLER_POD" -c boundary-controller -- tee /tmp/keycloak-ca.crt > /dev/null
            # Copy and run script
            kubectl cp /tmp/boundary_update.sh "$BOUNDARY_NAMESPACE/$CONTROLLER_POD:/tmp/boundary_update.sh" -c boundary-controller 2>/dev/null
            kubectl exec -n "$BOUNDARY_NAMESPACE" "$CONTROLLER_POD" -c boundary-controller -- /bin/ash /tmp/boundary_update.sh 2>/dev/null && echo "✅ OIDC config synced" || echo "⚠️  Could not sync OIDC config (may need manual update)"
            kubectl exec -n "$BOUNDARY_NAMESPACE" "$CONTROLLER_POD" -c boundary-controller -- rm -f /tmp/boundary_update.sh /tmp/keycloak-ca.crt 2>/dev/null
            rm -f /tmp/boundary_update.sh
        else
            # Create script with recovery key for auth
            # Note: Using public client (no client-secret required)
            cat > /tmp/boundary_update.sh << EOSCRIPT
#!/bin/ash
export BOUNDARY_ADDR=http://127.0.0.1:9200
CERT_CONTENT=\$(cat /tmp/keycloak-ca.crt)
boundary auth-methods update oidc \
    -id='$EXISTING_OIDC' \
    -issuer='$OIDC_ISSUER' \
    -idp-ca-cert="\$CERT_CONTENT" \
    -recovery-config=/tmp/recovery.hcl \
    -format=json
EOSCRIPT

            # Write CA cert and recovery config to pod
            echo "$CA_CERT_CONTENT" | kubectl exec -i -n "$BOUNDARY_NAMESPACE" "$CONTROLLER_POD" -c boundary-controller -- tee /tmp/keycloak-ca.crt > /dev/null
            # Write recovery HCL properly
            cat > /tmp/recovery.hcl << EOF
kms "aead" {
  purpose = "recovery"
  aead_type = "aes-gcm"
  key = "$RECOVERY_KEY"
  key_id = "global_recovery"
}
EOF
            kubectl cp /tmp/recovery.hcl "$BOUNDARY_NAMESPACE/$CONTROLLER_POD:/tmp/recovery.hcl" -c boundary-controller 2>/dev/null
            kubectl cp /tmp/boundary_update.sh "$BOUNDARY_NAMESPACE/$CONTROLLER_POD:/tmp/boundary_update.sh" -c boundary-controller 2>/dev/null
            kubectl exec -n "$BOUNDARY_NAMESPACE" "$CONTROLLER_POD" -c boundary-controller -- /bin/ash /tmp/boundary_update.sh 2>/dev/null && echo "✅ OIDC config synced" || echo "⚠️  Could not sync OIDC config (may need manual update)"
            kubectl exec -n "$BOUNDARY_NAMESPACE" "$CONTROLLER_POD" -c boundary-controller -- rm -f /tmp/boundary_update.sh /tmp/keycloak-ca.crt /tmp/recovery.hcl 2>/dev/null
            rm -f /tmp/boundary_update.sh /tmp/recovery.hcl
        fi
    else
        echo "⚠️  Could not fetch client secret from Keycloak - existing auth method unchanged"
    fi
    echo ""
else
    echo ""
    echo "Step 1: Create OIDC Auth Method"
    echo "--------------------------------"

    # Try to get client secret from shared Kubernetes secret first (preferred)
    # This ensures Boundary uses the SAME secret as Keycloak
    if [[ -z "${KEYCLOAK_CLIENT_SECRET:-}" ]]; then
        echo "Checking for shared OIDC client secret in Kubernetes..."
        KEYCLOAK_CLIENT_SECRET=$(kubectl get secret boundary-oidc-client-secret -n "$KEYCLOAK_NAMESPACE" -o jsonpath='{.data.client-secret}' 2>/dev/null | base64 -d || echo "")
        if [[ -n "$KEYCLOAK_CLIENT_SECRET" ]]; then
            echo "✅ Using shared client secret from Kubernetes (boundary-oidc-client-secret)"
        else
            echo "No shared secret found, fetching from Keycloak API..."
            KEYCLOAK_CLIENT_SECRET=$(get_keycloak_client_secret)
            if [[ -n "$KEYCLOAK_CLIENT_SECRET" ]]; then
                echo "✅ Retrieved client secret from Keycloak"
                # Save to Kubernetes secret for future use
                echo "Saving client secret to Kubernetes for consistency..."
                kubectl create secret generic boundary-oidc-client-secret \
                    --namespace="$KEYCLOAK_NAMESPACE" \
                    --from-literal=client-secret="$KEYCLOAK_CLIENT_SECRET" \
                    --dry-run=client -o yaml | kubectl apply -f - 2>/dev/null || true
            fi
        fi
    else
        echo "Using KEYCLOAK_CLIENT_SECRET from environment"
    fi

    if [[ -z "$KEYCLOAK_CLIENT_SECRET" ]]; then
        # Fallback to manual prompt only if auto-fetch fails and interactive mode
        echo ""
        echo "⚠️  Could not auto-fetch client secret."
        echo "    Tried: Kubernetes secret (boundary-oidc-client-secret), Keycloak API"
        echo ""
        echo "    You need to create a client in Keycloak with the following settings:"
        echo "    - Realm: $KEYCLOAK_REALM"
        echo "    - Client ID: $KEYCLOAK_CLIENT_ID"
        echo "    - Client Protocol: openid-connect"
        echo "    - Access Type: confidential"
        echo "    - Valid Redirect URIs: https://boundary.local/v1/auth-methods/oidc:authenticate:callback"
        echo "                           http://127.0.0.1:9200/v1/auth-methods/oidc:authenticate:callback"
        echo "                           http://localhost:9200/v1/auth-methods/oidc:authenticate:callback"
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

        if [[ -z "$KEYCLOAK_CLIENT_SECRET" ]]; then
            echo "❌ Client secret is required"
            exit 1
        fi
    fi

    # Create OIDC auth method
    # Note: Boundary controller needs hostAliases configured to resolve keycloak.local
    # The issuer URL must match what Keycloak advertises in OIDC discovery

    # Get the Keycloak TLS CA certificate for OIDC provider validation (already base64 in k8s)
    echo "Fetching Keycloak TLS certificate for OIDC validation..."
    CA_CERT_B64=$(kubectl get secret keycloak-tls -n "$KEYCLOAK_NAMESPACE" -o jsonpath='{.data.tls\.crt}')

    # Prepare CA cert content - file:// doesn't work for idp-ca-cert, so use inline content via script
    CA_CERT_CONTENT=$(echo "$CA_CERT_B64" | base64 -d)

    if [[ -n "$AUTH_TOKEN" ]]; then
        # Create script for boundary command - avoids shell escaping issues
        cat > /tmp/boundary_create.sh << EOSCRIPT
#!/bin/ash
export BOUNDARY_ADDR=http://127.0.0.1:9200
export BOUNDARY_TOKEN='$AUTH_TOKEN'
CERT_CONTENT=\$(cat /tmp/keycloak-ca.crt)
boundary auth-methods create oidc \
    -name='keycloak' \
    -description='Keycloak OIDC Authentication' \
    -scope-id='$ORG_ID' \
    -issuer='$OIDC_ISSUER' \
    -client-id='$KEYCLOAK_CLIENT_ID' \
    -client-secret='$KEYCLOAK_CLIENT_SECRET' \
    -idp-ca-cert="\$CERT_CONTENT" \
    -signing-algorithm=RS256 \
    -api-url-prefix='$BOUNDARY_EXTERNAL_URL' \
    -format=json
rm -f /tmp/keycloak-ca.crt
EOSCRIPT

        # Copy cert and script to pod, then execute
        echo "$CA_CERT_CONTENT" | kubectl exec -i -n "$BOUNDARY_NAMESPACE" "$CONTROLLER_POD" -c boundary-controller -- tee /tmp/keycloak-ca.crt > /dev/null
        kubectl cp /tmp/boundary_create.sh "$BOUNDARY_NAMESPACE/$CONTROLLER_POD:/tmp/boundary_create.sh" -c boundary-controller
        AUTH_RESULT=$(kubectl exec -n "$BOUNDARY_NAMESPACE" "$CONTROLLER_POD" -c boundary-controller -- /bin/ash /tmp/boundary_create.sh 2>&1 || echo "{}")
        rm -f /tmp/boundary_create.sh
    else
        # Create script with recovery config - avoids shell escaping issues
        cat > /tmp/boundary_create.sh << EOSCRIPT
#!/bin/ash
export BOUNDARY_ADDR=http://127.0.0.1:9200
CERT_CONTENT=\$(cat /tmp/keycloak-ca.crt)
boundary auth-methods create oidc \
    -name='keycloak' \
    -description='Keycloak OIDC Authentication' \
    -scope-id='$ORG_ID' \
    -issuer='$OIDC_ISSUER' \
    -client-id='$KEYCLOAK_CLIENT_ID' \
    -client-secret='$KEYCLOAK_CLIENT_SECRET' \
    -idp-ca-cert="\$CERT_CONTENT" \
    -signing-algorithm=RS256 \
    -api-url-prefix='$BOUNDARY_EXTERNAL_URL' \
    -recovery-config=/tmp/recovery.hcl \
    -format=json
rm -f /tmp/keycloak-ca.crt
EOSCRIPT

        # Create recovery config file
        cat > /tmp/recovery.hcl << 'EOHCL'
kms "aead" {
  purpose = "recovery"
  aead_type = "aes-gcm"
  key = "$RECOVERY_KEY"
  key_id = "global_recovery"
}
EOHCL
        # Substitute actual recovery key
        sed -i '' "s/\$RECOVERY_KEY/$RECOVERY_KEY/" /tmp/recovery.hcl

        # Copy cert, recovery config, and script to pod, then execute
        echo "$CA_CERT_CONTENT" | kubectl exec -i -n "$BOUNDARY_NAMESPACE" "$CONTROLLER_POD" -c boundary-controller -- tee /tmp/keycloak-ca.crt > /dev/null
        kubectl cp /tmp/recovery.hcl "$BOUNDARY_NAMESPACE/$CONTROLLER_POD:/tmp/recovery.hcl" -c boundary-controller
        kubectl cp /tmp/boundary_create.sh "$BOUNDARY_NAMESPACE/$CONTROLLER_POD:/tmp/boundary_create.sh" -c boundary-controller
        AUTH_RESULT=$(kubectl exec -n "$BOUNDARY_NAMESPACE" "$CONTROLLER_POD" -c boundary-controller -- /bin/ash /tmp/boundary_create.sh 2>&1 || echo "{}")
        rm -f /tmp/boundary_create.sh /tmp/recovery.hcl
    fi

    # Filter out deprecation warnings before parsing JSON
    AUTH_METHOD_ID=$(echo "$AUTH_RESULT" | grep -E '^\{' | jq -r '.item.id // empty' 2>/dev/null)
    if [[ -z "$AUTH_METHOD_ID" ]]; then
        echo "❌ Failed to create OIDC auth method"
        echo "$AUTH_RESULT"
        exit 1
    fi
    echo "✅ Created OIDC auth method: keycloak ($AUTH_METHOD_ID)"

    # Configure claims scopes
    # Note: "groups" is NOT a standard OIDC scope - groups are included via Keycloak mapper
    # Only request standard scopes that Keycloak supports
    echo "Configuring claims scopes..."
    run_boundary auth-methods update oidc \
        -id="$AUTH_METHOD_ID" \
        -claims-scopes="profile" \
        -claims-scopes="email" \
        2>/dev/null || true
    echo "✅ Configured claims scopes (profile, email)"

    # Activate the OIDC auth method (make it public)
    echo "Activating OIDC auth method..."
    ACTIVATE_RESULT=$(run_boundary auth-methods change-state oidc \
        -id="$AUTH_METHOD_ID" \
        -state=active-public \
        -format=json 2>&1 || echo "{}")

    ACTIVE_STATE=$(echo "$ACTIVATE_RESULT" | grep -E '^\{' | jq -r '.item.attributes.state // empty' 2>/dev/null)
    if [[ "$ACTIVE_STATE" == "active-public" ]]; then
        echo "✅ OIDC auth method activated"
    else
        echo "⚠️  Failed to activate OIDC auth method"
        echo "   You may need to activate manually:"
        echo "   boundary auth-methods change-state oidc -id=$AUTH_METHOD_ID -state=active-public"
        echo ""
        echo "   Error: $ACTIVATE_RESULT"
    fi
fi

# Set OIDC auth method as primary for the scope (enables auto-user creation)
echo "Setting OIDC auth method as primary for the scope..."
if [[ -n "$AUTH_TOKEN" ]]; then
    PRIMARY_RESULT=$(kubectl exec -n "$BOUNDARY_NAMESPACE" "$CONTROLLER_POD" -c boundary-controller -- \
        /bin/ash -c "
            export BOUNDARY_ADDR=http://127.0.0.1:9200
            export BOUNDARY_TOKEN='$AUTH_TOKEN'
            boundary scopes update -id='$ORG_ID' -primary-auth-method-id='$AUTH_METHOD_ID' -format=json
        " 2>&1 || echo "{}")
else
    PRIMARY_RESULT=$(kubectl exec -n "$BOUNDARY_NAMESPACE" "$CONTROLLER_POD" -c boundary-controller -- \
        /bin/ash -c "
            export BOUNDARY_ADDR=http://127.0.0.1:9200
            cat > /tmp/recovery.hcl << 'RECEOF'
kms \"aead\" {
  purpose = \"recovery\"
  aead_type = \"aes-gcm\"
  key = \"$RECOVERY_KEY\"
  key_id = \"global_recovery\"
}
RECEOF
            boundary scopes update -id='$ORG_ID' -primary-auth-method-id='$AUTH_METHOD_ID' -recovery-config=/tmp/recovery.hcl -format=json
            rm -f /tmp/recovery.hcl
        " 2>&1 || echo "{}")
fi

PRIMARY_ID=$(echo "$PRIMARY_RESULT" | grep -E '^\{' | jq -r '.item.primary_auth_method_id // empty' 2>/dev/null)
if [[ "$PRIMARY_ID" == "$AUTH_METHOD_ID" ]]; then
    echo "✅ OIDC auth method set as primary (enables auto-user creation)"
else
    echo "⚠️  Could not set OIDC as primary auth method"
    echo "   Users may need to be pre-created manually"
    echo "   To fix, run: boundary scopes update -id=$ORG_ID -primary-auth-method-id=$AUTH_METHOD_ID"
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

1. Keycloak client configuration (auto-configured by this script):
   - Realm: $KEYCLOAK_REALM
   - Client ID: $KEYCLOAK_CLIENT_ID
   - Client Protocol: openid-connect
   - Access Type: confidential
   - Valid Redirect URIs:
     * https://boundary.local/v1/auth-methods/oidc:authenticate:callback (via ingress)
     * http://127.0.0.1:9200/v1/auth-methods/oidc:authenticate:callback (port-forward)
     * http://localhost:9200/v1/auth-methods/oidc:authenticate:callback (port-forward)

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
