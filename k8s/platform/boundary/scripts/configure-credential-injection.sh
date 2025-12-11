#!/bin/bash
set -euo pipefail

# Configure Boundary Credential Injection for DevEnv SSH access
# This creates static credentials for developer SSH access
#
# REQUIRES: Boundary Enterprise license for credential injection
# For Community Edition, use credential brokering instead (see configure-targets.sh)

BOUNDARY_NAMESPACE="${1:-boundary}"
DEVENV_NAMESPACE="${2:-devenv}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
K8S_DIR="$(dirname "$(dirname "$(dirname "$SCRIPT_DIR")")")"

echo "=========================================="
echo "  Boundary Credential Injection Setup"
echo "=========================================="
echo ""

# Check for Enterprise license
if ! kubectl get secret boundary-license -n "$BOUNDARY_NAMESPACE" &>/dev/null; then
    echo "❌ Boundary Enterprise license not found"
    echo ""
    echo "Credential injection requires Boundary Enterprise."
    echo "For Community Edition, use credential brokering with Vault."
    echo ""
    echo "To add a license:"
    echo "  ./add-license.sh <license-key>"
    exit 1
fi
echo "✅ Enterprise license detected"

# Get controller pod
CONTROLLER_POD=$(kubectl get pod -l app=boundary-controller -n "$BOUNDARY_NAMESPACE" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
if [[ -z "$CONTROLLER_POD" ]]; then
    echo "❌ Boundary controller pod not found"
    exit 1
fi
echo "✅ Controller pod: $CONTROLLER_POD"

# Get admin credentials
CREDS_FILE="$SCRIPT_DIR/boundary-credentials.txt"
if [[ ! -f "$CREDS_FILE" ]]; then
    echo "❌ Credentials file not found at $CREDS_FILE"
    echo "   Run configure-targets.sh first"
    exit 1
fi

AUTH_METHOD_ID=$(grep "Auth Method ID:" "$CREDS_FILE" 2>/dev/null | awk '{print $4}' || echo "")
ADMIN_PASSWORD=$(grep "Password:" "$CREDS_FILE" 2>/dev/null | awk '{print $2}' || echo "")
PROJECT_ID=$(grep "Project:" "$CREDS_FILE" 2>/dev/null | awk '{print $2}' || echo "")
TARGET_ID=$(grep "Target (SSH):" "$CREDS_FILE" 2>/dev/null | awk '{print $3}' || echo "")

if [[ -z "$AUTH_METHOD_ID" ]] || [[ -z "$ADMIN_PASSWORD" ]]; then
    echo "❌ Could not extract credentials from file"
    exit 1
fi

# Authenticate
echo ""
echo "Authenticating with Boundary..."
AUTH_TOKEN=$(kubectl exec -n "$BOUNDARY_NAMESPACE" "$CONTROLLER_POD" -c boundary-controller -- \
    /bin/ash -c "
        export BOUNDARY_ADDR=http://127.0.0.1:9200
        export BOUNDARY_PASSWORD='$ADMIN_PASSWORD'
        boundary authenticate password \
            -auth-method-id='$AUTH_METHOD_ID' \
            -login-name=admin \
            -password=env://BOUNDARY_PASSWORD \
            -format=json
    " 2>/dev/null | jq -r '.item.attributes.token // empty' 2>/dev/null || echo "")

if [[ -z "$AUTH_TOKEN" ]]; then
    echo "❌ Authentication failed"
    exit 1
fi
echo "✅ Authenticated successfully"

# Function to run boundary commands
run_boundary() {
    local cmd="boundary"
    for arg in "$@"; do
        arg="${arg//\'/\'\\\'\'}"
        cmd="$cmd '$arg'"
    done
    kubectl exec -n "$BOUNDARY_NAMESPACE" "$CONTROLLER_POD" -c boundary-controller -- \
        /bin/ash -c "export BOUNDARY_ADDR=http://127.0.0.1:9200; export BOUNDARY_TOKEN='$AUTH_TOKEN'; $cmd"
}

# Get or find project ID
if [[ -z "$PROJECT_ID" ]]; then
    echo ""
    echo "Looking up project ID..."
    SCOPES=$(run_boundary scopes list -format=json 2>/dev/null || echo "{}")
    ORG_ID=$(echo "$SCOPES" | jq -r '.items[]? | select(.name=="DevOps") | .id' 2>/dev/null || echo "")

    if [[ -n "$ORG_ID" ]]; then
        ORG_SCOPES=$(run_boundary scopes list -scope-id="$ORG_ID" -format=json 2>/dev/null || echo "{}")
        PROJECT_ID=$(echo "$ORG_SCOPES" | jq -r '.items[]? | select(.name=="Agent-Sandbox") | .id' 2>/dev/null || echo "")
    fi
fi

if [[ -z "$PROJECT_ID" ]]; then
    echo "❌ Could not find Agent-Sandbox project"
    exit 1
fi
echo "✅ Project ID: $PROJECT_ID"

# Get SSH target ID
if [[ -z "$TARGET_ID" ]]; then
    TARGETS=$(run_boundary targets list -scope-id="$PROJECT_ID" -format=json 2>/dev/null || echo "{}")
    TARGET_ID=$(echo "$TARGETS" | jq -r '.items[]? | select(.name=="devenv-ssh") | .id' 2>/dev/null || echo "")
fi

if [[ -z "$TARGET_ID" ]]; then
    echo "❌ SSH target not found"
    exit 1
fi
echo "✅ Target ID: $TARGET_ID"

# ==========================================
# Create Static Credential Store
# ==========================================
echo ""
echo "Step 1: Create Static Credential Store"
echo "---------------------------------------"

# Check for existing static credential store
CRED_STORES=$(run_boundary credential-stores list -scope-id="$PROJECT_ID" -format=json 2>/dev/null || echo "{}")
STATIC_STORE_ID=$(echo "$CRED_STORES" | jq -r '.items[]? | select(.type=="static") | .id' 2>/dev/null | head -1 || echo "")

if [[ -n "$STATIC_STORE_ID" ]]; then
    echo "✅ Static credential store exists: $STATIC_STORE_ID"
else
    STORE_RESULT=$(run_boundary credential-stores create static \
        -name="devenv-creds" \
        -description="Static credentials for DevEnv SSH access" \
        -scope-id="$PROJECT_ID" \
        -format=json \
        2>/dev/null || echo "{}")

    STATIC_STORE_ID=$(echo "$STORE_RESULT" | jq -r '.item.id // empty' 2>/dev/null || echo "")
    if [[ -z "$STATIC_STORE_ID" ]]; then
        echo "❌ Failed to create static credential store"
        exit 1
    fi
    echo "✅ Created static credential store: $STATIC_STORE_ID"
fi

# ==========================================
# Create SSH Credentials for Developers
# ==========================================
echo ""
echo "Step 2: Create SSH Credentials"
echo "-------------------------------"

# Get the DevEnv SSH private key or generate SSH credentials
# First, check if VSO has created a secret with SSH credentials
DEVENV_SSH_SECRET=$(kubectl get secret devenv-ssh-credentials -n "$DEVENV_NAMESPACE" -o jsonpath='{.data}' 2>/dev/null || echo "")

if [[ -n "$DEVENV_SSH_SECRET" ]]; then
    echo "Found DevEnv SSH credentials from Vault"
    SSH_PRIVATE_KEY=$(kubectl get secret devenv-ssh-credentials -n "$DEVENV_NAMESPACE" -o jsonpath='{.data.private_key}' 2>/dev/null | base64 -d || echo "")
    SSH_USERNAME=$(kubectl get secret devenv-ssh-credentials -n "$DEVENV_NAMESPACE" -o jsonpath='{.data.username}' 2>/dev/null | base64 -d || echo "node")
else
    echo "Using default DevEnv SSH configuration"
    # Default SSH user for devenv
    SSH_USERNAME="node"

    # Check if we have Vault SSH CA configured - use certificate-based auth
    VAULT_TOKEN=$(grep "Root Token:" "$K8S_DIR/platform/vault/scripts/vault-keys.txt" 2>/dev/null | awk '{print $3}' || echo "")

    if [[ -n "$VAULT_TOKEN" ]]; then
        # Try to get SSH CA public key
        SSH_CA_PUBKEY=$(kubectl exec -n vault vault-0 -- sh -c "VAULT_TOKEN='$VAULT_TOKEN' vault read -field=public_key ssh/config/ca" 2>/dev/null || echo "")

        if [[ -n "$SSH_CA_PUBKEY" ]]; then
            echo "✅ Vault SSH CA available - using certificate-based authentication"
            USE_VAULT_SSH="true"
        else
            echo "⚠️  Vault SSH CA not configured"
            USE_VAULT_SSH="false"
        fi
    else
        USE_VAULT_SSH="false"
    fi
fi

# Check for existing username-password credential
CRED_LIST=$(run_boundary credentials list -credential-store-id="$STATIC_STORE_ID" -format=json 2>/dev/null || echo "{}")
EXISTING_CRED=$(echo "$CRED_LIST" | jq -r '.items[]? | select(.name=="devenv-developer-ssh") | .id' 2>/dev/null || echo "")

if [[ -n "$EXISTING_CRED" ]]; then
    echo "✅ Developer SSH credential exists: $EXISTING_CRED"
    CRED_ID="$EXISTING_CRED"
else
    # Create username-only credential (for SSH certificate injection, we just need the username)
    CRED_RESULT=$(run_boundary credentials create username-password \
        -name="devenv-developer-ssh" \
        -description="SSH credentials for developer access to DevEnv" \
        -credential-store-id="$STATIC_STORE_ID" \
        -username="$SSH_USERNAME" \
        -password="unused-with-ssh-certs" \
        -format=json \
        2>/dev/null || echo "{}")

    CRED_ID=$(echo "$CRED_RESULT" | jq -r '.item.id // empty' 2>/dev/null || echo "")
    if [[ -z "$CRED_ID" ]]; then
        echo "⚠️  Failed to create static credential"
        echo "   Will rely on Vault SSH certificate brokering instead"
    else
        echo "✅ Created SSH credential: $CRED_ID"
    fi
fi

# ==========================================
# Configure Credential Injection on Target
# ==========================================
echo ""
echo "Step 3: Configure Credential Injection"
echo "---------------------------------------"

if [[ -n "$CRED_ID" ]]; then
    # Check if Enterprise feature is available by trying to add injected credential
    INJECT_RESULT=$(run_boundary targets add-credential-sources \
        -id="$TARGET_ID" \
        -injected-application-credential-source="$CRED_ID" \
        -format=json \
        2>&1 || echo "{}")

    if echo "$INJECT_RESULT" | grep -q "enterprise"; then
        echo "⚠️  Credential injection requires valid Enterprise license activation"
        echo "   Using credential brokering as fallback"

        # Fall back to brokering
        run_boundary targets add-credential-sources \
            -id="$TARGET_ID" \
            -brokered-credential-source="$CRED_ID" \
            2>/dev/null || true

        INJECTION_MODE="brokered"
    elif echo "$INJECT_RESULT" | grep -q "already"; then
        echo "✅ Credential already attached to target"
        INJECTION_MODE="injected"
    else
        echo "✅ Credential injection configured on target"
        INJECTION_MODE="injected"
    fi
else
    echo "⚠️  No credential to attach - using SSH certificate brokering"
    INJECTION_MODE="vault-ssh"
fi

# ==========================================
# Summary
# ==========================================
echo ""
echo "=========================================="
echo "  Credential Injection Configuration"
echo "=========================================="
echo ""
echo "Mode: $INJECTION_MODE"
echo ""
echo "Static Credential Store: $STATIC_STORE_ID"
echo "SSH Credential: ${CRED_ID:-not created}"
echo "Target: $TARGET_ID"
echo ""

if [[ "$INJECTION_MODE" == "injected" ]]; then
    echo "✅ Credential Injection Enabled"
    echo ""
    echo "How it works:"
    echo "  1. Users authenticate to Boundary via password or OIDC"
    echo "  2. When connecting to target, credentials are automatically injected"
    echo "  3. Users don't need to manage or know SSH credentials"
    echo ""
    echo "Usage:"
    echo "  boundary connect ssh -target-id=$TARGET_ID"
else
    echo "ℹ️  Using Credential Brokering"
    echo ""
    echo "How it works:"
    echo "  1. Users authenticate to Boundary"
    echo "  2. Boundary retrieves credentials from Vault"
    echo "  3. Credentials are provided to the client for SSH connection"
    echo ""
    echo "Usage:"
    echo "  boundary connect ssh -target-id=$TARGET_ID -- -l node"
fi
echo ""
