#!/bin/bash
set -euo pipefail

# Unseal Vault using keys from vault-keys.txt
# This script can be run manually or automated via a CronJob/init container

NAMESPACE="${1:-vault}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KEYS_FILE="$SCRIPT_DIR/vault-keys.txt"

echo "=========================================="
echo "  Vault Unseal"
echo "=========================================="
echo ""

# Check if vault-keys.txt exists
if [[ ! -f "$KEYS_FILE" ]]; then
    echo "❌ Vault keys file not found: $KEYS_FILE"
    echo ""
    echo "Vault must be initialized first:"
    echo "  ./init-vault.sh"
    exit 1
fi

# Check if Vault pod is running
if ! kubectl get pod vault-0 -n "$NAMESPACE" &>/dev/null; then
    echo "❌ Vault pod not found in namespace '$NAMESPACE'"
    exit 1
fi

# Wait for pod to be ready
echo "⏳ Waiting for Vault pod to be ready..."
kubectl wait --for=condition=Ready pod/vault-0 -n "$NAMESPACE" --timeout=60s || true

# Check Vault status
VAULT_STATUS=$(kubectl exec -n "$NAMESPACE" vault-0 -- vault status -format=json 2>/dev/null || echo '{"initialized":false,"sealed":true}')
INITIALIZED=$(echo "$VAULT_STATUS" | jq -r '.initialized')
SEALED=$(echo "$VAULT_STATUS" | jq -r '.sealed')

if [[ "$INITIALIZED" != "true" ]]; then
    echo "❌ Vault is not initialized"
    echo ""
    echo "Initialize Vault first:"
    echo "  ./init-vault.sh"
    exit 1
fi

if [[ "$SEALED" != "true" ]]; then
    echo "✅ Vault is already unsealed"
    exit 0
fi

echo "🔒 Vault is sealed, unsealing..."

# Read unseal keys from file
# Use first 3 keys (threshold=3 for dev, threshold=1 for deploy-all.sh)
UNSEAL_KEY_1=$(grep "^Unseal Key 1:" "$KEYS_FILE" 2>/dev/null | awk '{print $4}' || \
               grep "^Unseal Key:" "$KEYS_FILE" 2>/dev/null | awk '{print $3}')
UNSEAL_KEY_2=$(grep "^Unseal Key 2:" "$KEYS_FILE" 2>/dev/null | awk '{print $4}' || echo "")
UNSEAL_KEY_3=$(grep "^Unseal Key 3:" "$KEYS_FILE" 2>/dev/null | awk '{print $4}' || echo "")

if [[ -z "$UNSEAL_KEY_1" ]]; then
    echo "❌ Could not read unseal keys from $KEYS_FILE"
    exit 1
fi

# Unseal with first key
kubectl exec -n "$NAMESPACE" vault-0 -- vault operator unseal "$UNSEAL_KEY_1" > /dev/null
echo "  Key 1/3 applied"

# Check if we need more keys (depends on threshold)
SEALED_AFTER_1=$(kubectl exec -n "$NAMESPACE" vault-0 -- vault status -format=json 2>/dev/null | jq -r '.sealed')
if [[ "$SEALED_AFTER_1" == "false" ]]; then
    echo "✅ Vault unsealed (threshold=1)"
    exit 0
fi

# Apply second key
if [[ -n "$UNSEAL_KEY_2" ]]; then
    kubectl exec -n "$NAMESPACE" vault-0 -- vault operator unseal "$UNSEAL_KEY_2" > /dev/null
    echo "  Key 2/3 applied"
fi

# Check if unsealed
SEALED_AFTER_2=$(kubectl exec -n "$NAMESPACE" vault-0 -- vault status -format=json 2>/dev/null | jq -r '.sealed')
if [[ "$SEALED_AFTER_2" == "false" ]]; then
    echo "✅ Vault unsealed (threshold=2)"
    exit 0
fi

# Apply third key
if [[ -n "$UNSEAL_KEY_3" ]]; then
    kubectl exec -n "$NAMESPACE" vault-0 -- vault operator unseal "$UNSEAL_KEY_3" > /dev/null
    echo "  Key 3/3 applied"
fi

# Final status check
SEALED_FINAL=$(kubectl exec -n "$NAMESPACE" vault-0 -- vault status -format=json 2>/dev/null | jq -r '.sealed')
if [[ "$SEALED_FINAL" == "false" ]]; then
    echo "✅ Vault unsealed successfully"
else
    echo "❌ Vault still sealed after applying keys"
    echo ""
    echo "Check vault status:"
    kubectl exec -n "$NAMESPACE" vault-0 -- vault status
    exit 1
fi
