#!/bin/bash
set -euo pipefail

# Add Enterprise license to existing Boundary deployment
# Does NOT regenerate KMS keys or database credentials

NAMESPACE="${1:-boundary}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_LICENSE_FILE="$SCRIPT_DIR/../../../scripts/license/boundary.hclic"
BOUNDARY_LICENSE_FILE="${BOUNDARY_LICENSE_FILE:-$DEFAULT_LICENSE_FILE}"

echo "=========================================="
echo "  Add Boundary Enterprise License"
echo "=========================================="
echo ""

if [[ -f "$BOUNDARY_LICENSE_FILE" ]]; then
    echo "📄 License file: $BOUNDARY_LICENSE_FILE"
    kubectl create secret generic boundary-license \
        --namespace="$NAMESPACE" \
        --from-file=license="$BOUNDARY_LICENSE_FILE" \
        --dry-run=client -o yaml | kubectl apply -f -
    echo "✅ Enterprise license secret created/updated"
    echo ""
    echo "Restart Boundary to apply license:"
    echo "  kubectl rollout restart deployment/boundary-controller -n $NAMESPACE"
    echo "  kubectl rollout restart deployment/boundary-worker -n $NAMESPACE"
elif [[ -n "${BOUNDARY_LICENSE:-}" ]]; then
    echo "📄 License from environment variable"
    kubectl create secret generic boundary-license \
        --namespace="$NAMESPACE" \
        --from-literal=license="$BOUNDARY_LICENSE" \
        --dry-run=client -o yaml | kubectl apply -f -
    echo "✅ Enterprise license secret created/updated"
else
    echo "❌ No license found"
    echo "   Place license at: k8s/scripts/license/boundary.hclic"
    echo "   Or set BOUNDARY_LICENSE_FILE or BOUNDARY_LICENSE env var"
    exit 1
fi
