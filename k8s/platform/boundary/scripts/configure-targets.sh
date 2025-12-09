#!/bin/bash
set -euo pipefail

# Configure Boundary with scopes, host catalogs, and targets for agent-sandbox
# This script automates the Boundary configuration using the recovery KMS workflow

BOUNDARY_NAMESPACE="${1:-boundary}"
DEVENV_NAMESPACE="${2:-devenv}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
K8S_DIR="$(dirname "$(dirname "$(dirname "$SCRIPT_DIR")")")"

# Source configuration if available
if [[ -f "$K8S_DIR/scripts/.env" ]]; then
    source "$K8S_DIR/scripts/.env"
elif [[ -f "$K8S_DIR/scripts/platform.env.example" ]]; then
    source "$K8S_DIR/scripts/platform.env.example"
fi

echo "=========================================="
echo "  Boundary Targets Configuration"
echo "=========================================="
echo ""

# Check for boundary CLI
if ! command -v boundary &> /dev/null; then
    echo "⚠️  Boundary CLI not found"
    echo ""
    echo "Install from: https://developer.hashicorp.com/boundary/downloads"
    echo "Or with Homebrew: brew install hashicorp/tap/boundary"
    echo ""
    echo "Alternatively, this script can configure Boundary using kubectl exec..."
    USE_KUBECTL="true"
else
    USE_KUBECTL="false"
fi

# Check Boundary controller is running
echo "Checking Boundary controller status..."
CONTROLLER_STATUS=$(kubectl get pod -l app=boundary-controller -n "$BOUNDARY_NAMESPACE" -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "NotFound")
if [[ "$CONTROLLER_STATUS" != "Running" ]]; then
    echo "❌ Boundary controller not running (status: $CONTROLLER_STATUS)"
    exit 1
fi
echo "✅ Boundary controller running"

# Get recovery key for initial configuration
RECOVERY_KEY=$(kubectl get secret boundary-kms-keys -n "$BOUNDARY_NAMESPACE" -o jsonpath='{.data.BOUNDARY_RECOVERY_KEY}' 2>/dev/null | base64 -d || echo "")
if [[ -z "$RECOVERY_KEY" ]]; then
    echo "❌ Cannot find Boundary recovery key"
    exit 1
fi
echo "✅ Found recovery key"

# Get devenv service info
DEVENV_SVC_IP=$(kubectl get svc devenv -n "$DEVENV_NAMESPACE" -o jsonpath='{.spec.clusterIP}' 2>/dev/null || echo "")
if [[ -z "$DEVENV_SVC_IP" ]]; then
    echo "⚠️  DevEnv service not found, using placeholder"
    DEVENV_SVC_IP="devenv.devenv.svc.cluster.local"
fi
echo "DevEnv service address: $DEVENV_SVC_IP"

echo ""
echo "Configuring Boundary resources..."
echo ""

# Use kubectl exec to run boundary commands in the controller pod
CONTROLLER_POD=$(kubectl get pod -l app=boundary-controller -n "$BOUNDARY_NAMESPACE" -o jsonpath='{.items[0].metadata.name}')

# Function to run boundary commands
run_boundary() {
    kubectl exec -n "$BOUNDARY_NAMESPACE" "$CONTROLLER_POD" -- \
        env BOUNDARY_ADDR=http://127.0.0.1:9200 \
        boundary "$@" 2>/dev/null
}

# Check if already configured by looking for existing org
echo "Checking for existing configuration..."
EXISTING_ORGS=$(run_boundary scopes list -format=json -recovery-kms-hcl="kms \"aead\" { purpose = \"recovery\"; aead_type = \"aes-gcm\"; key = \"$RECOVERY_KEY\"; key_id = \"global_recovery\" }" 2>/dev/null | jq -r '.items[]?.name // empty' || echo "")

if echo "$EXISTING_ORGS" | grep -q "DevOps"; then
    echo "✅ Boundary already configured (DevOps org exists)"
    echo ""
    echo "To reconfigure, delete the org first using the Boundary CLI"
    echo ""

    # Show existing configuration
    echo "Existing configuration:"
    run_boundary scopes list -format=json -recovery-kms-hcl="kms \"aead\" { purpose = \"recovery\"; aead_type = \"aes-gcm\"; key = \"$RECOVERY_KEY\"; key_id = \"global_recovery\" }" 2>/dev/null | jq -r '.items[] | "  - \(.name) (\(.id))"' || true
    exit 0
fi

