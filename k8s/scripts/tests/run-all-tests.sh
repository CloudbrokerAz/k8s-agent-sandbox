#!/bin/bash
set -euo pipefail

# Master test runner for Agent Sandbox Platform
# Runs all verification tests and provides summary
# Supports parallel execution for independent tests

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
K8S_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Track results (use temp files for parallel safety)
RESULTS_DIR=$(mktemp -d)
trap "rm -rf $RESULTS_DIR" EXIT

# Parallel execution control
PARALLEL="${PARALLEL:-true}"

run_test_suite() {
    local name="$1"
    local script="$2"

    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}  Running: $name${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""

    if [[ ! -f "$script" ]]; then
        echo -e "${YELLOW}⚠️  Test script not found: $script${NC}"
        return 2
    fi

    if [[ ! -x "$script" ]]; then
        chmod +x "$script"
    fi

    set +e
    "$script"
    local result=$?
    set -e

    return $result
}

run_test_parallel() {
    local name="$1"
    local script="$2"
    local safe_name=$(echo "$name" | tr ' ' '_' | tr -cd '[:alnum:]_')
    local output_file="$RESULTS_DIR/${safe_name}.log"
    local result_file="$RESULTS_DIR/${safe_name}.result"
    local pid_file="$RESULTS_DIR/${safe_name}.pid"

    (
        # Redirect all output to file for this subshell
        {
            run_test_suite "$name" "$script"
        } > "$output_file" 2>&1
        echo $? > "$result_file"
    ) &
    local pid=$!
    echo "$pid" > "$pid_file"
    # Return safe_name for tracking (no spaces)
    echo "$safe_name"
}

wait_for_parallel_tests() {
    local safe_names="$1"
    local passed=0
    local failed=0
    local warned=0
    local total=0

    for safe_name in $safe_names; do
        local pid_file="$RESULTS_DIR/${safe_name}.pid"
        local output_file="$RESULTS_DIR/${safe_name}.log"
        local result_file="$RESULTS_DIR/${safe_name}.result"

        if [[ -f "$pid_file" ]]; then
            local pid=$(cat "$pid_file")
            wait "$pid" 2>/dev/null || true
        fi
        total=$((total + 1))

        # Display output to terminal (fd 3 redirected to stdout before calling)
        if [[ -f "$output_file" ]]; then
            cat "$output_file" >&3
        fi

        # Check result
        if [[ -f "$result_file" ]]; then
            local result=$(cat "$result_file")
            if [[ "$result" -eq 0 ]]; then
                passed=$((passed + 1))
            elif [[ "$result" -eq 1 ]]; then
                failed=$((failed + 1))
            else
                warned=$((warned + 1))
            fi
        else
            warned=$((warned + 1))
        fi
    done

    echo "$total:$passed:$failed:$warned"
}

echo ""
echo -e "${BLUE}╔══════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║   Agent Sandbox Platform Test Suite      ║${NC}"
echo -e "${BLUE}╚══════════════════════════════════════════╝${NC}"
echo ""
if [[ "$PARALLEL" == "true" ]]; then
    echo "Running tests with parallel execution enabled..."
else
    echo "Running tests sequentially (PARALLEL=false to disable)..."
fi

# Initialize counters
TOTAL_SUITES=0
PASSED_SUITES=0
FAILED_SUITES=0
WARNED_SUITES=0

# ==========================================
# Phase 1: Core healthcheck (must run first)
# ==========================================
echo ""
echo -e "${BLUE}Phase 1: Core Healthcheck${NC}"

run_test_suite "Platform Healthcheck" "$SCRIPT_DIR/healthcheck.sh"
result=$?
TOTAL_SUITES=$((TOTAL_SUITES + 1))
if [[ $result -eq 0 ]]; then
    PASSED_SUITES=$((PASSED_SUITES + 1))
elif [[ $result -eq 1 ]]; then
    FAILED_SUITES=$((FAILED_SUITES + 1))
    echo -e "${RED}Healthcheck failed - stopping tests${NC}"
    # Continue anyway to show what else might be broken
else
    WARNED_SUITES=$((WARNED_SUITES + 1))
fi

# ==========================================
# Phase 2: Independent tests (can run in parallel)
# ==========================================
echo ""
echo -e "${BLUE}Phase 2: Component Tests${NC}"

