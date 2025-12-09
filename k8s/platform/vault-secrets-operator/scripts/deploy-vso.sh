#!/bin/bash
set -euo pipefail

# Deploy Vault Secrets Operator using Helm

NAMESPACE="${1:-vault-secrets-operator-system}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFESTS_DIR="$SCRIPT_DIR/../manifests"

echo "=========================================="
echo "  Vault Secrets Operator Deployment"
echo "=========================================="
echo ""

# Check prerequisites
if ! command -v kubectl &> /dev/null; then
    echo "❌ kubectl is required but not installed"
    exit 1
fi

if ! command -v helm &> /dev/null; then
    echo "📦 Installing Helm..."
    curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
fi

if ! kubectl cluster-info &> /dev/null; then
    echo "❌ Cannot connect to Kubernetes cluster"
    exit 1
fi

echo "✅ Prerequisites met"
echo ""

# Check if Vault is running
if ! kubectl get pod vault-0 -n vault &> /dev/null; then
    echo "❌ Vault is not deployed. Run vault deployment first."
    exit 1
fi

echo "✅ Vault is running"
echo ""

# Add HashiCorp Helm repo
echo "📦 Adding HashiCorp Helm repository..."
helm repo add hashicorp https://helm.releases.hashicorp.com 2>/dev/null || true
helm repo update

# Create namespace
echo "→ Creating namespace..."
kubectl apply -f "$MANIFESTS_DIR/01-namespace.yaml"

# Install VSO via Helm
echo "→ Installing Vault Secrets Operator..."
helm upgrade --install vault-secrets-operator hashicorp/vault-secrets-operator \
    --namespace "$NAMESPACE" \
    --set defaultVaultConnection.enabled=false \
    --set defaultAuthMethod.enabled=false \
    --wait \
    --timeout 5m

echo ""
echo "⏳ Waiting for operator to be ready..."
kubectl rollout status deployment/vault-secrets-operator-controller-manager -n "$NAMESPACE" --timeout=120s

echo ""
echo "→ Applying VaultConnection and VaultAuth..."
kubectl apply -f "$MANIFESTS_DIR/02-vaultconnection.yaml"
kubectl apply -f "$MANIFESTS_DIR/03-vaultauth.yaml"

echo ""
echo "=========================================="
echo "  ✅ Vault Secrets Operator Deployed"
echo "=========================================="
echo ""
echo "Operator pods:"
kubectl get pods -n "$NAMESPACE"
echo ""
echo "Custom Resources:"
kubectl get vaultconnection,vaultauth -A
echo ""
echo "⚠️  Important: Configure Vault Kubernetes auth before syncing secrets"
echo ""
echo "Next steps:"
echo "  1. Initialize Vault:  ../vault/scripts/init-vault.sh"
echo "  2. Configure K8s auth: ./configure-vault-k8s-auth.sh"
echo "  3. Create secrets in Vault and sync with VaultStaticSecret CRs"