echo ""
echo "Step 1: Create Organization Scope"
echo "----------------------------------"

# Create organization scope
ORG_RESULT=$(run_boundary scopes create \
    -name="DevOps" \
    -description="DevOps Team - Agent Sandbox Access" \
    -scope-id=global \
    -format=json \
    -recovery-kms-hcl="kms \"aead\" { purpose = \"recovery\"; aead_type = \"aes-gcm\"; key = \"$RECOVERY_KEY\"; key_id = \"global_recovery\" }" 2>/dev/null || echo "{}")

ORG_ID=$(echo "$ORG_RESULT" | jq -r '.item.id // empty')
if [[ -z "$ORG_ID" ]]; then
    echo "❌ Failed to create organization scope"
    echo "$ORG_RESULT"
    exit 1
fi
echo "✅ Created organization: DevOps ($ORG_ID)"

echo ""
echo "Step 2: Create Project Scope"
echo "----------------------------"

# Create project scope
PROJECT_RESULT=$(run_boundary scopes create \
    -name="Agent-Sandbox" \
    -description="Agent Sandbox Development Environment" \
    -scope-id="$ORG_ID" \
    -format=json \
    -recovery-kms-hcl="kms \"aead\" { purpose = \"recovery\"; aead_type = \"aes-gcm\"; key = \"$RECOVERY_KEY\"; key_id = \"global_recovery\" }" 2>/dev/null || echo "{}")

PROJECT_ID=$(echo "$PROJECT_RESULT" | jq -r '.item.id // empty')
if [[ -z "$PROJECT_ID" ]]; then
    echo "❌ Failed to create project scope"
    exit 1
fi
echo "✅ Created project: Agent-Sandbox ($PROJECT_ID)"

echo ""
echo "Step 3: Create Auth Method"
echo "--------------------------"

# Create password auth method in org scope
AUTH_RESULT=$(run_boundary auth-methods create password \
    -name="password" \
    -description="Password authentication" \
    -scope-id="$ORG_ID" \
    -format=json \
    -recovery-kms-hcl="kms \"aead\" { purpose = \"recovery\"; aead_type = \"aes-gcm\"; key = \"$RECOVERY_KEY\"; key_id = \"global_recovery\" }" 2>/dev/null || echo "{}")

AUTH_METHOD_ID=$(echo "$AUTH_RESULT" | jq -r '.item.id // empty')
if [[ -z "$AUTH_METHOD_ID" ]]; then
    echo "⚠️  Auth method creation failed (may already exist)"
else
    echo "✅ Created auth method: password ($AUTH_METHOD_ID)"
fi

echo ""
echo "Step 4: Create Admin Account"
echo "----------------------------"

# Generate random password for admin
ADMIN_PASSWORD=$(openssl rand -base64 16 | tr -d '\n/+=' | head -c 16)

# Create admin account
ACCOUNT_RESULT=$(run_boundary accounts create password \
    -auth-method-id="$AUTH_METHOD_ID" \
    -login-name="admin" \
    -password="$ADMIN_PASSWORD" \
    -name="Admin Account" \
    -description="Administrator account for Boundary" \
    -format=json \
    -recovery-kms-hcl="kms \"aead\" { purpose = \"recovery\"; aead_type = \"aes-gcm\"; key = \"$RECOVERY_KEY\"; key_id = \"global_recovery\" }" 2>/dev/null || echo "{}")

ACCOUNT_ID=$(echo "$ACCOUNT_RESULT" | jq -r '.item.id // empty')
if [[ -z "$ACCOUNT_ID" ]]; then
    echo "⚠️  Admin account creation failed (may already exist)"
else
    echo "✅ Created admin account ($ACCOUNT_ID)"
fi

# Create admin user
USER_RESULT=$(run_boundary users create \
    -name="admin" \
    -description="Administrator" \
    -scope-id="$ORG_ID" \
    -format=json \
    -recovery-kms-hcl="kms \"aead\" { purpose = \"recovery\"; aead_type = \"aes-gcm\"; key = \"$RECOVERY_KEY\"; key_id = \"global_recovery\" }" 2>/dev/null || echo "{}")

USER_ID=$(echo "$USER_RESULT" | jq -r '.item.id // empty')
if [[ -n "$USER_ID" ]] && [[ -n "$ACCOUNT_ID" ]]; then
    # Associate account with user
    run_boundary users set-accounts \
        -id="$USER_ID" \
        -account="$ACCOUNT_ID" \
        -recovery-kms-hcl="kms \"aead\" { purpose = \"recovery\"; aead_type = \"aes-gcm\"; key = \"$RECOVERY_KEY\"; key_id = \"global_recovery\" }" 2>/dev/null || true
    echo "✅ Created admin user ($USER_ID)"
