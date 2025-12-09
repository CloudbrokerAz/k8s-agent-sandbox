#!/bin/bash
set -euo pipefail

# Teardown dev environment from Kubernetes
# Usage: ./teardown.sh [namespace]

NAMESPACE="${1:-devenv}"

echo "⚠️  WARNING: This will delete the dev environment and ALL data in namespace: ${NAMESPACE}"
echo ""
read -p "Are you sure you want to continue? (yes/no): " CONFIRM

if [ "$CONFIRM" != "yes" ]; then
  echo "Aborted."
  exit 0
fi

echo ""
echo "Deleting namespace: ${NAMESPACE}"
kubectl delete namespace "${NAMESPACE}" --ignore-not-found=true

echo ""
echo "✅ Teardown complete."
echo ""
echo "Note: PersistentVolumes may still exist depending on your cluster's ReclaimPolicy."
echo "Check with: kubectl get pv"
