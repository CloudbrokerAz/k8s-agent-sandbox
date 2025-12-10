#!/bin/bash
set -euo pipefail

# Post-deployment healthcheck script
# Verifies all platform components are online and functioning

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
K8S_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")"

# Source configuration (look in parent scripts directory)
if [[ -f "$SCRIPT_DIR/../.env" ]]; then
    source "$SCRIPT_DIR/../.env"
elif [[ -f "$SCRIPT_DIR/../platform.env.example" ]]; then
    source "$SCRIPT_DIR/../platform.env.example"
fi

# Defaults
DEVENV_NAMESPACE="${DEVENV_NAMESPACE:-devenv}"
VAULT_NAMESPACE="${VAULT_NAMESPACE:-vault}"
BOUNDARY_NAMESPACE="${BOUNDARY_NAMESPACE:-boundary}"
VSO_NAMESPACE="${VSO_NAMESPACE:-vault-secrets-operator-system}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

PASSED=0
FAILED=0
WARNINGS=0

check_pass() {
    echo -e "${GREEN}✅ PASS${NC}: $1"
    PASSED=$((PASSED + 1))
}

check_fail() {
    echo -e "${RED}❌ FAIL${NC}: $1"
    FAILED=$((FAILED + 1))
}

check_warn() {
    echo -e "${YELLOW}⚠️  WARN${NC}: $1"
    WARNINGS=$((WARNINGS + 1))
}

check_info() {
    echo -e "${BLUE}ℹ️  INFO${NC}: $1"
}

echo "=========================================="
echo "  Agent Sandbox Platform Healthcheck"
echo "=========================================="
echo ""
echo "Checking all platform components..."
echo ""

# ==========================================
# Kubernetes Connectivity
# ==========================================
echo "--- Kubernetes Cluster ---"
if kubectl cluster-info &>/dev/null; then
    check_pass "Kubernetes cluster reachable"
else
    check_fail "Cannot connect to Kubernetes cluster"
    echo "Healthcheck aborted - no cluster connection"
    exit 1
fi

# ==========================================
# Agent Sandbox (DevEnv)
# ==========================================
echo ""
echo "--- Agent Sandbox (DevEnv) ---"

# Check namespace
if kubectl get namespace "$DEVENV_NAMESPACE" &>/dev/null; then
    check_pass "Namespace '$DEVENV_NAMESPACE' exists"
else
    check_fail "Namespace '$DEVENV_NAMESPACE' does not exist"
fi

# Check Sandbox CR (kubernetes-sigs/agent-sandbox pattern)
SANDBOX_NAME="claude-code-sandbox"
if kubectl get sandbox "$SANDBOX_NAME" -n "$DEVENV_NAMESPACE" &>/dev/null; then
    check_pass "Sandbox CR '$SANDBOX_NAME' exists"
else
    check_fail "Sandbox CR '$SANDBOX_NAME' not found"
fi

