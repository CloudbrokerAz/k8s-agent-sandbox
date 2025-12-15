#!/bin/bash
set -euo pipefail

# ==========================================
# Boundary OIDC Configuration - Fixed
# ==========================================

BOUNDARY_NAMESPACE="${1:-boundary}"
KEYCLOAK_NAMESPACE="${2:-keycloak}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
K8S_DIR="$(dirname "$(dirname "$(dirname "$SCRIPT_DIR")")")"

# Source configuration if available
if [[ -f "$K8S_DIR/scripts/.env" ]]; then
    source "$K8S_DIR/scripts/.env"
fi

# ------------------------------------
# Configuration Variables
# ------------------------------------
KEYCLOAK_EXTERNAL_URL="https://keycloak.hashicorp.lab"
KEYCLOAK_REALM="agent-sandbox"
KEYCLOAK_CLIENT_ID="boundary"
OIDC_ISSUER="${KEYCLOAK_EXTERNAL_URL}/realms/${KEYCLOAK_REALM}"
BOUNDARY_EXTERNAL_URL="https://boundary.hashicorp.lab"

# ------------------------------------
# Helper: Logging
# ------------------------------------
log_info() { echo "ℹ️  $1"; }
log_success() { echo "✅ $1"; }
log_warn() { echo "⚠️  $1"; }
log_error() { echo "❌ $1"; }

# ------------------------------------
# 1. Pre-flight Checks
# ------------------------------------
log_info "Checking Keycloak status..."
# Wait for Keycloak to be ready specifically
kubectl wait --for=condition=Ready pod -l app=keycloak -n "$KEYCLOAK_NAMESPACE" --timeout=60s >/dev/null 2>&1 || {
    log_error "Keycloak pods are not ready."
    exit 1
}
log_success "Keycloak is running"

