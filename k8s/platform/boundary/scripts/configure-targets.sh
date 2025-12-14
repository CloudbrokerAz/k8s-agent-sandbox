#!/usr/bin/env bash
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
# Use field-selector to only match Running pods (avoids race conditions during rollouts)
echo "Checking Boundary controller status..."
CONTROLLER_POD_COUNT=$(kubectl get pod -l app=boundary-controller -n "$BOUNDARY_NAMESPACE" --field-selector=status.phase=Running -o name 2>/dev/null | wc -l | tr -d ' ')
if [[ "$CONTROLLER_POD_COUNT" -eq 0 ]]; then
    # Get actual status for error message
    CONTROLLER_STATUS=$(kubectl get pod -l app=boundary-controller -n "$BOUNDARY_NAMESPACE" -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "NotFound")
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
    AUTH_METHOD_ID=$(grep "Auth Method ID:" "$CREDS_FILE" 2>/dev/null | awk '{print $4}' || echo "")
fi

if [[ -z "$ADMIN_PASSWORD" ]] || [[ -z "$AUTH_METHOD_ID" ]]; then
    echo "❌ Cannot find Boundary admin credentials in $CREDS_FILE"
    echo "   Please ensure boundary-credentials.txt exists and contains valid credentials"
    exit 1
fi
echo "✅ Found admin credentials (Auth Method: $AUTH_METHOD_ID)"

# Discover all SSH-capable services in the devenv namespace
# Support for multiple sandboxes (claude-code-sandbox, gemini-sandbox-ssh, etc.)
declare -a SANDBOX_SERVICES
declare -A SANDBOX_IPS

echo "Discovering sandbox services..."

# Known sandbox service names (in order of priority)
KNOWN_SERVICES=("claude-code-sandbox" "gemini-sandbox-ssh")

for SVC_NAME in "${KNOWN_SERVICES[@]}"; do
    SVC_IP=$(kubectl get svc "$SVC_NAME" -n "$DEVENV_NAMESPACE" -o jsonpath='{.spec.clusterIP}' 2>/dev/null || echo "")
    if [[ -n "$SVC_IP" ]] && [[ "$SVC_IP" != "None" ]]; then
        SANDBOX_SERVICES+=("$SVC_NAME")
        SANDBOX_IPS["$SVC_NAME"]="$SVC_IP"
        echo "✅ Found service: $SVC_NAME ($SVC_IP)"
    fi
done

# Also discover any other SSH-capable services
OTHER_SERVICES=$(kubectl get svc -n "$DEVENV_NAMESPACE" -o json 2>/dev/null | jq -r '.items[] | select(.spec.ports[]?.port == 22) | select(.spec.clusterIP != "None") | .metadata.name' || echo "")
for SVC_NAME in $OTHER_SERVICES; do
    # Skip if already in known services
    if [[ " ${SANDBOX_SERVICES[*]} " =~ " ${SVC_NAME} " ]]; then
        continue
    fi
    SVC_IP=$(kubectl get svc "$SVC_NAME" -n "$DEVENV_NAMESPACE" -o jsonpath='{.spec.clusterIP}' 2>/dev/null || echo "")
    if [[ -n "$SVC_IP" ]] && [[ "$SVC_IP" != "None" ]]; then
        SANDBOX_SERVICES+=("$SVC_NAME")
        SANDBOX_IPS["$SVC_NAME"]="$SVC_IP"
        echo "✅ Found service: $SVC_NAME ($SVC_IP)"
    fi
done

