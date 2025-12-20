#!/bin/bash
set -euo pipefail

# Configuration
BOUNDARY_NAMESPACE="${1:-boundary}"
TARGET_ID="tssh_RrlYVTBgBN"
PROJECT_SCOPE_ID="p_xYA3s0u7Oa"

echo "=========================================="
echo "  Test Boundary Session Recording"
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

# Verify target has recording enabled
echo "📋 Verifying target configuration..."
TARGET_CONFIG=$(kubectl exec -n "$BOUNDARY_NAMESPACE" "$CONTROLLER_POD" -c boundary-controller -- \
    boundary targets read -id="$TARGET_ID" \
    -recovery-config=/boundary/config/controller.hcl \
    -format=json 2>&1)

RECORDING_ENABLED=$(echo "$TARGET_CONFIG" | jq -r '.item.attributes.enable_session_recording // false')
STORAGE_BUCKET=$(echo "$TARGET_CONFIG" | jq -r '.item.attributes.storage_bucket_id // "none"')
INGRESS_FILTER=$(echo "$TARGET_CONFIG" | jq -r '.item.ingress_worker_filter // "none"')

if [ "$RECORDING_ENABLED" != "true" ]; then
    echo "❌ Session recording not enabled on target"
    echo "   Run: ./configure-session-recording.sh"
    exit 1
fi

if [ "$INGRESS_FILTER" == "none" ] || [ "$INGRESS_FILTER" == "null" ]; then
    echo "❌ Target missing ingress worker filter (REQUIRED for session recording)"
    echo "   This will cause error: 'No ingress workers can handle this session'"
    echo "   Run: ./configure-session-recording.sh"
    exit 1
fi

echo "✅ Target configured for recording"
echo "  Storage Bucket: $STORAGE_BUCKET"
echo "  Ingress Worker Filter: $INGRESS_FILTER"
echo ""

# Check worker status
echo "🔍 Checking Boundary worker status..."
WORKER_STATUS=$(kubectl get pods -n "$BOUNDARY_NAMESPACE" -l app=boundary-worker -o json | jq -r '.items[0].status.phase // "NotFound"')

if [ "$WORKER_STATUS" != "Running" ]; then
    echo "❌ Boundary worker not running: $WORKER_STATUS"
    exit 1
fi

echo "✅ Worker is running"
echo ""

# Check MinIO accessibility from worker
echo "🔍 Testing MinIO accessibility from worker..."
WORKER_POD=$(kubectl get pods -n "$BOUNDARY_NAMESPACE" -l app=boundary-worker -o jsonpath='{.items[0].metadata.name}')
MINIO_TEST=$(kubectl exec -n "$BOUNDARY_NAMESPACE" "$WORKER_POD" -- \
    sh -c "curl -s -o /dev/null -w '%{http_code}' http://minio.minio.svc.cluster.local:9000/minio/health/live" 2>&1 || echo "failed")

if [ "$MINIO_TEST" == "200" ]; then
    echo "✅ Worker can reach MinIO"
else
    echo "⚠️  Worker cannot reach MinIO (HTTP $MINIO_TEST)"
    echo "   This may prevent session recordings from being saved"
fi

echo ""

# Check for existing recordings
echo "📋 Checking for existing session recordings..."
RECORDINGS=$(kubectl exec -n "$BOUNDARY_NAMESPACE" "$CONTROLLER_POD" -c boundary-controller -- \
    boundary session-recordings list \
    -scope-id="$PROJECT_SCOPE_ID" \
    -recovery-config=/boundary/config/controller.hcl \
    -format=json 2>&1 || echo '{"items":[]}')

RECORDING_COUNT=$(echo "$RECORDINGS" | jq -r '.items | length' 2>/dev/null || echo "0")

if [ "$RECORDING_COUNT" == "0" ]; then
    echo "ℹ️  No recordings found yet"
else
    echo "✅ Found $RECORDING_COUNT recording(s)"
    echo ""
    echo "$RECORDINGS" | jq -r '.items[] | "  ID: \(.id)\n  Created: \(.created_time)\n  Duration: \(.duration // "N/A")\n"'
fi

echo ""

# Check MinIO bucket for recordings
echo "📦 Checking MinIO bucket for recordings..."
MINIO_OBJECTS=$(AWS_ACCESS_KEY_ID=boundary-access \
    AWS_SECRET_ACCESS_KEY=boundary-secret-key-change-me \
    aws s3 --endpoint-url=https://minio.hashicorp.lab --no-verify-ssl \
    ls s3://boundary-recordings/ 2>&1 | grep -v "InsecureRequestWarning" | grep -v "warnings.warn" || echo "")

if [ -z "$MINIO_OBJECTS" ]; then
    echo "ℹ️  No objects in MinIO bucket yet"
else
    echo "✅ Objects found in MinIO bucket:"
    echo "$MINIO_OBJECTS" | sed 's/^/  /'
fi

echo ""
echo "=========================================="
echo "  Test Connection Instructions"
echo "=========================================="
echo ""
echo "To test session recording:"
echo ""
echo "1. Ensure you have boundary CLI installed locally:"
echo "   brew install hashicorp/tap/boundary"
echo ""
echo "2. Set Boundary address (from outside cluster):"
echo "   export BOUNDARY_ADDR='https://boundary.hashicorp.lab'"
echo ""
echo "3. Authenticate with Boundary:"
echo "   boundary authenticate password \\"
echo "     -auth-method-id=ampw_xxxx \\"
echo "     -login-name=admin"
echo ""
echo "4. Connect to the target:"
echo "   boundary connect ssh -target-id=$TARGET_ID"
echo ""
echo "5. In the SSH session, run some commands:"
echo "   ls -la"
echo "   pwd"
echo "   echo 'Testing session recording'"
echo "   exit"
echo ""
echo "6. Check for recordings (run this script again):"
echo "   ./test-session-recording.sh"
echo ""
echo "7. Download a recording:"
echo "   boundary session-recordings download \\"
echo "     -id=<recording-id> \\"
echo "     -format=asciicast \\"
echo "     -output=recording.cast"
echo ""
echo "8. Play the recording with asciinema:"
echo "   asciinema play recording.cast"
echo ""
echo "=========================================="
echo ""