fi

echo ""
echo "Step 5: Create Host Catalog"
echo "---------------------------"

# Create static host catalog
CATALOG_RESULT=$(run_boundary host-catalogs create static \
    -name="devenv-hosts" \
    -description="Agent Sandbox DevEnv Hosts" \
    -scope-id="$PROJECT_ID" \
    -format=json \
    -recovery-kms-hcl="kms \"aead\" { purpose = \"recovery\"; aead_type = \"aes-gcm\"; key = \"$RECOVERY_KEY\"; key_id = \"global_recovery\" }" 2>/dev/null || echo "{}")

CATALOG_ID=$(echo "$CATALOG_RESULT" | jq -r '.item.id // empty')
if [[ -z "$CATALOG_ID" ]]; then
    echo "❌ Failed to create host catalog"
    exit 1
fi
echo "✅ Created host catalog: devenv-hosts ($CATALOG_ID)"

echo ""
echo "Step 6: Create Host"
echo "-------------------"

# Create host for devenv service
HOST_RESULT=$(run_boundary hosts create static \
    -name="devenv-service" \
    -description="DevEnv Kubernetes Service" \
    -address="$DEVENV_SVC_IP" \
    -host-catalog-id="$CATALOG_ID" \
    -format=json \
    -recovery-kms-hcl="kms \"aead\" { purpose = \"recovery\"; aead_type = \"aes-gcm\"; key = \"$RECOVERY_KEY\"; key_id = \"global_recovery\" }" 2>/dev/null || echo "{}")

HOST_ID=$(echo "$HOST_RESULT" | jq -r '.item.id // empty')
if [[ -z "$HOST_ID" ]]; then
    echo "❌ Failed to create host"
    exit 1
fi
echo "✅ Created host: devenv-service ($HOST_ID)"

echo ""
echo "Step 7: Create Host Set"
echo "-----------------------"

# Create host set
HOSTSET_RESULT=$(run_boundary host-sets create static \
    -name="devenv-set" \
    -description="DevEnv Host Set" \
    -host-catalog-id="$CATALOG_ID" \
    -format=json \
    -recovery-kms-hcl="kms \"aead\" { purpose = \"recovery\"; aead_type = \"aes-gcm\"; key = \"$RECOVERY_KEY\"; key_id = \"global_recovery\" }" 2>/dev/null || echo "{}")

HOSTSET_ID=$(echo "$HOSTSET_RESULT" | jq -r '.item.id // empty')
if [[ -z "$HOSTSET_ID" ]]; then
    echo "❌ Failed to create host set"
    exit 1
fi
echo "✅ Created host set: devenv-set ($HOSTSET_ID)"

# Add host to host set
run_boundary host-sets add-hosts \
    -id="$HOSTSET_ID" \
    -host="$HOST_ID" \
    -recovery-kms-hcl="kms \"aead\" { purpose = \"recovery\"; aead_type = \"aes-gcm\"; key = \"$RECOVERY_KEY\"; key_id = \"global_recovery\" }" 2>/dev/null || true
echo "✅ Added host to host set"

echo ""
echo "Step 8: Create SSH Target"
echo "-------------------------"

# Create SSH target
TARGET_RESULT=$(run_boundary targets create tcp \
    -name="devenv-ssh" \
    -description="SSH access to Agent Sandbox DevEnv" \
    -default-port=22 \
    -scope-id="$PROJECT_ID" \
    -format=json \
    -recovery-kms-hcl="kms \"aead\" { purpose = \"recovery\"; aead_type = \"aes-gcm\"; key = \"$RECOVERY_KEY\"; key_id = \"global_recovery\" }" 2>/dev/null || echo "{}")

TARGET_ID=$(echo "$TARGET_RESULT" | jq -r '.item.id // empty')
if [[ -z "$TARGET_ID" ]]; then
    echo "❌ Failed to create target"
    exit 1
fi
echo "✅ Created target: devenv-ssh ($TARGET_ID)"

# Add host source to target
run_boundary targets add-host-sources \
    -id="$TARGET_ID" \
    -host-source="$HOSTSET_ID" \
    -recovery-kms-hcl="kms \"aead\" { purpose = \"recovery\"; aead_type = \"aes-gcm\"; key = \"$RECOVERY_KEY\"; key_id = \"global_recovery\" }" 2>/dev/null || true