if [[ ${#SANDBOX_SERVICES[@]} -eq 0 ]]; then
    echo "⚠️  No SSH services found in $DEVENV_NAMESPACE namespace"
    echo "   Using DNS placeholder for claude-code-sandbox"
    SANDBOX_SERVICES=("claude-code-sandbox")
    SANDBOX_IPS["claude-code-sandbox"]="claude-code-sandbox.$DEVENV_NAMESPACE.svc.cluster.local"
fi

echo ""
echo "Found ${#SANDBOX_SERVICES[@]} sandbox service(s)"

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
echo "Step 5: Create Hosts for Each Sandbox"
echo "--------------------------------------"

# Get existing hosts
HOSTS=$(run_boundary hosts list -host-catalog-id="$CATALOG_ID" -format=json 2>/dev/null || echo '{"items":[]}')

# Create/update hosts for each discovered sandbox
declare -A HOST_IDS
for SVC_NAME in "${SANDBOX_SERVICES[@]}"; do
    HOST_NAME="${SVC_NAME}"
    SVC_IP="${SANDBOX_IPS[$SVC_NAME]}"

    HOST_ID=$(echo "$HOSTS" | jq -r ".items[] | select(.name==\"$HOST_NAME\") | .id" 2>/dev/null | head -1 || echo "")

    if [[ -n "$HOST_ID" ]]; then
        echo "✅ Host exists: $HOST_NAME ($HOST_ID)"
    else
        # Create host for sandbox service
        HOST_RESULT=$(run_boundary hosts create static \
            -name="$HOST_NAME" \
            -description="$HOST_NAME Kubernetes Service" \
            -address="$SVC_IP" \
            -host-catalog-id="$CATALOG_ID" \
            -format=json \
            2>/dev/null || echo "{}")

        HOST_ID=$(echo "$HOST_RESULT" | jq -r '.item.id // empty')
        if [[ -z "$HOST_ID" ]]; then
            echo "⚠️  Failed to create host: $HOST_NAME"
            continue
        fi
        echo "✅ Created host: $HOST_NAME ($HOST_ID)"
    fi
    HOST_IDS["$SVC_NAME"]="$HOST_ID"
done

echo ""
echo "Step 6: Create Host Sets and Targets for Each Sandbox"
echo "------------------------------------------------------"

# Get existing host sets and targets
HOSTSETS=$(run_boundary host-sets list -host-catalog-id="$CATALOG_ID" -format=json 2>/dev/null || echo '{"items":[]}')
TARGETS=$(run_boundary targets list -scope-id="$PROJECT_ID" -format=json 2>/dev/null || echo '{"items":[]}')

declare -A TARGET_IDS
for SVC_NAME in "${SANDBOX_SERVICES[@]}"; do
    HOST_ID="${HOST_IDS[$SVC_NAME]}"
    if [[ -z "$HOST_ID" ]]; then
        continue
    fi

    # Derive names - convert service name to target name
    # e.g., claude-code-sandbox -> claude-ssh, gemini-sandbox-ssh -> gemini-ssh
    if [[ "$SVC_NAME" == "claude-code-sandbox" ]]; then
        TARGET_NAME="claude-ssh"
        HOSTSET_NAME="claude-set"
    elif [[ "$SVC_NAME" == "gemini-sandbox-ssh" ]]; then
        TARGET_NAME="gemini-ssh"
        HOSTSET_NAME="gemini-set"
    else
        # Generic naming
        TARGET_NAME="${SVC_NAME%-sandbox}-ssh"
        TARGET_NAME="${TARGET_NAME%-ssh-ssh}-ssh"  # Avoid double -ssh
        HOSTSET_NAME="${SVC_NAME%-sandbox}-set"
    fi

    # Create or get host set
    HOSTSET_ID=$(echo "$HOSTSETS" | jq -r ".items[] | select(.name==\"$HOSTSET_NAME\") | .id" 2>/dev/null | head -1 || echo "")
    if [[ -z "$HOSTSET_ID" ]]; then
        HOSTSET_RESULT=$(run_boundary host-sets create static \
            -name="$HOSTSET_NAME" \
            -description="$SVC_NAME Host Set" \
            -host-catalog-id="$CATALOG_ID" \
            -format=json \
            2>/dev/null || echo "{}")
        HOSTSET_ID=$(echo "$HOSTSET_RESULT" | jq -r '.item.id // empty')
        if [[ -n "$HOSTSET_ID" ]]; then
            echo "✅ Created host set: $HOSTSET_NAME ($HOSTSET_ID)"
        fi
    else
        echo "✅ Host set exists: $HOSTSET_NAME ($HOSTSET_ID)"
    fi

    # Add host to host set (idempotent)
    if [[ -n "$HOSTSET_ID" ]]; then
        run_boundary host-sets add-hosts -id="$HOSTSET_ID" -host="$HOST_ID" 2>/dev/null || true
    fi

    # Create or get target
    TARGET_ID=$(echo "$TARGETS" | jq -r ".items[] | select(.name==\"$TARGET_NAME\") | .id" 2>/dev/null | head -1 || echo "")
    if [[ -z "$TARGET_ID" ]]; then
        TARGET_RESULT=$(run_boundary targets create tcp \
            -name="$TARGET_NAME" \
            -description="SSH access to $SVC_NAME" \
            -default-port=22 \
            -scope-id="$PROJECT_ID" \
            -format=json \
            2>/dev/null || echo "{}")
        TARGET_ID=$(echo "$TARGET_RESULT" | jq -r '.item.id // empty')
        if [[ -n "$TARGET_ID" ]]; then
            echo "✅ Created target: $TARGET_NAME ($TARGET_ID)"
        fi
    else
        echo "✅ Target exists: $TARGET_NAME ($TARGET_ID)"
    fi

    # Add host source to target (idempotent)
    if [[ -n "$TARGET_ID" ]] && [[ -n "$HOSTSET_ID" ]]; then
        run_boundary targets add-host-sources -id="$TARGET_ID" -host-source="$HOSTSET_ID" 2>/dev/null || true
    fi

    TARGET_IDS["$SVC_NAME"]="$TARGET_ID"
done

# For backward compatibility, also create the legacy devenv-ssh target
# pointing to claude-code-sandbox if it exists
echo ""
echo "Step 7: Legacy devenv-ssh Target (backward compatibility)"
echo "---------------------------------------------------------"

DEVENV_TARGET_ID=$(echo "$TARGETS" | jq -r '.items[] | select(.name=="devenv-ssh") | .id' 2>/dev/null | head -1 || echo "")
CLAUDE_HOSTSET_ID=$(echo "$HOSTSETS" | jq -r '.items[] | select(.name=="claude-set") | .id' 2>/dev/null | head -1 || echo "")

if [[ -n "$DEVENV_TARGET_ID" ]]; then
    echo "✅ Target exists: devenv-ssh ($DEVENV_TARGET_ID) - legacy target for claude-code-sandbox"
    TARGET_ID="$DEVENV_TARGET_ID"
elif [[ -n "$CLAUDE_HOSTSET_ID" ]]; then
    TARGET_RESULT=$(run_boundary targets create tcp \
        -name="devenv-ssh" \
        -description="SSH access to Agent Sandbox DevEnv (legacy - use claude-ssh)" \
        -default-port=22 \
        -scope-id="$PROJECT_ID" \
        -format=json \
        2>/dev/null || echo "{}")
    TARGET_ID=$(echo "$TARGET_RESULT" | jq -r '.item.id // empty')
    if [[ -n "$TARGET_ID" ]]; then
        run_boundary targets add-host-sources -id="$TARGET_ID" -host-source="$CLAUDE_HOSTSET_ID" 2>/dev/null || true
        echo "✅ Created legacy target: devenv-ssh ($TARGET_ID)"
    fi
else
    echo "⚠️  Skipping legacy devenv-ssh target (no claude-set found)"
    TARGET_ID=""
fi

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

# Build targets list for credentials file
TARGETS_LIST=""
for SVC_NAME in "${SANDBOX_SERVICES[@]}"; do
    TGT_ID="${TARGET_IDS[$SVC_NAME]:-}"
    if [[ -n "$TGT_ID" ]]; then
        if [[ "$SVC_NAME" == "claude-code-sandbox" ]]; then
            TARGETS_LIST+="  claude-ssh:        $TGT_ID\n"
        elif [[ "$SVC_NAME" == "gemini-sandbox-ssh" ]]; then
            TARGETS_LIST+="  gemini-ssh:        $TGT_ID\n"
        else
            TARGETS_LIST+="  ${SVC_NAME}:       $TGT_ID\n"
        fi
    fi
done
if [[ -n "$TARGET_ID" ]]; then
    TARGETS_LIST+="  devenv-ssh:        $TARGET_ID (legacy)\n"
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

Targets:
$(echo -e "$TARGETS_LIST")

==========================================
  Usage (Port-Forward + Vault SSH CA)
==========================================

1. Start port-forward for Boundary worker:
   kubectl port-forward -n boundary svc/boundary-worker 9202:9202 &

2. Generate and sign SSH key with Vault:
   ssh-keygen -t ed25519 -f /tmp/ssh-key -N ""
   vault write -field=signed_key ssh/sign/devenv-access \\
     public_key=@/tmp/ssh-key.pub \\
     valid_principals=node > /tmp/ssh-key-cert.pub

3. Connect to sandbox via Boundary:

   # Claude Code Sandbox:
   export BOUNDARY_ADDR=https://boundary.local
   export BOUNDARY_TLS_INSECURE=true
   boundary connect -target-id=${TARGET_IDS["claude-code-sandbox"]:-$TARGET_ID} -exec ssh -- \\
     -i /tmp/ssh-key \\
     -o CertificateFile=/tmp/ssh-key-cert.pub \\
     -o StrictHostKeyChecking=no \\
     -l node -p '{{boundary.port}}' '{{boundary.ip}}' 'hostname'

   # Gemini Sandbox:
   boundary connect -target-id=${TARGET_IDS["gemini-sandbox-ssh"]:-not_configured} -exec ssh -- \\
     -i /tmp/ssh-key \\
     -o CertificateFile=/tmp/ssh-key-cert.pub \\
     -o StrictHostKeyChecking=no \\
     -l node -p '{{boundary.port}}' '{{boundary.ip}}' 'hostname'

Note: SSH authentication uses Vault-signed certificates.
      No password required - certificates are trusted by the sandbox sshd.

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
echo "Configured targets:"
for SVC_NAME in "${SANDBOX_SERVICES[@]}"; do
    TGT_ID="${TARGET_IDS[$SVC_NAME]:-}"
    if [[ -n "$TGT_ID" ]]; then
        if [[ "$SVC_NAME" == "claude-code-sandbox" ]]; then
            echo "  - claude-ssh:  $TGT_ID"
        elif [[ "$SVC_NAME" == "gemini-sandbox-ssh" ]]; then
            echo "  - gemini-ssh:  $TGT_ID"
        else
            echo "  - $SVC_NAME:   $TGT_ID"
        fi
    fi
done
if [[ -n "$TARGET_ID" ]]; then
    echo "  - devenv-ssh:  $TARGET_ID (legacy)"
fi
echo ""
echo "Quick start (Port-Forward + Vault SSH CA):"
echo "  1. kubectl port-forward -n boundary svc/boundary-worker 9202:9202 &"
echo "  2. vault write -field=signed_key ssh/sign/devenv-access public_key=@~/.ssh/id_ed25519.pub valid_principals=node > /tmp/cert.pub"
echo "  3. export BOUNDARY_ADDR=https://boundary.local BOUNDARY_TLS_INSECURE=true"
echo "  4. boundary connect -target-id=<TARGET_ID> -exec ssh -- -i ~/.ssh/id_ed25519 -o CertificateFile=/tmp/cert.pub -l node -p '{{boundary.port}}' '{{boundary.ip}}'"
echo ""
echo "See $CREDS_FILE for detailed instructions."
echo ""
