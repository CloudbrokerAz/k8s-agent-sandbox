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
echo "→ Creating TFE roles..."
read -p "Enter your TFC/TFE organization name: " TFE_ORG

echo ""
echo "Token type options:"
echo "  1. Team token (recommended for CI/CD and agent-sandbox)"
echo "  2. Organization token"
echo ""
read -p "Select token type [1]: " TOKEN_TYPE_CHOICE
TOKEN_TYPE_CHOICE="${TOKEN_TYPE_CHOICE:-1}"

if [[ "$TOKEN_TYPE_CHOICE" == "1" ]]; then
    read -p "Enter Team ID (from TFE team settings URL): " TEAM_ID
    if [[ -z "$TEAM_ID" ]]; then
        echo "❌ Team ID is required for team tokens"
        exit 1
    fi

    kubectl exec -n "$VAULT_NAMESPACE" vault-0 -- sh -c "
        export VAULT_TOKEN='$VAULT_TOKEN'

        # Create role for team tokens (recommended)
        vault write terraform/role/team-token \
            organization='$TFE_ORG' \
            team_id='$TEAM_ID' \
            ttl=1h \
            max_ttl=24h
    "
    ROLE_NAME="team-token"
    echo "✅ Created team-token role"
else
    kubectl exec -n "$VAULT_NAMESPACE" vault-0 -- sh -c "
        export VAULT_TOKEN='$VAULT_TOKEN'

        # Create role for organization tokens
        vault write terraform/role/org-token \
            organization='$TFE_ORG' \
            token_type=organization \
            ttl=1h \
            max_ttl=24h
    "
    ROLE_NAME="org-token"
    echo "✅ Created org-token role"
fi

echo ""
echo "→ Creating Vault policy for TFE access..."
kubectl exec -n "$VAULT_NAMESPACE" vault-0 -- sh -c "
    export VAULT_TOKEN='$VAULT_TOKEN'

    vault policy write tfe-secrets - <<'POLICY'
# Read TFE tokens (both team and org)
path \"terraform/creds/team-token\" {
  capabilities = [\"read\"]
}
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
path \"terraform/creds/team-token\" {
  capabilities = [\"read\"]
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
echo "  - Role: $ROLE_NAME"
echo ""
echo "Usage:"
echo "  # Generate a dynamic TFE token"
echo "  vault read terraform/creds/$ROLE_NAME"
echo ""
echo "  # Use in Terraform"
echo "  export TFE_TOKEN=\$(vault read -field=token terraform/creds/$ROLE_NAME)"
echo ""

# Create VaultDynamicSecret manifest
MANIFEST_DIR="$(dirname "$SCRIPT_DIR")/../vault-secrets-operator/manifests"
mkdir -p "$MANIFEST_DIR"

cat > "$MANIFEST_DIR/05-vaultdynamicsecret-tfe.yaml" << EOF
# VaultDynamicSecret for TFE token injection into agent-sandbox
# This syncs a dynamic TFE token from Vault to a Kubernetes secret
apiVersion: secrets.hashicorp.com/v1beta1
kind: VaultDynamicSecret
metadata:
  name: tfe-token
  namespace: devenv
spec:
  vaultAuthRef: devenv-vault-auth
  mount: terraform
  path: creds/${ROLE_NAME}
  destination:
    name: tfe-dynamic-token
    create: true
    transformation:
      excludeRaw: true
      templates:
        TFE_TOKEN:
          text: "{{ .Secrets.token }}"
  renewalPercent: 67
EOF

echo "Created VaultDynamicSecret manifest: $MANIFEST_DIR/05-vaultdynamicsecret-tfe.yaml"
echo ""

# Apply the manifest
read -p "Apply VaultDynamicSecret now? (yes/no) [yes]: " APPLY_NOW
APPLY_NOW="${APPLY_NOW:-yes}"

if [[ "$APPLY_NOW" == "yes" ]]; then
    kubectl apply -f "$MANIFEST_DIR/05-vaultdynamicsecret-tfe.yaml"
    echo "✅ VaultDynamicSecret applied"
    echo ""
    echo "The TFE token will be synced to secret 'tfe-dynamic-token' in namespace 'devenv'"
    echo "with the key 'TFE_TOKEN'"
fi

echo ""
echo "To use in agent-sandbox, add this to your StatefulSet:"
echo ""
cat << 'YAML'
envFrom:
  - secretRef:
      name: tfe-dynamic-token
YAML
echo ""
echo "Or reference directly:"
echo ""
cat << 'YAML'
env:
  - name: TFE_TOKEN
    valueFrom:
      secretKeyRef:
        name: tfe-dynamic-token
        key: TFE_TOKEN
YAML
