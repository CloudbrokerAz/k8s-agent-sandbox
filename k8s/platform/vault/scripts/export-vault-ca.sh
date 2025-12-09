#!/bin/bash
set -euo pipefail

# Export Vault TLS CA certificate and create Kubernetes secret for devenv pods
# This allows the devenv containers to trust Vault's HTTPS endpoint

VAULT_NAMESPACE="${1:-vault}"
DEVENV_NAMESPACE="${2:-devenv}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=========================================="
echo "  Vault TLS CA Export"
echo "=========================================="
echo ""

# Check if Vault pod is running
if ! kubectl get pod vault-0 -n "$VAULT_NAMESPACE" &>/dev/null; then
    echo "❌ Vault pod not found in namespace $VAULT_NAMESPACE"
    exit 1
fi

# For development mode Vault (no TLS), create a placeholder
VAULT_TLS=$(kubectl get pod vault-0 -n "$VAULT_NAMESPACE" -o jsonpath='{.spec.containers[0].env[?(@.name=="VAULT_LOCAL_CONFIG")].value}' 2>/dev/null || echo "")

if echo "$VAULT_TLS" | grep -q '"tls_disable": 1' 2>/dev/null; then
    echo "ℹ️  Vault is running in dev mode without TLS"
    echo "Creating placeholder CA secret..."

    # Create a self-signed placeholder certificate
    openssl req -x509 -nodes -newkey rsa:2048 \
        -keyout /tmp/vault-ca.key \
        -out "$SCRIPT_DIR/vault-ca.crt" \
        -days 365 \
        -subj "/CN=vault-placeholder-ca" 2>/dev/null

    echo "⚠️  Using placeholder CA - for production, configure Vault with proper TLS"
else
    echo "Extracting Vault TLS CA certificate..."

    # Try to get the CA from the Vault pod's mounted secrets
    if kubectl exec -n "$VAULT_NAMESPACE" vault-0 -- cat /vault/userconfig/vault-server-tls/ca.crt > "$SCRIPT_DIR/vault-ca.crt" 2>/dev/null; then
        echo "✅ Extracted CA from Vault TLS secret"
    elif kubectl exec -n "$VAULT_NAMESPACE" vault-0 -- cat /etc/ssl/certs/vault-ca.crt > "$SCRIPT_DIR/vault-ca.crt" 2>/dev/null; then
        echo "✅ Extracted CA from Vault container"
    else
        echo "ℹ️  Could not extract Vault CA, using Kubernetes CA as fallback"
        # Use the Kubernetes cluster CA as fallback
        kubectl config view --raw --minify --flatten -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' | base64 -d > "$SCRIPT_DIR/vault-ca.crt"
    fi
fi

echo ""
echo "CA certificate saved to: $SCRIPT_DIR/vault-ca.crt"
echo ""

# Create Kubernetes secret for devenv namespace
echo "Creating Kubernetes secret with Vault CA..."
kubectl create namespace "$DEVENV_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic vault-tls-ca \
    --namespace="$DEVENV_NAMESPACE" \
    --from-file=vault-ca.crt="$SCRIPT_DIR/vault-ca.crt" \
    --dry-run=client -o yaml | kubectl apply -f -

echo "✅ Secret 'vault-tls-ca' created in $DEVENV_NAMESPACE namespace"
echo ""
echo "The devenv pods will automatically mount this CA certificate"
echo "and add it to the system trust store on startup."
echo ""
echo "Environment variables set in devenv pods:"
echo "  VAULT_ADDR=https://vault.vault.svc.cluster.local:8200"
echo "  VAULT_CACERT=/vault-ca/vault-ca.crt"
