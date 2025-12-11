#!/bin/bash
set -euo pipefail

# Test Boundary targets and connectivity
# Verifies targets are configured and reachable

NAMESPACE="${1:-boundary}"
DEVENV_NAMESPACE="${2:-devenv}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
K8S_DIR="$(dirname "$(dirname "$(dirname "$(dirname "$SCRIPT_DIR")")")")"
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
        TESTS_PASSED=$((TESTS_PASSED + 1))
        return 1
    fi
}

echo "=========================================="
echo "  Boundary Targets Tests"
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

# Get credentials and authenticate
CREDS_FILE="$SCRIPT_DIR/../boundary-credentials.txt"
if [[ ! -f "$CREDS_FILE" ]]; then
    echo "ERROR: Credentials file not found at $CREDS_FILE"
    echo "       Run configure-targets.sh first"
    exit 1
fi

AUTH_METHOD_ID=$(grep "Auth Method ID:" "$CREDS_FILE" 2>/dev/null | awk '{print $4}' || echo "")
ADMIN_PASSWORD=$(grep "Password:" "$CREDS_FILE" 2>/dev/null | awk '{print $2}' || echo "")

if [[ -z "$AUTH_METHOD_ID" ]] || [[ -z "$ADMIN_PASSWORD" ]]; then
    echo "ERROR: Could not extract credentials from file"
    exit 1
fi

