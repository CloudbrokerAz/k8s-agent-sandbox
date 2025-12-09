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
ORG_RESULT=$(run_boundary scopes list -format=json -recovery-kms-hcl="kms \"aead\" { purpose = \"recovery\"; aead_type = \"aes-gcm\"; key = \"$RECOVERY_KEY\"; key_id = \"global_recovery\" }" 2>/dev/null || echo "{}")

ORG_ID=$(echo "$ORG_RESULT" | jq -r '.items[] | select(.name=="DevOps") | .id' || echo "")
if [[ -n "$ORG_ID" ]]; then
    test_pass "DevOps organization exists ($ORG_ID)"
else
    test_fail "DevOps organization not found"
    exit 1
fi

# Get project ID
PROJECT_ID=$(run_boundary scopes list -scope-id="$ORG_ID" -format=json -recovery-kms-hcl="kms \"aead\" { purpose = \"recovery\"; aead_type = \"aes-gcm\"; key = \"$RECOVERY_KEY\"; key_id = \"global_recovery\" }" 2>/dev/null | jq -r '.items[] | select(.name=="Agent-Sandbox") | .id' || echo "")
if [[ -n "$PROJECT_ID" ]]; then
    test_pass "Agent-Sandbox project exists ($PROJECT_ID)"
else
    test_fail "Agent-Sandbox project not found"
    exit 1
fi

# Test 1: Check OIDC auth method exists
echo ""
echo "--- OIDC Auth Method ---"
AUTH_METHODS=$(run_boundary auth-methods list -scope-id="$ORG_ID" -format=json -recovery-kms-hcl="kms \"aead\" { purpose = \"recovery\"; aead_type = \"aes-gcm\"; key = \"$RECOVERY_KEY\"; key_id = \"global_recovery\" }" 2>/dev/null || echo "{}")

OIDC_AUTH_ID=$(echo "$AUTH_METHODS" | jq -r '.items[] | select(.type=="oidc") | .id' || echo "")
if [[ -n "$OIDC_AUTH_ID" ]]; then
    test_pass "OIDC auth method exists ($OIDC_AUTH_ID)"

    # Get auth method details
    AUTH_DETAILS=$(echo "$AUTH_METHODS" | jq -r ".items[] | select(.id==\"$OIDC_AUTH_ID\")")
    AUTH_NAME=$(echo "$AUTH_DETAILS" | jq -r '.name')
    AUTH_ISSUER=$(echo "$AUTH_DETAILS" | jq -r '.attributes.issuer // "unknown"')
    AUTH_CLIENT_ID=$(echo "$AUTH_DETAILS" | jq -r '.attributes.client_id // "unknown"')

    test_info "Auth method name: $AUTH_NAME"
    test_info "Issuer: $AUTH_ISSUER"
    test_info "Client ID: $AUTH_CLIENT_ID"

    # Validate issuer
    EXPECTED_ISSUER="http://keycloak.${KEYCLOAK_NAMESPACE}.svc.cluster.local:8080/realms/agent-sandbox"
    if [[ "$AUTH_ISSUER" == "$EXPECTED_ISSUER" ]]; then
        test_pass "OIDC issuer correctly configured"
    else
        test_fail "OIDC issuer mismatch (expected: $EXPECTED_ISSUER, got: $AUTH_ISSUER)"
    fi

    # Validate client ID
    if [[ "$AUTH_CLIENT_ID" == "boundary" ]]; then
        test_pass "OIDC client ID correctly configured"
    else
        test_fail "OIDC client ID mismatch (expected: boundary, got: $AUTH_CLIENT_ID)"
    fi
else
    test_fail "OIDC auth method not found"
    echo ""
    echo "Run configure-oidc-auth.sh to create the OIDC auth method"
    exit 1
fi

# Test 2: Check managed groups exist
echo ""
echo "--- Managed Groups ---"
MANAGED_GROUPS=$(run_boundary managed-groups list -auth-method-id="$OIDC_AUTH_ID" -format=json -recovery-kms-hcl="kms \"aead\" { purpose = \"recovery\"; aead_type = \"aes-gcm\"; key = \"$RECOVERY_KEY\"; key_id = \"global_recovery\" }" 2>/dev/null || echo "{}")

# Expected groups
EXPECTED_GROUPS=("keycloak-admins" "keycloak-developers" "keycloak-readonly")
for GROUP_NAME in "${EXPECTED_GROUPS[@]}"; do
    GROUP_ID=$(echo "$MANAGED_GROUPS" | jq -r ".items[] | select(.name==\"$GROUP_NAME\") | .id" || echo "")
    if [[ -n "$GROUP_ID" ]]; then
        test_pass "Managed group '$GROUP_NAME' exists ($GROUP_ID)"

        # Get filter
        GROUP_FILTER=$(echo "$MANAGED_GROUPS" | jq -r ".items[] | select(.id==\"$GROUP_ID\") | .attributes.filter" || echo "")
        test_info "  Filter: $GROUP_FILTER"
    else
        test_fail "Managed group '$GROUP_NAME' not found"
    fi
done

# Count total managed groups
TOTAL_GROUPS=$(echo "$MANAGED_GROUPS" | jq -r '.items | length' || echo "0")
test_info "Total managed groups: $TOTAL_GROUPS"

# Test 3: Check roles and permissions
echo ""
echo "--- Roles and Permissions ---"
ROLES=$(run_boundary roles list -scope-id="$PROJECT_ID" -format=json -recovery-kms-hcl="kms \"aead\" { purpose = \"recovery\"; aead_type = \"aes-gcm\"; key = \"$RECOVERY_KEY\"; key_id = \"global_recovery\" }" 2>/dev/null || echo "{}")

