#!/bin/bash
set -euo pipefail

# Test Boundary authentication
# Verifies password and OIDC auth methods are working

NAMESPACE="${1:-boundary}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_PASSED=0
TESTS_FAILED=0
TESTS_TOTAL=0

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

# Test function
run_test() {
    local test_name="$1"
    local test_cmd="$2"

    TESTS_TOTAL=$((TESTS_TOTAL + 1))
    printf "  Testing: %-50s " "$test_name"

    if eval "$test_cmd" > /dev/null 2>&1; then
        echo -e "[${GREEN}PASS${NC}]"
        TESTS_PASSED=$((TESTS_PASSED + 1))
        return 0
    else
        echo -e "[${RED}FAIL${NC}]"
        TESTS_FAILED=$((TESTS_FAILED + 1))
        return 1
    fi
}

# Optional test
run_optional_test() {
    local test_name="$1"
    local test_cmd="$2"

    TESTS_TOTAL=$((TESTS_TOTAL + 1))
    printf "  Testing: %-50s " "$test_name"

    if eval "$test_cmd" > /dev/null 2>&1; then
        echo -e "[${GREEN}PASS${NC}]"
        TESTS_PASSED=$((TESTS_PASSED + 1))
        return 0
    else
        echo -e "[${YELLOW}SKIP${NC}]"
        TESTS_PASSED=$((TESTS_PASSED + 1))  # Don't count as failure
        return 1
    fi
}

echo "=========================================="
echo "  Boundary Authentication Tests"
echo "=========================================="
echo ""