if [[ "$PARALLEL" == "true" ]]; then
    echo "  Running 4 tests in parallel..."
    PARALLEL_TESTS=""
    PARALLEL_TESTS+="$(run_test_parallel "Secrets Verification" "$SCRIPT_DIR/test-secrets.sh") "
    PARALLEL_TESTS+="$(run_test_parallel "Boundary Verification" "$SCRIPT_DIR/test-boundary.sh") "
    PARALLEL_TESTS+="$(run_test_parallel "Keycloak IDP Verification" "$SCRIPT_DIR/test-keycloak.sh") "
    PARALLEL_TESTS+="$(run_test_parallel "Claude Code Sandbox" "$SCRIPT_DIR/test-sandbox.sh") "

    # Wait and collect results (fd 3 = terminal for output display)
    exec 3>&1
    results=$(wait_for_parallel_tests "$PARALLEL_TESTS")
    exec 3>&-
    IFS=':' read -r total passed failed warned <<< "$results"
    TOTAL_SUITES=$((TOTAL_SUITES + total))
    PASSED_SUITES=$((PASSED_SUITES + passed))
    FAILED_SUITES=$((FAILED_SUITES + failed))
    WARNED_SUITES=$((WARNED_SUITES + warned))
else
    # Sequential execution
    for test_info in \
        "Secrets Verification:$SCRIPT_DIR/test-secrets.sh" \
        "Boundary Verification:$SCRIPT_DIR/test-boundary.sh" \
        "Keycloak IDP Verification:$SCRIPT_DIR/test-keycloak.sh" \
        "Claude Code Sandbox:$SCRIPT_DIR/test-sandbox.sh"; do
        IFS=':' read -r name script <<< "$test_info"
        run_test_suite "$name" "$script"
        result=$?
        TOTAL_SUITES=$((TOTAL_SUITES + 1))
        if [[ $result -eq 0 ]]; then
            PASSED_SUITES=$((PASSED_SUITES + 1))
        elif [[ $result -eq 1 ]]; then
            FAILED_SUITES=$((FAILED_SUITES + 1))
        else
            WARNED_SUITES=$((WARNED_SUITES + 1))
        fi
    done
fi

# ==========================================
# Phase 3: OIDC tests (depend on Keycloak)
# ==========================================
echo ""
echo -e "${BLUE}Phase 3: OIDC Integration Tests${NC}"

# OIDC authentication tests
run_test_suite "OIDC Authentication" "$SCRIPT_DIR/test-oidc-auth.sh"
result=$?
TOTAL_SUITES=$((TOTAL_SUITES + 1))
if [[ $result -eq 0 ]]; then
    PASSED_SUITES=$((PASSED_SUITES + 1))
elif [[ $result -eq 1 ]]; then
    FAILED_SUITES=$((FAILED_SUITES + 1))
else
    WARNED_SUITES=$((WARNED_SUITES + 1))
fi

# Browser-based OIDC flow test
if [[ "${RUN_BROWSER_TESTS:-true}" == "true" ]]; then
    run_test_suite "OIDC Browser Flow" "$SCRIPT_DIR/test-oidc-browser.sh"
    result=$?
    TOTAL_SUITES=$((TOTAL_SUITES + 1))
    if [[ $result -eq 0 ]]; then
        PASSED_SUITES=$((PASSED_SUITES + 1))
    elif [[ $result -eq 1 ]]; then
        FAILED_SUITES=$((FAILED_SUITES + 1))
    else
        WARNED_SUITES=$((WARNED_SUITES + 1))
    fi
fi

# ==========================================
# Summary
# ==========================================
echo ""
echo -e "${BLUE}╔══════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║   Test Suite Summary                     ║${NC}"
echo -e "${BLUE}╚══════════════════════════════════════════╝${NC}"
echo ""
echo "Test Suites Run: $TOTAL_SUITES"
echo ""
echo -e "${GREEN}Passed${NC}:   $PASSED_SUITES"
echo -e "${YELLOW}Warnings${NC}: $WARNED_SUITES"
echo -e "${RED}Failed${NC}:   $FAILED_SUITES"
echo ""

if [[ $FAILED_SUITES -gt 0 ]]; then
    echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${RED}  RESULT: SOME TEST SUITES FAILED${NC}"
    echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    exit 1
elif [[ $WARNED_SUITES -gt 0 ]]; then
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${YELLOW}  RESULT: PASSED WITH WARNINGS${NC}"
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo "Some optional components may not be configured."
    echo "Run individual configuration scripts to resolve warnings."
    exit 0
else
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}  RESULT: ALL TEST SUITES PASSED${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    exit 0
fi
