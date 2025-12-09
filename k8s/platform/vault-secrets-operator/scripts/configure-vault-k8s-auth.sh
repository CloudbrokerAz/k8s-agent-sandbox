#!/bin/bash
set -euo pipefail

# Configure Vault Kubernetes Auth for VSO

VAULT_NAMESPACE="${1:-vault}"
VSO_NAMESPACE="${2:-vault-secrets-operator-system}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=========================================="
echo "  Vault Kubernetes Auth Configuration"
echo "=========================================="
echo ""

# Check prerequisites
if ! command -v kubectl &> /dev/null; then
    echo "❌ kubectl is required"
    exit 1
fi

# Get Vault root token
VAULT_KEYS_FILE="$SCRIPT_DIR/../../vault/scripts/vault-keys.txt"
if [[ -z "${VAULT_TOKEN:-}" ]]; then
    if [[ -f "$VAULT_KEYS_FILE" ]]; then
        VAULT_TOKEN=$(grep "Root Token:" "$VAULT_KEYS_FILE" | awk '{print $3}')
        echo "✅ Found Vault token from vault-keys.txt"
    else
        echo "Enter Vault root token:"
        read -rs VAULT_TOKEN
    fi
fi

# Check Vault status
SEALED=$(kubectl exec -n "$VAULT_NAMESPACE" vault-0 -- vault status -format=json 2>/dev/null | jq -r '.sealed' || echo "true")
if [[ "$SEALED" == "true" ]]; then
    echo "❌ Vault is sealed. Run init-vault.sh first."
    exit 1
fi

echo "✅ Vault is unsealed"
echo ""

# Get Kubernetes host
K8S_HOST="https://kubernetes.default.svc"

# Get VSO ServiceAccount JWT and CA
echo "→ Getting Kubernetes auth details..."
VSO_SA="vault-secrets-operator-controller-manager"
VSO_SA_SECRET=$(kubectl get sa "$VSO_SA" -n "$VSO_NAMESPACE" -o jsonpath='{.secrets[0].name}' 2>/dev/null || echo "")

# For Kubernetes 1.24+, create a token
if [[ -z "$VSO_SA_SECRET" ]]; then
    echo "  Creating ServiceAccount token..."
    VSO_JWT=$(kubectl create token "$VSO_SA" -n "$VSO_NAMESPACE" --duration=87600h)
else
    VSO_JWT=$(kubectl get secret "$VSO_SA_SECRET" -n "$VSO_NAMESPACE" -o jsonpath='{.data.token}' | base64 -d)
fi

# Get CA cert
K8S_CA_CERT=$(kubectl config view --raw --minify --flatten -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' | base64 -d)

echo "✅ Got Kubernetes auth details"
echo ""

# Configure Vault
echo "→ Enabling Kubernetes auth in Vault..."
kubectl exec -n "$VAULT_NAMESPACE" vault-0 -- sh -c "
    export VAULT_TOKEN='$VAULT_TOKEN'

    # Enable kubernetes auth
    vault auth enable kubernetes 2>/dev/null || echo '  (already enabled)'

    # Configure kubernetes auth
    vault write auth/kubernetes/config \
        kubernetes_host='$K8S_HOST' \
        kubernetes_ca_cert='$K8S_CA_CERT' \
        disable_local_ca_jwt=true
"

echo "✅ Kubernetes auth enabled"
echo ""

# Create policy for VSO
echo "→ Creating Vault policies..."
kubectl exec -n "$VAULT_NAMESPACE" vault-0 -- sh -c "
    export VAULT_TOKEN='$VAULT_TOKEN'

    # VSO operator policy - can read all secrets
    vault policy write vault-secrets-operator - <<EOF
path \"secret/*\" {
  capabilities = [\"read\", \"list\"]
}
path \"ssh/*\" {
  capabilities = [\"read\", \"list\", \"create\", \"update\"]
}
EOF

    # DevEnv secrets policy
    vault policy write devenv-secrets - <<EOF
path \"secret/data/devenv/*\" {
  capabilities = [\"read\", \"list\"]
}
path \"ssh/sign/devenv-access\" {
  capabilities = [\"create\", \"update\"]
}
EOF
"

echo "✅ Policies created"
echo ""

# Create Vault roles
echo "→ Creating Kubernetes auth roles..."
kubectl exec -n "$VAULT_NAMESPACE" vault-0 -- sh -c "
    export VAULT_TOKEN='$VAULT_TOKEN'

    # Role for VSO operator
    vault write auth/kubernetes/role/vault-secrets-operator \
        bound_service_account_names=vault-secrets-operator-controller-manager \
        bound_service_account_namespaces=$VSO_NAMESPACE \
        policies=vault-secrets-operator \
        ttl=1h

    # Role for devenv - accept all service accounts in devenv namespace
    # This allows VSO to authenticate on behalf of the devenv namespace
    vault write auth/kubernetes/role/devenv-secrets \
        bound_service_account_names='*' \
        bound_service_account_namespaces=devenv,vault-secrets-operator-system \
        policies=devenv-secrets \
        ttl=1h
"

echo "✅ Roles created"
echo ""

# Enable KV secrets engine
echo "→ Enabling KV secrets engine..."
kubectl exec -n "$VAULT_NAMESPACE" vault-0 -- sh -c "
    export VAULT_TOKEN='$VAULT_TOKEN'
    vault secrets enable -path=secret kv-v2 2>/dev/null || echo '  (already enabled)'
"

echo "✅ KV secrets engine enabled"
echo ""

# Create example secret with correct key names for VaultStaticSecret templates
echo "→ Creating example secret..."
kubectl exec -n "$VAULT_NAMESPACE" vault-0 -- sh -c "
    export VAULT_TOKEN='$VAULT_TOKEN'
    vault kv put secret/devenv/credentials \
        github_token=placeholder-update-me \
        langfuse_host= \
        langfuse_public_key= \
        langfuse_secret_key=
"

echo "✅ Example secret created at secret/devenv/credentials"
echo "   Keys: github_token, langfuse_host, langfuse_public_key, langfuse_secret_key"
echo "   Update with real values using: ./configure-secrets.sh"
echo ""

echo "=========================================="
echo "  ✅ Vault Kubernetes Auth Configured"
echo "=========================================="
echo ""
echo "Configured:"
echo "  - Kubernetes auth method enabled"
echo "  - vault-secrets-operator role for VSO"
echo "  - devenv-secrets role for devenv namespace"
echo "  - KV-v2 secrets engine at 'secret/'"
echo "  - Example secret at 'secret/devenv/credentials'"
echo ""
echo "Next steps:"
echo "  1. Apply VaultStaticSecret to sync secrets:"
echo "     kubectl apply -f ../manifests/04-vaultstaticsecret-example.yaml"
echo ""
echo "  2. Verify secret sync:"
echo "     kubectl get secret devenv-vault-secrets -n devenv -o yaml"
