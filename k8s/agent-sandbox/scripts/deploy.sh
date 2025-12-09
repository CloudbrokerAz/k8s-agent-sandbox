#!/bin/bash
set -euo pipefail

# Deploy dev environment to Kubernetes
# Usage: ./deploy.sh [namespace]

NAMESPACE="${1:-devenv}"
MANIFESTS_DIR="$(dirname "$0")/../manifests"

echo "Deploying dev environment to namespace: ${NAMESPACE}"
echo ""

# Check if kubectl is available
if ! command -v kubectl &> /dev/null; then
  echo "Error: kubectl not found. Please install kubectl."
  exit 1
fi

# Check cluster connectivity
if ! kubectl cluster-info &> /dev/null; then
  echo "Error: Cannot connect to Kubernetes cluster."
  echo "Please check your kubeconfig and cluster status."
  exit 1
fi

echo "Current context: $(kubectl config current-context)"
echo ""

# Validate manifests exist
if [ ! -d "$MANIFESTS_DIR" ]; then
  echo "Error: Manifests directory not found: ${MANIFESTS_DIR}"
  exit 1
fi

# Apply manifests in order
echo "Applying manifests..."
echo ""

kubectl apply -f "${MANIFESTS_DIR}/01-namespace.yaml"
echo "✅ Namespace created/updated"

# Skip secrets - they should be created separately
echo "⏭️  Skipping secrets (create separately with create-secrets.sh)"

# Apply storage class (may fail if not supported on cluster)
if kubectl apply -f "${MANIFESTS_DIR}/03-storageclass.yaml" 2>/dev/null; then
  echo "✅ StorageClass created/updated"
else
  echo "⚠️  StorageClass creation failed (may not be needed on this cluster)"
fi

# Apply network policy (may not be enforced on all clusters)
if kubectl apply -f "${MANIFESTS_DIR}/07-networkpolicy.yaml" 2>/dev/null; then
  echo "✅ NetworkPolicy created/updated"
else
  echo "⚠️  NetworkPolicy creation failed (requires CNI support)"
fi

kubectl apply -f "${MANIFESTS_DIR}/06-service.yaml"
echo "✅ Service created/updated"

kubectl apply -f "${MANIFESTS_DIR}/05-statefulset.yaml"
echo "✅ StatefulSet created/updated"

echo ""
echo "✅ Deployment complete!"
echo ""
echo "Check status with:"
echo "  kubectl get pods -n ${NAMESPACE}"
echo "  kubectl logs -n ${NAMESPACE} devenv-0 -f"
echo ""
echo "Access the dev environment:"
echo "  kubectl exec -it -n ${NAMESPACE} devenv-0 -- /bin/zsh"
echo ""
echo "Or port-forward to access remotely:"
echo "  kubectl port-forward -n ${NAMESPACE} devenv-0 8080:8080"
