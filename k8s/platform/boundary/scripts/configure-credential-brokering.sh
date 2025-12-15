#!/bin/bash
set -euo pipefail

# Configure Boundary Credential Brokering for DevEnv SSH access
# Uses Vault KV with pre-signed SSH certificates for Community Edition
#
# COMMUNITY EDITION: Uses vault-generic credential library with brokered credentials
# Unlike Enterprise credential injection, credentials are returned to the user.
#
# LIMITATION: TCP targets cannot use vault-ssh-certificate libraries directly.
#             This script stores a pre-signed SSH key in Vault KV for brokering.
#
# REQUIRES: Vault SSH secrets engine configured with CA

BOUNDARY_NAMESPACE="${1:-boundary}"
VAULT_NAMESPACE="${2:-vault}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
K8S_DIR="$(dirname "$(dirname "$(dirname "$SCRIPT_DIR")")")"

echo "=========================================="
echo "  Boundary Credential Brokering Setup"
echo "  (Community Edition - Static SSH Credentials)"
echo "=========================================="
echo ""

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
# Step 1: Enable KV Secrets Engine (if needed)
# ==========================================
echo ""
echo "Step 1: Enable KV Secrets Engine"
echo "---------------------------------"

KV_ENABLED=$(kubectl exec -n "$VAULT_NAMESPACE" vault-0 -- sh -c "VAULT_TOKEN='$VAULT_ROOT_TOKEN' vault secrets list -format=json" 2>/dev/null | jq -r 'has("secret/")' || echo "false")

if [[ "$KV_ENABLED" == "true" ]]; then
    echo "✅ KV secrets engine already enabled at secret/"
else
    kubectl exec -n "$VAULT_NAMESPACE" vault-0 -- sh -c "VAULT_TOKEN='$VAULT_ROOT_TOKEN' vault secrets enable -path=secret kv-v2" 2>/dev/null || true
    echo "✅ Enabled KV v2 secrets engine at secret/"
fi

# ==========================================
# Step 2: Generate and Sign SSH Key
# ==========================================
echo ""
echo "Step 2: Generate and Sign SSH Key for Brokering"
echo "------------------------------------------------"

# Create temp directory for key generation
TEMP_DIR=$(mktemp -d)
trap "rm -rf $TEMP_DIR" EXIT

# Generate ED25519 SSH key pair
ssh-keygen -t ed25519 -f "$TEMP_DIR/boundary-ssh" -N "" -C "boundary-brokered-key" >/dev/null 2>&1
echo "✅ Generated ED25519 SSH key pair"

# Read the keys
SSH_PRIVATE_KEY=$(cat "$TEMP_DIR/boundary-ssh")
SSH_PUBLIC_KEY=$(cat "$TEMP_DIR/boundary-ssh.pub")

# Sign the public key with Vault SSH CA
echo "  Signing key with Vault SSH CA..."
# Sign with default TTL (role maximum is 24h)
SIGNED_CERT=$(kubectl exec -n "$VAULT_NAMESPACE" vault-0 -i -- sh -c "VAULT_TOKEN='$VAULT_ROOT_TOKEN' vault write -field=signed_key ssh/sign/devenv-access public_key='$SSH_PUBLIC_KEY' valid_principals=node" 2>/dev/null || echo "")

if [[ -z "$SIGNED_CERT" ]]; then
    echo "❌ Failed to sign SSH key with Vault CA"
    exit 1
fi
echo "✅ Key signed by Vault SSH CA (valid for 24h - role default)"

# ==========================================
# Step 3: Store Credentials in Vault KV
# ==========================================
echo ""
echo "Step 3: Store SSH Credentials in Vault KV"
echo "------------------------------------------"

# Store the private key and signed certificate in Vault KV
# Use file-based approach to properly handle multi-line SSH keys

# Save credentials to temp files for proper handling
PRIV_FILE="$TEMP_DIR/private_key.txt"
CERT_FILE="$TEMP_DIR/certificate.txt"
PUB_FILE="$TEMP_DIR/public_key.txt"

echo "$SSH_PRIVATE_KEY" > "$PRIV_FILE"
echo "$SIGNED_CERT" > "$CERT_FILE"
echo "$SSH_PUBLIC_KEY" > "$PUB_FILE"

# Create JSON payload using jq with file input
JSON_PAYLOAD=$(jq -n \
    --rawfile priv "$PRIV_FILE" \
    --rawfile cert "$CERT_FILE" \
    --rawfile pub "$PUB_FILE" \
    '{
        username: "node",
        private_key: $priv,
        private_key_passphrase: "",
        certificate: $cert,
        public_key: $pub
    }')

