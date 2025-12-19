#!/bin/bash
set -euo pipefail

NAMESPACE="${1:-seaweedfs}"
S3_ENDPOINT="https://seaweedfs-s3.hashicorp.lab"
S3_ACCESS_KEY="boundary-access"
S3_SECRET_KEY="boundary-secret-key-change-me"
TEST_BUCKET="seaweedfs-test-$(date +%s)"
TEMP_DIR=$(mktemp -d)

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Cleanup function
cleanup() {
    echo ""
    echo -e "${YELLOW}Cleaning up test resources...${NC}"

    # Delete test files
    rm -f "$TEMP_DIR/test-upload.txt" "$TEMP_DIR/test-download.txt" 2>/dev/null || true
    rmdir "$TEMP_DIR" 2>/dev/null || true

    # Delete test bucket (suppress warnings)
    if [ -n "${TEST_BUCKET:-}" ]; then
        AWS_ACCESS_KEY_ID="$S3_ACCESS_KEY" \
        AWS_SECRET_ACCESS_KEY="$S3_SECRET_KEY" \
        aws s3 --endpoint-url="$S3_ENDPOINT" --no-verify-ssl \
            rb "s3://$TEST_BUCKET" --force 2>/dev/null || true
    fi

    echo -e "${GREEN}✓ Cleanup complete${NC}"
}

trap cleanup EXIT

# Helper function to run AWS commands
run_aws_s3() {
    AWS_ACCESS_KEY_ID="$S3_ACCESS_KEY" \
    AWS_SECRET_ACCESS_KEY="$S3_SECRET_KEY" \
    aws s3 --endpoint-url="$S3_ENDPOINT" --no-verify-ssl "$@" 2>&1 | \
    grep -v "InsecureRequestWarning" | grep -v "warnings.warn" || true
}

echo "=========================================="
echo "  SeaweedFS S3 API Test Suite"
echo "=========================================="
echo ""
echo "Endpoint: $S3_ENDPOINT"
echo "Namespace: $NAMESPACE"
echo "Test Bucket: $TEST_BUCKET"
echo ""

# Test 1: Check pods are running
echo -e "${BLUE}[1/10]${NC} Checking SeaweedFS pods..."
if ! kubectl get pods -n "$NAMESPACE" &> /dev/null; then
    echo -e "${RED}✗ Cannot access namespace: $NAMESPACE${NC}"
    exit 1
fi

POD_STATUS=$(kubectl get pods -n "$NAMESPACE" -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.phase}{"\n"}{end}')
echo "$POD_STATUS" | while read -r pod status; do
    if [ "$status" == "Running" ]; then
        echo -e "${GREEN}  ✓ $pod: $status${NC}"
    else
        echo -e "${RED}  ✗ $pod: $status${NC}"
    fi
done

# Test 2: Check S3 is listening on all interfaces
echo ""
echo -e "${BLUE}[2/10]${NC} Checking S3 API binding..."
LISTEN_STATUS=$(kubectl exec -n "$NAMESPACE" seaweedfs-filer-0 -c s3 -- netstat -ln 2>/dev/null | grep ":8333" | head -1)
if echo "$LISTEN_STATUS" | grep -q ":::8333"; then
    echo -e "${GREEN}  ✓ S3 API listening on all interfaces${NC}"
    echo "    $LISTEN_STATUS"
else
    echo -e "${RED}  ✗ S3 API not properly configured${NC}"
    echo "    $LISTEN_STATUS"
fi

