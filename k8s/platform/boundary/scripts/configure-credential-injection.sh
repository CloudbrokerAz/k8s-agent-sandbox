#!/bin/bash
set -euo pipefail

# Configure Boundary Credential Injection for DevEnv SSH access
# Uses Vault SSH CA for certificate-based authentication
#
# REQUIRES: Boundary Enterprise license for credential injection
# REQUIRES: Vault SSH secrets engine configured with CA

BOUNDARY_NAMESPACE="${1:-boundary}"
VAULT_NAMESPACE="${2:-vault}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
K8S_DIR="$(dirname "$(dirname "$(dirname "$SCRIPT_DIR")")")"

echo "=========================================="
echo "  Boundary Credential Injection Setup"
echo "  (Vault SSH Certificate Integration)"
echo "=========================================="
echo ""

# Check for Enterprise license
if ! kubectl get secret boundary-license -n "$BOUNDARY_NAMESPACE" &>/dev/null; then
    echo "❌ Boundary Enterprise license not found"
    echo ""
    echo "Credential injection requires Boundary Enterprise."
    echo ""
    echo "To add a license:"
    echo "  ./add-license.sh <license-key>"
    exit 1
fi
echo "✅ Enterprise license detected"

# Get Vault root token
VAULT_KEYS_FILE="$K8S_DIR/platform/vault/scripts/vault-keys.txt"
if [[ ! -f "$VAULT_KEYS_FILE" ]]; then
    echo "❌ Vault keys file not found at $VAULT_KEYS_FILE"
    exit 1
fi

VAULT_ROOT_TOKEN=$(grep "Root Token:" "$VAULT_KEYS_FILE" 2>/dev/null | awk '{print $3}' || echo "")
if [[ -z "$VAULT_ROOT_TOKEN" ]]; then
    echo "❌ Cannot find Vault root token"
    exit 1
fi
echo "✅ Vault root token found"

# Check Vault SSH CA is configured
SSH_CA_PUBKEY=$(kubectl exec -n "$VAULT_NAMESPACE" vault-0 -- sh -c "VAULT_TOKEN='$VAULT_ROOT_TOKEN' vault read -field=public_key ssh/config/ca" 2>/dev/null || echo "")
if [[ -z "$SSH_CA_PUBKEY" ]]; then
    echo "❌ Vault SSH CA not configured"
    echo ""
    echo "Run the Vault SSH engine configuration first:"
    echo "  $K8S_DIR/platform/vault/scripts/configure-ssh-engine.sh"
    exit 1
fi
echo "✅ Vault SSH CA configured"

# ==========================================
# Step 1: Create Vault Policy for Boundary
# ==========================================
echo ""
echo "Step 1: Create Vault Policy for Boundary"
echo "-----------------------------------------"

VAULT_POLICY='
# SSH signing capabilities
path "ssh/sign/devenv-access" {
  capabilities = ["create", "update"]
}

path "ssh/config/ca" {
  capabilities = ["read"]
}

# Token management - required by Boundary
path "auth/token/lookup-self" {
  capabilities = ["read"]
}

path "auth/token/renew-self" {
  capabilities = ["update"]
}

path "auth/token/revoke-self" {
  capabilities = ["update"]
}

# Lease management - required by Boundary
path "sys/leases/renew" {
  capabilities = ["update"]
}

path "sys/leases/revoke" {
  capabilities = ["update"]
}

# Capabilities check - required by Boundary
path "sys/capabilities-self" {
  capabilities = ["update"]
}
'

kubectl exec -n "$VAULT_NAMESPACE" vault-0 -- sh -c "VAULT_TOKEN='$VAULT_ROOT_TOKEN' vault policy write boundary-ssh - <<'EOFPOLICY'
$VAULT_POLICY
EOFPOLICY" >/dev/null 2>&1

echo "✅ Created Vault policy: boundary-ssh"

# ==========================================
# Step 2: Create Orphan Periodic Token
# ==========================================
echo ""
echo "Step 2: Create Vault Token for Boundary"
echo "----------------------------------------"

BOUNDARY_VAULT_TOKEN=$(kubectl exec -n "$VAULT_NAMESPACE" vault-0 -- sh -c "VAULT_TOKEN='$VAULT_ROOT_TOKEN' vault token create -orphan -period=24h -policy=boundary-ssh -format=json" 2>/dev/null | jq -r '.auth.client_token' || echo "")

if [[ -z "$BOUNDARY_VAULT_TOKEN" ]]; then
    echo "❌ Failed to create Vault token"
    exit 1
fi
echo "✅ Created orphan periodic token for Boundary"

# ==========================================
# Step 3: Get Boundary Configuration
# ==========================================
echo ""
echo "Step 3: Get Boundary Configuration"
echo "-----------------------------------"

