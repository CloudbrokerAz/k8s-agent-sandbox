#!/bin/bash
set -euo pipefail

NAMESPACE="${1:-vault}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=========================================="
echo "  Vault SSH Engine Configuration"
echo "=========================================="
echo ""

# Get root token
if [[ -z "${VAULT_TOKEN:-}" ]]; then
    if [[ -f "$SCRIPT_DIR/vault-keys.txt" ]]; then
        VAULT_TOKEN=$(grep "Root Token:" "$SCRIPT_DIR/vault-keys.txt" | awk '{print $3}')
    else
        echo "Enter Vault root token:"
        read -rs VAULT_TOKEN
    fi
fi

echo "🔧 Enabling SSH secrets engine..."
kubectl exec -n "$NAMESPACE" vault-0 -- sh -c "
    export VAULT_TOKEN='$VAULT_TOKEN'
    vault secrets enable -path=ssh ssh 2>/dev/null || echo '  (already enabled)'
"

echo "🔧 Configuring SSH CA..."
kubectl exec -n "$NAMESPACE" vault-0 -- sh -c "
    export VAULT_TOKEN='$VAULT_TOKEN'
    vault write ssh/config/ca generate_signing_key=true
"

echo "🔧 Creating devenv-access role..."
kubectl exec -n "$NAMESPACE" vault-0 -- sh -c "
    export VAULT_TOKEN='$VAULT_TOKEN'
    vault write ssh/roles/devenv-access \
        key_type=ca \
        ttl=1h \
        max_ttl=24h \
        allow_user_certificates=true \
        allowed_users='node,root' \
        default_user=node \
        default_extensions='permit-pty='
"

echo ""
echo "📋 SSH CA Public Key:"
CA_KEY=$(kubectl exec -n "$NAMESPACE" vault-0 -- sh -c "
    export VAULT_TOKEN='$VAULT_TOKEN'
    vault read -field=public_key ssh/config/ca
")
echo "$CA_KEY"
echo "$CA_KEY" > "$SCRIPT_DIR/vault-ssh-ca.pub"

echo ""
echo "=========================================="
echo "  ✅ SSH Engine Configured"
echo "=========================================="
echo ""
echo "CA key saved to: $SCRIPT_DIR/vault-ssh-ca.pub"
echo ""
echo "To use with devenv:"
echo "  1. Add CA to devenv authorized_keys"
echo "  2. Request cert: vault write ssh/sign/devenv-access public_key=@~/.ssh/id_rsa.pub"
echo "  3. SSH with signed cert"
