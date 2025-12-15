#!/bin/bash
# test-ssh-ca-config.sh - Test that SSH CA is properly configured in sandboxes
# This test verifies the Vault SSH CA mount and sshd configuration
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test-helpers.sh" 2>/dev/null || true

echo "========================================"
echo "  Testing SSH CA Configuration"
echo "========================================"
echo ""

FAILED=0

# Test 1: Check vault-ssh-ca secret exists in devenv
echo "Test 1: Checking vault-ssh-ca secret exists..."
if kubectl get secret vault-ssh-ca -n devenv &>/dev/null; then
    echo "  ✅ Secret vault-ssh-ca exists in devenv namespace"
else
    echo "  ❌ Secret vault-ssh-ca NOT found in devenv namespace"
    FAILED=1
fi

# Test 2: Check secret has expected key
echo ""
echo "Test 2: Checking secret has vault-ssh-ca.pub key..."
if kubectl get secret vault-ssh-ca -n devenv -o jsonpath='{.data.vault-ssh-ca\.pub}' 2>/dev/null | base64 -d | grep -q "ssh-rsa"; then
    echo "  ✅ Secret contains valid SSH CA public key"
else
    echo "  ❌ Secret does not contain valid SSH CA public key"
    FAILED=1
fi

# Test 3: Check SSH CA is mounted in gemini-sandbox
echo ""
echo "Test 3: Checking SSH CA mounted in gemini-sandbox..."
if kubectl exec -n devenv gemini-sandbox -- test -f /vault-ssh-ca/vault-ssh-ca.pub 2>/dev/null; then
    echo "  ✅ SSH CA mounted at /vault-ssh-ca/vault-ssh-ca.pub"
else
    echo "  ❌ SSH CA NOT mounted in gemini-sandbox"
    FAILED=1
fi

# Test 4: Check SSH CA is mounted in claude-code-sandbox
echo ""
echo "Test 4: Checking SSH CA mounted in claude-code-sandbox..."
if kubectl exec -n devenv claude-code-sandbox -- test -f /vault-ssh-ca/vault-ssh-ca.pub 2>/dev/null; then
    echo "  ✅ SSH CA mounted at /vault-ssh-ca/vault-ssh-ca.pub"
else
    echo "  ❌ SSH CA NOT mounted in claude-code-sandbox"
    FAILED=1
fi

# Test 5: Check TrustedUserCAKeys configured in gemini-sandbox
echo ""
echo "Test 5: Checking TrustedUserCAKeys in gemini-sandbox sshd_config..."
if kubectl exec -n devenv gemini-sandbox -- grep -q "TrustedUserCAKeys /vault-ssh-ca/vault-ssh-ca.pub" /etc/ssh/sshd_config 2>/dev/null; then
    echo "  ✅ TrustedUserCAKeys points to mount path"
else
    echo "  ❌ TrustedUserCAKeys NOT configured correctly"
    FAILED=1
fi

# Test 6: Check TrustedUserCAKeys configured in claude-code-sandbox
echo ""
echo "Test 6: Checking TrustedUserCAKeys in claude-code-sandbox sshd_config..."
if kubectl exec -n devenv claude-code-sandbox -- grep -q "TrustedUserCAKeys /vault-ssh-ca/vault-ssh-ca.pub" /etc/ssh/sshd_config 2>/dev/null; then
    echo "  ✅ TrustedUserCAKeys points to mount path"
else
    echo "  ❌ TrustedUserCAKeys NOT configured correctly"
    FAILED=1
fi

# Test 7: Check sshd is running on port 22
echo ""
echo "Test 7: Checking sshd running on port 22 in gemini-sandbox..."
if kubectl exec -n devenv gemini-sandbox -- ss -tlnp 2>/dev/null | grep -q ":22 "; then
    echo "  ✅ sshd listening on port 22"
else
    echo "  ❌ sshd NOT listening on port 22"
    FAILED=1
fi

# Test 8: Check PubkeyAuthentication enabled
echo ""
echo "Test 8: Checking PubkeyAuthentication enabled..."
if kubectl exec -n devenv gemini-sandbox -- grep -q "^PubkeyAuthentication yes" /etc/ssh/sshd_config 2>/dev/null; then
    echo "  ✅ PubkeyAuthentication enabled"
else
    echo "  ❌ PubkeyAuthentication NOT enabled"
    FAILED=1
fi

# Test 9: Verify SSH CA matches between Vault and mounted secret
echo ""
echo "Test 9: Verifying SSH CA key consistency..."
VAULT_CA=$(kubectl get secret vault-ssh-ca -n devenv -o jsonpath='{.data.vault-ssh-ca\.pub}' 2>/dev/null | base64 -d | head -c 100)
MOUNTED_CA=$(kubectl exec -n devenv gemini-sandbox -- head -c 100 /vault-ssh-ca/vault-ssh-ca.pub 2>/dev/null)

if [[ "$VAULT_CA" == "$MOUNTED_CA" ]] && [[ -n "$VAULT_CA" ]]; then
    echo "  ✅ SSH CA key is consistent between secret and mount"
else
    echo "  ❌ SSH CA key mismatch or missing"
    FAILED=1
fi

# Note: Actual SSH connectivity via OIDC flow is tested by:
#   - test-oidc-browser.sh (browser-based OIDC auth)
#   - test-boundary.sh (Boundary target connectivity)
# To test manually: boundary connect ssh -target-id=<target> -- -l node

echo ""
echo "========================================"
if [ $FAILED -eq 0 ]; then
    echo "  ✅ All SSH CA tests passed!"
    echo "========================================"
    exit 0
else
    echo "  ❌ Some SSH CA tests failed"
    echo "========================================"
    exit 1
fi
