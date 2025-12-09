#!/bin/bash
set -euo pipefail

# Post-deployment healthcheck script
# Verifies all platform components are online and functioning

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
K8S_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")"

# Source configuration
if [[ -f "$SCRIPT_DIR/.env" ]]; then
    source "$SCRIPT_DIR/.env"
elif [[ -f "$SCRIPT_DIR/platform.env.example" ]]; then
    source "$SCRIPT_DIR/platform.env.example"
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
VAULT_SEALED=$(kubectl exec -n "$VAULT_NAMESPACE" vault-0 -- vault status -format=json 2>/dev/null | jq -r '.sealed' || echo "true")
if [[ "$VAULT_SEALED" == "false" ]]; then
    check_pass "Vault unsealed and ready"
else
    check_fail "Vault is sealed"
fi

# Check secrets engines
VAULT_TOKEN=$(grep "Root Token:" "$K8S_DIR/platform/vault/scripts/vault-keys.txt" 2>/dev/null | awk '{print $3}' || echo "")
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
    exit 0
fi
