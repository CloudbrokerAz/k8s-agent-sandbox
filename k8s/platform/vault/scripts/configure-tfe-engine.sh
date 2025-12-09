#!/bin/bash
set -euo pipefail

# Configure Vault Terraform Cloud/Enterprise Secrets Engine
# This enables dynamic TFE token generation

VAULT_NAMESPACE="${1:-vault}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=========================================="
echo "  Vault TFE Secrets Engine Configuration"
echo "=========================================="
echo ""

# Get Vault root token
if [[ -z "${VAULT_TOKEN:-}" ]]; then
    if [[ -f "$SCRIPT_DIR/vault-keys.txt" ]]; then
        VAULT_TOKEN=$(grep "Root Token:" "$SCRIPT_DIR/vault-keys.txt" | awk '{print $3}')
        echo "✅ Found Vault token"
    else
        echo "Enter Vault root token:"
        read -rs VAULT_TOKEN
    fi
fi

# Check Vault status
SEALED=$(kubectl exec -n "$VAULT_NAMESPACE" vault-0 -- vault status -format=json 2>/dev/null | jq -r '.sealed' || echo "true")
if [[ "$SEALED" == "true" ]]; then
    echo "❌ Vault is sealed"
    exit 1
fi

echo ""
echo "This script configures the Terraform Cloud/Enterprise secrets engine."
echo "You will need a TFC/TFE token with the following permissions:"
echo "  - Organization owner OR"
echo "  - Team token with 'Manage all projects' and 'Manage all workspaces'"
echo ""
echo "Get your token from:"
echo "  TFC: https://app.terraform.io/app/settings/tokens"
echo "  TFE: https://<your-tfe-host>/app/settings/tokens"
echo ""

read -p "Enter your TFC/TFE API token: " -rs TFE_TOKEN
echo ""

if [[ -z "$TFE_TOKEN" ]]; then
    echo "❌ No token provided"
    exit 1
fi

# Default to Terraform Cloud
read -p "TFE hostname [app.terraform.io]: " TFE_HOST
TFE_HOST="${TFE_HOST:-app.terraform.io}"

echo ""
echo "→ Enabling Terraform secrets engine..."
kubectl exec -n "$VAULT_NAMESPACE" vault-0 -- sh -c "
    export VAULT_TOKEN='$VAULT_TOKEN'
    vault secrets enable -path=terraform terraform 2>/dev/null || echo '  (already enabled)'
"

echo "→ Configuring TFE connection..."
kubectl exec -n "$VAULT_NAMESPACE" vault-0 -- sh -c "
    export VAULT_TOKEN='$VAULT_TOKEN'
    vault write terraform/config \
        address='https://$TFE_HOST' \
        token='$TFE_TOKEN'
"

echo ""
echo "→ Creating organization role..."
read -p "Enter your TFC/TFE organization name: " TFE_ORG

kubectl exec -n "$VAULT_NAMESPACE" vault-0 -- sh -c "
    export VAULT_TOKEN='$VAULT_TOKEN'

    # Create role for organization tokens
    vault write terraform/role/org-token \
        organization='$TFE_ORG' \
        token_type=organization \
        ttl=1h \
        max_ttl=24h

    # Create role for user tokens (requires user_id)
    # vault write terraform/role/user-token \
    #     user_id='<user-id>' \
    #     token_type=user \
    #     ttl=1h
"

echo ""
echo "→ Creating Vault policy for TFE access..."
kubectl exec -n "$VAULT_NAMESPACE" vault-0 -- sh -c "
    export VAULT_TOKEN='$VAULT_TOKEN'

    vault policy write tfe-secrets - <<'POLICY'
# Read TFE tokens
path \"terraform/creds/org-token\" {
  capabilities = [\"read\"]
}

# List available roles
path \"terraform/role/*\" {
  capabilities = [\"list\", \"read\"]
}
POLICY

    # Add TFE access to devenv policy
    vault policy write devenv-secrets - <<'POLICY'
path \"secret/data/devenv/*\" {
  capabilities = [\"read\", \"list\"]
}
path \"ssh/sign/devenv-access\" {
  capabilities = [\"create\", \"update\"]
}
path \"terraform/creds/org-token\" {
  capabilities = [\"read\"]
}
POLICY
"

echo ""
echo "=========================================="
echo "  ✅ TFE Secrets Engine Configured"
echo "=========================================="
echo ""
echo "Configuration:"
echo "  - Engine path: terraform/"
echo "  - TFE Host: $TFE_HOST"
echo "  - Organization: $TFE_ORG"
echo "  - Role: org-token (generates org-level tokens)"
echo ""
echo "Usage:"
echo "  # Generate a dynamic TFE token"
echo "  vault read terraform/creds/org-token"
echo ""
echo "  # Use in Terraform"
echo "  export TFE_TOKEN=\$(vault read -field=token terraform/creds/org-token)"
echo ""
echo "VSO Integration:"
echo "  Use VaultDynamicSecret to sync TFE tokens to Kubernetes:"
echo ""
cat << 'YAML'
apiVersion: secrets.hashicorp.com/v1beta1
kind: VaultDynamicSecret
metadata:
  name: tfe-token
  namespace: devenv
spec:
  vaultAuthRef: devenv-vault-auth
  mount: terraform
  path: creds/org-token
  destination:
    name: tfe-dynamic-token
    create: true
  renewalPercent: 67
YAML