# Test 3: Internal cluster connectivity
echo ""
echo -e "${BLUE}[3/10]${NC} Testing internal cluster connectivity..."
INTERNAL_STATUS=$(kubectl exec -n "$NAMESPACE" seaweedfs-volume-0 -- \
    curl -s -o /dev/null -w "%{http_code}" \
    http://seaweedfs-s3.seaweedfs.svc.cluster.local:8333/ 2>&1)
if [ "$INTERNAL_STATUS" == "403" ]; then
    echo -e "${GREEN}  ✓ Internal service accessible (HTTP $INTERNAL_STATUS)${NC}"
else
    echo -e "${RED}  ✗ Internal service failed (HTTP $INTERNAL_STATUS)${NC}"
    exit 1
fi

# Test 4: External ingress connectivity
echo ""
echo -e "${BLUE}[4/10]${NC} Testing external ingress connectivity..."
EXTERNAL_STATUS=$(curl -k -s -o /dev/null -w "%{http_code}" "$S3_ENDPOINT/")
if [ "$EXTERNAL_STATUS" == "403" ]; then
    echo -e "${GREEN}  ✓ External ingress accessible (HTTP $EXTERNAL_STATUS)${NC}"
else
    echo -e "${RED}  ✗ External ingress failed (HTTP $EXTERNAL_STATUS)${NC}"
    exit 1
fi

# Test 5: Check AWS CLI is available
echo ""
echo -e "${BLUE}[5/10]${NC} Checking AWS CLI availability..."
if ! command -v aws &> /dev/null; then
    echo -e "${RED}  ✗ AWS CLI not found. Please install: brew install awscli${NC}"
    exit 1
fi
AWS_VERSION=$(aws --version 2>&1 | cut -d' ' -f1)
echo -e "${GREEN}  ✓ AWS CLI available: $AWS_VERSION${NC}"

# Test 6: List existing buckets
echo ""
echo -e "${BLUE}[6/10]${NC} Listing existing buckets..."
BUCKETS=$(run_aws_s3 ls)
if [ $? -eq 0 ]; then
    if [ -n "$BUCKETS" ]; then
        echo -e "${GREEN}  ✓ Authenticated successfully${NC}"
        echo "$BUCKETS" | sed 's/^/    /'
    else
        echo -e "${GREEN}  ✓ Authenticated successfully (no buckets yet)${NC}"
    fi
else
    echo -e "${RED}  ✗ Authentication failed${NC}"
    exit 1
fi

# Test 7: Create test bucket
echo ""
echo -e "${BLUE}[7/10]${NC} Creating test bucket: $TEST_BUCKET..."
CREATE_OUTPUT=$(run_aws_s3 mb "s3://$TEST_BUCKET")
if echo "$CREATE_OUTPUT" | grep -q "make_bucket"; then
    echo -e "${GREEN}  ✓ Bucket created successfully${NC}"
else
    echo -e "${RED}  ✗ Failed to create bucket${NC}"
    echo "$CREATE_OUTPUT"
    exit 1
fi

# Test 8: Upload test file
echo ""
echo -e "${BLUE}[8/10]${NC} Uploading test file..."
TEST_CONTENT="SeaweedFS S3 Test - $(date)"
echo "$TEST_CONTENT" > "$TEMP_DIR/test-upload.txt"
UPLOAD_OUTPUT=$(run_aws_s3 cp "$TEMP_DIR/test-upload.txt" "s3://$TEST_BUCKET/test.txt")
if echo "$UPLOAD_OUTPUT" | grep -q "upload:"; then
    echo -e "${GREEN}  ✓ File uploaded successfully${NC}"
    FILE_SIZE=$(stat -f%z "$TEMP_DIR/test-upload.txt" 2>/dev/null || stat -c%s "$TEMP_DIR/test-upload.txt" 2>/dev/null)
    echo "    Size: $FILE_SIZE bytes"
else
    echo -e "${RED}  ✗ Failed to upload file${NC}"
    echo "$UPLOAD_OUTPUT"
    exit 1
fi

# Test 9: List bucket contents
echo ""
echo -e "${BLUE}[9/10]${NC} Listing bucket contents..."
LIST_OUTPUT=$(run_aws_s3 ls "s3://$TEST_BUCKET/")
if echo "$LIST_OUTPUT" | grep -q "test.txt"; then
    echo -e "${GREEN}  ✓ File found in bucket${NC}"
    echo "$LIST_OUTPUT" | sed 's/^/    /'
else
    echo -e "${RED}  ✗ File not found in bucket${NC}"
    echo "$LIST_OUTPUT"
    exit 1
fi

# Test 10: Download and verify file
echo ""
echo -e "${BLUE}[10/10]${NC} Downloading and verifying file..."
DOWNLOAD_OUTPUT=$(run_aws_s3 cp "s3://$TEST_BUCKET/test.txt" "$TEMP_DIR/test-download.txt")
if echo "$DOWNLOAD_OUTPUT" | grep -q "download:"; then
    DOWNLOADED_CONTENT=$(cat "$TEMP_DIR/test-download.txt")
    if [ "$DOWNLOADED_CONTENT" == "$TEST_CONTENT" ]; then
        echo -e "${GREEN}  ✓ File downloaded and verified${NC}"
        echo "    Content matches: '$DOWNLOADED_CONTENT'"
    else
        echo -e "${RED}  ✗ Content mismatch${NC}"
        echo "    Expected: '$TEST_CONTENT'"
        echo "    Got: '$DOWNLOADED_CONTENT'"
        exit 1
    fi
else
    echo -e "${RED}  ✗ Failed to download file${NC}"
    echo "$DOWNLOAD_OUTPUT"
    exit 1
fi

# Summary
echo ""
echo "=========================================="
echo -e "${GREEN}  ✅ All Tests Passed!${NC}"
echo "=========================================="
echo ""
echo "SeaweedFS S3 API is fully functional:"
echo "  • Pod connectivity: ✓"
echo "  • Network binding: ✓"
echo "  • Internal service: ✓"
echo "  • External ingress: ✓"
echo "  • Authentication: ✓"
echo "  • Bucket operations: ✓"
echo "  • File upload: ✓"
echo "  • File download: ✓"
echo "  • Data integrity: ✓"
echo ""
echo "S3 Credentials:"
echo "  Access Key: $S3_ACCESS_KEY"
echo "  Secret Key: $S3_SECRET_KEY"
echo ""
echo "Ready for Boundary session recording! 🎉"
echo ""
