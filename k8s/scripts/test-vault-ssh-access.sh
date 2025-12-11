#!/bin/bash
set -euo pipefail

# Test Vault SSH access to claude-code-sandbox pod
# This script validates:
#   1. Pod is running and SSH server is configured
#   2. Vault SSH engine is available
#   3. SSH certificate authentication works

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VAULT_SCRIPTS_DIR="$SCRIPT_DIR/../platform/vault/scripts"

# Options
POD_NAME="${POD_NAME:-claude-code-sandbox}"
POD_NAMESPACE="${POD_NAMESPACE:-devenv}"
VAULT_NAMESPACE="${VAULT_NAMESPACE:-vault}"
VAULT_ROLE="${VAULT_ROLE:-devenv-access}"
SSH_USER="${SSH_USER:-node}"
VERBOSE="${VERBOSE:-false}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Test results
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

# Helper function
run_test() {
    local test_name="$1"
    local test_command="$2"

    ((TESTS_RUN++))

    [[ "$VERBOSE" == "true" ]] && echo -n "  Testing $test_name... "

    if eval "$test_command" &>/dev/null; then
        [[ "$VERBOSE" == "true" ]] && echo -e "${GREEN}✓${NC}"
        ((TESTS_PASSED++))
        return 0
    else
        [[ "$VERBOSE" == "true" ]] && echo -e "${RED}✗${NC}"
        ((TESTS_FAILED++))
        return 1
    fi
}

echo "=========================================="
echo "  Vault SSH Access Test"
echo "=========================================="
echo ""
echo "Testing SSH access to pod: $POD_NAMESPACE/$POD_NAME"
echo ""

# Test Suite 1: Pod Infrastructure
echo "Pod Infrastructure Tests:"
echo ""

# Test 1.1: Pod exists and is running
echo -n "  Pod exists and is running... "
if kubectl get pod "$POD_NAME" -n "$POD_NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null | grep -q "Running"; then
    echo -e "${GREEN}✓${NC}"
    ((TESTS_PASSED++))
else
    echo -e "${RED}✗${NC}"
    echo "    Error: Pod not found or not running"
    ((TESTS_FAILED++))
fi
((TESTS_RUN++))

# Test 1.2: Get pod IP
POD_IP=$(kubectl get pod "$POD_NAME" -n "$POD_NAMESPACE" -o jsonpath='{.status.podIP}' 2>/dev/null || echo "")
if [[ -n "$POD_IP" ]]; then
    echo -e "  Pod IP: ${BLUE}$POD_IP${NC}"
else
    echo -e "  ${RED}✗${NC} Could not get pod IP"
fi

# Test 1.3: Vault SSH CA is mounted
echo -n "  Vault SSH CA mounted... "
if kubectl exec -n "$POD_NAMESPACE" "$POD_NAME" -- test -f /vault-ssh-ca/vault-ssh-ca.pub 2>/dev/null; then
    echo -e "${GREEN}✓${NC}"
    ((TESTS_PASSED++))
else
    echo -e "${RED}✗${NC}"
    echo "    Error: Vault SSH CA not mounted at /vault-ssh-ca/vault-ssh-ca.pub"
    ((TESTS_FAILED++))
fi
((TESTS_RUN++))

# Test 1.4: SSH CA configured in sshd_config
echo -n "  SSH CA configured in sshd... "
if kubectl exec -n "$POD_NAMESPACE" "$POD_NAME" -- sudo grep -q "TrustedUserCAKeys /etc/ssh/vault-ssh-ca.pub" /etc/ssh/sshd_config 2>/dev/null; then
    echo -e "${GREEN}✓${NC}"
    ((TESTS_PASSED++))
else
    echo -e "${RED}✗${NC}"
    echo "    Error: SSH CA not configured in /etc/ssh/sshd_config"
    echo "    Run: kubectl exec -n $POD_NAMESPACE $POD_NAME -- sudo bash -c 'echo TrustedUserCAKeys /etc/ssh/vault-ssh-ca.pub >> /etc/ssh/sshd_config'"
    ((TESTS_FAILED++))
fi
((TESTS_RUN++))

# Test 1.5: SSH server is running
echo -n "  SSH server running... "
if kubectl exec -n "$POD_NAMESPACE" "$POD_NAME" -- pgrep -x sshd &>/dev/null; then
    SSHD_PID=$(kubectl exec -n "$POD_NAMESPACE" "$POD_NAME" -- pgrep -x sshd | head -1)
    echo -e "${GREEN}✓${NC} (PID: $SSHD_PID)"
    ((TESTS_PASSED++))
else
    echo -e "${RED}✗${NC}"
    echo "    Error: SSH server not running"
    echo "    Run: kubectl exec -n $POD_NAMESPACE $POD_NAME -- sudo /usr/sbin/sshd"
    ((TESTS_FAILED++))
fi
((TESTS_RUN++))

echo ""

# Test Suite 2: Vault Infrastructure
echo "Vault Infrastructure Tests:"
echo ""

