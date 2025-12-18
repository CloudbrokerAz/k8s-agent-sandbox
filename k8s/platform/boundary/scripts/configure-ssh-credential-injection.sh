#!/bin/bash
set -euo pipefail

# Configure Boundary SSH Credential Injection for DevEnv SSH access
# Uses Vault SSH secrets engine with certificate-based injection
#
# ENTERPRISE EDITION: Uses vault-ssh-certificate credential library
# Credentials are INJECTED (not brokered) - they are not exposed to end users.
#
# REQUIRES:
#   - Boundary Enterprise
#   - Vault SSH secrets engine configured with CA
#   - Existing Vault credential store

BOUNDARY_NAMESPACE="${1:-boundary}"
VAULT_NAMESPACE="${2:-vault}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
K8S_DIR="$(dirname "$(dirname "$(dirname "$SCRIPT_DIR")")")"

echo "=========================================="
echo "  Boundary SSH Credential Injection Setup"
echo "  (Enterprise Edition - SSH Certificates)"
echo "=========================================="
echo ""

# ==========================================
# Step 1: Get Vault root token
# ==========================================
echo "Step 1: Verify Vault Configuration"
echo "-----------------------------------"

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

# Verify the devenv-access role exists
ROLE_CHECK=$(kubectl exec -n "$VAULT_NAMESPACE" vault-0 -- sh -c "VAULT_TOKEN='$VAULT_ROOT_TOKEN' vault read ssh/roles/devenv-access -format=json" 2>/dev/null || echo "{}")
if ! echo "$ROLE_CHECK" | jq -e '.data' >/dev/null 2>&1; then
    echo "❌ Vault SSH role 'devenv-access' not found"
    echo ""
    echo "The role should be created during Vault deployment."
    echo "Check the deploy-all.sh script or configure it manually."
    exit 1
fi
echo "✅ Vault SSH role 'devenv-access' exists"

# ==========================================
# Step 2: Get Boundary Configuration
# ==========================================
echo ""
echo "Step 2: Get Boundary Configuration"
echo "-----------------------------------"

