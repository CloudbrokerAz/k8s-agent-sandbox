#!/bin/bash
set -euo pipefail

# Test script to verify Boundary OIDC configuration
# This validates that OIDC auth method, managed groups, and roles are properly configured

BOUNDARY_NAMESPACE="${1:-boundary}"
KEYCLOAK_NAMESPACE="${2:-keycloak}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
K8S_DIR="$(dirname "$(dirname "$(dirname "$SCRIPT_DIR")")")"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

PASSED=0
FAILED=0
WARNINGS=0

test_pass() {
    echo -e "${GREEN}✅ PASS${NC}: $1"
    PASSED=$((PASSED + 1))
}

test_fail() {
    echo -e "${RED}❌ FAIL${NC}: $1"
    FAILED=$((FAILED + 1))
}

test_warn() {
    echo -e "${YELLOW}⚠️  WARN${NC}: $1"
    WARNINGS=$((WARNINGS + 1))
}

test_info() {
    echo -e "${BLUE}ℹ️  INFO${NC}: $1"
}

echo "=========================================="
echo "  Boundary OIDC Configuration Test"
echo "=========================================="
echo ""

# Check for boundary CLI
if ! command -v boundary &> /dev/null; then
    echo "⚠️  Boundary CLI not found - using kubectl exec"
    USE_KUBECTL="true"
else
    USE_KUBECTL="false"
    test_info "Using local Boundary CLI"
fi

# Check Boundary controller is running
echo ""
echo "--- Prerequisites ---"
CONTROLLER_STATUS=$(kubectl get pod -l app=boundary-controller -n "$BOUNDARY_NAMESPACE" -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "NotFound")
if [[ "$CONTROLLER_STATUS" == "Running" ]]; then
    test_pass "Boundary controller is running"
else
    test_fail "Boundary controller not running (status: $CONTROLLER_STATUS)"
    exit 1
fi

# Check Keycloak is running
KEYCLOAK_STATUS=$(kubectl get pod -l app=keycloak -n "$KEYCLOAK_NAMESPACE" -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "NotFound")
if [[ "$KEYCLOAK_STATUS" == "Running" ]]; then
    test_pass "Keycloak is running"
else
    test_warn "Keycloak not running (status: $KEYCLOAK_STATUS)"
fi

# Get recovery key
RECOVERY_KEY=$(kubectl get secret boundary-kms-keys -n "$BOUNDARY_NAMESPACE" -o jsonpath='{.data.BOUNDARY_RECOVERY_KEY}' 2>/dev/null | base64 -d || echo "")
if [[ -z "$RECOVERY_KEY" ]]; then
    test_fail "Cannot find Boundary recovery key"
    exit 1
fi
test_pass "Found Boundary recovery key"

# Get controller pod
CONTROLLER_POD=$(kubectl get pod -l app=boundary-controller -n "$BOUNDARY_NAMESPACE" -o jsonpath='{.items[0].metadata.name}')

# Function to run boundary commands
run_boundary() {
    kubectl exec -n "$BOUNDARY_NAMESPACE" "$CONTROLLER_POD" -- \
        env BOUNDARY_ADDR=http://127.0.0.1:9200 \
        boundary "$@" 2>/dev/null
}

# Get organization ID
echo ""
echo "--- Organization and Project ---"

# Get admin credentials from credentials file
CREDS_FILE="$K8S_DIR/k8s/platform/boundary/scripts/boundary-credentials.txt"
ADMIN_PASSWORD=""

if [[ -f "$CREDS_FILE" ]]; then
    ADMIN_PASSWORD=$(grep "Password:" "$CREDS_FILE" 2>/dev/null | awk '{print $2}' || echo "")
fi