# Test 2.1: Vault pod is running
echo -n "  Vault pod running... "
if kubectl get pod -n "$VAULT_NAMESPACE" -l app.kubernetes.io/name=vault -o jsonpath='{.items[0].status.phase}' 2>/dev/null | grep -q "Running"; then
    echo -e "${GREEN}✓${NC}"
    ((TESTS_PASSED++))
else
    echo -e "${RED}✗${NC}"
    echo "    Error: Vault pod not running in namespace $VAULT_NAMESPACE"
    ((TESTS_FAILED++))
fi
((TESTS_RUN++))

# Test 2.2: Vault is unsealed
echo -n "  Vault unsealed... "
VAULT_SEALED=$(kubectl exec -n "$VAULT_NAMESPACE" vault-0 -- vault status -format=json 2>/dev/null | jq -r '.sealed' || echo "unknown")
if [[ "$VAULT_SEALED" == "false" ]]; then
    echo -e "${GREEN}✓${NC}"
    ((TESTS_PASSED++))
elif [[ "$VAULT_SEALED" == "true" ]]; then
    echo -e "${RED}✗${NC} (sealed)"
    echo "    Error: Vault is sealed"
    echo "    Run: $VAULT_SCRIPTS_DIR/unseal-vault.sh"
    ((TESTS_FAILED++))
else
    echo -e "${RED}✗${NC} (status unknown)"
    ((TESTS_FAILED++))
fi
((TESTS_RUN++))

# Test 2.3: Vault SSH engine is enabled
echo -n "  Vault SSH engine enabled... "
if kubectl exec -n "$VAULT_NAMESPACE" vault-0 -- sh -c "VAULT_TOKEN=\$(cat /vault/data/keys | grep 'Root Token:' | awk '{print \$3}'); vault secrets list -format=json" 2>/dev/null | jq -e '.["ssh/"]' &>/dev/null; then
    echo -e "${GREEN}✓${NC}"
    ((TESTS_PASSED++))
else
    echo -e "${RED}✗${NC}"
    echo "    Error: SSH secrets engine not enabled"
    echo "    Run: $VAULT_SCRIPTS_DIR/configure-ssh-engine.sh"
    ((TESTS_FAILED++))
fi
((TESTS_RUN++))

# Test 2.4: Vault SSH role exists
echo -n "  Vault SSH role '$VAULT_ROLE' exists... "
if kubectl exec -n "$VAULT_NAMESPACE" vault-0 -- sh -c "VAULT_TOKEN=\$(cat /vault/data/keys | grep 'Root Token:' | awk '{print \$3}'); vault read ssh/roles/$VAULT_ROLE" &>/dev/null; then
    echo -e "${GREEN}✓${NC}"
    ((TESTS_PASSED++))
else
    echo -e "${RED}✗${NC}"
    echo "    Error: Vault SSH role '$VAULT_ROLE' not found"
    echo "    Run: $VAULT_SCRIPTS_DIR/configure-ssh-engine.sh"
    ((TESTS_FAILED++))
fi
((TESTS_RUN++))

echo ""

# Test Suite 3: SSH Access Test
echo "SSH Access Tests:"
echo ""

# Check if we should run SSH access tests
if [[ $TESTS_FAILED -gt 0 ]]; then
    echo -e "${YELLOW}⚠ Skipping SSH access tests due to previous failures${NC}"
    echo "  Fix the issues above and re-run this test"
