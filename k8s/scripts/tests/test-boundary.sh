#!/bin/bash
set -euo pipefail

# Test script to verify Boundary deployment and configuration
# Tests controller, worker, database, scopes, hosts, and targets

BOUNDARY_NAMESPACE="${1:-boundary}"
DEVENV_NAMESPACE="${2:-devenv}"
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
WARNINGS=0

test_pass() {
    echo -e "${GREEN}✅ PASS${NC}: $1"
    PASSED=$((PASSED + 1))
}

test_fail() {
    echo -e "${RED}❌ FAIL${NC}: $1"
    FAILED=$((FAILED + 1))
}

test_warn() {
    echo -e "${YELLOW}⚠️  WARN${NC}: $1"
    WARNINGS=$((WARNINGS + 1))
}

test_info() {
    echo -e "${BLUE}ℹ️  INFO${NC}: $1"
}

echo "=========================================="
echo "  Boundary Test Suite"
echo "=========================================="
echo ""

# ==========================================
# Infrastructure Tests
# ==========================================
echo "--- Infrastructure Tests ---"

# Check namespace
if kubectl get namespace "$BOUNDARY_NAMESPACE" &>/dev/null; then
    test_pass "Boundary namespace exists"
else
    test_fail "Boundary namespace does not exist"
    echo "Boundary not deployed. Exiting."
    exit 1
fi

# Check PostgreSQL
POSTGRES_STATUS=$(kubectl get pod -l app=boundary-postgres -n "$BOUNDARY_NAMESPACE" -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "NotFound")
if [[ "$POSTGRES_STATUS" == "Running" ]]; then
    test_pass "PostgreSQL running"
else
    test_fail "PostgreSQL status: $POSTGRES_STATUS"
fi

# Check PostgreSQL PVC
if kubectl get pvc -l app=boundary-postgres -n "$BOUNDARY_NAMESPACE" -o jsonpath='{.items[0].status.phase}' 2>/dev/null | grep -q "Bound"; then
    test_pass "PostgreSQL PVC bound"
else
    test_warn "PostgreSQL PVC not bound"
fi

# Check controller
CONTROLLER_STATUS=$(kubectl get pod -l app=boundary-controller -n "$BOUNDARY_NAMESPACE" -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "NotFound")
if [[ "$CONTROLLER_STATUS" == "Running" ]]; then
    test_pass "Boundary controller running"
else
    test_fail "Boundary controller status: $CONTROLLER_STATUS"
fi

