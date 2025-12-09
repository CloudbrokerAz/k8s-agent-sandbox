#!/bin/bash
set -euo pipefail

# Scale the dev environment StatefulSet
# Usage: ./scale.sh <replicas> [namespace]

REPLICAS="${1:-}"
NAMESPACE="${2:-devenv}"

if [ -z "$REPLICAS" ]; then
  echo "Error: Number of replicas required"
  echo "Usage: $0 <replicas> [namespace]"
  echo ""
  echo "Examples:"
  echo "  $0 3        # Scale to 3 dev environments"
  echo "  $0 0        # Scale down to 0 (pause all)"
  exit 1
fi

echo "Scaling StatefulSet 'devenv' to ${REPLICAS} replicas in namespace ${NAMESPACE}"
echo ""

kubectl scale statefulset devenv -n "${NAMESPACE}" --replicas="${REPLICAS}"

echo ""
echo "✅ Scaling initiated"
echo ""
echo "Watch progress with:"
echo "  kubectl get pods -n ${NAMESPACE} -w"
echo ""
echo "Access individual environments:"
for ((i=0; i<REPLICAS; i++)); do
  echo "  kubectl exec -it -n ${NAMESPACE} devenv-${i} -- /bin/zsh"
done