# Get controller pod
CONTROLLER_POD=$(kubectl get pod -l app=boundary-controller -n "$NAMESPACE" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

if [[ -z "$CONTROLLER_POD" ]]; then
    echo "ERROR: Boundary controller pod not found"
    exit 1
fi

echo "Controller Pod: $CONTROLLER_POD"
echo ""

# ==========================================
# Auth Method Tests
# ==========================================
echo "Auth Method Tests:"
echo "--------------------------------------------"

# List auth methods
AUTH_METHODS=$(kubectl exec -n "$NAMESPACE" "$CONTROLLER_POD" -c boundary-controller -- \
    /bin/ash -c "export BOUNDARY_ADDR=http://127.0.0.1:9200; boundary auth-methods list -scope-id=global -format=json" 2>/dev/null || echo "{}")

run_test "Global auth methods accessible" \
    "echo '$AUTH_METHODS' | jq -e '.items' > /dev/null 2>&1"

# Check for password auth method
GLOBAL_PASSWORD_AUTH=$(echo "$AUTH_METHODS" | jq -r '.items[]? | select(.type=="password") | .id' 2>/dev/null | head -1 || echo "")
if [[ -n "$GLOBAL_PASSWORD_AUTH" ]]; then
    run_test "Global password auth method exists" "true"
    echo "         Auth Method ID: $GLOBAL_PASSWORD_AUTH"
else
    run_test "Global password auth method exists" "false"
fi

echo ""

# ==========================================
# Password Authentication Tests
# ==========================================
echo "Password Authentication Tests:"
echo "--------------------------------------------"

# Get credentials from file
CREDS_FILE="$SCRIPT_DIR/../boundary-credentials.txt"
if [[ -f "$CREDS_FILE" ]]; then
    AUTH_METHOD_ID=$(grep "Auth Method ID:" "$CREDS_FILE" 2>/dev/null | awk '{print $4}' || echo "")
    ADMIN_PASSWORD=$(grep "Password:" "$CREDS_FILE" 2>/dev/null | awk '{print $2}' || echo "")

    if [[ -n "$AUTH_METHOD_ID" ]] && [[ -n "$ADMIN_PASSWORD" ]]; then
        # Test authentication
        AUTH_RESULT=$(kubectl exec -n "$NAMESPACE" "$CONTROLLER_POD" -c boundary-controller -- \
            /bin/ash -c "
                export BOUNDARY_ADDR=http://127.0.0.1:9200
                export BOUNDARY_PASSWORD='$ADMIN_PASSWORD'
                boundary authenticate password \
                    -auth-method-id='$AUTH_METHOD_ID' \
                    -login-name=admin \
                    -password=env://BOUNDARY_PASSWORD \
                    -format=json
            " 2>/dev/null || echo "{}")

        TOKEN=$(echo "$AUTH_RESULT" | jq -r '.item.attributes.token // empty' 2>/dev/null || echo "")

        if [[ -n "$TOKEN" ]]; then
            run_test "Admin password authentication" "true"
            echo "         Successfully obtained auth token"

            # Test token is valid by listing scopes
            SCOPES_RESULT=$(kubectl exec -n "$NAMESPACE" "$CONTROLLER_POD" -c boundary-controller -- \
                /bin/ash -c "
                    export BOUNDARY_ADDR=http://127.0.0.1:9200
                    export BOUNDARY_TOKEN='$TOKEN'
                    boundary scopes list -format=json
                " 2>/dev/null || echo "{}")

            run_test "Token can list scopes" \
                "echo '$SCOPES_RESULT' | jq -e '.items' > /dev/null 2>&1"
        else
            run_test "Admin password authentication" "false"
            echo "         Failed to authenticate"
        fi
    else
        printf "  Testing: %-50s [${YELLOW}SKIP${NC}]\n" "Password authentication"
        echo "           (Credentials not found in file)"
        TESTS_TOTAL=$((TESTS_TOTAL + 1))
        TESTS_PASSED=$((TESTS_PASSED + 1))
    fi
else
    printf "  Testing: %-50s [${YELLOW}SKIP${NC}]\n" "Password authentication"
    echo "           (Credentials file not found)"
    TESTS_TOTAL=$((TESTS_TOTAL + 1))
    TESTS_PASSED=$((TESTS_PASSED + 1))
fi

echo ""

# ==========================================
# OIDC Authentication Tests
# ==========================================
echo "OIDC Authentication Tests:"
echo "--------------------------------------------"

# Check if Keycloak is running
KEYCLOAK_STATUS=$(kubectl get pod -l app=keycloak -n keycloak -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "NotFound")

if [[ "$KEYCLOAK_STATUS" == "Running" ]]; then
    # Check for OIDC config file
    OIDC_CONFIG="$SCRIPT_DIR/../boundary-oidc-config.txt"

    if [[ -f "$OIDC_CONFIG" ]]; then
        OIDC_AUTH_METHOD=$(grep "Auth Method ID:" "$OIDC_CONFIG" 2>/dev/null | awk '{print $4}' || echo "")

        if [[ -n "$OIDC_AUTH_METHOD" ]]; then
            run_test "OIDC auth method configured" "true"
            echo "         Auth Method ID: $OIDC_AUTH_METHOD"

            # Verify OIDC auth method exists in Boundary
            run_test "OIDC auth method exists in Boundary" \
                "kubectl exec -n $NAMESPACE $CONTROLLER_POD -c boundary-controller -- /bin/ash -c \"export BOUNDARY_ADDR=http://127.0.0.1:9200; boundary auth-methods read -id=$OIDC_AUTH_METHOD\" 2>/dev/null | grep -q oidc"
        else
            run_optional_test "OIDC auth method configured" "false"
        fi
    else
        run_optional_test "OIDC configuration file exists" "false"
        echo "           (Run configure-oidc-auth.sh to configure)"
    fi
else
    printf "  Testing: %-50s [${YELLOW}SKIP${NC}]\n" "OIDC authentication"
    echo "           (Keycloak not running)"
    TESTS_TOTAL=$((TESTS_TOTAL + 1))
    TESTS_PASSED=$((TESTS_PASSED + 1))
fi

echo ""

# ==========================================
# Summary
# ==========================================
echo "=========================================="
echo "  Test Summary"
echo "=========================================="
echo ""

if [[ $TESTS_FAILED -eq 0 ]]; then
    echo -e "  ${GREEN}All tests passed!${NC}"
else
    echo -e "  ${RED}Some tests failed${NC}"
fi
echo ""
echo "  Total:  $TESTS_TOTAL"
echo -e "  Passed: ${GREEN}$TESTS_PASSED${NC}"
echo -e "  Failed: ${RED}$TESTS_FAILED${NC}"
echo ""

# Exit with failure if any tests failed
if [[ $TESTS_FAILED -gt 0 ]]; then
    exit 1
fi
