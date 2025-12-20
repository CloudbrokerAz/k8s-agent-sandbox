#!/bin/bash
set -euo pipefail

# Configuration
BOUNDARY_NAMESPACE="${1:-boundary}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Storage bucket configuration
STORAGE_BUCKET_NAME="boundary-session-recordings"
STORAGE_BUCKET_DESCRIPTION="MinIO S3 storage for Boundary session recordings"
S3_BUCKET_NAME="boundary-recordings"
# Use internal Kubernetes service URL (worker runs inside the cluster)
S3_ENDPOINT="http://minio.minio.svc.cluster.local:9000"
S3_ACCESS_KEY="boundary-access"
S3_SECRET_KEY="boundary-secret-key-change-me"
S3_REGION="us-east-1"  # Required by S3 API, can be any value for S3-compliant storage
BUCKET_PREFIX=""  # Empty prefix - recordings stored at bucket root
WORKER_FILTER='"kubernetes-worker" in "/name"'  # Match Kubernetes worker by name

echo "=========================================="
echo "  Configure Boundary Storage Bucket"
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

# Check if already authenticated (from previous script runs)
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

# Get global scope ID (storage buckets must be created at global scope)
echo "📋 Using global scope for storage bucket..."
GLOBAL_SCOPE="global"

# Verify global scope is accessible
SCOPE_CHECK=$(kubectl exec -n "$BOUNDARY_NAMESPACE" "$CONTROLLER_POD" -c boundary-controller -- \
    boundary scopes read -id="$GLOBAL_SCOPE" -recovery-config=/boundary/config/controller.hcl 2>&1 | grep "ID:" || echo "")

if [ -z "$SCOPE_CHECK" ]; then
    echo "❌ Could not access global scope"
    echo "   Storage buckets must be created at the global scope level"
    exit 1
fi

echo "✅ Global scope verified: $GLOBAL_SCOPE"
echo "   (Storage buckets are global resources)"
echo ""

# Check if storage bucket already exists
echo "🔍 Checking for existing storage bucket..."
LIST_RESULT=$(kubectl exec -n "$BOUNDARY_NAMESPACE" "$CONTROLLER_POD" -c boundary-controller -- \
    boundary storage-buckets list \
    -scope-id="$GLOBAL_SCOPE" \
    -recovery-config=/boundary/config/controller.hcl \
    -format=json 2>&1 || echo "")

# Check if there are any storage buckets
if echo "$LIST_RESULT" | grep -q "No storage buckets found"; then
    EXISTING_BUCKET=""
else
    EXISTING_BUCKET=$(echo "$LIST_RESULT" | jq -r ".items[]? | select(.name == \"$STORAGE_BUCKET_NAME\") | .id" 2>/dev/null || echo "")
fi

if [ -n "$EXISTING_BUCKET" ]; then
    echo "✅ Storage bucket already exists: $EXISTING_BUCKET"
    echo ""

    # Show current configuration
    echo "📊 Current storage bucket configuration:"
    kubectl exec -n "$BOUNDARY_NAMESPACE" "$CONTROLLER_POD" -c boundary-controller -- \
        boundary storage-buckets read \
        -id="$EXISTING_BUCKET" \
        -recovery-config=/boundary/config/controller.hcl \
        -format=json 2>/dev/null | jq -r '
        "  ID: \(.id)",
        "  Name: \(.name)",
        "  Bucket: \(.attributes.bucket_name)",
        "  Endpoint: \(.attributes.endpoint_url // "default")",
        "  Prefix: \(.attributes.bucket_prefix // "none")",
        "  Region: \(.attributes.region)",
        "  Worker Filter: \(.worker_filter)"
        '

    echo ""
    echo "ℹ️  To update the storage bucket, delete it first:"
    echo "   boundary storage-buckets delete -id=$EXISTING_BUCKET"
    echo ""

    STORAGE_BUCKET_ID="$EXISTING_BUCKET"