log_info "Checking Boundary Controller status..."
CONTROLLER_POD=$(kubectl get pod -l app=boundary-controller -n "$BOUNDARY_NAMESPACE" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
if [[ -z "$CONTROLLER_POD" ]]; then
    log_error "Boundary controller pod not found."
    exit 1
fi
log_success "Boundary controller found: $CONTROLLER_POD"

# ------------------------------------
# 2. Authentication (Get Token)
# ------------------------------------
AUTH_TOKEN=""
RECOVERY_KEY=""

# Try credentials file first
CREDS_FILE="$SCRIPT_DIR/boundary-credentials.txt"
if [[ -f "$CREDS_FILE" ]]; then
    ADMIN_PASSWORD=$(grep "Password:" "$CREDS_FILE" | head -n 1 | awk '{print $2}')
    if [[ -n "$ADMIN_PASSWORD" ]]; then
        log_info "Attempting authentication via Admin Password..."
        AUTH_TOKEN=$(kubectl exec -n "$BOUNDARY_NAMESPACE" "$CONTROLLER_POD" -c boundary-controller -- /bin/ash -c "
            export BOUNDARY_ADDR=http://127.0.0.1:9200
            boundary authenticate password -login-name=admin -password='$ADMIN_PASSWORD' -format=json
        " 2>/dev/null | jq -r '.item.attributes.token // empty')
    fi
fi

# Fallback to Recovery Key if Token failed
if [[ -z "$AUTH_TOKEN" ]]; then
    log_warn "Standard auth failed or missing. Fetching Recovery Key..."
    RECOVERY_KEY=$(kubectl get secret boundary-kms-keys -n "$BOUNDARY_NAMESPACE" -o jsonpath='{.data.BOUNDARY_RECOVERY_KEY}' | base64 -d)
    if [[ -z "$RECOVERY_KEY" ]]; then
        log_error "Critical: Cannot auth with password AND cannot find recovery key."
        exit 1
    fi
    log_success "Using Recovery Key for operations."
else
    log_success "Authenticated successfully with Admin Token."
fi

# ------------------------------------
# 3. Helper: Run Boundary Command
# ------------------------------------
# Solves Quoting Hell: Instead of passing args via shell, we construct the command
# inside a temporary script in the pod.
run_boundary_cmd() {
    local cmd="$1"
    local use_recovery="${2:-false}"
    
    # Create the script content locally
    cat <<EOF > /tmp/boundary_exec.sh
#!/bin/ash
set -e
export BOUNDARY_ADDR=http://127.0.0.1:9200
export BOUNDARY_TOKEN='$AUTH_TOKEN'

# If using recovery key, create the HCL config
if [ "$use_recovery" = "true" ]; then
    cat > /tmp/recovery.hcl <<HCL
kms "aead" {
  purpose   = "recovery"
  aead_type = "aes-gcm"
  key       = "$RECOVERY_KEY"
  key_id    = "global_recovery"
}
HCL
    # Append recovery flag to command
    CMD_TO_RUN="$cmd -recovery-kms-hcl=file:///tmp/recovery.hcl"
else
    CMD_TO_RUN="$cmd"
fi

# Execute
eval "\$CMD_TO_RUN"
rm -f /tmp/recovery.hcl
EOF

    # Copy script to pod
    kubectl cp /tmp/boundary_exec.sh "${BOUNDARY_NAMESPACE}/${CONTROLLER_POD}:/tmp/boundary_exec.sh" -c boundary-controller >/dev/null
    
    # Execute script
    kubectl exec -n "$BOUNDARY_NAMESPACE" "$CONTROLLER_POD" -c boundary-controller -- /bin/ash -c "chmod +x /tmp/boundary_exec.sh && /tmp/boundary_exec.sh"
    
    # Cleanup local
    rm -f /tmp/boundary_exec.sh
}

# ------------------------------------
# 4. Keycloak Client & Secret Management
# ------------------------------------
get_keycloak_client_secret() {
    local KEYCLOAK_LOCAL_PORT=18080
    local PF_PID=""
    
    # Cleanup logic
    cleanup() {
        if [[ -n "$PF_PID" ]]; then kill $PF_PID 2>/dev/null || true; fi
    }
    trap cleanup EXIT

    log_info "Port-forwarding Keycloak to localhost:$KEYCLOAK_LOCAL_PORT..."
    kubectl port-forward -n "$KEYCLOAK_NAMESPACE" svc/keycloak ${KEYCLOAK_LOCAL_PORT}:8080 >/dev/null 2>&1 &
    PF_PID=$!

    # Wait for port forward
    local attempts=0
    while ! curl -s "http://localhost:${KEYCLOAK_LOCAL_PORT}/health/ready" >/dev/null 2>&1; do
        sleep 0.5
        attempts=$((attempts + 1))
        if [[ $attempts -ge 20 ]]; then
            # check if process died
            if ! kill -0 $PF_PID 2>/dev/null; then
                 log_error "Port forward failed immediately. Port $KEYCLOAK_LOCAL_PORT might be in use."
                 return 1
            fi
            log_error "Timeout waiting for Keycloak API."
            return 1
        fi
    done

    # Get Admin Token
    local ADMIN_USER ADMIN_PASS
    ADMIN_USER=$(kubectl get secret keycloak-admin -n "$KEYCLOAK_NAMESPACE" -o jsonpath='{.data.KEYCLOAK_ADMIN}' | base64 -d)
    ADMIN_PASS=$(kubectl get secret keycloak-admin -n "$KEYCLOAK_NAMESPACE" -o jsonpath='{.data.KEYCLOAK_ADMIN_PASSWORD}' | base64 -d)

    local ADMIN_TOKEN
    ADMIN_TOKEN=$(curl -s -X POST "http://localhost:${KEYCLOAK_LOCAL_PORT}/realms/master/protocol/openid-connect/token" \
        -H "Content-Type: application/x-www-form-urlencoded" \
        -d "username=${ADMIN_USER}" -d "password=${ADMIN_PASS}" -d "grant_type=password" -d "client_id=admin-cli" | jq -r '.access_token')

    if [[ -z "$ADMIN_TOKEN" || "$ADMIN_TOKEN" == "null" ]]; then
        log_error "Failed to get Keycloak Admin Token."
        return 1
    fi

    # Check/Create Client
    local CLIENT_ID_INTERNAL
    CLIENT_ID_INTERNAL=$(curl -s -H "Authorization: Bearer $ADMIN_TOKEN" \
        "http://localhost:${KEYCLOAK_LOCAL_PORT}/admin/realms/${KEYCLOAK_REALM}/clients?clientId=${KEYCLOAK_CLIENT_ID}" | jq -r '.[0].id // empty')

    if [[ -z "$CLIENT_ID_INTERNAL" ]]; then
        log_info "Creating Boundary client in Keycloak..."
        curl -s -X POST "http://localhost:${KEYCLOAK_LOCAL_PORT}/admin/realms/${KEYCLOAK_REALM}/clients" \
            -H "Authorization: Bearer $ADMIN_TOKEN" -H "Content-Type: application/json" \
            -d '{
                "clientId": "'"${KEYCLOAK_CLIENT_ID}"'",
                "name": "Boundary",
                "protocol": "openid-connect",
                "enabled": true,
                "publicClient": false,
                "clientAuthenticatorType": "client-secret",
                "standardFlowEnabled": true,
                "directAccessGrantsEnabled": false,
                "serviceAccountsEnabled": false,
                "redirectUris": [
                    "https://boundary.hashicorp.lab/v1/auth-methods/oidc:authenticate:callback",
                    "http://127.0.0.1:9200/v1/auth-methods/oidc:authenticate:callback",
                    "http://localhost:9200/v1/auth-methods/oidc:authenticate:callback"
                ],
                "webOrigins": ["*"],
                "defaultClientScopes": ["openid", "profile", "email"]
            }' >/dev/null

        # Fetch ID again
        CLIENT_ID_INTERNAL=$(curl -s -H "Authorization: Bearer $ADMIN_TOKEN" \
            "http://localhost:${KEYCLOAK_LOCAL_PORT}/admin/realms/${KEYCLOAK_REALM}/clients?clientId=${KEYCLOAK_CLIENT_ID}" | jq -r '.[0].id // empty')
        
        # Add Groups Mapper
        log_info "Adding groups mapper..."
        curl -s -X POST "http://localhost:${KEYCLOAK_LOCAL_PORT}/admin/realms/${KEYCLOAK_REALM}/clients/${CLIENT_ID_INTERNAL}/protocol-mappers/models" \
            -H "Authorization: Bearer $ADMIN_TOKEN" -H "Content-Type: application/json" \
            -d '{
                "name": "groups", "protocol": "openid-connect", "protocolMapper": "oidc-group-membership-mapper",
                "consentRequired": false, "config": { "full.path": "false", "id.token.claim": "true", "access.token.claim": "true", "claim.name": "groups", "userinfo.token.claim": "true" }
            }' >/dev/null
    fi

    # ALWAYS fetch the secret from Keycloak (The Truth)
    local CLIENT_SECRET
    CLIENT_SECRET=$(curl -s -H "Authorization: Bearer $ADMIN_TOKEN" \
        "http://localhost:${KEYCLOAK_LOCAL_PORT}/admin/realms/${KEYCLOAK_REALM}/clients/${CLIENT_ID_INTERNAL}/client-secret" | jq -r '.value')

    echo "$CLIENT_SECRET"
    trap - EXIT
    kill $PF_PID 2>/dev/null || true
}

