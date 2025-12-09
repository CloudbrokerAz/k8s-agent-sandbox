#!/bin/bash
set -euo pipefail

# Master teardown script for the complete K8s platform
# Removes: VSO, Boundary, Vault, and DevEnv

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
K8S_DIR="$(dirname "$SCRIPT_DIR")"

echo "=========================================="
echo "  Complete Platform Teardown"
echo "=========================================="
echo ""
echo "This will remove:"
echo "  1. Vault Secrets Operator"
echo "  2. Boundary (controller, worker, postgres)"
echo "  3. Vault"
echo "  4. Agent Sandbox (devenv)"
echo ""
echo "WARNING: This will delete all data!"
echo ""

read -p "Are you sure you want to proceed? (yes/no): " confirm
if [[ "$confirm" != "yes" ]]; then
    echo "Cancelled"
    exit 0
fi

echo ""
echo "=========================================="
echo "  Step 1: Remove Vault Secrets Operator"
echo "=========================================="
echo ""

# Remove VSO custom resources first
kubectl delete vaultstaticsecret --all -n devenv 2>/dev/null || true
kubectl delete vaultauth --all -n devenv 2>/dev/null || true
kubectl delete vaultconnection --all -n devenv 2>/dev/null || true
kubectl delete vaultauth --all -n vault-secrets-operator-system 2>/dev/null || true
kubectl delete vaultconnection --all -n vault-secrets-operator-system 2>/dev/null || true

# Uninstall Helm release
if helm status vault-secrets-operator -n vault-secrets-operator-system &>/dev/null; then
    helm uninstall vault-secrets-operator -n vault-secrets-operator-system --wait
fi

# Delete namespace
kubectl delete namespace vault-secrets-operator-system --timeout=60s 2>/dev/null || true
echo "Vault Secrets Operator removed"

echo ""
echo "=========================================="
echo "  Step 2: Remove Boundary"
echo "=========================================="
echo ""

# Delete Boundary components
kubectl delete deployment boundary-controller -n boundary 2>/dev/null || true
kubectl delete deployment boundary-worker -n boundary 2>/dev/null || true
kubectl delete statefulset boundary-postgres -n boundary 2>/dev/null || true
kubectl delete job boundary-db-init -n boundary 2>/dev/null || true
kubectl delete pvc -l app=boundary-postgres -n boundary 2>/dev/null || true
kubectl delete namespace boundary --timeout=60s 2>/dev/null || true
echo "Boundary removed"

echo ""
echo "=========================================="
echo "  Step 3: Remove Vault"
echo "=========================================="
echo ""

kubectl delete statefulset vault -n vault 2>/dev/null || true
kubectl delete pvc -l app=vault -n vault 2>/dev/null || true
kubectl delete namespace vault --timeout=60s 2>/dev/null || true

# Remove vault keys file
rm -f "$K8S_DIR/platform/vault/scripts/vault-keys.txt" 2>/dev/null || true
echo "Vault removed"

echo ""
echo "=========================================="
echo "  Step 4: Remove Agent Sandbox (DevEnv)"
echo "=========================================="
echo ""

kubectl delete statefulset devenv -n devenv 2>/dev/null || true
kubectl delete pvc -l app=devenv -n devenv 2>/dev/null || true
kubectl delete namespace devenv --timeout=60s 2>/dev/null || true
echo "Agent Sandbox removed"

echo ""
echo "=========================================="
echo "  Cleanup Complete"
echo "=========================================="
echo ""

# Show remaining resources
REMAINING=$(kubectl get ns 2>/dev/null | grep -E "(devenv|boundary|vault)" || true)
if [[ -n "$REMAINING" ]]; then
    echo "Remaining namespaces (may still be terminating):"
    echo "$REMAINING"
else
    echo "All platform namespaces removed"
fi

echo ""
echo "To also remove the Kind cluster:"
echo "  kind delete cluster --name sandbox"
echo ""
