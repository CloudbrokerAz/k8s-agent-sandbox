#!/bin/bash
set -euo pipefail

# Test script to verify secrets are properly configured and accessible
# Tests:
# 1. Can read GITHUB_TOKEN from Vault KV
# 2. Container has TFE_TOKEN environment variable
# 3. Container has GITHUB_TOKEN environment variable

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
K8S_DIR="$(dirname "$SCRIPT_DIR")"

# Source configuration
if [[ -f "$SCRIPT_DIR/.env" ]]; then
    source "$SCRIPT_DIR/.env"
elif [[ -f "$SCRIPT_DIR/platform.env.example" ]]; then
    source "$SCRIPT_DIR/platform.env.example"
fi

DEVENV_NAMESPACE="${DEVENV_NAMESPACE:-devenv}"
VAULT_NAMESPACE="${VAULT_NAMESPACE:-vault}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

PASSED=0
FAILED=0

test_pass() {
    echo -e "${GREEN}✅ PASS${NC}: $1"
    PASSED=$((PASSED + 1))
}

test_fail() {
    echo -e "${RED}❌ FAIL${NC}: $1"
    FAILED=$((FAILED + 1))
}

test_info() {
    echo -e "${BLUE}ℹ️  INFO${NC}: $1"
}

echo "=========================================="
echo "  Agent Sandbox Secrets Test Suite"
echo "=========================================="
echo ""

# ==========================================
# Pre-flight checks
# ==========================================
echo "--- Pre-flight Checks ---"

# Check cluster connectivity
if ! kubectl cluster-info &>/dev/null; then
    test_fail "Cannot connect to Kubernetes cluster"
    exit 1
fi
test_pass "Kubernetes cluster reachable"

