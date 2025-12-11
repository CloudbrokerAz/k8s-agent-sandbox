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

# Get admin credentials from credentials file
CREDS_FILE="$SCRIPT_DIR/boundary-credentials.txt"
ADMIN_PASSWORD=""
AUTH_METHOD_ID=""

if [[ -f "$CREDS_FILE" ]]; then
    ADMIN_PASSWORD=$(grep "Password:" "$CREDS_FILE" 2>/dev/null | awk '{print $2}' || echo "")
    AUTH_METHOD_ID=$(grep "Auth Method ID:" "$CREDS_FILE" 2>/dev/null | awk '{print $3}' || echo "")
fi

if [[ -z "$ADMIN_PASSWORD" ]] || [[ -z "$AUTH_METHOD_ID" ]]; then
    echo "❌ Cannot find Boundary admin credentials in $CREDS_FILE"
    echo "   Please ensure boundary-credentials.txt exists and contains valid credentials"
    exit 1
fi
echo "✅ Found admin credentials (Auth Method: $AUTH_METHOD_ID)"

# Get devenv service info - try known service names
DEVENV_SVC_NAME=""
DEVENV_SVC_IP=""

# Try to find the service by common names
for SVC_NAME in "claude-code-sandbox" "devenv" "sandbox"; do
    DEVENV_SVC_IP=$(kubectl get svc "$SVC_NAME" -n "$DEVENV_NAMESPACE" -o jsonpath='{.spec.clusterIP}' 2>/dev/null || echo "")
    if [[ -n "$DEVENV_SVC_IP" ]]; then
        DEVENV_SVC_NAME="$SVC_NAME"
        break
    fi
done

if [[ -z "$DEVENV_SVC_IP" ]]; then
    # Fallback: find any SSH-capable service (port 22) in the namespace
    DEVENV_SVC_NAME=$(kubectl get svc -n "$DEVENV_NAMESPACE" -o jsonpath='{.items[?(@.spec.ports[*].port==22)].metadata.name}' 2>/dev/null | awk '{print $1}' || echo "")
    if [[ -n "$DEVENV_SVC_NAME" ]]; then
        DEVENV_SVC_IP=$(kubectl get svc "$DEVENV_SVC_NAME" -n "$DEVENV_NAMESPACE" -o jsonpath='{.spec.clusterIP}' 2>/dev/null || echo "")
    fi
fi

if [[ -z "$DEVENV_SVC_IP" ]]; then
    echo "⚠️  No SSH service found in $DEVENV_NAMESPACE namespace"
    echo "   Using DNS placeholder (will resolve if service is created later)"
    DEVENV_SVC_IP="claude-code-sandbox.$DEVENV_NAMESPACE.svc.cluster.local"
    DEVENV_SVC_NAME="claude-code-sandbox"
else
    echo "✅ Found service: $DEVENV_SVC_NAME"
fi
echo "DevEnv service address: $DEVENV_SVC_IP"

echo ""
echo "Configuring Boundary resources..."
echo ""

# Use kubectl exec to run boundary commands in the controller pod
CONTROLLER_POD=$(kubectl get pod -l app=boundary-controller -n "$BOUNDARY_NAMESPACE" -o jsonpath='{.items[0].metadata.name}')