# Store via kubectl with JSON payload piped to vault
echo "$JSON_PAYLOAD" | kubectl exec -n "$VAULT_NAMESPACE" vault-0 -i -- sh -c "VAULT_TOKEN='$VAULT_ROOT_TOKEN' vault kv put -format=json secret/boundary/ssh-credentials -" > /dev/null

echo "✅ SSH credentials stored at secret/boundary/ssh-credentials"

# ==========================================
# Step 4: Create Vault Policy for Boundary
# ==========================================
echo ""
echo "Step 4: Create Vault Policy for Boundary"
echo "-----------------------------------------"

VAULT_POLICY='
# Access to brokered SSH credentials
path "secret/data/boundary/ssh-credentials" {
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

kubectl exec -n "$VAULT_NAMESPACE" vault-0 -- sh -c "VAULT_TOKEN='$VAULT_ROOT_TOKEN' vault policy write boundary-ssh-brokered - <<'EOFPOLICY'
$VAULT_POLICY
EOFPOLICY" >/dev/null 2>&1

echo "✅ Created Vault policy: boundary-ssh-brokered"

# ==========================================
# Step 5: Create Orphan Periodic Token
# ==========================================
echo ""
echo "Step 5: Create Vault Token for Boundary"
echo "----------------------------------------"

BOUNDARY_VAULT_TOKEN=$(kubectl exec -n "$VAULT_NAMESPACE" vault-0 -- sh -c "VAULT_TOKEN='$VAULT_ROOT_TOKEN' vault token create -orphan -period=24h -policy=boundary-ssh-brokered -format=json" 2>/dev/null | jq -r '.auth.client_token' || echo "")

if [[ -z "$BOUNDARY_VAULT_TOKEN" ]]; then
    echo "❌ Failed to create Vault token"
    exit 1
fi
echo "✅ Created orphan periodic token for Boundary"

# ==========================================
# Step 6: Get Boundary Configuration
# ==========================================
echo ""
echo "Step 6: Get Boundary Configuration"
echo "-----------------------------------"

# Get controller pod
CONTROLLER_POD=$(kubectl get pod -l app=boundary-controller -n "$BOUNDARY_NAMESPACE" --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
if [[ -z "$CONTROLLER_POD" ]]; then
    echo "❌ Boundary controller pod not found or not running"
    exit 1
fi
echo "✅ Controller pod: $CONTROLLER_POD"

# Get project ID from credentials file or search for it
CREDS_FILE="$SCRIPT_DIR/boundary-credentials.txt"
PROJECT_ID=""
CLAUDE_TARGET_ID=""
GEMINI_TARGET_ID=""

if [[ -f "$CREDS_FILE" ]]; then
    PROJECT_ID=$(grep "Project:" "$CREDS_FILE" 2>/dev/null | awk '{print $2}' | head -1 || echo "")
    CLAUDE_TARGET_ID=$(grep "claude-ssh:" "$CREDS_FILE" 2>/dev/null | awk '{print $2}' | head -1 || echo "")
    GEMINI_TARGET_ID=$(grep "gemini-ssh:" "$CREDS_FILE" 2>/dev/null | awk '{print $2}' | head -1 || echo "")
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
# Step 7: Create Vault Credential Store
# ==========================================
echo ""
echo "Step 7: Create Vault Credential Store"
echo "--------------------------------------"

# Use internal cluster URL for reliability
VAULT_ADDR="http://vault.vault.svc.cluster.local:8200"

# Check for existing Vault credential store
EXISTING_STORES=$(kubectl exec -n "$BOUNDARY_NAMESPACE" "$CONTROLLER_POD" -c boundary-controller -- \
    boundary credential-stores list -scope-id="$PROJECT_ID" -recovery-config=/boundary/config/controller.hcl -format=json 2>/dev/null || echo "{}")

VAULT_STORE_ID=$(echo "$EXISTING_STORES" | jq -r '.items[]? | select(.type=="vault") | .id' 2>/dev/null | head -1 || echo "")

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
    # Create new Vault credential store
    STORE_RESULT=$(kubectl exec -n "$BOUNDARY_NAMESPACE" "$CONTROLLER_POD" -c boundary-controller -- \
        boundary credential-stores create vault \
        -scope-id="$PROJECT_ID" \
        -vault-address="$VAULT_ADDR" \
        -vault-token="$BOUNDARY_VAULT_TOKEN" \
        -name="Vault SSH Credential Store" \
        -description="Vault-backed credential store for SSH brokered credentials" \
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
# Step 8: Create vault-generic Credential Library
# ==========================================
echo ""
echo "Step 8: Create vault-generic Credential Library"
echo "------------------------------------------------"

# Check for existing credential library
EXISTING_LIBS=$(kubectl exec -n "$BOUNDARY_NAMESPACE" "$CONTROLLER_POD" -c boundary-controller -- \
    boundary credential-libraries list -credential-store-id="$VAULT_STORE_ID" -recovery-config=/boundary/config/controller.hcl -format=json 2>/dev/null || echo "{}")

SSH_LIB_ID=$(echo "$EXISTING_LIBS" | jq -r '.items[]? | select(.type=="vault-generic" and (.name | contains("SSH"))) | .id' 2>/dev/null | head -1 || echo "")

if [[ -n "$SSH_LIB_ID" ]]; then
    echo "✅ SSH credential library exists: $SSH_LIB_ID"
else
    # Create vault-generic credential library pointing to KV secret
    # Note: For KV v2, the path is secret/data/... (data is inserted)
    LIB_RESULT=$(kubectl exec -n "$BOUNDARY_NAMESPACE" "$CONTROLLER_POD" -c boundary-controller -- \
        boundary credential-libraries create vault-generic \
        -credential-store-id="$VAULT_STORE_ID" \
        -vault-path="secret/data/boundary/ssh-credentials" \
        -name="SSH Brokered Credentials" \
        -description="Pre-signed SSH credentials for devenv access" \
        -recovery-config=/boundary/config/controller.hcl \
        -format=json \
        2>/dev/null || echo "{}")

    SSH_LIB_ID=$(echo "$LIB_RESULT" | jq -r '.item.id // empty' 2>/dev/null || echo "")
    if [[ -z "$SSH_LIB_ID" ]]; then
        echo "❌ Failed to create SSH credential library"
        echo "   Error: $(echo "$LIB_RESULT" | jq -r '.status_code // .message // "unknown"' 2>/dev/null)"
        exit 1
    fi
    echo "✅ Created vault-generic credential library: $SSH_LIB_ID"
fi

# ==========================================
# Step 9: Find SSH Targets
# ==========================================
echo ""
echo "Step 9: Find SSH Targets"
echo "-------------------------"

# Find SSH targets if not already known
if [[ -z "$CLAUDE_TARGET_ID" ]] || [[ -z "$GEMINI_TARGET_ID" ]]; then
    TARGETS=$(kubectl exec -n "$BOUNDARY_NAMESPACE" "$CONTROLLER_POD" -c boundary-controller -- \
        boundary targets list -scope-id="$PROJECT_ID" -recovery-config=/boundary/config/controller.hcl -format=json 2>/dev/null || echo "{}")

    if [[ -z "$CLAUDE_TARGET_ID" ]]; then
        CLAUDE_TARGET_ID=$(echo "$TARGETS" | jq -r '.items[]? | select(.name=="claude-ssh") | .id' 2>/dev/null | head -1 || echo "")
    fi
    if [[ -z "$GEMINI_TARGET_ID" ]]; then
        GEMINI_TARGET_ID=$(echo "$TARGETS" | jq -r '.items[]? | select(.name=="gemini-ssh") | .id' 2>/dev/null | head -1 || echo "")
    fi
fi

echo "  Claude SSH Target: ${CLAUDE_TARGET_ID:-not found}"
echo "  Gemini SSH Target: ${GEMINI_TARGET_ID:-not found}"

# ==========================================
# Step 10: Add Brokered Credential Sources to Targets
# ==========================================
echo ""
echo "Step 10: Configure Brokered Credentials on Targets"
echo "---------------------------------------------------"
echo ""
echo "Note: Using vault-generic for TCP targets (Community Edition)"
echo ""

# Function to add brokered credential source to a target
add_brokered_credential() {
    local target_id="$1"
    local target_name="$2"

    if [[ -z "$target_id" ]]; then
        echo "⚠️  Skipping $target_name - target not found"
        return
    fi

    # First check if credential is already attached
    TARGET_CHECK=$(kubectl exec -n "$BOUNDARY_NAMESPACE" "$CONTROLLER_POD" -c boundary-controller -- \
        boundary targets read -id="$target_id" -recovery-config=/boundary/config/controller.hcl -format=json 2>/dev/null || echo "{}")

    EXISTING_CREDS=$(echo "$TARGET_CHECK" | jq -r '.item.brokered_credential_source_ids // []' 2>/dev/null)
    if echo "$EXISTING_CREDS" | grep -q "$SSH_LIB_ID"; then
        echo "✅ $target_name: Brokered credential already attached"
        return
    fi

    # Add brokered credential source
    ADD_RESULT=$(kubectl exec -n "$BOUNDARY_NAMESPACE" "$CONTROLLER_POD" -c boundary-controller -- \
        boundary targets add-credential-sources \
        -id="$target_id" \
        -brokered-credential-source="$SSH_LIB_ID" \
        -recovery-config=/boundary/config/controller.hcl \
        -format=json \
        2>&1 || echo "{}")

    if echo "$ADD_RESULT" | grep -q "already exists"; then
        echo "✅ $target_name: Brokered credential already attached"
    elif echo "$ADD_RESULT" | grep -q '"id"'; then
        echo "✅ $target_name: Brokered credential source added"
    elif echo "$ADD_RESULT" | grep -q '"item"'; then
        echo "✅ $target_name: Brokered credential source added"
    else
        echo "⚠️  $target_name: Result unclear"
        echo "   $(echo "$ADD_RESULT" | head -c 150)"
    fi
}

add_brokered_credential "$CLAUDE_TARGET_ID" "claude-ssh"
add_brokered_credential "$GEMINI_TARGET_ID" "gemini-ssh"

# ==========================================
# Summary
# ==========================================
echo ""
echo "=========================================="
echo "  ✅ Credential Brokering Configuration Complete"
echo "=========================================="
echo ""
echo "Components configured:"
echo "  • Vault Policy:           boundary-ssh-brokered"
echo "  • Vault KV Secret:        secret/boundary/ssh-credentials"
echo "  • Vault Credential Store: $VAULT_STORE_ID"
echo "  • Credential Library:     $SSH_LIB_ID (vault-generic)"
echo "  • Claude SSH Target:      ${CLAUDE_TARGET_ID:-not configured}"
echo "  • Gemini SSH Target:      ${GEMINI_TARGET_ID:-not configured}"
echo ""
echo "How Brokered Credentials Work:"
echo "  1. User authenticates to Boundary (password or OIDC)"
echo "  2. User authorizes a session to an SSH target"
echo "  3. Boundary retrieves SSH credentials from Vault KV"
echo "  4. Credentials are returned to the user"
echo "  5. User uses the credentials with their SSH client"
echo ""
echo "Usage:"
echo ""
echo "  # Authenticate via OIDC"
echo "  export BOUNDARY_ADDR=https://boundary.local"
echo "  export BOUNDARY_TLS_INSECURE=true"
echo "  boundary authenticate oidc -auth-method-id=<oidc-id>"
echo ""
echo "  # Get brokered credentials and connect"
echo "  # Method 1: Let boundary handle SSH for you"
echo "  boundary connect -target-id=${CLAUDE_TARGET_ID:-<target-id>} -exec ssh -- -l node -p '{{boundary.port}}' '{{boundary.ip}}'"
echo ""
echo "  # Method 2: Get credentials explicitly"
echo "  boundary targets authorize-session -id=${CLAUDE_TARGET_ID:-<target-id>} -format=json | jq '.item.credentials'"
echo ""
echo "Security Note:"
echo "  This uses a shared pre-signed SSH key stored in Vault KV."
echo "  For per-user certificates, use Enterprise credential injection"
echo "  or sign keys manually via vault.local."
echo ""

# Update credentials file with brokering info
if [[ -f "$CREDS_FILE" ]]; then
    # Remove old brokering section if exists
    sed -i.bak '/==========================================/{N;N;/Vault SSH Credential Brokering/,/^$/d}' "$CREDS_FILE" 2>/dev/null || true
    sed -i.bak '/^Vault Credential Store:/,/^$/d' "$CREDS_FILE" 2>/dev/null || true
    rm -f "$CREDS_FILE.bak" 2>/dev/null || true

    # Check if credential brokering section already exists
    if ! grep -q "Credential Brokering" "$CREDS_FILE"; then
        cat >> "$CREDS_FILE" << EOF

==========================================
  Vault SSH Credential Brokering (Community)
==========================================

Vault Credential Store: $VAULT_STORE_ID
Credential Library:     $SSH_LIB_ID (vault-generic)
Vault KV Path:          secret/boundary/ssh-credentials
Vault Policy:           boundary-ssh-brokered

SSH connection (with brokered credentials):
  # Authenticate first (OIDC or password)
  boundary authenticate oidc -auth-method-id=<oidc-method-id>

  # Connect with automatic credential retrieval
  boundary connect -target-id=${CLAUDE_TARGET_ID:-<target-id>} -exec ssh -- \\
    -l node -p '{{boundary.port}}' '{{boundary.ip}}'

  # Or get credentials explicitly
  boundary targets authorize-session -id=${CLAUDE_TARGET_ID:-<target-id>} -format=json

Note: Uses shared pre-signed SSH key (Community Edition).
      For per-user certs, use Enterprise or manual Vault signing.
EOF
        echo "Updated: $CREDS_FILE"
    else
        echo "Credentials file already contains brokering info"
    fi
fi