# Get controller pod
CONTROLLER_POD=$(kubectl get pod -l app=boundary-controller -n "$BOUNDARY_NAMESPACE" --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
if [[ -z "$CONTROLLER_POD" ]]; then
    echo "❌ Boundary controller pod not found or not running"
    exit 1
fi
echo "✅ Controller pod: $CONTROLLER_POD"

# Get project ID from credentials file
CREDS_FILE="$SCRIPT_DIR/boundary-credentials.txt"
PROJECT_ID=""
VAULT_STORE_ID=""

if [[ -f "$CREDS_FILE" ]]; then
    PROJECT_ID=$(grep "Project:" "$CREDS_FILE" 2>/dev/null | awk '{print $2}' | head -1 || echo "")
    VAULT_STORE_ID=$(grep "Vault Credential Store:" "$CREDS_FILE" 2>/dev/null | awk '{print $4}' | head -1 || echo "")
fi

# If not found, search using recovery config
if [[ -z "$PROJECT_ID" ]]; then
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
# Step 3: Find or Verify Vault Credential Store
# ==========================================
echo ""
echo "Step 3: Verify Vault Credential Store"
echo "--------------------------------------"

# Check for existing Vault credential store
EXISTING_STORES=$(kubectl exec -n "$BOUNDARY_NAMESPACE" "$CONTROLLER_POD" -c boundary-controller -- \
    boundary credential-stores list -scope-id="$PROJECT_ID" -recovery-config=/boundary/config/controller.hcl -format=json 2>/dev/null || echo "{}")

if [[ -z "$VAULT_STORE_ID" ]]; then
    VAULT_STORE_ID=$(echo "$EXISTING_STORES" | jq -r '.items[]? | select(.type=="vault") | .id' 2>/dev/null | head -1 || echo "")
fi

if [[ -z "$VAULT_STORE_ID" ]]; then
    echo "❌ Vault credential store not found"
    echo "   Run configure-credential-brokering.sh first to create the Vault credential store"
    exit 1
fi
echo "✅ Vault credential store exists: $VAULT_STORE_ID"

# ==========================================
# Step 4: Create SSH Certificate Credential Library
# ==========================================
echo ""
echo "Step 4: Create SSH Certificate Credential Library"
echo "--------------------------------------------------"

# Check if SSH certificate credential library already exists
EXISTING_LIBS=$(kubectl exec -n "$BOUNDARY_NAMESPACE" "$CONTROLLER_POD" -c boundary-controller -- \
    boundary credential-libraries list -credential-store-id="$VAULT_STORE_ID" -recovery-config=/boundary/config/controller.hcl -format=json 2>/dev/null || echo "{}")

SSH_CERT_LIB_ID=$(echo "$EXISTING_LIBS" | jq -r '.items[]? | select(.type=="vault-ssh-certificate" and (.name | contains("Injection") or contains("Certificate"))) | .id' 2>/dev/null | head -1 || echo "")

if [[ -n "$SSH_CERT_LIB_ID" ]]; then
    echo "✅ SSH certificate credential library already exists: $SSH_CERT_LIB_ID"
else
    echo "Creating new SSH certificate credential library..."

    # Create vault-ssh-certificate credential library
    # This uses Vault's SSH secrets engine to dynamically generate signed certificates
    LIB_RESULT=$(kubectl exec -n "$BOUNDARY_NAMESPACE" "$CONTROLLER_POD" -c boundary-controller -- \
        boundary credential-libraries create vault-ssh-certificate \
        -credential-store-id="$VAULT_STORE_ID" \
        -vault-path="ssh/sign/devenv-access" \
        -username="node" \
        -name="SSH Certificate Injection" \
        -description="Vault SSH certificate for credential injection (Enterprise)" \
        -recovery-config=/boundary/config/controller.hcl \
        -format=json \
        2>&1 || echo "{}")

    SSH_CERT_LIB_ID=$(echo "$LIB_RESULT" | jq -r '.item.id // empty' 2>/dev/null || echo "")

    if [[ -z "$SSH_CERT_LIB_ID" ]]; then
        echo "❌ Failed to create SSH certificate credential library"
        echo ""
        echo "Full error output:"
        echo "$LIB_RESULT" | head -20
        echo ""
        echo "This feature requires Boundary Enterprise."
        echo "Check that you have a valid Enterprise license."
        exit 1
    fi

    echo "✅ Created SSH certificate credential library: $SSH_CERT_LIB_ID"
fi

# ==========================================
# Step 5: Find Host Catalog and Host Set
# ==========================================
echo ""
echo "Step 5: Find Host Catalog and Host Set"
echo "---------------------------------------"

# Get host catalogs in the project
HOST_CATALOGS=$(kubectl exec -n "$BOUNDARY_NAMESPACE" "$CONTROLLER_POD" -c boundary-controller -- \
    boundary host-catalogs list -scope-id="$PROJECT_ID" -recovery-config=/boundary/config/controller.hcl -format=json 2>/dev/null || echo '{"items":[]}')

CATALOG_ID=$(echo "$HOST_CATALOGS" | jq -r '.items[]? | select(.name=="devenv-hosts") | .id' 2>/dev/null | head -1 || echo "")

if [[ -z "$CATALOG_ID" ]]; then
    echo "❌ Host catalog 'devenv-hosts' not found"
    echo "   Run configure-targets.sh first to create the host catalog"
    exit 1
fi
echo "✅ Host catalog found: devenv-hosts ($CATALOG_ID)"

# Get host sets in the catalog
HOSTSETS=$(kubectl exec -n "$BOUNDARY_NAMESPACE" "$CONTROLLER_POD" -c boundary-controller -- \
    boundary host-sets list -host-catalog-id="$CATALOG_ID" -recovery-config=/boundary/config/controller.hcl -format=json 2>/dev/null || echo '{"items":[]}')

HOSTSET_ID=$(echo "$HOSTSETS" | jq -r '.items[]? | select(.name=="claude-set") | .id' 2>/dev/null | head -1 || echo "")

if [[ -z "$HOSTSET_ID" ]]; then
    echo "❌ Host set 'claude-set' not found"
    echo "   Run configure-targets.sh first to create the host set"
    exit 1
fi
echo "✅ Host set found: claude-set ($HOSTSET_ID)"

# ==========================================
# Step 6: Create Target with SSH Credential Injection
# ==========================================
echo ""
echo "Step 6: Create Target with SSH Credential Injection"
echo "----------------------------------------------------"

# Check if target already exists
TARGETS=$(kubectl exec -n "$BOUNDARY_NAMESPACE" "$CONTROLLER_POD" -c boundary-controller -- \
    boundary targets list -scope-id="$PROJECT_ID" -recovery-config=/boundary/config/controller.hcl -format=json 2>/dev/null || echo '{"items":[]}')

TARGET_ID=$(echo "$TARGETS" | jq -r '.items[]? | select(.name=="claude-ssh-injected") | .id' 2>/dev/null | head -1 || echo "")

if [[ -n "$TARGET_ID" ]]; then
    echo "✅ Target already exists: claude-ssh-injected ($TARGET_ID)"
else
    echo "Creating new target: claude-ssh-injected..."

    # Create SSH target (required for credential injection)
    # TCP targets only support brokered credentials, not injected
    TARGET_RESULT=$(kubectl exec -n "$BOUNDARY_NAMESPACE" "$CONTROLLER_POD" -c boundary-controller -- \
        boundary targets create ssh \
        -name="claude-ssh-injected" \
        -description="SSH access to claude-code-sandbox with credential injection" \
        -default-port=22 \
        -scope-id="$PROJECT_ID" \
        -recovery-config=/boundary/config/controller.hcl \
        -format=json \
        2>&1 || echo "{}")

    TARGET_ID=$(echo "$TARGET_RESULT" | jq -r '.item.id // empty' 2>/dev/null || echo "")

    if [[ -z "$TARGET_ID" ]]; then
        echo "❌ Failed to create target"
        echo ""
        echo "Error output:"
        echo "$TARGET_RESULT" | head -20
        exit 1
    fi

    echo "✅ Created target: claude-ssh-injected ($TARGET_ID)"
fi

# Add host source to target (idempotent)
echo "Adding host set to target..."
kubectl exec -n "$BOUNDARY_NAMESPACE" "$CONTROLLER_POD" -c boundary-controller -- \
    boundary targets add-host-sources \
    -id="$TARGET_ID" \
    -host-source="$HOSTSET_ID" \
    -recovery-config=/boundary/config/controller.hcl \
    >/dev/null 2>&1 || echo "  (already added)"
echo "✅ Host set attached to target"

# Add SSH certificate credential library as injected credential source
echo "Adding injected credential source to target..."

# First check if credential is already attached
TARGET_CHECK=$(kubectl exec -n "$BOUNDARY_NAMESPACE" "$CONTROLLER_POD" -c boundary-controller -- \
    boundary targets read -id="$TARGET_ID" -recovery-config=/boundary/config/controller.hcl -format=json 2>/dev/null || echo "{}")

EXISTING_INJECTED_CREDS=$(echo "$TARGET_CHECK" | jq -r '.item.injected_application_credential_source_ids // []' 2>/dev/null)

if echo "$EXISTING_INJECTED_CREDS" | grep -q "$SSH_CERT_LIB_ID"; then
    echo "✅ Injected credential already attached to target"
else
    # Add injected application credential source
    ADD_RESULT=$(kubectl exec -n "$BOUNDARY_NAMESPACE" "$CONTROLLER_POD" -c boundary-controller -- \
        boundary targets add-credential-sources \
        -id="$TARGET_ID" \
        -injected-application-credential-source="$SSH_CERT_LIB_ID" \
        -recovery-config=/boundary/config/controller.hcl \
        -format=json \
        2>&1 || echo "{}")

    if echo "$ADD_RESULT" | grep -q "already exists"; then
        echo "✅ Injected credential already attached to target"
    elif echo "$ADD_RESULT" | grep -q '"id"' || echo "$ADD_RESULT" | grep -q '"item"'; then
        echo "✅ Injected credential source attached to target"
    else
        echo "⚠️  Result unclear when adding credential source:"
        echo "$ADD_RESULT" | head -10
    fi
fi

# ==========================================
# Summary
# ==========================================
echo ""
echo "=========================================="
echo "  ✅ SSH Credential Injection Complete"
echo "=========================================="
echo ""
echo "Components configured:"
echo "  • Vault SSH Role:         devenv-access"
echo "  • Vault Credential Store: $VAULT_STORE_ID"
echo "  • SSH Cert Library:       $SSH_CERT_LIB_ID (vault-ssh-certificate)"
echo "  • Host Catalog:           $CATALOG_ID (devenv-hosts)"
echo "  • Host Set:               $HOSTSET_ID (claude-set)"
echo "  • Target:                 $TARGET_ID (claude-ssh-injected)"
echo ""
echo "SSH Credential Injection:"
echo "  When users connect to this target, Boundary will:"
echo "  1. Request a signed SSH certificate from Vault"
echo "  2. INJECT the certificate directly into the SSH connection"
echo "  3. User never sees the credentials (Enterprise security)"
echo ""
echo "Usage:"
echo "  # Authenticate to Boundary"
echo "  export BOUNDARY_ADDR=https://boundary.hashicorp.lab"
echo "  export BOUNDARY_TLS_INSECURE=true"
echo "  boundary authenticate password -auth-method-id=ampw_ndMBrw5s8N -login-name=admin"
echo ""
echo "  # Connect with automatic credential injection"
echo "  boundary connect ssh -target-id=$TARGET_ID"
echo ""
echo "  # Or use with exec for custom SSH options"
echo "  boundary connect -target-id=$TARGET_ID -exec ssh -- -l node -p '{{boundary.port}}' '{{boundary.ip}}'"
echo ""