# ------------------------------------
# 5. Core Logic
# ------------------------------------

log_info "Fetching/Verifying Keycloak Client Secret..."
KEYCLOAK_CLIENT_SECRET=$(get_keycloak_client_secret)

if [[ -z "$KEYCLOAK_CLIENT_SECRET" ]]; then
    log_error "Failed to retrieve Client Secret from Keycloak."
    exit 1
fi

# Update K8s secret to match Keycloak (Sync Truth)
kubectl create secret generic boundary-oidc-client-secret --namespace="$KEYCLOAK_NAMESPACE" \
    --from-literal=client-secret="$KEYCLOAK_CLIENT_SECRET" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null

# Get IDs
ORG_ID=$(run_boundary_cmd "boundary scopes list -format=json" "${RECOVERY_KEY:+true}" | jq -r '.items[]? | select(.name=="DevOps") | .id')
if [[ -z "$ORG_ID" ]]; then log_error "DevOps Org not found."; exit 1; fi

PROJECT_ID=$(run_boundary_cmd "boundary scopes list -scope-id=$ORG_ID -format=json" "${RECOVERY_KEY:+true}" | jq -r '.items[]? | select(.name=="Agent-Sandbox") | .id')

# Prepare files for Boundary Pod
# We do this to avoid quoting issues with certificates and secrets
log_info "Preparing configuration inside Boundary pod..."
CA_CERT_CONTENT=$(kubectl get secret keycloak-tls -n "$KEYCLOAK_NAMESPACE" -o jsonpath='{.data.tls\.crt}' | base64 -d)

# Write Secret and Cert to pod safely
cat <<EOF > /tmp/boundary_files_setup.sh
echo "$KEYCLOAK_CLIENT_SECRET" > /tmp/client_secret.txt
cat <<CERT > /tmp/keycloak-ca.crt
$CA_CERT_CONTENT
CERT
EOF
kubectl cp /tmp/boundary_files_setup.sh "${BOUNDARY_NAMESPACE}/${CONTROLLER_POD}:/tmp/boundary_files_setup.sh" -c boundary-controller
kubectl exec -n "$BOUNDARY_NAMESPACE" "$CONTROLLER_POD" -c boundary-controller -- /bin/ash -c "chmod +x /tmp/boundary_files_setup.sh && /tmp/boundary_files_setup.sh"


# Check Existing Auth Method
EXISTING_OIDC=$(run_boundary_cmd "boundary auth-methods list -scope-id=$ORG_ID -format=json" "${RECOVERY_KEY:+true}" | jq -r '.items[]? | select(.type=="oidc") | .id')

