#!/bin/bash
set -euo pipefail

# Grant session recording permissions at org scope
# Session recordings are org-scoped resources, so we need org-scoped permissions

BOUNDARY_NAMESPACE="${1:-boundary}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=========================================="
echo "  Grant Session Recording Permissions"
echo "=========================================="
echo ""

# Get controller pod
CONTROLLER_POD=$(kubectl get pod -l app=boundary-controller -n "$BOUNDARY_NAMESPACE" -o jsonpath='{.items[0].metadata.name}')

# Try to get admin credentials
CREDS_FILE="$SCRIPT_DIR/boundary-credentials.txt"
if [[ -f "$CREDS_FILE" ]]; then
    ADMIN_PASSWORD=$(grep "Password:" "$CREDS_FILE" 2>/dev/null | awk '{print $2}' || echo "")
else
    ADMIN_PASSWORD=""
fi

# Authenticate
if [[ -n "$ADMIN_PASSWORD" ]]; then
    echo "Authenticating with Boundary..."
    AUTH_TOKEN=$(kubectl exec -n "$BOUNDARY_NAMESPACE" "$CONTROLLER_POD" -c boundary-controller -- /bin/ash -c "
        export BOUNDARY_ADDR=http://127.0.0.1:9200
        export BOUNDARY_PASSWORD='$ADMIN_PASSWORD'
        boundary authenticate password -login-name=admin -password=env://BOUNDARY_PASSWORD -format=json
    " 2>/dev/null | jq -r '.item.attributes.token // empty' 2>/dev/null || echo "")

    if [[ -n "$AUTH_TOKEN" ]]; then
        echo "✅ Authenticated successfully"
    else
        echo "⚠️  Token auth failed, falling back to recovery key"
        AUTH_TOKEN=""
    fi
else
    AUTH_TOKEN=""
fi

# Get recovery key as fallback
if [[ -z "$AUTH_TOKEN" ]]; then
    RECOVERY_KEY=$(kubectl get secret boundary-kms-keys -n "$BOUNDARY_NAMESPACE" -o jsonpath='{.data.BOUNDARY_RECOVERY_KEY}' 2>/dev/null | base64 -d || echo "")
    if [[ -z "$RECOVERY_KEY" ]]; then
        echo "❌ Cannot find Boundary recovery key or authenticate"
        exit 1
    fi
    echo "✅ Using recovery key"
fi

# Function to run boundary commands
run_boundary() {
    local cmd="boundary"
    for arg in "$@"; do
        arg="${arg//\'/\'\\\'\'}"
        cmd="$cmd '$arg'"
    done
    if [[ -n "$AUTH_TOKEN" ]]; then
        kubectl exec -n "$BOUNDARY_NAMESPACE" "$CONTROLLER_POD" -c boundary-controller -- \
            /bin/ash -c "export BOUNDARY_ADDR=http://127.0.0.1:9200; export BOUNDARY_TOKEN='$AUTH_TOKEN'; $cmd"
    else
        kubectl exec -n "$BOUNDARY_NAMESPACE" "$CONTROLLER_POD" -c boundary-controller -- \
            /bin/ash -c "
                export BOUNDARY_ADDR=http://127.0.0.1:9200
                echo 'kms \"aead\" { purpose = \"recovery\"; aead_type = \"aes-gcm\"; key = \"$RECOVERY_KEY\"; key_id = \"global_recovery\" }' > /tmp/recovery.hcl
                $cmd -recovery-kms-hcl=file:///tmp/recovery.hcl
            "
    fi
}

# Get organization ID
echo "Looking up organization scope..."
ORG_RESULT=$(run_boundary scopes list -format=json 2>/dev/null || echo "{}")
ORG_ID=$(echo "$ORG_RESULT" | jq -r '.items[]? | select(.name=="DevOps") | .id' 2>/dev/null || echo "")

if [[ -z "$ORG_ID" ]]; then
    echo "❌ DevOps organization not found"
    exit 1
fi
echo "✅ Found organization: DevOps ($ORG_ID)"

# Get OIDC auth method ID
echo "Looking up OIDC auth method..."
AUTH_METHOD_ID=$(run_boundary auth-methods list -scope-id="$ORG_ID" -format=json 2>/dev/null | jq -r '.items[]? | select(.type=="oidc") | .id' 2>/dev/null || echo "")

if [[ -z "$AUTH_METHOD_ID" ]]; then
    echo "❌ OIDC auth method not found"
    exit 1
fi
echo "✅ Found OIDC auth method: $AUTH_METHOD_ID"

# Get managed groups
echo "Looking up managed groups..."
ADMINS_GROUP_ID=$(run_boundary managed-groups list -auth-method-id="$AUTH_METHOD_ID" -format=json 2>/dev/null | jq -r '.items[]? | select(.name=="keycloak-admins") | .id' 2>/dev/null || echo "")
DEVELOPERS_GROUP_ID=$(run_boundary managed-groups list -auth-method-id="$AUTH_METHOD_ID" -format=json 2>/dev/null | jq -r '.items[]? | select(.name=="keycloak-developers") | .id' 2>/dev/null || echo "")
READONLY_GROUP_ID=$(run_boundary managed-groups list -auth-method-id="$AUTH_METHOD_ID" -format=json 2>/dev/null | jq -r '.items[]? | select(.name=="keycloak-readonly") | .id' 2>/dev/null || echo "")

echo "✅ Found managed groups"
echo "  Admins: $ADMINS_GROUP_ID"
echo "  Developers: $DEVELOPERS_GROUP_ID"
echo "  Readonly: $READONLY_GROUP_ID"

echo ""
echo "Creating session recording roles at ORG scope..."

# Function to create or update role
create_or_update_role() {
    local ROLE_NAME=$1
    local ROLE_DESC=$2
    local GRANT_STRING=$3
    local MANAGED_GROUP_ID=$4

    # Check if role exists
    EXISTING_ROLE=$(run_boundary roles list -scope-id="$ORG_ID" -format=json 2>/dev/null | jq -r ".items[]? | select(.name==\"$ROLE_NAME\") | .id" 2>/dev/null || echo "")

    if [[ -n "$EXISTING_ROLE" ]]; then
        echo "  ✅ Role '$ROLE_NAME' already exists ($EXISTING_ROLE)"
        # Update grants
        run_boundary roles set-grants -id="$EXISTING_ROLE" -grant="$GRANT_STRING" 2>/dev/null || true
        echo "    - Updated grants: $GRANT_STRING"
        # Ensure group is principal
        run_boundary roles add-principals -id="$EXISTING_ROLE" -principal="$MANAGED_GROUP_ID" 2>/dev/null || true
        echo "    - Ensured managed group is principal"
    else
        # Create role
        ROLE_RESULT=$(run_boundary roles create \
            -name="$ROLE_NAME" \
            -description="$ROLE_DESC" \
            -scope-id="$ORG_ID" \
            -format=json 2>/dev/null || echo "{}")

        ROLE_ID=$(echo "$ROLE_RESULT" | jq -r '.item.id // empty')
        if [[ -z "$ROLE_ID" ]]; then
            echo "  ⚠️  Failed to create role '$ROLE_NAME'"
            return
        fi
        echo "  ✅ Created role: $ROLE_NAME ($ROLE_ID)"

        # Add grants
        run_boundary roles add-grants -id="$ROLE_ID" -grant="$GRANT_STRING" 2>/dev/null || true
        echo "    - Added grant: $GRANT_STRING"

        # Add managed group as principal
        run_boundary roles add-principals -id="$ROLE_ID" -principal="$MANAGED_GROUP_ID" 2>/dev/null || true
        echo "    - Added managed group as principal"
    fi
}

# Admin: full access to session recordings
if [[ -n "$ADMINS_GROUP_ID" ]]; then
    create_or_update_role \
        "oidc-admins-session-recordings" \
        "OIDC Admins - Session Recording Access" \
        "ids=*;type=session-recording;actions=*" \
        "$ADMINS_GROUP_ID"
fi

# Developers: read-only access to session recordings
if [[ -n "$DEVELOPERS_GROUP_ID" ]]; then
    create_or_update_role \
        "oidc-developers-session-recordings" \
        "OIDC Developers - Session Recording Read Access" \
        "ids=*;type=session-recording;actions=list,read,download" \
        "$DEVELOPERS_GROUP_ID"
fi

# Readonly: read-only access to session recordings
if [[ -n "$READONLY_GROUP_ID" ]]; then
    create_or_update_role \
        "oidc-readonly-session-recordings" \
        "OIDC Readonly - Session Recording Read Access" \
        "ids=*;type=session-recording;actions=list,read" \
        "$READONLY_GROUP_ID"
fi

echo ""
echo "=========================================="
echo "  ✅ Session Recording Permissions Added"
echo "=========================================="
echo ""
echo "All users in the following groups can now access session recordings:"
echo "  - admins: Full access (all operations)"
echo "  - developers: Read access (list, read, download)"
echo "  - readonly: Read access (list, read)"
echo ""