# Check Sandbox pod is running
SANDBOX_POD_STATUS=$(kubectl get pod "$SANDBOX_NAME" -n "$DEVENV_NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo "NotFound")
if [[ "$SANDBOX_POD_STATUS" == "Running" ]]; then
    check_pass "Sandbox pod '$SANDBOX_NAME' running"
else
    check_fail "Sandbox pod status: $SANDBOX_POD_STATUS"
fi

# Check Claude Code installation (npm global bin may not be in PATH for kubectl exec)
CLAUDE_BIN="/usr/local/share/npm-global/bin/claude"
if kubectl exec -n "$DEVENV_NAMESPACE" "$SANDBOX_NAME" -- test -x "$CLAUDE_BIN" &>/dev/null; then
    CLAUDE_VERSION=$(kubectl exec -n "$DEVENV_NAMESPACE" "$SANDBOX_NAME" -- "$CLAUDE_BIN" --version 2>/dev/null || echo "unknown")
    check_pass "Claude Code installed ($CLAUDE_VERSION)"
elif kubectl exec -n "$DEVENV_NAMESPACE" "$SANDBOX_NAME" -- which claude &>/dev/null; then
    CLAUDE_VERSION=$(kubectl exec -n "$DEVENV_NAMESPACE" "$SANDBOX_NAME" -- claude --version 2>/dev/null || echo "unknown")
    check_pass "Claude Code installed ($CLAUDE_VERSION)"
else
    check_warn "Claude Code not found (install with: npm install -g @anthropic-ai/claude-code)"
fi

# Check Terraform installation
if kubectl exec -n "$DEVENV_NAMESPACE" "$SANDBOX_NAME" -- terraform version &>/dev/null; then
    TF_VERSION=$(kubectl exec -n "$DEVENV_NAMESPACE" "$SANDBOX_NAME" -- terraform version -json 2>/dev/null | jq -r '.terraform_version' || echo "unknown")
    check_pass "Terraform installed ($TF_VERSION)"
else
    check_warn "Terraform not found"
fi

# Check environment variables
if kubectl exec -n "$DEVENV_NAMESPACE" "$SANDBOX_NAME" -- printenv TFE_TOKEN &>/dev/null; then
    check_pass "TFE_TOKEN environment variable set"
else
    check_warn "TFE_TOKEN not set (run configure-tfe-engine.sh)"
fi

# Check GITHUB_TOKEN from VSO
GH_TOKEN=$(kubectl exec -n "$DEVENV_NAMESPACE" "$SANDBOX_NAME" -- printenv GITHUB_TOKEN 2>/dev/null || echo "")
if [[ -n "$GH_TOKEN" ]] && [[ "$GH_TOKEN" != "placeholder-update-me" ]]; then
    check_pass "GITHUB_TOKEN set from Vault"
elif [[ "$GH_TOKEN" == "placeholder-update-me" ]]; then
    check_warn "GITHUB_TOKEN is placeholder (run configure-secrets.sh)"
else
    check_warn "GITHUB_TOKEN not set (run configure-secrets.sh)"
fi

# ==========================================
# Vault
# ==========================================
echo ""
echo "--- HashiCorp Vault ---"

# Check namespace
if kubectl get namespace "$VAULT_NAMESPACE" &>/dev/null; then
    check_pass "Namespace '$VAULT_NAMESPACE' exists"
else
    check_fail "Namespace '$VAULT_NAMESPACE' does not exist"
fi

# Check pod status
VAULT_STATUS=$(kubectl get pod vault-0 -n "$VAULT_NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo "NotFound")
if [[ "$VAULT_STATUS" == "Running" ]]; then
    check_pass "Vault pod running"
else
    check_fail "Vault pod status: $VAULT_STATUS"
fi

# Check Vault sealed/unsealed status
VAULT_STATUS_JSON=$(kubectl exec -n "$VAULT_NAMESPACE" vault-0 -- vault status -format=json 2>&1) || true
if echo "$VAULT_STATUS_JSON" | jq -e . >/dev/null 2>&1; then
    VAULT_INITIALIZED=$(echo "$VAULT_STATUS_JSON" | jq -r '.initialized // false')
    # Note: Cannot use '.sealed // true' because jq's // operator treats false as falsy
    VAULT_SEALED=$(echo "$VAULT_STATUS_JSON" | jq -r 'if .sealed == null then true else .sealed end')

    if [[ "$VAULT_INITIALIZED" == "false" ]]; then
        check_fail "Vault not initialized (run: ./platform/vault/scripts/init-vault.sh or re-run deploy-all.sh)"
    elif [[ "$VAULT_SEALED" == "false" ]]; then
        check_pass "Vault unsealed and ready"
    else
        check_fail "Vault is sealed (run: ./platform/vault/scripts/unseal-vault.sh)"
    fi
else
    check_fail "Vault not responding (status: $VAULT_STATUS)"
fi

# Check secrets engines
VAULT_KEYS_FILE="$K8S_DIR/platform/vault/scripts/vault-keys.txt"
if [[ -f "$VAULT_KEYS_FILE" ]]; then
    VAULT_TOKEN=$(grep "Root Token:" "$VAULT_KEYS_FILE" 2>/dev/null | awk '{print $3}' || echo "")
else
    VAULT_TOKEN=""
    check_warn "Vault keys file not found (Vault not initialized)"
fi

if [[ -n "$VAULT_TOKEN" ]]; then
    # Check KV engine
    if kubectl exec -n "$VAULT_NAMESPACE" vault-0 -- sh -c "VAULT_TOKEN='$VAULT_TOKEN' vault secrets list" 2>/dev/null | grep -q "secret/"; then
        check_pass "KV secrets engine enabled"
    else
        check_warn "KV secrets engine not configured"
    fi

    # Check SSH engine
    if kubectl exec -n "$VAULT_NAMESPACE" vault-0 -- sh -c "VAULT_TOKEN='$VAULT_TOKEN' vault secrets list" 2>/dev/null | grep -q "ssh/"; then
        check_pass "SSH secrets engine enabled"
    else
        check_warn "SSH secrets engine not configured (run configure-ssh-engine.sh)"
    fi

    # Check Terraform engine (optional - for dynamic token rotation)
    if kubectl exec -n "$VAULT_NAMESPACE" vault-0 -- sh -c "VAULT_TOKEN='$VAULT_TOKEN' vault secrets list" 2>/dev/null | grep -q "terraform/"; then
        check_pass "Terraform secrets engine enabled (dynamic tokens)"
    else
        check_info "Terraform secrets engine not configured (optional - static TFE_TOKEN used via KV)"
    fi
else
    check_warn "Cannot check secrets engines - no Vault token found"
fi

# ==========================================
# Boundary
# ==========================================
echo ""
echo "--- HashiCorp Boundary ---"

# Check namespace
if kubectl get namespace "$BOUNDARY_NAMESPACE" &>/dev/null; then
    check_pass "Namespace '$BOUNDARY_NAMESPACE' exists"
else
    check_warn "Namespace '$BOUNDARY_NAMESPACE' does not exist (Boundary optional)"
fi

# Check controller
BOUNDARY_CTRL_STATUS=$(kubectl get pod -l app=boundary-controller -n "$BOUNDARY_NAMESPACE" -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "NotFound")
if [[ "$BOUNDARY_CTRL_STATUS" == "Running" ]]; then
    check_pass "Boundary controller running"
elif [[ "$BOUNDARY_CTRL_STATUS" == "NotFound" ]]; then
    check_warn "Boundary controller not deployed"
else
    check_fail "Boundary controller status: $BOUNDARY_CTRL_STATUS"
fi

# Check worker
BOUNDARY_WORKER_STATUS=$(kubectl get pod -l app=boundary-worker -n "$BOUNDARY_NAMESPACE" -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "NotFound")
if [[ "$BOUNDARY_WORKER_STATUS" == "Running" ]]; then
    check_pass "Boundary worker running"
elif [[ "$BOUNDARY_WORKER_STATUS" == "NotFound" ]]; then
    check_warn "Boundary worker not deployed"
else
    check_fail "Boundary worker status: $BOUNDARY_WORKER_STATUS"
fi

# Check OIDC auth method if Boundary is running
if [[ "$BOUNDARY_CTRL_STATUS" == "Running" ]]; then
    RECOVERY_KEY=$(kubectl get secret boundary-kms-keys -n "$BOUNDARY_NAMESPACE" -o jsonpath='{.data.BOUNDARY_RECOVERY_KEY}' 2>/dev/null | base64 -d || echo "")
    CONTROLLER_POD=$(kubectl get pod -l app=boundary-controller -n "$BOUNDARY_NAMESPACE" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

    if [[ -n "$RECOVERY_KEY" ]] && [[ -n "$CONTROLLER_POD" ]]; then
        # Get org scope ID
        ORG_ID=$(kubectl exec -n "$BOUNDARY_NAMESPACE" "$CONTROLLER_POD" -- \
            env BOUNDARY_ADDR=http://127.0.0.1:9200 \
            boundary scopes list -format=json \
            -recovery-kms-hcl="kms \"aead\" { purpose = \"recovery\"; aead_type = \"aes-gcm\"; key = \"$RECOVERY_KEY\"; key_id = \"global_recovery\" }" 2>/dev/null | \
            jq -r '.items[] | select(.name=="DevOps") | .id' 2>/dev/null || echo "")

        if [[ -n "$ORG_ID" ]]; then
            # Check for OIDC auth method
            OIDC_AUTH=$(kubectl exec -n "$BOUNDARY_NAMESPACE" "$CONTROLLER_POD" -- \
                env BOUNDARY_ADDR=http://127.0.0.1:9200 \
                boundary auth-methods list -scope-id="$ORG_ID" -format=json \
                -recovery-kms-hcl="kms \"aead\" { purpose = \"recovery\"; aead_type = \"aes-gcm\"; key = \"$RECOVERY_KEY\"; key_id = \"global_recovery\" }" 2>/dev/null | \
                jq -r '.items[] | select(.type=="oidc") | .id' 2>/dev/null || echo "")

            if [[ -n "$OIDC_AUTH" ]]; then
                check_pass "Boundary OIDC auth method configured"

                # Check managed groups
                MANAGED_GROUPS=$(kubectl exec -n "$BOUNDARY_NAMESPACE" "$CONTROLLER_POD" -- \
                    env BOUNDARY_ADDR=http://127.0.0.1:9200 \
                    boundary managed-groups list -auth-method-id="$OIDC_AUTH" -format=json \
                    -recovery-kms-hcl="kms \"aead\" { purpose = \"recovery\"; aead_type = \"aes-gcm\"; key = \"$RECOVERY_KEY\"; key_id = \"global_recovery\" }" 2>/dev/null | \
                    jq -r '.items | length' 2>/dev/null || echo "0")

                if [[ "$MANAGED_GROUPS" -ge 3 ]]; then
                    check_pass "Boundary managed groups configured ($MANAGED_GROUPS groups)"
                else
                    check_warn "Boundary managed groups incomplete (found $MANAGED_GROUPS, expected 3)"
                fi
            else
                check_warn "Boundary OIDC auth not configured (run configure-oidc-auth.sh)"
            fi
        fi
    fi
fi

# ==========================================
# Boundary Configuration
# ==========================================
echo ""
echo "--- Boundary Configuration ---"

BOUNDARY_CREDS_FILE="$K8S_DIR/platform/boundary/scripts/boundary-credentials.txt"

# Check if Boundary configuration exists
if [[ -f "$BOUNDARY_CREDS_FILE" ]]; then
    # Read configuration IDs from credentials file
    BOUNDARY_ORG_ID=$(grep "Organization:" "$BOUNDARY_CREDS_FILE" 2>/dev/null | awk '{print $2}' || echo "")
    BOUNDARY_PROJECT_ID=$(grep "Project:" "$BOUNDARY_CREDS_FILE" 2>/dev/null | awk '{print $2}' || echo "")
    BOUNDARY_HOST_CATALOG_ID=$(grep "Host Catalog:" "$BOUNDARY_CREDS_FILE" 2>/dev/null | awk '{print $3}' || echo "")
    BOUNDARY_TARGET_ID=$(grep "Target (SSH):" "$BOUNDARY_CREDS_FILE" 2>/dev/null | awk '{print $3}' || echo "")
    BOUNDARY_AUTH_METHOD_ID=$(grep "Auth Method ID:" "$BOUNDARY_CREDS_FILE" 2>/dev/null | awk '{print $4}' || echo "")

    if [[ -n "$BOUNDARY_ORG_ID" ]] && [[ "$BOUNDARY_ORG_ID" != "not" ]]; then
        check_pass "Organization scope configured ($BOUNDARY_ORG_ID)"
    else
        check_info "Organization scope not configured"
    fi

    if [[ -n "$BOUNDARY_PROJECT_ID" ]] && [[ "$BOUNDARY_PROJECT_ID" != "not" ]]; then
        check_pass "Project scope configured ($BOUNDARY_PROJECT_ID)"
    else
        check_info "Project scope not configured"
    fi

    if [[ -n "$BOUNDARY_HOST_CATALOG_ID" ]] && [[ "$BOUNDARY_HOST_CATALOG_ID" != "not" ]]; then
        check_pass "Host catalog configured ($BOUNDARY_HOST_CATALOG_ID)"
    else
        check_info "Host catalog not configured"
    fi

    if [[ -n "$BOUNDARY_TARGET_ID" ]] && [[ "$BOUNDARY_TARGET_ID" != "not" ]]; then
        check_pass "SSH target configured ($BOUNDARY_TARGET_ID)"
    else
        check_info "SSH target not configured"
    fi

    if [[ -n "$BOUNDARY_AUTH_METHOD_ID" ]] && [[ "$BOUNDARY_AUTH_METHOD_ID" != "not" ]]; then
        check_pass "Password auth method configured ($BOUNDARY_AUTH_METHOD_ID)"
    else
        check_info "Password auth method not configured"
    fi
else
    check_info "Boundary not configured (run configure-targets.sh)"
fi

# ==========================================
# Boundary User Tests
# ==========================================
echo ""
echo "--- Boundary User Tests ---"
echo "Note: Tests Boundary authentication and target configuration"

# Only run if Boundary controller is running
if [[ "$BOUNDARY_CTRL_STATUS" == "Running" ]]; then
    CONTROLLER_POD=$(kubectl get pod -l app=boundary-controller -n "$BOUNDARY_NAMESPACE" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

    if [[ -n "$CONTROLLER_POD" ]] && [[ -f "$BOUNDARY_CREDS_FILE" ]]; then
        # Get password auth method ID from credentials file
        AUTH_METHOD_ID=$(grep "Auth Method ID:" "$BOUNDARY_CREDS_FILE" 2>/dev/null | awk '{print $4}' || echo "")
        ADMIN_PASS=$(grep "Password:" "$BOUNDARY_CREDS_FILE" 2>/dev/null | awk '{print $2}' || echo "")

        if [[ -n "$AUTH_METHOD_ID" ]] && [[ -n "$ADMIN_PASS" ]]; then
            # Test admin authentication via password auth method
            # Note: Boundary CLI requires env:// or file:// syntax for password
            # Use /bin/ash -c to run the full command in the container's shell to handle quoting properly
            AUTH_RESULT=$(kubectl exec -n "$BOUNDARY_NAMESPACE" "$CONTROLLER_POD" -c boundary-controller -- \
                /bin/ash -c "export BOUNDARY_ADDR=http://127.0.0.1:9200; export BOUNDARY_PASSWORD='$ADMIN_PASS'; boundary authenticate password -auth-method-id='$AUTH_METHOD_ID' -login-name=admin -password=env://BOUNDARY_PASSWORD -format=json" 2>/dev/null | jq -r '.item.attributes.token // .item.id // empty' 2>/dev/null || echo "")

            if [[ -n "$AUTH_RESULT" ]]; then
                check_pass "Boundary admin authentication"
            else
                check_info "Boundary admin authentication failed (credentials may have changed)"
            fi
        else
            check_info "Boundary credentials not found (run configure-targets.sh)"
        fi
    else
        check_info "Boundary controller pod or credentials not available"
    fi

    # Check Boundary-Keycloak OIDC integration if both are running
    KC_POD_STATUS=$(kubectl get pod -l app=keycloak -n keycloak -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "NotFound")
    if [[ "$KC_POD_STATUS" == "Running" ]]; then
        # Check if boundary client exists in Keycloak
        # Use -s (not -sf) to get JSON error response body on HTTP errors
        KC_BOUNDARY_CLIENT=$(kubectl run -n keycloak oidc-client-check-$RANDOM --rm -i --restart=Never --image=curlimages/curl:latest \
            -- curl -s -X POST "http://keycloak:8080/realms/agent-sandbox/protocol/openid-connect/token" \
                -d "grant_type=client_credentials" \
                -d "client_id=boundary" \
                -d "client_secret=boundary-client-secret-change-me" 2>&1 || echo "")

        # If we get any response (token, unauthorized, invalid_secret, Invalid client credentials), the client exists
        # Note: "Invalid client credentials" means client exists but wrong secret or grant type not allowed
        if echo "$KC_BOUNDARY_CLIENT" | grep -qiE '"access_token"|unauthorized_client|invalid_client_secret|Invalid client credentials|invalid_grant'; then
            check_pass "Keycloak 'boundary' OIDC client exists"
        elif echo "$KC_BOUNDARY_CLIENT" | grep -qi 'Client not found'; then
            check_info "Keycloak 'boundary' client not found (run configure-realm.sh)"
        else
            check_info "Could not verify Keycloak boundary client"
        fi
    fi
else
    check_info "Boundary user tests skipped (controller not running)"
fi

# ==========================================
# Keycloak
# ==========================================
echo ""
echo "--- Keycloak (Identity Provider) ---"

KEYCLOAK_NAMESPACE="${KEYCLOAK_NAMESPACE:-keycloak}"

# Check namespace
if kubectl get namespace "$KEYCLOAK_NAMESPACE" &>/dev/null; then
    check_pass "Namespace '$KEYCLOAK_NAMESPACE' exists"
else
    check_warn "Namespace '$KEYCLOAK_NAMESPACE' does not exist (Keycloak optional)"
fi

# Check Keycloak deployment/pod (uses Deployment, not StatefulSet)
KEYCLOAK_POD=$(kubectl get pod -l app=keycloak -n "$KEYCLOAK_NAMESPACE" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
KEYCLOAK_STATUS=$(kubectl get pod -l app=keycloak -n "$KEYCLOAK_NAMESPACE" -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "NotFound")
if [[ "$KEYCLOAK_STATUS" == "Running" ]]; then
    check_pass "Keycloak pod running"
elif [[ -z "$KEYCLOAK_POD" ]] || [[ "$KEYCLOAK_STATUS" == "NotFound" ]]; then
    check_warn "Keycloak not deployed"
else
    check_fail "Keycloak pod status: $KEYCLOAK_STATUS"
fi

# Check PostgreSQL pod (uses Deployment, not StatefulSet)
POSTGRES_STATUS=$(kubectl get pod -l app=keycloak-postgres -n "$KEYCLOAK_NAMESPACE" -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "NotFound")
if [[ "$POSTGRES_STATUS" == "Running" ]]; then
    check_pass "Keycloak PostgreSQL running"
elif [[ "$POSTGRES_STATUS" == "NotFound" ]]; then
    check_warn "Keycloak PostgreSQL not deployed"
else
    check_fail "Keycloak PostgreSQL status: $POSTGRES_STATUS"
fi

# Check Keycloak health and realm via service endpoint (Keycloak container has no curl)
if [[ "$KEYCLOAK_STATUS" == "Running" ]]; then
    # Use kubectl run to check health via service
    KC_HEALTH=$(kubectl run -n "$KEYCLOAK_NAMESPACE" curl-check-$RANDOM --rm -i --restart=Never --image=curlimages/curl:latest \
        -- curl -sf http://keycloak:8080/health/ready 2>&1 | grep -o '"status"' | head -1 || echo "")
    if [[ -n "$KC_HEALTH" ]]; then
        check_pass "Keycloak health endpoint responding"
    else
        check_warn "Keycloak health endpoint not responding"
    fi

    # Check agent-sandbox realm exists via well-known OIDC endpoint
    # Extract JSON line (starts with {) to filter kubectl pod lifecycle messages
    OIDC_RESPONSE=$(kubectl run -n "$KEYCLOAK_NAMESPACE" oidc-check-$RANDOM --rm -i --restart=Never --image=curlimages/curl:latest \
        -- curl -sf http://keycloak:8080/realms/agent-sandbox/.well-known/openid-configuration 2>&1 | grep '^{' || echo "")
    if [[ -n "$OIDC_RESPONSE" ]] && echo "$OIDC_RESPONSE" | grep -q '"issuer"'; then
        check_pass "Realm 'agent-sandbox' OIDC configured"
    else
        # Fall back to realm endpoint check
        REALM_RESPONSE=$(kubectl run -n "$KEYCLOAK_NAMESPACE" realm-check-$RANDOM --rm -i --restart=Never --image=curlimages/curl:latest \
            -- curl -sf http://keycloak:8080/realms/agent-sandbox 2>&1 | grep '^{' || echo "")
        if [[ -n "$REALM_RESPONSE" ]] && echo "$REALM_RESPONSE" | grep -q '"realm"'; then
            check_pass "Realm 'agent-sandbox' configured"
        else
            check_warn "Realm 'agent-sandbox' not configured (run configure-realm.sh)"
        fi
    fi
fi

# ==========================================
# OIDC Integration Testing
# ==========================================
echo ""
echo "--- OIDC Integration Testing ---"
echo "Note: User login tests are optional - users must be created via configure-realm.sh"

# Only run if Keycloak is running and realm exists
if [[ "$KEYCLOAK_STATUS" == "Running" ]] && [[ -n "${OIDC_RESPONSE:-}" ]]; then
    # Test user authentication using admin-cli (public client with direct access grants)
    # Uses the demo developer user created by configure-realm.sh
    # Note: Passwords contain special chars that need URL encoding: ! = %21, @ = %40, # = %23
    LOGIN_RESULT=$(kubectl run -n "$KEYCLOAK_NAMESPACE" login-test-$RANDOM --rm -i --restart=Never --image=curlimages/curl:latest \
        -- curl -sf -X POST "http://keycloak:8080/realms/agent-sandbox/protocol/openid-connect/token" \
            -d "grant_type=password" \
            -d "client_id=admin-cli" \
            -d "username=developer" \
            -d "password=Dev123%21%40%23" 2>&1 | grep -o '"access_token"' | head -1 || echo "")
    if [[ -n "$LOGIN_RESULT" ]]; then
        check_pass "User authentication (developer)"
    else
        check_info "User authentication failed for developer (users need to be created via configure-realm.sh)"
    fi

    # Test realmadmin user authentication (realm admin, not master admin)
    ADMIN_LOGIN=$(kubectl run -n "$KEYCLOAK_NAMESPACE" admin-login-$RANDOM --rm -i --restart=Never --image=curlimages/curl:latest \
        -- curl -sf -X POST "http://keycloak:8080/realms/agent-sandbox/protocol/openid-connect/token" \
            -d "grant_type=password" \
            -d "client_id=admin-cli" \
            -d "username=realmadmin" \
            -d "password=Admin123%21%40%23" 2>&1 | grep -o '"access_token"' | head -1 || echo "")
    if [[ -n "$ADMIN_LOGIN" ]]; then
        check_pass "User authentication (realmadmin)"
    else
        check_info "User authentication failed for realmadmin (users need to be created via configure-realm.sh)"
    fi
else
    check_info "OIDC tests skipped (Keycloak or realm not available)"
fi

# ==========================================
# Vault Secrets Operator
# ==========================================
echo ""
echo "--- Vault Secrets Operator ---"

# Check namespace
if kubectl get namespace "$VSO_NAMESPACE" &>/dev/null; then
    check_pass "Namespace '$VSO_NAMESPACE' exists"
else
    check_fail "Namespace '$VSO_NAMESPACE' does not exist"
fi

# Check controller manager
VSO_STATUS=$(kubectl get pod -l app.kubernetes.io/name=vault-secrets-operator -n "$VSO_NAMESPACE" -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "NotFound")
if [[ "$VSO_STATUS" == "Running" ]]; then
    check_pass "VSO controller manager running"
else
    check_fail "VSO controller manager status: $VSO_STATUS"
fi

# Check VaultConnection
VC_READY=$(kubectl get vaultconnection vault-connection -n "$DEVENV_NAMESPACE" -o jsonpath='{.status.valid}' 2>/dev/null || echo "false")
if [[ "$VC_READY" == "true" ]]; then
    check_pass "VaultConnection is valid"
else
    check_warn "VaultConnection not ready or not configured"
fi

# Check synced secrets
if kubectl get secret devenv-vault-secrets -n "$DEVENV_NAMESPACE" &>/dev/null; then
    check_pass "Vault secrets synced to devenv namespace"
else
    check_warn "No synced secrets found in devenv namespace"
fi

# ==========================================
# Secrets and CA Certificates
# ==========================================
echo ""
echo "--- Secrets and Certificates ---"

# Check Vault SSH CA secret
if kubectl get secret vault-ssh-ca -n "$DEVENV_NAMESPACE" &>/dev/null; then
    check_pass "Vault SSH CA secret exists"
else
    check_warn "Vault SSH CA secret not found (run configure-ssh-engine.sh)"
fi

# Check Vault TLS CA secret
if kubectl get secret vault-tls-ca -n "$DEVENV_NAMESPACE" &>/dev/null; then
    check_pass "Vault TLS CA secret exists"
else
    check_warn "Vault TLS CA secret not found (run export-vault-ca.sh)"
fi

# Check TFE dynamic token secret (optional - static TFE_TOKEN in devenv-vault-secrets is primary)
if kubectl get secret tfe-dynamic-token -n "$DEVENV_NAMESPACE" &>/dev/null; then
    check_pass "TFE dynamic token secret exists (Vault dynamic tokens)"
else
    check_info "TFE dynamic token not configured (optional - static TFE_TOKEN used via KV)"
fi

# ==========================================
# Summary
# ==========================================
echo ""
echo "=========================================="
echo "  Healthcheck Summary"
echo "=========================================="
echo ""
echo -e "${GREEN}Passed${NC}: $PASSED"
echo -e "${YELLOW}Warnings${NC}: $WARNINGS"
echo -e "${RED}Failed${NC}: $FAILED"
echo ""

if [[ $FAILED -gt 0 ]]; then
    echo -e "${RED}HEALTH: UNHEALTHY${NC} - Some critical checks failed"
    exit 1
elif [[ $WARNINGS -gt 0 ]]; then
    echo -e "${YELLOW}HEALTH: DEGRADED${NC} - Platform running with warnings"
    echo ""
    echo "To resolve warnings, run the configuration scripts:"
    echo "  ./platform/vault/scripts/configure-ssh-engine.sh"
    echo "  ./platform/vault/scripts/configure-tfe-engine.sh"
    exit 0
else
    echo -e "${GREEN}HEALTH: HEALTHY${NC} - All systems operational"
fi

# ==========================================
# Access Credentials
# ==========================================
echo ""
echo "=========================================="
echo "  Access Credentials"
echo "=========================================="
echo ""
echo -e "${BLUE}Vault:${NC}"
echo "  URL: http://vault.vault.svc.cluster.local:8200"
echo "  Root Token: See platform/vault/scripts/vault-keys.txt"
echo ""
echo -e "${BLUE}Keycloak:${NC}"
echo "  URL: http://keycloak.keycloak.svc.cluster.local:8080"
echo "  Admin Console: /admin/master/console/"
echo "  Master Admin: admin / admin123!@#"
echo "  Realm: agent-sandbox"
echo "  Demo Users:"
echo "    developer / Dev123!@# (developers group)"
echo "    realmadmin / Admin123!@# (admins group)"
echo ""
echo -e "${BLUE}Boundary:${NC}"
echo "  Controller API: http://boundary-controller-api.boundary.svc.cluster.local:9200"
echo "  Worker: boundary-worker.boundary.svc.cluster.local:9202"
echo "  Credentials: See platform/boundary/scripts/boundary-credentials.txt"
# Show credentials if file exists
if [[ -f "$K8S_DIR/platform/boundary/scripts/boundary-credentials.txt" ]]; then
    BOUNDARY_AUTH_ID=$(grep "Auth Method ID:" "$K8S_DIR/platform/boundary/scripts/boundary-credentials.txt" 2>/dev/null | awk '{print $4}' || echo "")
    BOUNDARY_ADMIN_PASS=$(grep "Password:" "$K8S_DIR/platform/boundary/scripts/boundary-credentials.txt" 2>/dev/null | awk '{print $2}' || echo "")
    BOUNDARY_TARGET_ID=$(grep "Target (SSH):" "$K8S_DIR/platform/boundary/scripts/boundary-credentials.txt" 2>/dev/null | awk '{print $3}' || echo "")
    if [[ -n "$BOUNDARY_AUTH_ID" ]]; then
        echo "  Auth Method ID: $BOUNDARY_AUTH_ID"
        echo "  Admin Login: admin / $BOUNDARY_ADMIN_PASS"
        echo "  SSH Target ID: $BOUNDARY_TARGET_ID"
    fi
fi
echo ""
echo -e "${BLUE}Agent Sandbox:${NC}"
echo "  Namespace: devenv"
echo "  Pod: claude-code-sandbox"
echo "  Connect: kubectl exec -it -n devenv claude-code-sandbox -- /bin/bash"
echo ""

exit 0