if [[ -n "$EXISTING_OIDC" ]]; then
    log_info "Updating existing OIDC Auth Method: $EXISTING_OIDC"
    # Note: We update Issuer/Client-ID here too, to ensure sync if vars changed
    run_boundary_cmd "boundary auth-methods update oidc \
        -id=$EXISTING_OIDC \
        -issuer=$OIDC_ISSUER \
        -client-id=$KEYCLOAK_CLIENT_ID \
        -client-secret=file:///tmp/client_secret.txt \
        -idp-ca-cert=file:///tmp/keycloak-ca.crt \
        -api-url-prefix=$BOUNDARY_EXTERNAL_URL" "${RECOVERY_KEY:+true}" >/dev/null
    AUTH_METHOD_ID="$EXISTING_OIDC"
else
    log_info "Creating new OIDC Auth Method..."
    AUTH_RESULT=$(run_boundary_cmd "boundary auth-methods create oidc \
        -name=keycloak \
        -scope-id=$ORG_ID \
        -issuer=$OIDC_ISSUER \
        -client-id=$KEYCLOAK_CLIENT_ID \
        -client-secret=file:///tmp/client_secret.txt \
        -idp-ca-cert=file:///tmp/keycloak-ca.crt \
        -signing-algorithm=RS256 \
        -api-url-prefix=$BOUNDARY_EXTERNAL_URL \
        -claims-scopes=profile \
        -claims-scopes=email \
        -is-primary-for-scope=true \
        -state=active-public \
        -format=json" "${RECOVERY_KEY:+true}")
    AUTH_METHOD_ID=$(echo "$AUTH_RESULT" | jq -r '.item.id')
fi

log_success "Auth Method Configured: $AUTH_METHOD_ID"

# ------------------------------------
# 6. Managed Groups (Wait loop added)
# ------------------------------------
# We loop to retry creation because sometimes after auth method update, it takes a ms to register
create_managed_group() {
    local NAME=$1
    local FILTER=$2
    
    # Check existence
    local G_ID
    G_ID=$(run_boundary_cmd "boundary managed-groups list -auth-method-id=$AUTH_METHOD_ID -format=json" "${RECOVERY_KEY:+true}" | jq -r ".items[]? | select(.name==\"$NAME\") | .id")
    
    if [[ -z "$G_ID" ]]; then
        # Note the escaping of the FILTER here. Since we are passing this to our helper function
        # which puts it into a heredoc, we just need to ensure internal quotes are escaped for the HCL/CLI
        log_info "Creating Group: $NAME"
        
        # Use single quotes for the command string to protect the double quotes in filter
        G_ID=$(run_boundary_cmd "boundary managed-groups create oidc -name=$NAME -auth-method-id=$AUTH_METHOD_ID -filter='$FILTER' -format=json" "${RECOVERY_KEY:+true}" | jq -r '.item.id')
    else
        log_success "Group $NAME exists ($G_ID)"
    fi
    echo "$G_ID"
}

# The filters must be carefully constructed
# Boundary expects: "/token/groups" contains "admins"
ADMIN_GID=$(create_managed_group "keycloak-admins" '"/token/groups" contains "admins"')
DEV_GID=$(create_managed_group "keycloak-developers" '"/token/groups" contains "developers"')

# ------------------------------------
# 7. Roles (Simplified)
# ------------------------------------
create_role_if_missing() {
    local R_NAME=$1
    local MG_ID=$2
    local GRANTS=$3
    
    if [[ -z "$MG_ID" ]]; then return; fi

    local R_ID
    R_ID=$(run_boundary_cmd "boundary roles list -scope-id=$PROJECT_ID -format=json" "${RECOVERY_KEY:+true}" | jq -r ".items[]? | select(.name==\"$R_NAME\") | .id")

    if [[ -z "$R_ID" ]]; then
        log_info "Creating Role: $R_NAME"
        R_ID=$(run_boundary_cmd "boundary roles create -name=$R_NAME -scope-id=$PROJECT_ID -format=json" "${RECOVERY_KEY:+true}" | jq -r '.item.id')
        
        run_boundary_cmd "boundary roles add-principals -id=$R_ID -principal=$MG_ID" "${RECOVERY_KEY:+true}" >/dev/null
        run_boundary_cmd "boundary roles add-grants -id=$R_ID -grant='$GRANTS'" "${RECOVERY_KEY:+true}" >/dev/null
    fi
}

create_role_if_missing "oidc-admins" "$ADMIN_GID" "ids=*;type=*;actions=*"
create_role_if_missing "oidc-developers" "$DEV_GID" "ids=*;type=target;actions=read,authorize-session"

# Cleanup Pod Files
kubectl exec -n "$BOUNDARY_NAMESPACE" "$CONTROLLER_POD" -c boundary-controller -- rm -f /tmp/client_secret.txt /tmp/keycloak-ca.crt /tmp/boundary_files_setup.sh

log_success "Configuration Complete."