# Authenticate and get token
echo "Authenticating with Boundary..."
AUTH_TOKEN=$(kubectl exec -n "$BOUNDARY_NAMESPACE" "$CONTROLLER_POD" -c boundary-controller -- /bin/ash -c "
    export BOUNDARY_ADDR=http://127.0.0.1:9200
    echo '$ADMIN_PASSWORD' > /tmp/boundary-pass.txt
    boundary authenticate password \
        -auth-method-id='$AUTH_METHOD_ID' \
        -login-name=admin \
        -password=file:///tmp/boundary-pass.txt \
        -keyring-type=none \
        -format=json
    rm -f /tmp/boundary-pass.txt
" 2>/dev/null | sed -n 's/.*\"token\":\"\([^\"]*\)\".*/\1/p' || echo "")

if [[ -z "$AUTH_TOKEN" ]]; then
    echo "❌ Failed to authenticate with Boundary"
    exit 1
fi
echo "✅ Authenticated successfully"

# Function to run boundary commands with auth token
run_boundary() {
    local cmd="boundary"
    for arg in "$@"; do
        # Escape single quotes in arguments
        arg="${arg//\'/\'\\\'\'}"
        cmd="$cmd '$arg'"
    done
    kubectl exec -n "$BOUNDARY_NAMESPACE" "$CONTROLLER_POD" -c boundary-controller -- \
        /bin/ash -c "export BOUNDARY_ADDR=http://127.0.0.1:9200; export BOUNDARY_TOKEN='$AUTH_TOKEN'; $cmd"
}

# Check for existing configuration and resume if needed
echo "Checking for existing configuration..."
SCOPES_JSON=$(run_boundary scopes list -format=json 2>/dev/null || echo '{"items":[]}')

# Look for DevOps org
ORG_ID=$(echo "$SCOPES_JSON" | jq -r '.items[] | select(.name=="DevOps") | .id' 2>/dev/null | head -1 || echo "")

echo ""
echo "Step 1: Create Organization Scope"
echo "----------------------------------"

if [[ -n "$ORG_ID" ]]; then
    echo "✅ Organization exists: DevOps ($ORG_ID)"
else
    # Create organization scope
    ORG_RESULT=$(run_boundary scopes create \
        -name="DevOps" \
        -description="DevOps Team - Agent Sandbox Access" \
        -scope-id=global \
        -format=json \
        2>/dev/null || echo "{}")

    ORG_ID=$(echo "$ORG_RESULT" | jq -r '.item.id // empty')
    if [[ -z "$ORG_ID" ]]; then
        echo "❌ Failed to create organization scope"
        echo "$ORG_RESULT"
        exit 1
    fi
    echo "✅ Created organization: DevOps ($ORG_ID)"
fi

echo ""
echo "Step 2: Create Project Scope"
echo "----------------------------"

# Check for existing project
ORG_SCOPES=$(run_boundary scopes list -scope-id="$ORG_ID" -format=json 2>/dev/null || echo '{"items":[]}')
PROJECT_ID=$(echo "$ORG_SCOPES" | jq -r '.items[] | select(.name=="Agent-Sandbox") | .id' 2>/dev/null | head -1 || echo "")

if [[ -n "$PROJECT_ID" ]]; then
    echo "✅ Project exists: Agent-Sandbox ($PROJECT_ID)"
else
    # Create project scope
    PROJECT_RESULT=$(run_boundary scopes create \
        -name="Agent-Sandbox" \
        -description="Agent Sandbox Development Environment" \
        -scope-id="$ORG_ID" \
        -format=json \
        2>/dev/null || echo "{}")

    PROJECT_ID=$(echo "$PROJECT_RESULT" | jq -r '.item.id // empty')
    if [[ -z "$PROJECT_ID" ]]; then
        echo "❌ Failed to create project scope"
        exit 1
    fi
    echo "✅ Created project: Agent-Sandbox ($PROJECT_ID)"
fi

echo ""
echo "Step 3: Create Auth Method"
echo "--------------------------"

# Check for existing auth method
AUTH_METHODS=$(run_boundary auth-methods list -scope-id="$ORG_ID" -format=json 2>/dev/null || echo '{"items":[]}')
AUTH_METHOD_ID=$(echo "$AUTH_METHODS" | jq -r '.items[] | select(.name=="password") | .id' 2>/dev/null | head -1 || echo "")

if [[ -n "$AUTH_METHOD_ID" ]]; then
    echo "✅ Auth method exists: password ($AUTH_METHOD_ID)"
else
    # Create password auth method in org scope
    AUTH_RESULT=$(run_boundary auth-methods create password \
        -name="password" \
        -description="Password authentication" \
        -scope-id="$ORG_ID" \
        -format=json \
        2>/dev/null || echo "{}")

    AUTH_METHOD_ID=$(echo "$AUTH_RESULT" | jq -r '.item.id // empty')
    if [[ -z "$AUTH_METHOD_ID" ]]; then
        echo "⚠️  Auth method creation failed"
    else
        echo "✅ Created auth method: password ($AUTH_METHOD_ID)"
    fi
fi

echo ""
echo "Step 4: Create Host Catalog"
echo "---------------------------"

# Check for existing host catalog
HOST_CATALOGS=$(run_boundary host-catalogs list -scope-id="$PROJECT_ID" -format=json 2>/dev/null || echo '{"items":[]}')
CATALOG_ID=$(echo "$HOST_CATALOGS" | jq -r '.items[] | select(.name=="devenv-hosts") | .id' 2>/dev/null | head -1 || echo "")

if [[ -n "$CATALOG_ID" ]]; then
    echo "✅ Host catalog exists: devenv-hosts ($CATALOG_ID)"
else
    # Create static host catalog
    CATALOG_RESULT=$(run_boundary host-catalogs create static \
        -name="devenv-hosts" \
        -description="Agent Sandbox DevEnv Hosts" \
        -scope-id="$PROJECT_ID" \
        -format=json \
        2>/dev/null || echo "{}")

    CATALOG_ID=$(echo "$CATALOG_RESULT" | jq -r '.item.id // empty')
    if [[ -z "$CATALOG_ID" ]]; then
        echo "❌ Failed to create host catalog"
        exit 1
    fi
    echo "✅ Created host catalog: devenv-hosts ($CATALOG_ID)"
fi

echo ""
echo "Step 5: Create Host"
echo "-------------------"

# Check for existing host
HOSTS=$(run_boundary hosts list -host-catalog-id="$CATALOG_ID" -format=json 2>/dev/null || echo '{"items":[]}')
HOST_ID=$(echo "$HOSTS" | jq -r '.items[] | select(.name=="devenv-service") | .id' 2>/dev/null | head -1 || echo "")

if [[ -n "$HOST_ID" ]]; then
    echo "✅ Host exists: devenv-service ($HOST_ID)"
else
    # Create host for devenv service
    HOST_RESULT=$(run_boundary hosts create static \
        -name="devenv-service" \
        -description="DevEnv Kubernetes Service" \
        -address="$DEVENV_SVC_IP" \
        -host-catalog-id="$CATALOG_ID" \
        -format=json \
        2>/dev/null || echo "{}")

    HOST_ID=$(echo "$HOST_RESULT" | jq -r '.item.id // empty')
    if [[ -z "$HOST_ID" ]]; then
        echo "❌ Failed to create host"
        exit 1
    fi
    echo "✅ Created host: devenv-service ($HOST_ID)"
fi

echo ""
echo "Step 6: Create Host Set"
echo "-----------------------"

# Check for existing host set
HOSTSETS=$(run_boundary host-sets list -host-catalog-id="$CATALOG_ID" -format=json 2>/dev/null || echo '{"items":[]}')
HOSTSET_ID=$(echo "$HOSTSETS" | jq -r '.items[] | select(.name=="devenv-set") | .id' 2>/dev/null | head -1 || echo "")

if [[ -n "$HOSTSET_ID" ]]; then
    echo "✅ Host set exists: devenv-set ($HOSTSET_ID)"
else
    # Create host set
    HOSTSET_RESULT=$(run_boundary host-sets create static \
        -name="devenv-set" \
        -description="DevEnv Host Set" \
        -host-catalog-id="$CATALOG_ID" \
        -format=json \
        2>/dev/null || echo "{}")

    HOSTSET_ID=$(echo "$HOSTSET_RESULT" | jq -r '.item.id // empty')
    if [[ -z "$HOSTSET_ID" ]]; then
        echo "❌ Failed to create host set"
        exit 1
    fi
    echo "✅ Created host set: devenv-set ($HOSTSET_ID)"
fi

# Add host to host set (idempotent)
run_boundary host-sets add-hosts \
    -id="$HOSTSET_ID" \
    -host="$HOST_ID" \
    2>/dev/null || true

echo ""
echo "Step 7: Create SSH Target"
echo "-------------------------"

# Check for existing target
TARGETS=$(run_boundary targets list -scope-id="$PROJECT_ID" -format=json 2>/dev/null || echo '{"items":[]}')
TARGET_ID=$(echo "$TARGETS" | jq -r '.items[] | select(.name=="devenv-ssh") | .id' 2>/dev/null | head -1 || echo "")

if [[ -n "$TARGET_ID" ]]; then
    echo "✅ Target exists: devenv-ssh ($TARGET_ID)"
else
    # Create SSH target
    TARGET_RESULT=$(run_boundary targets create tcp \
        -name="devenv-ssh" \
        -description="SSH access to Agent Sandbox DevEnv" \
        -default-port=22 \
        -scope-id="$PROJECT_ID" \
        -format=json \
        2>/dev/null || echo "{}")

    TARGET_ID=$(echo "$TARGET_RESULT" | jq -r '.item.id // empty')
    if [[ -z "$TARGET_ID" ]]; then
        echo "❌ Failed to create target"
        exit 1
    fi
    echo "✅ Created target: devenv-ssh ($TARGET_ID)"
fi

# Add host source to target (idempotent)
run_boundary targets add-host-sources \
    -id="$TARGET_ID" \
    -host-source="$HOSTSET_ID" \
    2>/dev/null || true

echo ""
echo "Step 8: TCP Target Configuration Complete"
echo "-----------------------------------------"
echo ""
echo "ℹ️  TCP target configured without credential injection"
echo "   This allows VSCode Remote SSH and other SSH clients to work properly."
echo ""
echo "   To use with VSCode Remote SSH:"
echo "   1. Create a local TCP tunnel:"
echo "      boundary connect -target-id=$TARGET_ID -listen-port=2222"
echo ""
echo "   2. Configure VSCode Remote SSH with:"
echo "      Host: localhost"
echo "      Port: 2222"
echo "      User: node"
echo "      IdentityFile: ~/.ssh/id_rsa (your SSH key)"
echo ""
echo "   Note: Credential injection has been disabled to support VSCode Remote SSH."
echo "   You must use your own SSH keys configured on the target host."
echo ""

# Note: Credential injection/brokering is disabled for VSCode Remote SSH compatibility
# VSCode Remote SSH manages its own SSH connection and doesn't work with Boundary's
# credential injection. Users should configure their SSH keys on the target host.
VAULT_SSH_CONFIGURED="disabled_for_vscode"

echo ""
echo "Step 9: Create Role for Admin"
echo "------------------------------"

# Check for existing role
ROLES=$(run_boundary roles list -scope-id="$PROJECT_ID" -format=json 2>/dev/null || echo '{"items":[]}')
ROLE_ID=$(echo "$ROLES" | jq -r '.items[] | select(.name=="admin") | .id' 2>/dev/null | head -1 || echo "")

if [[ -n "$ROLE_ID" ]]; then
    echo "✅ Role exists: admin ($ROLE_ID)"
else
    # Create admin role in project scope
    ROLE_RESULT=$(run_boundary roles create \
        -name="admin" \
        -description="Full admin access" \
        -scope-id="$PROJECT_ID" \
        -format=json \
        2>/dev/null || echo "{}")

    ROLE_ID=$(echo "$ROLE_RESULT" | jq -r '.item.id // empty')
    if [[ -n "$ROLE_ID" ]]; then
        # Add grants
        run_boundary roles add-grants \
            -id="$ROLE_ID" \
            -grant="ids=*;type=*;actions=*" \
            2>/dev/null || true
        echo "✅ Created admin role with full access ($ROLE_ID)"
    else
        echo "⚠️  Failed to create admin role"
    fi
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
  Usage (VSCode Remote SSH Compatible)
==========================================

1. Authenticate with Boundary:
   export BOUNDARY_ADDR=https://boundary.local
   export BOUNDARY_TLS_INSECURE=true
   boundary authenticate password \\
     -auth-method-id=$AUTH_METHOD_ID \\
     -login-name=admin \\
     -password='$ADMIN_PASSWORD'

2. Create a TCP tunnel (keep this running):
   boundary connect -target-id=$TARGET_ID -listen-port=2222

3. VSCode Remote SSH Configuration:
   Add to ~/.ssh/config:

   Host devenv-boundary
     HostName localhost
     Port 2222
     User node
     IdentityFile ~/.ssh/id_rsa
     StrictHostKeyChecking no
     UserKnownHostsFile /dev/null

4. Connect via VSCode:
   - Open VSCode
   - Use Remote-SSH: Connect to Host
   - Select "devenv-boundary"

Note: Your SSH key must be authorized on the target host.
      Credential injection is disabled for VSCode compatibility.

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
echo "Quick start (VSCode Remote SSH):"
echo "  1. export BOUNDARY_ADDR=https://boundary.local"
echo "  2. export BOUNDARY_TLS_INSECURE=true"
echo "  3. boundary authenticate password -auth-method-id=$AUTH_METHOD_ID -login-name=admin -password='$ADMIN_PASSWORD'"
echo "  4. boundary connect -target-id=$TARGET_ID -listen-port=2222"
echo "  5. Configure VSCode Remote SSH to connect to localhost:2222 with user 'node'"
echo ""
echo "See $CREDS_FILE for detailed VSCode setup instructions."
echo ""