else
    # Test 3.1: Generate temporary SSH key
    TEMP_DIR=$(mktemp -d)
    TEMP_KEY="$TEMP_DIR/test_key"

    echo -n "  Generating temporary SSH key... "
    if ssh-keygen -t rsa -b 2048 -f "$TEMP_KEY" -N "" -C "vault-ssh-test" &>/dev/null; then
        echo -e "${GREEN}✓${NC}"
        ((TESTS_PASSED++))
    else
        echo -e "${RED}✗${NC}"
        ((TESTS_FAILED++))
    fi
    ((TESTS_RUN++))

    # Test 3.2: Sign public key with Vault
    echo -n "  Signing key with Vault... "

    # Get Vault root token
    if [[ -f "$VAULT_SCRIPTS_DIR/vault-keys.txt" ]]; then
        VAULT_TOKEN=$(grep "Root Token:" "$VAULT_SCRIPTS_DIR/vault-keys.txt" | awk '{print $3}')
    else
        echo -e "${YELLOW}⚠${NC}"
        echo "    Warning: Could not find vault-keys.txt, need Vault token"
        VAULT_TOKEN=""
    fi

    if [[ -n "$VAULT_TOKEN" ]]; then
        # Port forward to Vault
        kubectl port-forward -n "$VAULT_NAMESPACE" svc/vault 8201:8200 &>/dev/null &
        PORT_FORWARD_PID=$!
        sleep 2

        # Sign the key
        if VAULT_ADDR=https://127.0.0.1:8201 VAULT_SKIP_VERIFY=1 VAULT_TOKEN="$VAULT_TOKEN" \
           vault write -field=signed_key "ssh/sign/$VAULT_ROLE" public_key=@"$TEMP_KEY.pub" > "$TEMP_KEY-cert.pub" 2>/dev/null; then
            echo -e "${GREEN}✓${NC}"
            ((TESTS_PASSED++))

            # Kill port-forward
            kill $PORT_FORWARD_PID 2>/dev/null || true
        else
            echo -e "${RED}✗${NC}"
            echo "    Error: Could not sign key with Vault"
            ((TESTS_FAILED++))
            kill $PORT_FORWARD_PID 2>/dev/null || true
        fi
    else
        echo -e "${YELLOW}⚠ Skipped${NC} (no Vault token)"
        ((TESTS_RUN--))
    fi
    ((TESTS_RUN++))

    # Test 3.3: SSH to pod with signed certificate
    if [[ -f "$TEMP_KEY-cert.pub" ]]; then
        echo -n "  SSH access with Vault certificate... "

        # Port forward to pod SSH
        kubectl port-forward -n "$POD_NAMESPACE" "$POD_NAME" 2223:22 &>/dev/null &
        SSH_PORT_FORWARD_PID=$!
        sleep 2

        # Try to SSH
        if ssh -i "$TEMP_KEY" \
               -o CertificateFile="$TEMP_KEY-cert.pub" \
               -o StrictHostKeyChecking=no \
               -o UserKnownHostsFile=/dev/null \
               -o ConnectTimeout=5 \
               -p 2223 \
               "$SSH_USER@localhost" \
               "echo 'SSH access successful'" &>/dev/null; then
            echo -e "${GREEN}✓${NC}"
            ((TESTS_PASSED++))
        else
            echo -e "${RED}✗${NC}"
            echo "    Error: Could not SSH to pod with Vault certificate"
            echo "    Debug: ssh -vvv -i $TEMP_KEY -o CertificateFile=$TEMP_KEY-cert.pub -p 2223 $SSH_USER@localhost"
            ((TESTS_FAILED++))
        fi
        ((TESTS_RUN++))

        # Kill port-forward
        kill $SSH_PORT_FORWARD_PID 2>/dev/null || true
    else
        echo -e "  ${YELLOW}⚠ Skipping SSH test${NC} (no signed certificate)"
    fi

    # Cleanup
    rm -rf "$TEMP_DIR" 2>/dev/null || true
fi

echo ""
echo "=========================================="
echo "  Test Summary"
echo "=========================================="
echo ""
echo "  Total:   $TESTS_RUN"
echo -e "  ${GREEN}Passed:  $TESTS_PASSED${NC}"
[[ $TESTS_FAILED -gt 0 ]] && echo -e "  ${RED}Failed:  $TESTS_FAILED${NC}" || echo "  Failed:  $TESTS_FAILED"
echo ""

if [[ $TESTS_FAILED -eq 0 ]]; then
    echo -e "${GREEN}✅ All tests passed!${NC}"
    echo ""
    echo "You can SSH to the pod using:"
    echo ""
    echo "  1. Generate/use your SSH key:"
    echo "     ssh-keygen -t rsa -f ~/.ssh/id_rsa_vault"
    echo ""
    echo "  2. Sign it with Vault:"
    echo "     VAULT_ADDR=https://vault.local vault write -field=signed_key \\"
    echo "       ssh/sign/$VAULT_ROLE public_key=@~/.ssh/id_rsa_vault.pub > ~/.ssh/id_rsa_vault-cert.pub"
    echo ""
    echo "  3. Port-forward and SSH:"
    echo "     kubectl port-forward -n $POD_NAMESPACE $POD_NAME 2222:22 &"
    echo "     ssh -i ~/.ssh/id_rsa_vault -o CertificateFile=~/.ssh/id_rsa_vault-cert.pub \\"
    echo "       -p 2222 $SSH_USER@localhost"
    echo ""
    echo "  Or configure in ~/.ssh/config:"
    echo "     Host $POD_NAME"
    echo "       HostName localhost"
    echo "       Port 2222"
    echo "       User $SSH_USER"
    echo "       IdentityFile ~/.ssh/id_rsa_vault"
    echo "       CertificateFile ~/.ssh/id_rsa_vault-cert.pub"
    echo "       StrictHostKeyChecking no"
    echo ""
    exit 0
else
    echo -e "${RED}❌ Some tests failed${NC}"
    echo ""
    echo "Troubleshooting:"
    echo "  - Check pod: kubectl get pod $POD_NAME -n $POD_NAMESPACE"
    echo "  - Check logs: kubectl logs $POD_NAME -n $POD_NAMESPACE"
    echo "  - Check SSH CA: kubectl exec -n $POD_NAMESPACE $POD_NAME -- sudo grep TrustedUserCAKeys /etc/ssh/sshd_config"
    echo "  - Restart SSH: kubectl exec -n $POD_NAMESPACE $POD_NAME -- sudo /usr/sbin/sshd"
    echo "  - Configure Vault SSH: $VAULT_SCRIPTS_DIR/configure-ssh-engine.sh"
    echo ""
    exit 1
fi
