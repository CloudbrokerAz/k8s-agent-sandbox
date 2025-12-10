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
echo "🗑️  Deleting Boundary namespace and all resources..."
kubectl delete namespace "$NAMESPACE" --ignore-not-found=true

echo ""
echo "=========================================="
echo "  ✅ Boundary Teardown Complete"
echo "=========================================="
echo ""
echo "Note: PersistentVolumes may still exist if using 'Retain' policy."
echo "Check with: kubectl get pv | grep boundary"
echo ""
