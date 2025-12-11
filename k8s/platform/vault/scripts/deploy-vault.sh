#!/bin/bash
set -euo pipefail

NAMESPACE="${1:-vault}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFESTS_DIR="$SCRIPT_DIR/../manifests"

echo "=========================================="
echo "  Vault Deployment"
echo "=========================================="
echo ""

if ! kubectl cluster-info &> /dev/null; then
    echo "❌ Cannot connect to Kubernetes cluster"
    exit 1
fi

echo "✅ Connected to Kubernetes cluster"
echo ""

echo "📦 Deploying Vault components..."
kubectl apply -f "$MANIFESTS_DIR/01-namespace.yaml"
kubectl apply -f "$MANIFESTS_DIR/03-configmap.yaml"
kubectl apply -f "$MANIFESTS_DIR/04-rbac.yaml"
kubectl apply -f "$MANIFESTS_DIR/05-statefulset.yaml"
kubectl apply -f "$MANIFESTS_DIR/06-service.yaml"

echo "  → Applying TLS Certificate..."
kubectl apply -f "$MANIFESTS_DIR/08-tls-secret.yaml"

echo "  → Applying Ingress Resource..."
kubectl apply -f "$MANIFESTS_DIR/07-ingress.yaml"

echo ""
echo "⏳ Waiting for Vault pod..."
kubectl rollout status statefulset/vault -n "$NAMESPACE" --timeout=180s

echo ""
echo "=========================================="
echo "  ✅ Vault Deployed"
echo "=========================================="
echo ""
echo "Components:"
kubectl get pods -n "$NAMESPACE"
echo ""
echo "Services:"
kubectl get svc -n "$NAMESPACE"
echo ""
echo "Ingress:"
kubectl get ingress -n "$NAMESPACE"
echo ""
echo "Access Information:"
echo "  URL: https://vault.local"
echo "  (Add '127.0.0.1 vault.local' to /etc/hosts if needed)"
echo ""
echo "⚠️  Vault is SEALED - run ./init-vault.sh next"