# Check controller health endpoint
CONTROLLER_POD=$(kubectl get pod -l app=boundary-controller -n "$BOUNDARY_NAMESPACE" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
if [[ -n "$CONTROLLER_POD" ]]; then
    HEALTH=$(kubectl exec -n "$BOUNDARY_NAMESPACE" "$CONTROLLER_POD" -- wget -q -O- http://127.0.0.1:9203/health 2>/dev/null || echo "")
    if echo "$HEALTH" | grep -q "ok"; then
        test_pass "Controller health endpoint responding"
    else
        test_warn "Controller health endpoint not responding"
    fi
fi

# Check worker
WORKER_STATUS=$(kubectl get pod -l app=boundary-worker -n "$BOUNDARY_NAMESPACE" -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "NotFound")
if [[ "$WORKER_STATUS" == "Running" ]]; then
    test_pass "Boundary worker running"
else
    test_fail "Boundary worker status: $WORKER_STATUS"
fi

# Check services
if kubectl get svc boundary-controller-api -n "$BOUNDARY_NAMESPACE" &>/dev/null; then
    test_pass "Controller API service exists"
else
    test_fail "Controller API service missing"
fi

if kubectl get svc boundary-worker -n "$BOUNDARY_NAMESPACE" &>/dev/null; then
    test_pass "Worker service exists"
else
    test_fail "Worker service missing"
fi

echo ""

# ==========================================
# Configuration Tests
# ==========================================
echo "--- Configuration Tests ---"

# Get recovery key
RECOVERY_KEY=$(kubectl get secret boundary-kms-keys -n "$BOUNDARY_NAMESPACE" -o jsonpath='{.data.BOUNDARY_RECOVERY_KEY}' 2>/dev/null | base64 -d || echo "")
if [[ -z "$RECOVERY_KEY" ]]; then
    test_fail "Cannot find recovery key"
    echo "Cannot proceed with configuration tests without recovery key"
else
    test_pass "Recovery key available"

    # Function to run boundary commands
    run_boundary() {
        kubectl exec -n "$BOUNDARY_NAMESPACE" "$CONTROLLER_POD" -- \
            env BOUNDARY_ADDR=http://127.0.0.1:9200 \
            boundary "$@" \
            -recovery-kms-hcl="kms \"aead\" { purpose = \"recovery\"; aead_type = \"aes-gcm\"; key = \"$RECOVERY_KEY\"; key_id = \"global_recovery\" }" 2>/dev/null
    }

    # Check for organization scope
    ORG_EXISTS=$(run_boundary scopes list -format=json | jq -r '.items[] | select(.name=="DevOps") | .id' 2>/dev/null || echo "")
    if [[ -n "$ORG_EXISTS" ]]; then
        test_pass "DevOps organization scope exists ($ORG_EXISTS)"
        ORG_ID="$ORG_EXISTS"
    else
        test_warn "DevOps organization scope not configured (run configure-targets.sh)"
        ORG_ID=""
    fi

    if [[ -n "$ORG_ID" ]]; then
        # Check for project scope
        PROJECT_EXISTS=$(run_boundary scopes list -scope-id="$ORG_ID" -format=json | jq -r '.items[] | select(.name=="Agent-Sandbox") | .id' 2>/dev/null || echo "")
        if [[ -n "$PROJECT_EXISTS" ]]; then
            test_pass "Agent-Sandbox project scope exists ($PROJECT_EXISTS)"
            PROJECT_ID="$PROJECT_EXISTS"
        else
            test_warn "Agent-Sandbox project scope not configured"
            PROJECT_ID=""
        fi

        # Check for auth methods
        AUTH_METHODS=$(run_boundary auth-methods list -scope-id="$ORG_ID" -format=json | jq -r '.items | length' 2>/dev/null || echo "0")
        if [[ "$AUTH_METHODS" -gt 0 ]]; then
            test_pass "Auth methods configured ($AUTH_METHODS found)"

            # Check for password auth
            PASSWORD_AUTH=$(run_boundary auth-methods list -scope-id="$ORG_ID" -format=json | jq -r '.items[] | select(.type=="password") | .id' 2>/dev/null || echo "")
            if [[ -n "$PASSWORD_AUTH" ]]; then
                test_pass "Password auth method configured"
            fi

            # Check for OIDC auth
            OIDC_AUTH=$(run_boundary auth-methods list -scope-id="$ORG_ID" -format=json | jq -r '.items[] | select(.type=="oidc") | .id' 2>/dev/null || echo "")
            if [[ -n "$OIDC_AUTH" ]]; then
                test_pass "OIDC auth method configured"
            else
                test_info "OIDC auth not configured (optional)"
            fi
        else
            test_warn "No auth methods configured"
        fi

        if [[ -n "$PROJECT_ID" ]]; then
            # Check for host catalogs
            HOST_CATALOGS=$(run_boundary host-catalogs list -scope-id="$PROJECT_ID" -format=json | jq -r '.items | length' 2>/dev/null || echo "0")
            if [[ "$HOST_CATALOGS" -gt 0 ]]; then
                test_pass "Host catalogs configured ($HOST_CATALOGS found)"
            else
                test_warn "No host catalogs configured"
            fi

            # Check for targets
            TARGETS=$(run_boundary targets list -scope-id="$PROJECT_ID" -format=json | jq -r '.items | length' 2>/dev/null || echo "0")
            if [[ "$TARGETS" -gt 0 ]]; then
                test_pass "Targets configured ($TARGETS found)"

                # Check for SSH target
                SSH_TARGET=$(run_boundary targets list -scope-id="$PROJECT_ID" -format=json | jq -r '.items[] | select(.name=="devenv-ssh") | .id' 2>/dev/null || echo "")
                if [[ -n "$SSH_TARGET" ]]; then
                    test_pass "SSH target 'devenv-ssh' configured ($SSH_TARGET)"
                fi
            else
                test_warn "No targets configured"
            fi
        fi
    fi
fi

echo ""

# ==========================================
# Vault SSH Integration Tests
# ==========================================
echo "--- Vault SSH Integration Tests ---"

VAULT_NAMESPACE="${VAULT_NAMESPACE:-vault}"
VAULT_KEYS_FILE="$K8S_DIR/platform/vault/scripts/vault-keys.txt"

# Check Vault SSH secrets engine
if [[ -f "$VAULT_KEYS_FILE" ]]; then
    VAULT_TOKEN=$(grep "Root Token:" "$VAULT_KEYS_FILE" | awk '{print $3}' || echo "")
    if [[ -n "$VAULT_TOKEN" ]]; then
        # Check if Vault SSH engine is enabled
        SSH_ENGINE=$(kubectl exec -n "$VAULT_NAMESPACE" vault-0 -- sh -c "VAULT_TOKEN='$VAULT_TOKEN' vault secrets list -format=json" 2>/dev/null | jq -r '."ssh/"' || echo "")
        if [[ -n "$SSH_ENGINE" ]] && [[ "$SSH_ENGINE" != "null" ]]; then
            test_pass "Vault SSH secrets engine enabled"

            # Check SSH CA is configured
            SSH_CA=$(kubectl exec -n "$VAULT_NAMESPACE" vault-0 -- sh -c "VAULT_TOKEN='$VAULT_TOKEN' vault read -field=public_key ssh/config/ca" 2>/dev/null || echo "")
            if [[ -n "$SSH_CA" ]]; then
                test_pass "Vault SSH CA configured"
            else
                test_warn "Vault SSH CA not configured"
            fi

            # Check devenv-access role exists
            SSH_ROLE=$(kubectl exec -n "$VAULT_NAMESPACE" vault-0 -- sh -c "VAULT_TOKEN='$VAULT_TOKEN' vault read ssh/roles/devenv-access -format=json" 2>/dev/null | jq -r '.data.key_type' || echo "")
            if [[ "$SSH_ROLE" == "ca" ]]; then
                test_pass "Vault SSH role 'devenv-access' configured (CA signing)"
            else
                test_warn "Vault SSH role 'devenv-access' not configured"
            fi
        else
            test_info "Vault SSH secrets engine not enabled"
        fi
    else
        test_warn "Vault token not found in keys file"
    fi
else
    test_info "Vault keys file not found - skipping SSH integration tests"
fi

# Check for Boundary credential store if we have a project ID
if [[ -n "${PROJECT_ID:-}" ]] && [[ -n "${RECOVERY_KEY:-}" ]]; then
    CRED_STORES=$(run_boundary credential-stores list -scope-id="$PROJECT_ID" -format=json | jq -r '.items | length' 2>/dev/null || echo "0")
    if [[ "$CRED_STORES" -gt 0 ]]; then
        test_pass "Credential stores configured in Boundary ($CRED_STORES found)"

        # Check for Vault credential store
        VAULT_CRED_STORE=$(run_boundary credential-stores list -scope-id="$PROJECT_ID" -format=json | jq -r '.items[] | select(.type=="vault") | .id' 2>/dev/null || echo "")
        if [[ -n "$VAULT_CRED_STORE" ]]; then
            test_pass "Vault credential store configured ($VAULT_CRED_STORE)"

            # Check for credential libraries
            CRED_LIBS=$(run_boundary credential-libraries list -credential-store-id="$VAULT_CRED_STORE" -format=json | jq -r '.items | length' 2>/dev/null || echo "0")
            if [[ "$CRED_LIBS" -gt 0 ]]; then
                test_pass "Credential libraries configured ($CRED_LIBS found)"

                # Check for SSH certificate library
                SSH_LIB=$(run_boundary credential-libraries list -credential-store-id="$VAULT_CRED_STORE" -format=json | jq -r '.items[] | select(.type=="vault-ssh-certificate") | .id' 2>/dev/null || echo "")
                if [[ -n "$SSH_LIB" ]]; then
                    test_pass "SSH certificate credential library configured ($SSH_LIB)"
                else
                    test_warn "SSH certificate credential library not found"
                fi
            else
                test_warn "No credential libraries configured"
            fi
        else
            test_info "Vault credential store not configured (manual SSH auth only)"
        fi
    else
        test_info "No credential stores configured (manual SSH auth only)"
    fi
fi

# Check SSH CA secret in devenv namespace
if kubectl get secret vault-ssh-ca -n "$DEVENV_NAMESPACE" &>/dev/null; then
    test_pass "SSH CA secret exists in devenv namespace"
else
    test_warn "SSH CA secret not found in devenv namespace"
fi

# Check if devenv trusts the Vault SSH CA
DEVENV_POD=$(kubectl get pod -l app=devenv -n "$DEVENV_NAMESPACE" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
if [[ -n "$DEVENV_POD" ]]; then
    # Check if SSH CA is trusted in sshd config
    TRUSTED_CA=$(kubectl exec -n "$DEVENV_NAMESPACE" "$DEVENV_POD" -- cat /etc/ssh/sshd_config 2>/dev/null | grep -i "TrustedUserCAKeys" || echo "")
    if [[ -n "$TRUSTED_CA" ]]; then
        test_pass "DevEnv SSH server configured to trust Vault CA"
    else
        test_info "DevEnv SSH server not configured for CA-signed certificates"
    fi
fi

echo ""

# ==========================================
# Connectivity Tests
# ==========================================
echo "--- Connectivity Tests ---"

# Test controller API port
if kubectl exec -n "$BOUNDARY_NAMESPACE" "$CONTROLLER_POD" -- nc -z 127.0.0.1 9200 2>/dev/null; then
    test_pass "Controller API port (9200) accessible"
else
    test_fail "Controller API port (9200) not accessible"
fi

# Test controller cluster port
if kubectl exec -n "$BOUNDARY_NAMESPACE" "$CONTROLLER_POD" -- nc -z 127.0.0.1 9201 2>/dev/null; then
    test_pass "Controller cluster port (9201) accessible"
else
    test_fail "Controller cluster port (9201) not accessible"
fi

# Test worker proxy port
WORKER_POD=$(kubectl get pod -l app=boundary-worker -n "$BOUNDARY_NAMESPACE" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
if [[ -n "$WORKER_POD" ]]; then
    if kubectl exec -n "$BOUNDARY_NAMESPACE" "$WORKER_POD" -- nc -z 127.0.0.1 9202 2>/dev/null; then
        test_pass "Worker proxy port (9202) accessible"
    else
        test_fail "Worker proxy port (9202) not accessible"
    fi
fi

# Test database connectivity from controller
if kubectl exec -n "$BOUNDARY_NAMESPACE" "$CONTROLLER_POD" -- nc -z boundary-postgres.boundary.svc.cluster.local 5432 2>/dev/null; then
    test_pass "Database connectivity from controller"
else
    test_fail "Cannot reach database from controller"
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
echo -e "${YELLOW}Warnings${NC}: $WARNINGS"
echo -e "${RED}Failed${NC}: $FAILED"
echo ""

if [[ $FAILED -gt 0 ]]; then
    echo -e "${RED}RESULT: SOME TESTS FAILED${NC}"
    exit 1
elif [[ $WARNINGS -gt 0 ]]; then
    echo -e "${YELLOW}RESULT: PASSED WITH WARNINGS${NC}"
    echo ""
    echo "To resolve warnings, run:"
    echo "  ./platform/boundary/scripts/configure-targets.sh"
    echo "  ./platform/boundary/scripts/configure-oidc-auth.sh"
    exit 0
else
    echo -e "${GREEN}RESULT: ALL TESTS PASSED${NC}"
    exit 0
fi