# Check devenv pod is running
DEVENV_STATUS=$(kubectl get pod devenv-0 -n "$DEVENV_NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo "NotFound")
if [[ "$DEVENV_STATUS" != "Running" ]]; then
    test_fail "DevEnv pod not running (status: $DEVENV_STATUS)"
    exit 1
fi
test_pass "DevEnv pod is running"

# Check Vault is unsealed
VAULT_SEALED=$(kubectl exec -n "$VAULT_NAMESPACE" vault-0 -- vault status -format=json 2>/dev/null | jq -r '.sealed' || echo "true")
if [[ "$VAULT_SEALED" != "false" ]]; then
    test_fail "Vault is sealed or not accessible"
    exit 1
fi
test_pass "Vault is unsealed"

echo ""

# ==========================================
# Test 1: Read GITHUB_TOKEN from Vault KV
# ==========================================
echo "--- Test 1: Vault KV Access ---"

# Get Vault token
VAULT_TOKEN=$(grep "Root Token:" "$K8S_DIR/platform/vault/scripts/vault-keys.txt" 2>/dev/null | awk '{print $3}' || echo "")

if [[ -z "$VAULT_TOKEN" ]]; then
    test_fail "Cannot find Vault root token"
else
    # Try to read the secret from Vault
    KV_RESULT=$(kubectl exec -n "$VAULT_NAMESPACE" vault-0 -- sh -c "
        export VAULT_TOKEN='$VAULT_TOKEN'
        vault kv get -format=json secret/devenv/credentials 2>/dev/null
    " 2>/dev/null || echo "")

    if [[ -z "$KV_RESULT" ]]; then
        test_fail "Cannot read secret/devenv/credentials from Vault KV"
    else
        # Check if github_token key exists
        GH_TOKEN_EXISTS=$(echo "$KV_RESULT" | jq -r '.data.data.github_token // empty')
        if [[ -n "$GH_TOKEN_EXISTS" ]]; then
            if [[ "$GH_TOKEN_EXISTS" == "placeholder-update-me" ]]; then
                test_pass "github_token exists in Vault KV (placeholder value)"
                test_info "Run configure-secrets.sh to set real token"
            else
                # Mask the token for display
                MASKED="${GH_TOKEN_EXISTS:0:4}...${GH_TOKEN_EXISTS: -4}"
                test_pass "github_token exists in Vault KV (value: $MASKED)"
            fi
        else
            test_fail "github_token key not found in Vault KV"
        fi

        # List all keys in the secret
        KEYS=$(echo "$KV_RESULT" | jq -r '.data.data | keys | join(", ")')
        test_info "Keys in secret/devenv/credentials: $KEYS"
    fi
fi

echo ""

# ==========================================
# Test 2: VSO Secret Sync
# ==========================================
echo "--- Test 2: VSO Secret Sync ---"

# Check if the synced secret exists
if kubectl get secret devenv-vault-secrets -n "$DEVENV_NAMESPACE" &>/dev/null; then
    test_pass "devenv-vault-secrets K8s secret exists"

    # Check the keys in the secret
    SECRET_KEYS=$(kubectl get secret devenv-vault-secrets -n "$DEVENV_NAMESPACE" -o jsonpath='{.data}' | jq -r 'keys | join(", ")')
    test_info "Keys in devenv-vault-secrets: $SECRET_KEYS"

    # Check GITHUB_TOKEN key
    GH_TOKEN_B64=$(kubectl get secret devenv-vault-secrets -n "$DEVENV_NAMESPACE" -o jsonpath='{.data.GITHUB_TOKEN}' 2>/dev/null || echo "")
    if [[ -n "$GH_TOKEN_B64" ]]; then
        GH_TOKEN_DECODED=$(echo "$GH_TOKEN_B64" | base64 -d 2>/dev/null || echo "")
        if [[ -n "$GH_TOKEN_DECODED" ]]; then
            if [[ "$GH_TOKEN_DECODED" == "placeholder-update-me" ]]; then
                test_pass "GITHUB_TOKEN synced to K8s secret (placeholder)"
            else
                MASKED="${GH_TOKEN_DECODED:0:4}...${GH_TOKEN_DECODED: -4}"
                test_pass "GITHUB_TOKEN synced to K8s secret (value: $MASKED)"
            fi
        else
            test_fail "GITHUB_TOKEN in K8s secret is empty"
        fi
    else
        test_fail "GITHUB_TOKEN key not found in devenv-vault-secrets"
    fi
else
    test_fail "devenv-vault-secrets K8s secret does not exist"
    test_info "Check VaultStaticSecret and VSO controller status"
fi

echo ""

# ==========================================
# Test 3: Container Environment Variables
# ==========================================
echo "--- Test 3: Container Environment Variables ---"

# Test GITHUB_TOKEN in container
CONTAINER_GH_TOKEN=$(kubectl exec -n "$DEVENV_NAMESPACE" devenv-0 -- printenv GITHUB_TOKEN 2>/dev/null || echo "")
if [[ -n "$CONTAINER_GH_TOKEN" ]]; then
    if [[ "$CONTAINER_GH_TOKEN" == "placeholder-update-me" ]]; then
        test_pass "GITHUB_TOKEN visible in container (placeholder)"
        test_info "Run configure-secrets.sh to set real token"
    else
        MASKED="${CONTAINER_GH_TOKEN:0:4}...${CONTAINER_GH_TOKEN: -4}"
        test_pass "GITHUB_TOKEN visible in container (value: $MASKED)"
    fi
else
    test_fail "GITHUB_TOKEN not visible in container environment"
fi

# Test TFE_TOKEN in container
CONTAINER_TFE_TOKEN=$(kubectl exec -n "$DEVENV_NAMESPACE" devenv-0 -- printenv TFE_TOKEN 2>/dev/null || echo "")
if [[ -n "$CONTAINER_TFE_TOKEN" ]]; then
    MASKED="${CONTAINER_TFE_TOKEN:0:4}...${CONTAINER_TFE_TOKEN: -4}"
    test_pass "TFE_TOKEN visible in container (value: $MASKED)"
else
    test_fail "TFE_TOKEN not visible in container environment"
    test_info "Run configure-tfe-engine.sh to configure TFE tokens"
fi

# Test TF_TOKEN_app_terraform_io (alias for TFE_TOKEN)
CONTAINER_TF_TOKEN=$(kubectl exec -n "$DEVENV_NAMESPACE" devenv-0 -- printenv TF_TOKEN_app_terraform_io 2>/dev/null || echo "")
if [[ -n "$CONTAINER_TF_TOKEN" ]]; then
    test_pass "TF_TOKEN_app_terraform_io visible in container"
else
    test_fail "TF_TOKEN_app_terraform_io not visible in container"
fi

echo ""

# ==========================================
# Test 4: Functional Token Tests
# ==========================================
echo "--- Test 4: Functional Token Tests ---"

# Test GitHub token with gh CLI (if available and token is not placeholder)
if [[ -n "$CONTAINER_GH_TOKEN" ]] && [[ "$CONTAINER_GH_TOKEN" != "placeholder-update-me" ]]; then
    GH_USER=$(kubectl exec -n "$DEVENV_NAMESPACE" devenv-0 -- sh -c 'gh api user --jq .login 2>/dev/null' || echo "")
    if [[ -n "$GH_USER" ]]; then
        test_pass "GitHub API accessible (authenticated as: $GH_USER)"
    else
        test_fail "GitHub API not accessible with provided token"
        test_info "Token may be invalid or expired"
    fi
else
    test_info "Skipping GitHub API test (placeholder token)"
fi

# Test Terraform Cloud connection (if TFE token is set)
if [[ -n "$CONTAINER_TFE_TOKEN" ]]; then
    TFE_WHOAMI=$(kubectl exec -n "$DEVENV_NAMESPACE" devenv-0 -- sh -c 'curl -s -H "Authorization: Bearer $TFE_TOKEN" https://app.terraform.io/api/v2/account/details 2>/dev/null | jq -r ".data.attributes.username // empty"' || echo "")
    if [[ -n "$TFE_WHOAMI" ]]; then
        test_pass "Terraform Cloud API accessible (user: $TFE_WHOAMI)"
    else
        test_fail "Terraform Cloud API not accessible"
        test_info "Token may be invalid, expired, or network issue"
    fi
else
    test_info "Skipping Terraform Cloud API test (no TFE_TOKEN)"
fi

echo ""

# ==========================================
# Summary
# ==========================================
echo "=========================================="
echo "  Test Summary"
echo "=========================================="
echo ""
echo -e "${GREEN}Passed${NC}: $PASSED"
echo -e "${RED}Failed${NC}: $FAILED"
echo ""

if [[ $FAILED -gt 0 ]]; then
    echo -e "${RED}RESULT: SOME TESTS FAILED${NC}"
    echo ""
    echo "Troubleshooting tips:"
    echo "  1. Run configure-secrets.sh to set GITHUB_TOKEN"
    echo "  2. Run configure-tfe-engine.sh to set TFE_TOKEN"
    echo "  3. Check VSO controller: kubectl logs -n vault-secrets-operator-system -l app.kubernetes.io/name=vault-secrets-operator"
    echo "  4. Check VaultStaticSecret status: kubectl get vaultstaticsecret -n devenv -o yaml"
    exit 1
else
    echo -e "${GREEN}RESULT: ALL TESTS PASSED${NC}"
    exit 0
fi
