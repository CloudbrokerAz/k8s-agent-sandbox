#!/bin/bash
set -euo pipefail

NAMESPACE="${1:-vault}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=========================================="
echo "  Vault Initialization"
echo "=========================================="
echo ""

# Check if already initialized
INIT_STATUS=$(kubectl exec -n "$NAMESPACE" vault-0 -- vault status -format=json 2>/dev/null | jq -r '.initialized' || echo "false")

if [[ "$INIT_STATUS" == "true" ]]; then
    echo "⚠️  Vault already initialized"
    SEALED=$(kubectl exec -n "$NAMESPACE" vault-0 -- vault status -format=json | jq -r '.sealed')
    if [[ "$SEALED" == "true" ]]; then
        echo "🔒 Vault is sealed - use unseal keys to unlock"
    else
        echo "✅ Vault is unsealed and ready"
    fi
    exit 0
fi

echo "🔧 Initializing Vault..."
INIT_OUTPUT=$(kubectl exec -n "$NAMESPACE" vault-0 -- vault operator init -key-shares=5 -key-threshold=3 -format=json)

UNSEAL_KEY_1=$(echo "$INIT_OUTPUT" | jq -r '.unseal_keys_b64[0]')
UNSEAL_KEY_2=$(echo "$INIT_OUTPUT" | jq -r '.unseal_keys_b64[1]')
UNSEAL_KEY_3=$(echo "$INIT_OUTPUT" | jq -r '.unseal_keys_b64[2]')
UNSEAL_KEY_4=$(echo "$INIT_OUTPUT" | jq -r '.unseal_keys_b64[3]')
UNSEAL_KEY_5=$(echo "$INIT_OUTPUT" | jq -r '.unseal_keys_b64[4]')
ROOT_TOKEN=$(echo "$INIT_OUTPUT" | jq -r '.root_token')

echo "✅ Vault initialized"
echo ""

echo "🔓 Unsealing Vault..."
kubectl exec -n "$NAMESPACE" vault-0 -- vault operator unseal "$UNSEAL_KEY_1" > /dev/null
kubectl exec -n "$NAMESPACE" vault-0 -- vault operator unseal "$UNSEAL_KEY_2" > /dev/null
kubectl exec -n "$NAMESPACE" vault-0 -- vault operator unseal "$UNSEAL_KEY_3" > /dev/null
echo "✅ Vault unsealed"

# Save keys
cat > "$SCRIPT_DIR/vault-keys.txt" << EOF
========================================
  VAULT KEYS - SAVE SECURELY!
========================================
Unseal Key 1: $UNSEAL_KEY_1
Unseal Key 2: $UNSEAL_KEY_2
Unseal Key 3: $UNSEAL_KEY_3
Unseal Key 4: $UNSEAL_KEY_4
Unseal Key 5: $UNSEAL_KEY_5

Root Token: $ROOT_TOKEN
========================================
EOF
chmod 600 "$SCRIPT_DIR/vault-keys.txt"

echo ""
echo "=========================================="
echo "  ⚠️  SAVE THESE KEYS!"
echo "=========================================="
echo "Root Token: $ROOT_TOKEN"
echo ""
echo "Keys saved to: $SCRIPT_DIR/vault-keys.txt"
echo ""
echo "Next: ./configure-ssh-engine.sh"