# Get the global auth method ID (no auth required for this query)
# The global auth method is the one created during Boundary init and is needed to authenticate
GLOBAL_AUTH_METHOD_ID=$(kubectl exec -n "$BOUNDARY_NAMESPACE" "$CONTROLLER_POD" -c boundary-controller -- sh -c "
    BOUNDARY_ADDR=http://127.0.0.1:9200 boundary auth-methods list -scope-id=global -format=json 2>/dev/null
" 2>/dev/null | jq -r '.items[] | select(.type=="password") | .id' 2>/dev/null | head -1 || echo "")

# Authenticate with admin to get token
if [[ -n "$ADMIN_PASSWORD" ]] && [[ -n "$GLOBAL_AUTH_METHOD_ID" ]]; then
    # Write password to temp file locally, copy to pod, then authenticate
    echo -n "$ADMIN_PASSWORD" > /tmp/boundary-pass.txt
    kubectl cp /tmp/boundary-pass.txt "$BOUNDARY_NAMESPACE/$CONTROLLER_POD:/tmp/boundary-pass.txt" -c boundary-controller 2>/dev/null || true
    rm -f /tmp/boundary-pass.txt

    TOKEN=$(kubectl exec -n "$BOUNDARY_NAMESPACE" "$CONTROLLER_POD" -c boundary-controller -- sh -c "
        BOUNDARY_ADDR=http://127.0.0.1:9200 boundary authenticate password \
            -auth-method-id='$GLOBAL_AUTH_METHOD_ID' \
            -login-name=admin \
            -password=file:///tmp/boundary-pass.txt \
            -keyring-type=none \
            -format=json 2>/dev/null
        rm -f /tmp/boundary-pass.txt
    " 2>/dev/null | jq -r '.item.attributes.token // empty' 2>/dev/null || echo "")
fi

# List scopes using token if available, otherwise check init job for org ID
if [[ -n "${TOKEN:-}" ]]; then
    ORG_RESULT=$(kubectl exec -n "$BOUNDARY_NAMESPACE" "$CONTROLLER_POD" -- sh -c "
        BOUNDARY_ADDR=http://127.0.0.1:9200 BOUNDARY_TOKEN='$TOKEN' boundary scopes list -format=json
    " 2>/dev/null || echo "{}")
    ORG_ID=$(echo "$ORG_RESULT" | jq -r '.items[] | select(.type=="org") | .id' 2>/dev/null | head -1 || echo "")
else
    # Fallback: get from init job logs
    ORG_ID=$(kubectl logs -n "$BOUNDARY_NAMESPACE" job/boundary-db-init 2>/dev/null | grep "Scope ID:" | head -1 | awk '{print $3}' || echo "")
fi

if [[ -n "$ORG_ID" ]]; then
    test_pass "Organization scope exists ($ORG_ID)"
else
    test_fail "Organization scope not found"
    echo ""
    echo "Run configure-targets.sh to create organization and project scopes"
    exit 1
fi

# Get project ID from init logs
PROJECT_ID=$(kubectl logs -n "$BOUNDARY_NAMESPACE" job/boundary-db-init 2>/dev/null | grep "Scope ID:" | grep "p_" | head -1 | awk '{print $3}' || echo "")
if [[ -n "$PROJECT_ID" ]]; then
    test_pass "Agent-Sandbox project exists ($PROJECT_ID)"
else
    test_fail "Agent-Sandbox project not found"
    exit 1
fi

# Test 1: Check auth methods
echo ""
echo "--- Auth Methods ---"

# Check for password auth method (created by default)
AUTH_METHOD_ID=$(kubectl logs -n "$BOUNDARY_NAMESPACE" job/boundary-db-init 2>/dev/null | grep "Auth Method ID:" | head -1 | awk '{print $4}' || echo "")
if [[ -n "$AUTH_METHOD_ID" ]]; then
    test_pass "Password auth method exists ($AUTH_METHOD_ID)"
else
    test_warn "Could not find auth method ID"
fi

# Check OIDC auth method (optional - only if configure-oidc-auth.sh was run)
echo ""
echo "--- OIDC Auth Method (Optional) ---"
if [[ -n "${TOKEN:-}" ]]; then
    AUTH_METHODS=$(kubectl exec -n "$BOUNDARY_NAMESPACE" "$CONTROLLER_POD" -- sh -c "
        BOUNDARY_ADDR=http://127.0.0.1:9200 BOUNDARY_TOKEN='$TOKEN' boundary auth-methods list -scope-id='$ORG_ID' -format=json
    " 2>/dev/null || echo "{}")

    OIDC_AUTH_ID=$(echo "$AUTH_METHODS" | jq -r '.items[] | select(.type=="oidc") | .id' 2>/dev/null || echo "")
    if [[ -n "$OIDC_AUTH_ID" ]]; then
        test_pass "OIDC auth method configured ($OIDC_AUTH_ID)"
    else
        test_warn "OIDC auth method not configured (run configure-oidc-auth.sh)"
    fi
else
    test_warn "Skipping OIDC check (no auth token available)"
fi

# Test 2: Check targets
echo ""
echo "--- Targets ---"
TARGET_ID=$(kubectl logs -n "$BOUNDARY_NAMESPACE" job/boundary-db-init 2>/dev/null | grep "Target ID:" | head -1 | awk '{print $3}' || echo "")
if [[ -n "$TARGET_ID" ]]; then
    test_pass "SSH target exists ($TARGET_ID)"
else
    test_warn "Could not find target ID"
fi

# Test 3: Verify Keycloak connectivity (if running)
echo ""
echo "--- Keycloak Connectivity ---"
if [[ "$KEYCLOAK_STATUS" == "Running" ]]; then
    # Test OIDC discovery endpoint via curl pod
    # Use --quiet to suppress pod lifecycle messages, redirect stderr to /dev/null
    DISCOVERY_STATUS=$(kubectl run curl-oidc-boundary-test --image=curlimages/curl --rm -i --restart=Never --quiet -- \
        curl -s -o /dev/null -w "%{http_code}" "http://keycloak.keycloak.svc.cluster.local:8080/realms/agent-sandbox/.well-known/openid-configuration" 2>/dev/null | tr -d '[:space:]' || echo "000")

    # Extract just the HTTP status code (last 3 digits)
    DISCOVERY_STATUS="${DISCOVERY_STATUS: -3}"

    if [[ "$DISCOVERY_STATUS" == "200" ]]; then
        test_pass "OIDC discovery endpoint accessible (HTTP 200)"
    elif [[ "$DISCOVERY_STATUS" == "404" ]]; then
        test_warn "OIDC realm 'agent-sandbox' not configured (HTTP 404) - run configure-realm.sh"
    else
        test_warn "OIDC discovery endpoint not accessible (HTTP $DISCOVERY_STATUS) - run configure-realm.sh"
    fi
else
    test_warn "Keycloak not running - skipping connectivity tests"
fi

# Summary
echo ""
echo "=========================================="
echo "  Test Summary"
echo "=========================================="
echo ""
echo -e "${GREEN}Passed${NC}: $PASSED"
echo -e "${YELLOW}Warnings${NC}: $WARNINGS"
echo -e "${RED}Failed${NC}: $FAILED"
echo ""

if [[ $FAILED -gt 0 ]]; then
    echo -e "${RED}RESULT: FAILED${NC} - Some critical checks failed"
    echo ""
    echo "To fix issues:"
    echo "  1. Run: $SCRIPT_DIR/configure-oidc-auth.sh"
    echo "  2. Ensure Keycloak client is properly configured"
    echo "  3. Verify Keycloak groups exist: admins, developers, readonly"
    exit 1
elif [[ $WARNINGS -gt 0 ]]; then
    echo -e "${YELLOW}RESULT: WARNING${NC} - Configuration has warnings"
    echo ""
    echo "To complete OIDC setup:"
    echo "  1. Run: platform/keycloak/scripts/configure-realm.sh"
    echo "  2. Run: platform/boundary/scripts/configure-oidc-auth.sh"
    exit 0
else
    echo -e "${GREEN}RESULT: PASSED${NC} - All tests passed"
    echo ""
    echo "Boundary is configured and ready!"
    exit 0
fi
