#!/bin/bash
set -euo pipefail

# Master test runner for Boundary
# Runs all tests in sequence

NAMESPACE="${1:-boundary}"
DEVENV_NAMESPACE="${2:-devenv}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo "=========================================="
echo -e "  ${BLUE}Boundary Complete Test Suite${NC}"
echo "=========================================="
echo ""
echo "Namespace: $NAMESPACE"
echo "DevEnv Namespace: $DEVENV_NAMESPACE"
echo ""

OVERALL_PASS=true

# Function to run a test suite
run_suite() {
    local suite_name="$1"
    local script="$2"
    shift 2
    local args="$*"

    echo ""
    echo -e "${BLUE}Running: $suite_name${NC}"
    echo "=========================================="

    if [[ -x "$SCRIPT_DIR/$script" ]]; then
        if "$SCRIPT_DIR/$script" $args; then
            echo -e "${GREEN}$suite_name: PASSED${NC}"
        else
            echo -e "${RED}$suite_name: FAILED${NC}"
            OVERALL_PASS=false
        fi
    else
        echo -e "${YELLOW}$suite_name: SKIPPED (script not found)${NC}"
    fi
}

# Run test suites
run_suite "Deployment Tests" "test-deployment.sh" "$NAMESPACE"
run_suite "Authentication Tests" "test-authentication.sh" "$NAMESPACE"
run_suite "Targets Tests" "test-targets.sh" "$NAMESPACE" "$DEVENV_NAMESPACE"

echo ""
echo "=========================================="
echo -e "  ${BLUE}Overall Results${NC}"
echo "=========================================="
echo ""

if [[ "$OVERALL_PASS" == "true" ]]; then
    echo -e "  ${GREEN}ALL TEST SUITES PASSED${NC}"
    exit 0
else
    echo -e "  ${RED}SOME TEST SUITES FAILED${NC}"
    exit 1
fi
