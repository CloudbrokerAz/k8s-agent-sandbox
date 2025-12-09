#!/bin/bash
set -euo pipefail

# Teardown Vault Secrets Operator

NAMESPACE="${1:-vault-secrets-operator-system}"

echo "=========================================="
echo "  Vault Secrets Operator Teardown"
echo "=========================================="
echo ""
echo "⚠️  This will remove:"
echo "  - VSO Helm release"
echo "  - All VaultConnection, VaultAuth, VaultStaticSecret CRs"
echo "  - VSO namespace"
echo ""
read -p "Continue? (yes/no): " confirm

if [[ "$confirm" != "yes" ]]; then
    echo "❌ Cancelled"
    exit 0
fi

echo ""
echo "🗑️  Removing VSO..."

# Delete custom resources first
kubectl delete vaultstaticsecret --all -A 2>/dev/null || true
kubectl delete vaultdynamicsecret --all -A 2>/dev/null || true
kubectl delete vaultauth --all -A 2>/dev/null || true
kubectl delete vaultconnection --all -A 2>/dev/null || true

# Uninstall Helm release
helm uninstall vault-secrets-operator -n "$NAMESPACE" 2>/dev/null || true

# Delete namespace
kubectl delete namespace "$NAMESPACE" --ignore-not-found=true

echo ""
echo "=========================================="
echo "  ✅ VSO Removed"
echo "=========================================="
