#!/bin/bash
set -euo pipefail

# Test script to verify SSH Credential Injection (Enterprise feature)
# Tests vault-ssh-certificate credential library and injected credentials
# Pattern: Same as test-ssh-oidc-browser.sh but for credential injection

BOUNDARY_NAMESPACE="${1:-boundary}"
VAULT_NAMESPACE="${2:-vault}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
K8S_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")"

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

# Configuration
BOUNDARY_ADDR="${BOUNDARY_ADDR:-https://boundary.hashicorp.lab}"
export BOUNDARY_TLS_INSECURE=true

echo "======================================================================"
echo "  SSH Credential Injection Test"
echo "  (Enterprise Feature - vault-ssh-certificate)"
echo "======================================================================"
echo "  Boundary URL: $BOUNDARY_ADDR"
echo ""

# ==========================================
# Phase 1: Prerequisite Checks
# ==========================================
echo ""
echo "=================================================="
echo "  Phase 1: Prerequisite Checks"
echo "=================================================="

# Check for Enterprise license
echo ""
echo "Step 1.1: Checking Boundary Enterprise license..."
BOUNDARY_LICENSE=$(kubectl get secret -n "$BOUNDARY_NAMESPACE" boundary-license -o jsonpath='{.data.license}' 2>/dev/null | base64 -d || echo "")
if [[ -n "$BOUNDARY_LICENSE" ]]; then
    test_pass "Boundary Enterprise license found"
else
    test_fail "No Enterprise license found - credential injection requires Enterprise"
    echo ""
    echo "SSH credential injection is an Enterprise feature."
    echo "Use credential brokering (configure-credential-brokering.sh) for Community Edition."
    exit 1
fi

# Get Vault root token
echo ""
echo "Step 1.2: Getting Vault credentials..."
VAULT_KEYS_FILE="$K8S_DIR/platform/vault/scripts/vault-keys.txt"
if [[ -f "$VAULT_KEYS_FILE" ]]; then
    VAULT_ROOT_TOKEN=$(grep "Root Token:" "$VAULT_KEYS_FILE" 2>/dev/null | awk '{print $3}' || echo "")
    if [[ -n "$VAULT_ROOT_TOKEN" ]]; then
        test_pass "Vault root token available"
    else
        test_fail "Cannot find Vault root token"
        exit 1
    fi
else
    test_fail "Vault keys file not found"
    exit 1
fi

# Check Vault is unsealed
echo ""
echo "Step 1.3: Checking Vault status..."
VAULT_STATUS=$(kubectl exec -n "$VAULT_NAMESPACE" vault-0 -- vault status -format=json 2>/dev/null || echo '{"sealed":true}')
if echo "$VAULT_STATUS" | jq -e '.sealed == false' >/dev/null 2>&1; then
    test_pass "Vault is unsealed"
else
    test_fail "Vault is sealed - unseal it first"
    exit 1
fi

# ==========================================
# Phase 2: Vault SSH Configuration
# ==========================================
echo ""
echo "=================================================="
echo "  Phase 2: Vault SSH Configuration"
echo "=================================================="

echo ""
echo "Step 2.1: Checking Vault SSH CA..."
SSH_CA_PUBKEY=$(kubectl exec -n "$VAULT_NAMESPACE" vault-0 -- sh -c "VAULT_TOKEN='$VAULT_ROOT_TOKEN' vault read -field=public_key ssh/config/ca" 2>/dev/null || echo "")
if [[ -n "$SSH_CA_PUBKEY" ]]; then
    test_pass "Vault SSH CA configured"
else
    test_fail "Vault SSH CA not configured"
    echo "  Run: ./k8s/platform/vault/scripts/configure-ssh-engine.sh"
    exit 1
fi

echo ""
echo "Step 2.2: Checking devenv-access role..."
ROLE_CHECK=$(kubectl exec -n "$VAULT_NAMESPACE" vault-0 -- sh -c "VAULT_TOKEN='$VAULT_ROOT_TOKEN' vault read ssh/roles/devenv-access -format=json" 2>/dev/null || echo "{}")
if echo "$ROLE_CHECK" | jq -e '.data' >/dev/null 2>&1; then
    test_pass "Vault SSH role 'devenv-access' exists"
else
    test_fail "Vault SSH role 'devenv-access' not found"
    exit 1
