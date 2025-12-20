#!/bin/bash
set -euo pipefail

# Configuration
BOUNDARY_NAMESPACE="${1:-boundary}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Target configuration
TARGET_NAME="claude-ssh-injected"
TARGET_ID="tssh_RrlYVTBgBN"
STORAGE_BUCKET_ID="sb_xRYaMJCMup"

echo "=========================================="
echo "  Enable Session Recording on Target"
echo "=========================================="
echo ""

# Check if boundary namespace exists
if ! kubectl get namespace "$BOUNDARY_NAMESPACE" &> /dev/null; then
    echo "❌ Boundary namespace not found: $BOUNDARY_NAMESPACE"
    exit 1
fi

# Get Boundary controller pod
echo "🔍 Finding Boundary controller pod..."
CONTROLLER_POD=$(kubectl get pods -n "$BOUNDARY_NAMESPACE" -o name 2>/dev/null | grep "boundary-controller" | head -1 | cut -d'/' -f2 || echo "")

if [ -z "$CONTROLLER_POD" ]; then
    echo "❌ No Boundary controller pod found"
    exit 1
fi

echo "✅ Found controller: $CONTROLLER_POD"
echo ""

# Check if already authenticated
echo "🔐 Checking Boundary authentication..."
AUTH_CHECK=$(kubectl exec -n "$BOUNDARY_NAMESPACE" "$CONTROLLER_POD" -c boundary-controller -- \
    boundary scopes list -recovery-config=/boundary/config/controller.hcl -format=json 2>&1 || echo "")

if echo "$AUTH_CHECK" | grep -q "Error"; then
    echo "❌ Not authenticated to Boundary"
    echo "   Please ensure you've run the deployment scripts first"
    exit 1
fi

echo "✅ Authenticated to Boundary"
echo ""

# Get current target configuration
echo "📋 Reading current target configuration..."
TARGET_INFO=$(kubectl exec -n "$BOUNDARY_NAMESPACE" "$CONTROLLER_POD" -c boundary-controller -- \
    boundary targets read -id="$TARGET_ID" \
    -recovery-config=/boundary/config/controller.hcl \
    -format=json 2>&1 || echo "{}")

if echo "$TARGET_INFO" | grep -q "Error"; then
    echo "❌ Failed to read target: $TARGET_ID"
    echo "$TARGET_INFO"
    exit 1
fi

echo "✅ Target found: $TARGET_NAME"
echo ""

# Check current recording status
CURRENT_RECORDING=$(echo "$TARGET_INFO" | jq -r '.item.attributes.enable_session_recording // false' 2>/dev/null || echo "false")
CURRENT_STORAGE_BUCKET=$(echo "$TARGET_INFO" | jq -r '.item.attributes.storage_bucket_id // "none"' 2>/dev/null || echo "none")

echo "Current Configuration:"
echo "  Target ID: $TARGET_ID"
echo "  Target Name: $TARGET_NAME"
echo "  Recording Enabled: $CURRENT_RECORDING"
echo "  Storage Bucket ID: $CURRENT_STORAGE_BUCKET"
echo ""

if [ "$CURRENT_RECORDING" == "true" ] && [ "$CURRENT_STORAGE_BUCKET" == "$STORAGE_BUCKET_ID" ]; then
    echo "✅ Session recording already enabled on this target"
    echo ""

    # Show current configuration
    echo "📊 Current target configuration:"
    kubectl exec -n "$BOUNDARY_NAMESPACE" "$CONTROLLER_POD" -c boundary-controller -- \
        boundary targets read -id="$TARGET_ID" \
        -recovery-config=/boundary/config/controller.hcl \
        -format=json 2>/dev/null | jq -r '
        .item |
        "  ID: \(.id)",
        "  Name: \(.name)",
        "  Type: \(.type)",
        "  Recording Enabled: \(.enable_session_recording)",
        "  Storage Bucket: \(.storage_bucket_id // "none")"
        '

    echo ""
    echo "ℹ️  To disable recording, run:"
    echo "   boundary targets update ssh -id=$TARGET_ID \\"
    echo "     -enable-session-recording=false"
    echo ""

    exit 0
fi

# Enable session recording
echo "🎥 Enabling session recording on target..."
# Note: ingress-worker-filter is REQUIRED for session recording
# It must match the worker that has access to the storage bucket
UPDATE_RESULT=$(kubectl exec -n "$BOUNDARY_NAMESPACE" "$CONTROLLER_POD" -c boundary-controller -- \
    boundary targets update ssh \
    -id="$TARGET_ID" \
    -enable-session-recording=true \
    -storage-bucket-id="$STORAGE_BUCKET_ID" \
    -ingress-worker-filter='"kubernetes-worker" in "/name"' \
    -recovery-config=/boundary/config/controller.hcl \
    -format=json 2>&1 || echo "{}")

# Check if update was successful
if echo "$UPDATE_RESULT" | grep -q "Error"; then
    echo "❌ Failed to enable session recording"
    echo "$UPDATE_RESULT"
    exit 1
fi

echo "✅ Session recording enabled successfully"
echo ""

# Verify the update
echo "✅ Verifying configuration..."
UPDATED_INFO=$(kubectl exec -n "$BOUNDARY_NAMESPACE" "$CONTROLLER_POD" -c boundary-controller -- \
    boundary targets read -id="$TARGET_ID" \
    -recovery-config=/boundary/config/controller.hcl \
    -format=json 2>/dev/null)

echo "$UPDATED_INFO" | jq -r '
.item |
"Target Configuration:",
"  ID: \(.id)",
"  Name: \(.name)",
"  Type: \(.type)",
"  Recording Enabled: \(.attributes.enable_session_recording)",
"  Storage Bucket ID: \(.attributes.storage_bucket_id)",
"  Ingress Worker Filter: \(.ingress_worker_filter)",
"  ",
"Storage Bucket Details:",
"  Name: boundary-session-recordings",
"  Plugin: minio",
"  Bucket: boundary-recordings",
"  Endpoint: http://minio.minio.svc.cluster.local:9000"
'

echo ""
echo "=========================================="
echo "  ✅ Session Recording Enabled"
echo "=========================================="
echo ""
echo "Next Steps:"
echo "  1. Connect to the target via Boundary:"
echo "     boundary connect ssh -target-id=$TARGET_ID"
echo ""
echo "  2. Perform some actions in the SSH session"
echo ""
echo "  3. List session recordings:"
echo "     boundary session-recordings list -scope-id=p_xYA3s0u7Oa"
echo ""
echo "  4. Download a recording:"
echo "     boundary session-recordings download -id=<recording-id> -format=asciicast"
echo ""
echo "Target: $TARGET_NAME ($TARGET_ID)"
echo "Storage Bucket: $STORAGE_BUCKET_ID"
echo ""