echo "✅ Added host set to target"

echo ""
echo "Step 9: Configure Vault SSH Credential Brokering"
echo "------------------------------------------------"

# Check if Vault is available and SSH engine is configured
VAULT_NAMESPACE="${VAULT_NAMESPACE:-vault}"
VAULT_TOKEN=$(grep "Root Token:" "$K8S_DIR/platform/vault/scripts/vault-keys.txt" 2>/dev/null | awk '{print $3}' || echo "")

if [[ -n "$VAULT_TOKEN" ]]; then
    # Check if Vault SSH engine is enabled
    SSH_ENGINE=$(kubectl exec -n "$VAULT_NAMESPACE" vault-0 -- sh -c "VAULT_TOKEN='$VAULT_TOKEN' vault secrets list -format=json" 2>/dev/null | jq -r '."ssh/"' || echo "")

    if [[ -n "$SSH_ENGINE" ]] && [[ "$SSH_ENGINE" != "null" ]]; then
        echo "✅ Vault SSH secrets engine detected"

        # Get Vault address for Boundary to reach
        VAULT_SVC="http://vault.vault.svc.cluster.local:8200"

        # Create Vault credential store
        CRED_STORE_RESULT=$(run_boundary credential-stores create vault \
            -name="vault-creds" \
            -description="Vault credential store for SSH certificates" \
            -scope-id="$PROJECT_ID" \
            -vault-address="$VAULT_SVC" \
            -vault-token="$VAULT_TOKEN" \
            -format=json \
            -recovery-kms-hcl="kms \"aead\" { purpose = \"recovery\"; aead_type = \"aes-gcm\"; key = \"$RECOVERY_KEY\"; key_id = \"global_recovery\" }" 2>/dev/null || echo "{}")

        CRED_STORE_ID=$(echo "$CRED_STORE_RESULT" | jq -r '.item.id // empty')
        if [[ -n "$CRED_STORE_ID" ]]; then
            echo "✅ Created Vault credential store ($CRED_STORE_ID)"

            # Create SSH certificate credential library
            CRED_LIB_RESULT=$(run_boundary credential-libraries create vault-ssh-certificate \
                -name="ssh-certs" \
                -description="Vault SSH certificate signing" \
                -credential-store-id="$CRED_STORE_ID" \
                -vault-path="ssh/sign/devenv-access" \
                -username="node" \
                -key-type="ed25519" \
                -format=json \
                -recovery-kms-hcl="kms \"aead\" { purpose = \"recovery\"; aead_type = \"aes-gcm\"; key = \"$RECOVERY_KEY\"; key_id = \"global_recovery\" }" 2>/dev/null || echo "{}")

            CRED_LIB_ID=$(echo "$CRED_LIB_RESULT" | jq -r '.item.id // empty')
            if [[ -n "$CRED_LIB_ID" ]]; then
                echo "✅ Created SSH certificate credential library ($CRED_LIB_ID)"

                # Add credential brokering to SSH target
                run_boundary targets add-credential-sources \
                    -id="$TARGET_ID" \
                    -brokered-credential-source="$CRED_LIB_ID" \
                    -recovery-kms-hcl="kms \"aead\" { purpose = \"recovery\"; aead_type = \"aes-gcm\"; key = \"$RECOVERY_KEY\"; key_id = \"global_recovery\" }" 2>/dev/null || true
                echo "✅ Attached SSH credentials to target (brokered)"

                VAULT_SSH_CONFIGURED="true"
            else
                echo "⚠️  Failed to create SSH credential library"
                VAULT_SSH_CONFIGURED="false"
            fi
        else
            echo "⚠️  Failed to create Vault credential store"
            echo "   (This may be due to network policy or Vault token issues)"
            VAULT_SSH_CONFIGURED="false"
        fi
    else
        echo "ℹ️  Vault SSH secrets engine not enabled"
        echo "   Run: ./platform/vault/scripts/configure-ssh-engine.sh"
        VAULT_SSH_CONFIGURED="false"
    fi
else
    echo "ℹ️  Vault token not found - skipping credential brokering"
    echo "   (SSH access will work with manual authentication)"
    VAULT_SSH_CONFIGURED="false"
fi

echo ""
echo "Step 10: Create Role for Admin"
echo "------------------------------"