fi

echo ""
echo "Step 2.3: Checking boundary-ssh-full policy..."
POLICY_CHECK=$(kubectl exec -n "$VAULT_NAMESPACE" vault-0 -- sh -c "VAULT_TOKEN='$VAULT_ROOT_TOKEN' vault policy read boundary-ssh-full" 2>/dev/null || echo "")
if [[ -n "$POLICY_CHECK" ]]; then
    test_pass "Vault policy 'boundary-ssh-full' exists"

    if echo "$POLICY_CHECK" | grep -q "ssh/sign"; then
        test_pass "Policy includes SSH signing capability"
    else
        test_fail "Policy missing SSH signing capability"
    fi
else
    test_fail "Vault policy 'boundary-ssh-full' not found"
    echo "  Run: ./k8s/platform/boundary/scripts/configure-credential-brokering.sh"
    exit 1
fi

# ==========================================
# Phase 3: Boundary Configuration
# ==========================================
echo ""
echo "=================================================="
echo "  Phase 3: Boundary Configuration"
echo "=================================================="

echo ""
echo "Step 3.1: Finding Boundary controller..."
CONTROLLER_POD=$(kubectl get pod -l app=boundary-controller -n "$BOUNDARY_NAMESPACE" --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
if [[ -n "$CONTROLLER_POD" ]]; then
    test_pass "Boundary controller found: $CONTROLLER_POD"
else
    test_fail "Boundary controller not found"
    exit 1
fi

# Get project ID and Vault store ID
echo ""
echo "Step 3.2: Getting Boundary configuration..."
CREDS_FILE="$K8S_DIR/platform/boundary/scripts/boundary-credentials.txt"
PROJECT_ID=""
VAULT_STORE_ID=""
INJECTED_TARGET_ID=""

if [[ -f "$CREDS_FILE" ]]; then
    PROJECT_ID=$(grep "Project:" "$CREDS_FILE" 2>/dev/null | awk '{print $2}' | head -1 || echo "")
    VAULT_STORE_ID=$(grep "Vault Credential Store:" "$CREDS_FILE" 2>/dev/null | awk '{print $4}' | head -1 || echo "")
    # Look for injected target (might be added later)
    INJECTED_TARGET_ID=$(grep "claude-ssh-injected:" "$CREDS_FILE" 2>/dev/null | awk '{print $2}' | head -1 || echo "")
fi

# Find project if not in credentials file
if [[ -z "$PROJECT_ID" ]]; then
    SCOPES=$(kubectl exec -n "$BOUNDARY_NAMESPACE" "$CONTROLLER_POD" -c boundary-controller -- \
        boundary scopes list -recovery-config=/boundary/config/controller.hcl -format=json 2>/dev/null || echo "{}")

    ORG_ID=$(echo "$SCOPES" | jq -r '.items[]? | select(.name | contains("DevOps") or contains("Development")) | .id' 2>/dev/null | head -1 || echo "")

    if [[ -n "$ORG_ID" ]]; then
        ORG_SCOPES=$(kubectl exec -n "$BOUNDARY_NAMESPACE" "$CONTROLLER_POD" -c boundary-controller -- \
            boundary scopes list -scope-id="$ORG_ID" -recovery-config=/boundary/config/controller.hcl -format=json 2>/dev/null || echo "{}")
        PROJECT_ID=$(echo "$ORG_SCOPES" | jq -r '.items[]? | select(.name | contains("Agent") or contains("Sandbox")) | .id' 2>/dev/null | head -1 || echo "")
    fi
fi

if [[ -n "$PROJECT_ID" ]]; then
    test_pass "Project ID: $PROJECT_ID"
else
    test_fail "Could not find project scope"
    exit 1
fi

# Find Vault credential store
echo ""
echo "Step 3.3: Checking Vault credential store..."
if [[ -z "$VAULT_STORE_ID" ]]; then
    EXISTING_STORES=$(kubectl exec -n "$BOUNDARY_NAMESPACE" "$CONTROLLER_POD" -c boundary-controller -- \
        boundary credential-stores list -scope-id="$PROJECT_ID" -recovery-config=/boundary/config/controller.hcl -format=json 2>/dev/null || echo "{}")
    VAULT_STORE_ID=$(echo "$EXISTING_STORES" | jq -r '.items[]? | select(.type=="vault") | .id' 2>/dev/null | head -1 || echo "")
fi

if [[ -n "$VAULT_STORE_ID" ]]; then
    test_pass "Vault credential store: $VAULT_STORE_ID"
else
    test_fail "Vault credential store not found"
    echo "  Run: ./k8s/platform/boundary/scripts/configure-credential-brokering.sh"
    exit 1
fi

# ==========================================
# Phase 4: Credential Library Check
# ==========================================
echo ""
echo "=================================================="
echo "  Phase 4: Credential Library Configuration"
echo "=================================================="

echo ""
echo "Step 4.1: Checking for vault-ssh-certificate library..."
EXISTING_LIBS=$(kubectl exec -n "$BOUNDARY_NAMESPACE" "$CONTROLLER_POD" -c boundary-controller -- \
    boundary credential-libraries list -credential-store-id="$VAULT_STORE_ID" -recovery-config=/boundary/config/controller.hcl -format=json 2>/dev/null || echo "{}")

SSH_CERT_LIB_ID=$(echo "$EXISTING_LIBS" | jq -r '.items[]? | select(.type=="vault-ssh-certificate") | .id' 2>/dev/null | head -1 || echo "")

if [[ -n "$SSH_CERT_LIB_ID" ]]; then
    test_pass "SSH certificate library found: $SSH_CERT_LIB_ID"

    # Validate library configuration
    echo ""
    echo "Step 4.2: Validating library configuration..."
    LIB_CONFIG=$(kubectl exec -n "$BOUNDARY_NAMESPACE" "$CONTROLLER_POD" -c boundary-controller -- \
        boundary credential-libraries read -id="$SSH_CERT_LIB_ID" -recovery-config=/boundary/config/controller.hcl -format=json 2>/dev/null || echo "{}")

    VAULT_PATH=$(echo "$LIB_CONFIG" | jq -r '.item.attributes.path // ""')
    USERNAME=$(echo "$LIB_CONFIG" | jq -r '.item.attributes.username // ""')

    if [[ "$VAULT_PATH" == "ssh/sign/devenv-access" ]]; then
        test_pass "Vault path: $VAULT_PATH"
    else
        test_fail "Vault path incorrect: $VAULT_PATH (expected: ssh/sign/devenv-access)"
    fi

    if [[ "$USERNAME" == "node" ]]; then
        test_pass "Username: $USERNAME"
    else
        test_fail "Username incorrect: $USERNAME (expected: node)"
    fi
else
    test_fail "SSH certificate library not found"
    echo "  Run: ./k8s/platform/boundary/scripts/configure-ssh-credential-injection.sh"
    exit 1
fi

# ==========================================
# Phase 5: Target Configuration
# ==========================================
echo ""
echo "=================================================="
echo "  Phase 5: Target Configuration"
echo "=================================================="

echo ""
echo "Step 5.1: Checking for injected credentials target..."
TARGETS=$(kubectl exec -n "$BOUNDARY_NAMESPACE" "$CONTROLLER_POD" -c boundary-controller -- \
    boundary targets list -scope-id="$PROJECT_ID" -recovery-config=/boundary/config/controller.hcl -format=json 2>/dev/null || echo '{"items":[]}')

if [[ -z "$INJECTED_TARGET_ID" ]]; then
    INJECTED_TARGET_ID=$(echo "$TARGETS" | jq -r '.items[]? | select(.name=="claude-ssh-injected") | .id' 2>/dev/null | head -1 || echo "")
fi

if [[ -n "$INJECTED_TARGET_ID" ]]; then
    test_pass "Injected target found: $INJECTED_TARGET_ID"

    echo ""
    echo "Step 5.2: Validating target configuration..."
    TARGET_CONFIG=$(kubectl exec -n "$BOUNDARY_NAMESPACE" "$CONTROLLER_POD" -c boundary-controller -- \
        boundary targets read -id="$INJECTED_TARGET_ID" -recovery-config=/boundary/config/controller.hcl -format=json 2>/dev/null || echo "{}")

    TARGET_TYPE=$(echo "$TARGET_CONFIG" | jq -r '.item.type // ""')
    INJECTED_CREDS=$(echo "$TARGET_CONFIG" | jq -r '.item.injected_application_credential_source_ids[]?' 2>/dev/null | head -1 || echo "")

    if [[ "$TARGET_TYPE" == "ssh" ]]; then
        test_pass "Target type: SSH (required for injection)"
    else
        test_fail "Target type: $TARGET_TYPE (should be 'ssh')"
    fi

    if [[ -n "$INJECTED_CREDS" ]]; then
        test_pass "Injected credential source attached"
    else
        test_fail "No injected credential source on target"
    fi
else
    test_fail "Injected credentials target not found"
    echo "  Run: ./k8s/platform/boundary/scripts/configure-ssh-credential-injection.sh"
    exit 1
fi

# ==========================================
# Phase 6: SSH Certificate Test
# ==========================================
echo ""
echo "=================================================="
echo "  Phase 6: SSH Certificate Signing Test"
echo "=================================================="

echo ""
echo "Step 6.1: Testing Vault SSH certificate signing..."

# Generate a test key
TEST_DIR=$(mktemp -d)
trap "rm -rf $TEST_DIR" EXIT

ssh-keygen -t ed25519 -f "$TEST_DIR/test-key" -N "" -C "test-key" >/dev/null 2>&1
TEST_PUBKEY=$(cat "$TEST_DIR/test-key.pub")

# Sign with Vault
SIGNED_CERT=$(kubectl exec -n "$VAULT_NAMESPACE" vault-0 -i -- sh -c "VAULT_TOKEN='$VAULT_ROOT_TOKEN' vault write -field=signed_key ssh/sign/devenv-access public_key='$TEST_PUBKEY' valid_principals=node ttl=1h" 2>/dev/null || echo "")

if [[ -n "$SIGNED_CERT" ]] && [[ "$SIGNED_CERT" != *"error"* ]]; then
    test_pass "Vault SSH certificate signing works"

    echo "$SIGNED_CERT" > "$TEST_DIR/test-key-cert.pub"
    CERT_INFO=$(ssh-keygen -L -f "$TEST_DIR/test-key-cert.pub" 2>/dev/null || echo "")

    if echo "$CERT_INFO" | grep -q "Type: ssh-ed25519-cert"; then
        test_pass "Certificate type: ssh-ed25519-cert"
    fi

    if echo "$CERT_INFO" | grep -q "Principal: node"; then
        test_pass "Certificate principal: node"
    fi

    if echo "$CERT_INFO" | grep -q "permit-port-forwarding"; then
        test_pass "Certificate has port-forwarding extension"
    else
        test_fail "Certificate missing port-forwarding extension"
    fi
else
    test_fail "Vault SSH certificate signing failed"
    echo "  Error: ${SIGNED_CERT:0:200}"
fi

# ==========================================
# Phase 7: SSH Connection Test
# ==========================================
echo ""
echo "=================================================="
echo "  Phase 7: SSH Connection Test (Injected Credentials)"
echo "=================================================="

echo ""
echo "Step 7.1: Authenticating to Boundary..."

# Get admin password (handle both "Password:" and "Admin Password:" formats)
ADMIN_PASSWORD=$(grep -E "^Password:" "$CREDS_FILE" 2>/dev/null | awk '{print $2}' || echo "")
if [[ -z "$ADMIN_PASSWORD" ]]; then
    ADMIN_PASSWORD=$(grep "Admin Password:" "$CREDS_FILE" 2>/dev/null | awk '{print $3}' || echo "")
fi
if [[ -z "$ADMIN_PASSWORD" ]]; then
    test_fail "Cannot find admin password"
    exit 1
fi

export BOUNDARY_ADDR
export BOUNDARY_PASS="$ADMIN_PASSWORD"

# Get auth method ID - prefer the global password auth method
# The credentials file may have an old/different auth method ID
AUTH_METHOD_ID="ampw_tByHvnwnn8"  # Global scope password auth method

# Authenticate
AUTH_RESULT=$(boundary authenticate password \
    -auth-method-id="$AUTH_METHOD_ID" \
    -login-name=admin \
    -password=env://BOUNDARY_PASS \
    -format=json 2>/dev/null || echo "{}")

BOUNDARY_TOKEN=$(echo "$AUTH_RESULT" | jq -r '.item.attributes.token // ""')

if [[ -n "$BOUNDARY_TOKEN" ]]; then
    test_pass "Authenticated to Boundary"
    export BOUNDARY_TOKEN
else
    test_fail "Failed to authenticate to Boundary"
    echo "  Error: $(echo "$AUTH_RESULT" | jq -r '.status_message // .message // "unknown"')"
    exit 1
fi

echo ""
echo "Step 7.2: Testing SSH connection with injected credentials..."
test_info "Target: $INJECTED_TARGET_ID"

# For credential injection, use 'boundary connect ssh' which handles everything
# The -target-id with an SSH-type target and injected creds will:
# 1. Authorize session
# 2. Request certificate from Vault
# 3. Inject certificate into SSH connection
# 4. Execute SSH command

# Use gtimeout on macOS, timeout on Linux
TIMEOUT_CMD="timeout"
if command -v gtimeout &>/dev/null; then
    TIMEOUT_CMD="gtimeout"
elif ! command -v timeout &>/dev/null; then
    # No timeout available, run without timeout
    TIMEOUT_CMD=""
fi

if [[ -n "$TIMEOUT_CMD" ]]; then
    SSH_RESULT=$($TIMEOUT_CMD 30 boundary connect ssh \
        -target-id="$INJECTED_TARGET_ID" \
        -token=env://BOUNDARY_TOKEN \
        -remote-command="hostname" 2>&1) || SSH_EXIT=$?
else
    SSH_RESULT=$(boundary connect ssh \
        -target-id="$INJECTED_TARGET_ID" \
        -token=env://BOUNDARY_TOKEN \
        -remote-command="hostname" 2>&1) || SSH_EXIT=$?
fi

SSH_EXIT=${SSH_EXIT:-0}

if [[ $SSH_EXIT -eq 0 ]]; then
    # Filter out proxy info lines
    HOSTNAME_OUTPUT=$(echo "$SSH_RESULT" | grep -v "^Proxy" | grep -v "^  " | tail -1)
    if [[ -n "$HOSTNAME_OUTPUT" ]] && [[ "$HOSTNAME_OUTPUT" == *"sandbox"* || "$HOSTNAME_OUTPUT" == *"claude"* ]]; then
        test_pass "SSH connection successful!"
        echo "  Remote hostname: $HOSTNAME_OUTPUT"
    elif [[ -n "$HOSTNAME_OUTPUT" ]]; then
        test_pass "SSH connection successful!"
        echo "  Remote hostname: $HOSTNAME_OUTPUT"
    else
        test_pass "SSH command completed (no hostname output)"
    fi
else
    test_fail "SSH connection failed (exit code: $SSH_EXIT)"
    echo "  Output: ${SSH_RESULT:0:500}"

    # Additional debug info
    echo ""
    echo "Debug: Checking worker connectivity..."
    WORKER_STATUS=$(kubectl get pod -l app=boundary-worker -n "$BOUNDARY_NAMESPACE" -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "NotFound")
    echo "  Worker status: $WORKER_STATUS"
fi

# ==========================================
# Summary
# ==========================================
echo ""
echo "======================================================================"
echo "  Test Summary"
echo "======================================================================"
echo -e "  ${GREEN}Passed${NC}: $PASSED"
echo -e "  ${RED}Failed${NC}: $FAILED"
echo ""

if [[ $FAILED -gt 0 ]]; then
    echo -e "${RED}❌ TEST FAILED${NC}"
    echo ""
    echo "Troubleshooting:"
    echo "  1. Verify Enterprise license: kubectl get secret -n boundary boundary-license"
    echo "  2. Run credential brokering first: ./k8s/platform/boundary/scripts/configure-credential-brokering.sh"
    echo "  3. Run credential injection: ./k8s/platform/boundary/scripts/configure-ssh-credential-injection.sh"
    echo "  4. Check worker logs: kubectl logs -n boundary -l app=boundary-worker"
    exit 1
else
    echo -e "${GREEN}✅ ALL TESTS PASSED${NC}"
    echo ""
    echo "SSH Credential Injection is working correctly."
    echo ""
    echo "Usage (with injected credentials - no key handling needed):"
    echo "  boundary authenticate password -auth-method-id=$AUTH_METHOD_ID -login-name=admin"
    echo "  boundary connect ssh -target-id=$INJECTED_TARGET_ID"
    exit 0
fi