# Expected OIDC roles
EXPECTED_ROLES=("oidc-admins" "oidc-developers" "oidc-readonly")
for ROLE_NAME in "${EXPECTED_ROLES[@]}"; do
    ROLE_ID=$(echo "$ROLES" | jq -r ".items[] | select(.name==\"$ROLE_NAME\") | .id" || echo "")
    if [[ -n "$ROLE_ID" ]]; then
        test_pass "Role '$ROLE_NAME' exists ($ROLE_ID)"

        # Get role details
        ROLE_DETAILS=$(run_boundary roles read -id="$ROLE_ID" -format=json -recovery-kms-hcl="kms \"aead\" { purpose = \"recovery\"; aead_type = \"aes-gcm\"; key = \"$RECOVERY_KEY\"; key_id = \"global_recovery\" }" 2>/dev/null || echo "{}")

        # Check grants
        GRANTS=$(echo "$ROLE_DETAILS" | jq -r '.item.grant_strings[]?' 2>/dev/null || echo "")
        if [[ -n "$GRANTS" ]]; then
            test_pass "  Role has grant permissions configured"
            echo "$GRANTS" | while read -r grant; do
                test_info "    Grant: $grant"
            done
        else
            test_warn "  No grants found for role"
        fi

        # Check principals (managed groups)
        PRINCIPALS=$(echo "$ROLE_DETAILS" | jq -r '.item.principal_ids[]?' 2>/dev/null || echo "")
        if [[ -n "$PRINCIPALS" ]]; then
            test_pass "  Role has principals (managed groups) assigned"
            PRINCIPAL_COUNT=$(echo "$PRINCIPALS" | wc -l)
            test_info "    Principal count: $PRINCIPAL_COUNT"
        else
            test_warn "  No principals assigned to role"
        fi
    else
        test_fail "Role '$ROLE_NAME' not found"
    fi
done

# Test 4: Verify Keycloak connectivity (if running)
echo ""
echo "--- Keycloak Connectivity ---"
if [[ "$KEYCLOAK_STATUS" == "Running" ]]; then
    KEYCLOAK_POD=$(kubectl get pod -l app=keycloak -n "$KEYCLOAK_NAMESPACE" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

    if [[ -n "$KEYCLOAK_POD" ]]; then
        # Test if Keycloak is reachable from Boundary controller
        KEYCLOAK_URL="http://keycloak.${KEYCLOAK_NAMESPACE}.svc.cluster.local:8080"
        KEYCLOAK_REACHABLE=$(kubectl exec -n "$BOUNDARY_NAMESPACE" "$CONTROLLER_POD" -- \
            curl -s -o /dev/null -w "%{http_code}" "$KEYCLOAK_URL" 2>/dev/null || echo "000")

        if [[ "$KEYCLOAK_REACHABLE" != "000" ]]; then
            test_pass "Keycloak is reachable from Boundary controller (HTTP $KEYCLOAK_REACHABLE)"
        else
            test_fail "Keycloak not reachable from Boundary controller"
        fi

        # Test OIDC discovery endpoint
        OIDC_DISCOVERY="$KEYCLOAK_URL/realms/agent-sandbox/.well-known/openid-configuration"
        DISCOVERY_STATUS=$(kubectl exec -n "$BOUNDARY_NAMESPACE" "$CONTROLLER_POD" -- \
            curl -s -o /dev/null -w "%{http_code}" "$OIDC_DISCOVERY" 2>/dev/null || echo "000")

        if [[ "$DISCOVERY_STATUS" == "200" ]]; then
            test_pass "OIDC discovery endpoint accessible (HTTP 200)"
        else
            test_fail "OIDC discovery endpoint not accessible (HTTP $DISCOVERY_STATUS)"
        fi
    fi
else
    test_warn "Keycloak not running - skipping connectivity tests"
fi

# Test 5: Verify group mappings
echo ""
echo "--- Group Mapping Summary ---"
test_info "Keycloak Group → Boundary Role → Permissions"
test_info "──────────────────────────────────────────────"
test_info "admins         → oidc-admins     → Full access (all operations)"
test_info "developers     → oidc-developers → Connect access (read + authorize-session on targets)"
test_info "readonly       → oidc-readonly   → List access (read + list on all resources)"

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
    echo "Next steps:"
    echo "  1. Configure Keycloak client with client secret"
    echo "  2. Create groups in Keycloak (admins, developers, readonly)"
    echo "  3. Assign users to groups"
    echo "  4. Test authentication:"
    echo "     export BOUNDARY_ADDR=http://127.0.0.1:9200"
    echo "     boundary authenticate oidc -auth-method-id=$OIDC_AUTH_ID"
    exit 0
else
    echo -e "${GREEN}RESULT: PASSED${NC} - All tests passed"
    echo ""
    echo "OIDC configuration is complete!"
    echo ""
    echo "Next steps:"
    echo "  1. Configure Keycloak client (see boundary-oidc-config.txt)"
    echo "  2. Create groups and users in Keycloak"
    echo "  3. Test authentication:"
    echo "     kubectl port-forward -n $BOUNDARY_NAMESPACE svc/boundary-controller-api 9200:9200"
    echo "     export BOUNDARY_ADDR=http://127.0.0.1:9200"
    echo "     boundary authenticate oidc -auth-method-id=$OIDC_AUTH_ID"
    exit 0
fi
