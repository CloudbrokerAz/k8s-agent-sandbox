#!/bin/bash
set -euo pipefail

# Teardown Boundary deployment
# Following pattern from scripts/teardown.sh in the k8s root

NAMESPACE="${1:-boundary}"

echo "=========================================="
echo "  Boundary Teardown"
echo "=========================================="
echo ""
echo "⚠️  WARNING: This will delete the Boundary deployment"
echo "    including all data in PostgreSQL!"
echo ""
echo "Namespace to delete: $NAMESPACE"
echo ""
read -p "Are you sure you want to continue? (yes/no): " confirm

if [[ "$confirm" != "yes" ]]; then
    echo "❌ Teardown cancelled"
    exit 0
fi

echo ""
echo "🗑️  Deleting Boundary resources..."

# Delete ingress resources first
echo "  → Deleting ingress resources..."
kubectl delete ingress boundary boundary-worker -n "$NAMESPACE" --ignore-not-found=true 2>/dev/null || true

# Delete deployments and jobs
echo "  → Deleting deployments..."
kubectl delete deployment boundary-controller boundary-worker -n "$NAMESPACE" --ignore-not-found=true 2>/dev/null || true
kubectl delete job boundary-db-init -n "$NAMESPACE" --ignore-not-found=true 2>/dev/null || true
kubectl delete pod boundary-db-init -n "$NAMESPACE" --ignore-not-found=true 2>/dev/null || true

# Delete statefulset
echo "  → Deleting PostgreSQL..."
kubectl delete statefulset boundary-postgres -n "$NAMESPACE" --ignore-not-found=true 2>/dev/null || true

# Delete PVCs
echo "  → Deleting PVCs..."
kubectl delete pvc -l app=boundary-postgres -n "$NAMESPACE" --ignore-not-found=true 2>/dev/null || true

# Delete namespace
echo "  → Deleting namespace..."
kubectl delete namespace "$NAMESPACE" --ignore-not-found=true --timeout=60s

# Clean up credential files
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
rm -f "$SCRIPT_DIR/boundary-credentials.txt" 2>/dev/null || true
rm -f "$SCRIPT_DIR/boundary-oidc-config.txt" 2>/dev/null || true

echo ""
echo "=========================================="
echo "  ✅ Boundary Teardown Complete"
echo "=========================================="
echo ""
echo "Note: PersistentVolumes may still exist if using 'Retain' policy."
echo "Check with: kubectl get pv | grep boundary"
echo ""