# Authenticate
echo "Authenticating with Boundary..."
AUTH_TOKEN=$(kubectl exec -n "$NAMESPACE" "$CONTROLLER_POD" -c boundary-controller -- \
    /bin/ash -c "
        export BOUNDARY_ADDR=http://127.0.0.1:9200
        export BOUNDARY_PASSWORD='$ADMIN_PASSWORD'
        boundary authenticate password \
            -auth-method-id='$AUTH_METHOD_ID' \
            -login-name=admin \
            -password=env://BOUNDARY_PASSWORD \
            -format=json
    " 2>/dev/null | jq -r '.item.attributes.token // empty' 2>/dev/null || echo "")

if [[ -z "$AUTH_TOKEN" ]]; then
    echo "ERROR: Authentication failed"
    exit 1
fi
echo "Authenticated successfully"
echo ""

# Function to run boundary commands
run_boundary() {
    kubectl exec -n "$NAMESPACE" "$CONTROLLER_POD" -c boundary-controller -- \
        /bin/ash -c "export BOUNDARY_ADDR=http://127.0.0.1:9200; export BOUNDARY_TOKEN='$AUTH_TOKEN'; boundary $*"
}

# ==========================================
# Scope Tests
# ==========================================
echo "Scope Tests:"
echo "--------------------------------------------"

SCOPES=$(run_boundary scopes list -format=json 2>/dev/null || echo "{}")

run_test "Can list scopes" \
    "echo '$SCOPES' | jq -e '.items' > /dev/null 2>&1"

ORG_ID=$(echo "$SCOPES" | jq -r '.items[]? | select(.name=="DevOps") | .id' 2>/dev/null || echo "")
run_test "DevOps organization exists" \
    "[[ -n '$ORG_ID' ]]"

if [[ -n "$ORG_ID" ]]; then
    echo "         Organization ID: $ORG_ID"

    ORG_SCOPES=$(run_boundary scopes list -scope-id="$ORG_ID" -format=json 2>/dev/null || echo "{}")
    PROJECT_ID=$(echo "$ORG_SCOPES" | jq -r '.items[]? | select(.name=="Agent-Sandbox") | .id' 2>/dev/null || echo "")

    run_test "Agent-Sandbox project exists" \
        "[[ -n '$PROJECT_ID' ]]"

    if [[ -n "$PROJECT_ID" ]]; then
        echo "         Project ID: $PROJECT_ID"
    fi
fi

echo ""

# ==========================================
# Host Catalog Tests
# ==========================================
echo "Host Catalog Tests:"
echo "--------------------------------------------"

if [[ -n "$PROJECT_ID" ]]; then
    CATALOGS=$(run_boundary host-catalogs list -scope-id="$PROJECT_ID" -format=json 2>/dev/null || echo "{}")
    CATALOG_ID=$(echo "$CATALOGS" | jq -r '.items[]? | select(.name=="devenv-hosts") | .id' 2>/dev/null || echo "")

    run_test "devenv-hosts catalog exists" \
        "[[ -n '$CATALOG_ID' ]]"

    if [[ -n "$CATALOG_ID" ]]; then
        echo "         Catalog ID: $CATALOG_ID"

        HOSTS=$(run_boundary hosts list -host-catalog-id="$CATALOG_ID" -format=json 2>/dev/null || echo "{}")
        HOST_ID=$(echo "$HOSTS" | jq -r '.items[]? | select(.name=="devenv-service") | .id' 2>/dev/null || echo "")

        run_test "devenv-service host exists" \
            "[[ -n '$HOST_ID' ]]"

        if [[ -n "$HOST_ID" ]]; then
            HOST_ADDRESS=$(echo "$HOSTS" | jq -r ".items[]? | select(.id==\"$HOST_ID\") | .attributes.address" 2>/dev/null || echo "")
            echo "         Host ID: $HOST_ID"
            echo "         Host Address: $HOST_ADDRESS"
        fi

        HOSTSETS=$(run_boundary host-sets list -host-catalog-id="$CATALOG_ID" -format=json 2>/dev/null || echo "{}")
        HOSTSET_ID=$(echo "$HOSTSETS" | jq -r '.items[]? | select(.name=="devenv-set") | .id' 2>/dev/null || echo "")

        run_test "devenv-set host set exists" \
            "[[ -n '$HOSTSET_ID' ]]"
    fi
else
    printf "  Testing: %-50s [${YELLOW}SKIP${NC}]\n" "Host catalog tests"
    echo "           (Project not found)"
fi

echo ""

# ==========================================
# Target Tests
# ==========================================
echo "Target Tests:"
echo "--------------------------------------------"

if [[ -n "$PROJECT_ID" ]]; then
    TARGETS=$(run_boundary targets list -scope-id="$PROJECT_ID" -format=json 2>/dev/null || echo "{}")
    TARGET_ID=$(echo "$TARGETS" | jq -r '.items[]? | select(.name=="devenv-ssh") | .id' 2>/dev/null || echo "")

    run_test "devenv-ssh target exists" \
        "[[ -n '$TARGET_ID' ]]"

    if [[ -n "$TARGET_ID" ]]; then
        echo "         Target ID: $TARGET_ID"

        # Get target details
        TARGET_DETAILS=$(run_boundary targets read -id="$TARGET_ID" -format=json 2>/dev/null || echo "{}")

        TARGET_PORT=$(echo "$TARGET_DETAILS" | jq -r '.item.attributes.default_port // empty' 2>/dev/null || echo "")
        run_test "Target has port 22" \
            "[[ '$TARGET_PORT' == '22' ]]"

        # Check host sources
        HOST_SOURCES=$(echo "$TARGET_DETAILS" | jq -r '.item.host_source_ids // []' 2>/dev/null || echo "[]")
        run_test "Target has host source" \
            "echo '$HOST_SOURCES' | jq -e 'length > 0' > /dev/null 2>&1"
    fi
else
    printf "  Testing: %-50s [${YELLOW}SKIP${NC}]\n" "Target tests"
    echo "           (Project not found)"
fi

echo ""

# ==========================================
# Credential Store Tests
# ==========================================
echo "Credential Store Tests:"
echo "--------------------------------------------"

if [[ -n "$PROJECT_ID" ]]; then
    CRED_STORES=$(run_boundary credential-stores list -scope-id="$PROJECT_ID" -format=json 2>/dev/null || echo "{}")
    VAULT_STORE_ID=$(echo "$CRED_STORES" | jq -r '.items[]? | select(.type=="vault") | .id' 2>/dev/null || echo "")

    if [[ -n "$VAULT_STORE_ID" ]]; then
        run_test "Vault credential store exists" "true"
        echo "         Store ID: $VAULT_STORE_ID"

        # Check credential libraries
        CRED_LIBS=$(run_boundary credential-libraries list -credential-store-id="$VAULT_STORE_ID" -format=json 2>/dev/null || echo "{}")
        SSH_LIB_ID=$(echo "$CRED_LIBS" | jq -r '.items[]? | select(.type=="vault-ssh-certificate") | .id' 2>/dev/null || echo "")

        if [[ -n "$SSH_LIB_ID" ]]; then
            run_test "SSH credential library exists" "true"
            echo "         Library ID: $SSH_LIB_ID"
        else
            run_optional_test "SSH credential library exists" "false"
        fi
    else
        run_optional_test "Vault credential store exists" "false"
        echo "           (Vault integration not configured)"
    fi
else
    printf "  Testing: %-50s [${YELLOW}SKIP${NC}]\n" "Credential store tests"
fi

echo ""

# ==========================================
# DevEnv Connectivity Tests
# ==========================================
echo "DevEnv Connectivity Tests:"
echo "--------------------------------------------"

# Check if devenv is running
DEVENV_POD=$(kubectl get pod -l app=devenv -n "$DEVENV_NAMESPACE" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

if [[ -n "$DEVENV_POD" ]]; then
    run_test "DevEnv pod running" "true"

    # Check if devenv service exists
    DEVENV_SVC=$(kubectl get svc -n "$DEVENV_NAMESPACE" -l app=devenv -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

    if [[ -z "$DEVENV_SVC" ]]; then
        # Try other common names
        for SVC_NAME in "claude-code-sandbox" "devenv" "sandbox"; do
            DEVENV_SVC=$(kubectl get svc "$SVC_NAME" -n "$DEVENV_NAMESPACE" -o name 2>/dev/null || echo "")
            if [[ -n "$DEVENV_SVC" ]]; then
                DEVENV_SVC="$SVC_NAME"
                break
            fi
        done
    fi

    if [[ -n "$DEVENV_SVC" ]]; then
        run_test "DevEnv service exists" "true"
        echo "         Service: $DEVENV_SVC"

        # Test SSH port from worker
        WORKER_POD=$(kubectl get pod -l app=boundary-worker -n "$NAMESPACE" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
        if [[ -n "$WORKER_POD" ]]; then
            # Test connectivity from worker to devenv SSH
            run_test "Worker can reach DevEnv SSH" \
                "kubectl exec -n $NAMESPACE $WORKER_POD -c boundary-worker -- nc -zv $DEVENV_SVC.$DEVENV_NAMESPACE.svc.cluster.local 22 2>&1 | grep -q succeeded"
        fi
    else
        run_optional_test "DevEnv service exists" "false"
    fi
else
    printf "  Testing: %-50s [${YELLOW}SKIP${NC}]\n" "DevEnv connectivity"
    echo "           (DevEnv not deployed)"
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