else
    echo "📦 Creating new storage bucket..."

    # Create storage bucket with S3-compliant configuration
    # Note: Using internal service URL for worker access
    BUCKET_PREFIX_ARG=""
    if [ -n "$BUCKET_PREFIX" ]; then
        BUCKET_PREFIX_ARG="-bucket-prefix=$BUCKET_PREFIX"
    fi

    CREATE_RESULT=$(kubectl exec -n "$BOUNDARY_NAMESPACE" "$CONTROLLER_POD" -c boundary-controller -- \
        boundary storage-buckets create \
        -scope-id="$GLOBAL_SCOPE" \
        -name="$STORAGE_BUCKET_NAME" \
        -description="$STORAGE_BUCKET_DESCRIPTION" \
        -worker-filter="$WORKER_FILTER" \
        -plugin-name="minio" \
        -bucket-name="$S3_BUCKET_NAME" \
        $BUCKET_PREFIX_ARG \
        -attr="region=$S3_REGION" \
        -attr="endpoint_url=$S3_ENDPOINT" \
        -attr="disable_credential_rotation=true" \
        -secret="access_key_id=$S3_ACCESS_KEY" \
        -secret="secret_access_key=$S3_SECRET_KEY" \
        -recovery-config=/boundary/config/controller.hcl \
        -format=json 2>&1 || echo "{}")

    # Check if creation was successful
    if echo "$CREATE_RESULT" | grep -q "Error"; then
        echo "❌ Failed to create storage bucket"
        echo "$CREATE_RESULT"
        exit 1
    fi

    STORAGE_BUCKET_ID=$(echo "$CREATE_RESULT" | jq -r '.item.id // .id // empty' 2>/dev/null || echo "")

    if [ -z "$STORAGE_BUCKET_ID" ]; then
        echo "❌ Failed to parse storage bucket ID"
        echo "$CREATE_RESULT"
        exit 1
    fi

    echo "✅ Storage bucket created: $STORAGE_BUCKET_ID"
    echo ""
fi

# Verify the storage bucket configuration
echo "✅ Verifying storage bucket configuration..."
BUCKET_INFO=$(kubectl exec -n "$BOUNDARY_NAMESPACE" "$CONTROLLER_POD" -c boundary-controller -- \
    boundary storage-buckets read \
    -id="$STORAGE_BUCKET_ID" \
    -recovery-config=/boundary/config/controller.hcl \
    -format=json 2>/dev/null)

echo "$BUCKET_INFO" | jq -r '
"Storage Bucket Details:",
"  ID: \(.id)",
"  Name: \(.name)",
"  Description: \(.description)",
"  Plugin: \(.plugin.name)",
"  ",
"S3 Configuration:",
"  Bucket Name: \(.attributes.bucket_name)",
"  Endpoint URL: \(.attributes.endpoint_url)",
"  Region: \(.attributes.region)",
"  Prefix: \(.attributes.bucket_prefix)",
"  Disable SSL Verify: \(.attributes.disable_ssl_verification)",
"  ",
"Worker Configuration:",
"  Worker Filter: \(.worker_filter)"
'

echo ""

# Test S3 bucket accessibility (optional validation)
echo "🧪 Testing S3 bucket accessibility..."
if command -v aws &> /dev/null; then
    TEST_RESULT=$(AWS_ACCESS_KEY_ID="$S3_ACCESS_KEY" \
        AWS_SECRET_ACCESS_KEY="$S3_SECRET_KEY" \
        aws s3 --endpoint-url="$S3_ENDPOINT" --no-verify-ssl \
        ls "s3://$S3_BUCKET_NAME/" 2>&1 | grep -v "InsecureRequestWarning" || echo "FAILED")

    if echo "$TEST_RESULT" | grep -q "FAILED"; then
        echo "⚠️  Warning: Could not access S3 bucket directly"
        echo "   This may be normal if bucket doesn't exist yet or credentials need time to propagate"
    else
        echo "✅ S3 bucket is accessible"
    fi
else
    echo "ℹ️  AWS CLI not available, skipping direct S3 test"
fi

echo ""

# Save storage bucket ID for other scripts
CREDENTIALS_FILE="$SCRIPT_DIR/../../../boundary-credentials.txt"
if [ -f "$CREDENTIALS_FILE" ]; then
    # Update or add storage bucket ID
    if grep -q "STORAGE_BUCKET_ID=" "$CREDENTIALS_FILE"; then
        sed -i.bak "s/STORAGE_BUCKET_ID=.*/STORAGE_BUCKET_ID=$STORAGE_BUCKET_ID/" "$CREDENTIALS_FILE"
        rm -f "${CREDENTIALS_FILE}.bak"
    else
        echo "STORAGE_BUCKET_ID=$STORAGE_BUCKET_ID" >> "$CREDENTIALS_FILE"
    fi
    echo "✅ Storage bucket ID saved to $CREDENTIALS_FILE"
fi

echo ""
echo "=========================================="
echo "  ✅ Storage Bucket Configured"
echo "=========================================="
echo ""
echo "Next Steps:"
echo "  1. Enable session recording on target:"
echo "     boundary targets update ssh -id=<target-id> \\"
echo "       -enable-session-recording=true \\"
echo "       -storage-bucket-id=$STORAGE_BUCKET_ID"
echo ""
echo "  2. Or run: ./configure-session-recording.sh"
echo ""
echo "Storage Bucket ID: $STORAGE_BUCKET_ID"
echo ""