# Create admin role in project scope
ROLE_RESULT=$(run_boundary roles create \
    -name="admin" \
    -description="Full admin access" \
    -scope-id="$PROJECT_ID" \
    -format=json \
    -recovery-kms-hcl="kms \"aead\" { purpose = \"recovery\"; aead_type = \"aes-gcm\"; key = \"$RECOVERY_KEY\"; key_id = \"global_recovery\" }" 2>/dev/null || echo "{}")

ROLE_ID=$(echo "$ROLE_RESULT" | jq -r '.item.id // empty')
if [[ -n "$ROLE_ID" ]] && [[ -n "$USER_ID" ]]; then
    # Add grants
    run_boundary roles add-grants \
        -id="$ROLE_ID" \
        -grant="ids=*;type=*;actions=*" \
        -recovery-kms-hcl="kms \"aead\" { purpose = \"recovery\"; aead_type = \"aes-gcm\"; key = \"$RECOVERY_KEY\"; key_id = \"global_recovery\" }" 2>/dev/null || true

    # Add principal
    run_boundary roles add-principals \
        -id="$ROLE_ID" \
        -principal="$USER_ID" \
        -recovery-kms-hcl="kms \"aead\" { purpose = \"recovery\"; aead_type = \"aes-gcm\"; key = \"$RECOVERY_KEY\"; key_id = \"global_recovery\" }" 2>/dev/null || true
    echo "✅ Created admin role with full access"
fi

# Save credentials
CREDS_FILE="$SCRIPT_DIR/boundary-credentials.txt"
cat > "$CREDS_FILE" << EOF
==========================================
  Boundary Admin Credentials
==========================================

Auth Method ID: $AUTH_METHOD_ID
Login Name:     admin
Password:       $ADMIN_PASSWORD

==========================================
  Configuration IDs
==========================================

Organization:       $ORG_ID
Project:            $PROJECT_ID
Host Catalog:       $CATALOG_ID
Host:               $HOST_ID
Host Set:           $HOSTSET_ID
Target (SSH):       $TARGET_ID
Credential Store:   ${CRED_STORE_ID:-not configured}
Credential Library: ${CRED_LIB_ID:-not configured}
Vault SSH:          ${VAULT_SSH_CONFIGURED:-false}

==========================================
  Usage
==========================================

1. Port forward to Boundary API:
   kubectl port-forward -n $BOUNDARY_NAMESPACE svc/boundary-controller-api 9200:9200

2. Authenticate:
   export BOUNDARY_ADDR=http://127.0.0.1:9200
   boundary authenticate password \\
     -auth-method-id=$AUTH_METHOD_ID \\
     -login-name=admin \\
     -password='$ADMIN_PASSWORD'

3. Connect to DevEnv via SSH:
   boundary connect ssh -target-id=$TARGET_ID -- -l node

4. Or establish a proxy:
   boundary connect -target-id=$TARGET_ID -listen-port=2222
   ssh -p 2222 node@127.0.0.1

EOF
chmod 600 "$CREDS_FILE"

# Step 11: Optionally configure OIDC if Keycloak is available
echo ""
echo "Step 11: Check for Keycloak (Optional OIDC)"
echo "-------------------------------------------"

KEYCLOAK_STATUS=$(kubectl get pod -l app=keycloak -n keycloak -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "NotFound")
if [[ "$KEYCLOAK_STATUS" == "Running" ]]; then
    echo "✅ Keycloak detected and running"
    echo ""
    echo "You can configure OIDC authentication with Keycloak by running:"
    echo "  $SCRIPT_DIR/configure-oidc-auth.sh"
    echo ""
    echo "This will enable SSO authentication via Keycloak with role-based access."
else
    echo "ℹ️  Keycloak not detected - skipping OIDC configuration"
    echo "   (Password authentication is configured and ready to use)"
fi

echo ""
echo "=========================================="
echo "  ✅ Boundary Configuration Complete"
echo "=========================================="
echo ""
echo "Credentials saved to: $CREDS_FILE"
echo ""
echo "Quick start:"
echo "  1. kubectl port-forward -n $BOUNDARY_NAMESPACE svc/boundary-controller-api 9200:9200"
echo "  2. export BOUNDARY_ADDR=http://127.0.0.1:9200"
echo "  3. boundary authenticate password -auth-method-id=$AUTH_METHOD_ID -login-name=admin -password='$ADMIN_PASSWORD'"
echo "  4. boundary connect ssh -target-id=$TARGET_ID -- -l node"
echo ""