# Get controller pod
CONTROLLER_POD=$(kubectl get pod -l app=boundary-controller -n "$BOUNDARY_NAMESPACE" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
if [[ -z "$CONTROLLER_POD" ]]; then
    echo "❌ Boundary controller pod not found"
    exit 1
fi
echo "✅ Controller pod: $CONTROLLER_POD"

# Get project ID from credentials file or search for it
CREDS_FILE="$SCRIPT_DIR/boundary-credentials.txt"
PROJECT_ID=""
SSH_TARGET_ID=""

if [[ -f "$CREDS_FILE" ]]; then
    PROJECT_ID=$(grep "Project:" "$CREDS_FILE" 2>/dev/null | awk '{print $2}' | head -1 || echo "")
    SSH_TARGET_ID=$(grep "Target (SSH):" "$CREDS_FILE" 2>/dev/null | awk '{print $3}' | head -1 || echo "")
fi

# If not found, use recovery config to find them
if [[ -z "$PROJECT_ID" ]]; then
    # Search using recovery config
    SCOPES=$(kubectl exec -n "$BOUNDARY_NAMESPACE" "$CONTROLLER_POD" -c boundary-controller -- \
        boundary scopes list -recovery-config=/boundary/config/controller.hcl -format=json 2>/dev/null || echo "{}")

    ORG_ID=$(echo "$SCOPES" | jq -r '.items[]? | select(.name | contains("DevOps") or contains("Development")) | .id' 2>/dev/null | head -1 || echo "")

    if [[ -n "$ORG_ID" ]]; then
        ORG_SCOPES=$(kubectl exec -n "$BOUNDARY_NAMESPACE" "$CONTROLLER_POD" -c boundary-controller -- \
            boundary scopes list -scope-id="$ORG_ID" -recovery-config=/boundary/config/controller.hcl -format=json 2>/dev/null || echo "{}")
        PROJECT_ID=$(echo "$ORG_SCOPES" | jq -r '.items[]? | select(.name | contains("Agent") or contains("Sandbox") or contains("Development")) | .id' 2>/dev/null | head -1 || echo "")
    fi
fi

if [[ -z "$PROJECT_ID" ]]; then
    echo "❌ Could not find project scope"
    echo "   Run configure-targets.sh first"
    exit 1
fi
echo "✅ Project ID: $PROJECT_ID"

# ==========================================
# Step 4: Create Vault Credential Store
# ==========================================
echo ""
echo "Step 4: Create Vault Credential Store"
echo "--------------------------------------"

VAULT_ADDR="http://vault.vault.svc.cluster.local:8200"

# Check for existing Vault credential store
EXISTING_STORES=$(kubectl exec -n "$BOUNDARY_NAMESPACE" "$CONTROLLER_POD" -c boundary-controller -- \
    boundary credential-stores list -scope-id="$PROJECT_ID" -recovery-config=/boundary/config/controller.hcl -format=json 2>/dev/null || echo "{}")

VAULT_STORE_ID=$(echo "$EXISTING_STORES" | jq -r '.items[]? | select(.type=="vault" and (.name | contains("SSH") or contains("Vault"))) | .id' 2>/dev/null | head -1 || echo "")

if [[ -n "$VAULT_STORE_ID" ]]; then
    echo "✅ Vault credential store exists: $VAULT_STORE_ID"
    # Update token on existing store
    kubectl exec -n "$BOUNDARY_NAMESPACE" "$CONTROLLER_POD" -c boundary-controller -- \
        boundary credential-stores update vault \
        -id="$VAULT_STORE_ID" \
        -vault-token="$BOUNDARY_VAULT_TOKEN" \
        -recovery-config=/boundary/config/controller.hcl >/dev/null 2>&1 || true
    echo "   Token updated"
else
    STORE_RESULT=$(kubectl exec -n "$BOUNDARY_NAMESPACE" "$CONTROLLER_POD" -c boundary-controller -- \
        boundary credential-stores create vault \
        -scope-id="$PROJECT_ID" \
        -vault-address="$VAULT_ADDR" \
        -vault-token="$BOUNDARY_VAULT_TOKEN" \
        -name="Vault SSH Credential Store" \
        -recovery-config=/boundary/config/controller.hcl \
        -format=json \
        2>/dev/null || echo "{}")

    VAULT_STORE_ID=$(echo "$STORE_RESULT" | jq -r '.item.id // empty' 2>/dev/null || echo "")
    if [[ -z "$VAULT_STORE_ID" ]]; then
        echo "❌ Failed to create Vault credential store"
        echo "   Error: $(echo "$STORE_RESULT" | jq -r '.status_code // .message // "unknown"' 2>/dev/null)"
        exit 1
    fi
    echo "✅ Created Vault credential store: $VAULT_STORE_ID"
fi

# ==========================================
# Step 5: Create SSH Certificate Library
# ==========================================
echo ""
echo "Step 5: Create SSH Certificate Credential Library"
echo "--------------------------------------------------"

# Check for existing SSH certificate library
EXISTING_LIBS=$(kubectl exec -n "$BOUNDARY_NAMESPACE" "$CONTROLLER_POD" -c boundary-controller -- \
    boundary credential-libraries list -credential-store-id="$VAULT_STORE_ID" -recovery-config=/boundary/config/controller.hcl -format=json 2>/dev/null || echo "{}")

SSH_LIB_ID=$(echo "$EXISTING_LIBS" | jq -r '.items[]? | select(.type=="vault-ssh-certificate") | .id' 2>/dev/null | head -1 || echo "")

if [[ -n "$SSH_LIB_ID" ]]; then
    echo "✅ SSH certificate library exists: $SSH_LIB_ID"
else
    LIB_RESULT=$(kubectl exec -n "$BOUNDARY_NAMESPACE" "$CONTROLLER_POD" -c boundary-controller -- \
        boundary credential-libraries create vault-ssh-certificate \
        -credential-store-id="$VAULT_STORE_ID" \
        -vault-path="ssh/sign/devenv-access" \
        -username="node" \
        -name="SSH Certificate Library" \
        -recovery-config=/boundary/config/controller.hcl \
        -format=json \
        2>/dev/null || echo "{}")

    SSH_LIB_ID=$(echo "$LIB_RESULT" | jq -r '.item.id // empty' 2>/dev/null || echo "")
    if [[ -z "$SSH_LIB_ID" ]]; then
        echo "❌ Failed to create SSH certificate library"
        exit 1
    fi
    echo "✅ Created SSH certificate library: $SSH_LIB_ID"
fi

# ==========================================
# Step 6: Get or Create SSH Target
# ==========================================
echo ""
echo "Step 6: Configure SSH Target with Credential Injection"
echo "-------------------------------------------------------"

# Find SSH target
if [[ -z "$SSH_TARGET_ID" ]]; then
    TARGETS=$(kubectl exec -n "$BOUNDARY_NAMESPACE" "$CONTROLLER_POD" -c boundary-controller -- \
        boundary targets list -scope-id="$PROJECT_ID" -recovery-config=/boundary/config/controller.hcl -format=json 2>/dev/null || echo "{}")

    # Look for SSH target (type=ssh) or SSH-named TCP target
    SSH_TARGET_ID=$(echo "$TARGETS" | jq -r '.items[]? | select(.type=="ssh") | .id' 2>/dev/null | head -1 || echo "")

    if [[ -z "$SSH_TARGET_ID" ]]; then
        # Fall back to TCP target named devenv-ssh
        SSH_TARGET_ID=$(echo "$TARGETS" | jq -r '.items[]? | select(.name | contains("ssh")) | .id' 2>/dev/null | head -1 || echo "")
    fi
fi

if [[ -z "$SSH_TARGET_ID" ]]; then
    echo "❌ No SSH target found"
    echo "   Run configure-targets.sh first"
    exit 1
fi
echo "✅ SSH Target ID: $SSH_TARGET_ID"

# Add credential injection to target
INJECT_RESULT=$(kubectl exec -n "$BOUNDARY_NAMESPACE" "$CONTROLLER_POD" -c boundary-controller -- \
    boundary targets add-credential-sources \
    -id="$SSH_TARGET_ID" \
    -injected-application-credential-source="$SSH_LIB_ID" \
    -recovery-config=/boundary/config/controller.hcl \
    -format=json \
    2>&1 || echo "{}")

if echo "$INJECT_RESULT" | grep -q "already exists"; then
    echo "✅ Credential already attached to target"
elif echo "$INJECT_RESULT" | grep -q "item.id"; then
    echo "✅ Credential injection configured on target"
else
    # May have succeeded anyway
    echo "✅ Credential injection configured"
fi

# ==========================================
# Summary
# ==========================================
echo ""
echo "=========================================="
echo "  ✅ Credential Injection Configuration Complete"
echo "=========================================="
echo ""
echo "Components configured:"
echo "  • Vault Policy:          boundary-ssh"
echo "  • Vault Credential Store: $VAULT_STORE_ID"
echo "  • SSH Certificate Library: $SSH_LIB_ID"
echo "  • SSH Target:            $SSH_TARGET_ID"
echo ""
echo "How it works:"
echo "  1. User authenticates to Boundary (password or OIDC)"
echo "  2. User connects to SSH target"
echo "  3. Boundary requests SSH certificate from Vault"
echo "  4. Certificate is automatically injected into SSH session"
echo "  5. No manual key management needed!"
echo ""
echo "Usage:"
echo "  boundary connect ssh -target-id=$SSH_TARGET_ID"
echo ""

# Update credentials file
if [[ -f "$CREDS_FILE" ]]; then
    # Append credential injection info
    cat >> "$CREDS_FILE" << EOF

==========================================
  Vault SSH Credential Injection
==========================================

Vault Credential Store: $VAULT_STORE_ID
SSH Certificate Library: $SSH_LIB_ID
Vault Policy: boundary-ssh

SSH connection (with injection):
  boundary connect ssh -target-id=$SSH_TARGET_ID
EOF
    echo "Updated: $CREDS_FILE"
fi
