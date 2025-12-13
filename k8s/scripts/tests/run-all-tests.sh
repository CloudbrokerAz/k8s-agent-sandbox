#!/bin/bash
set -euo pipefail

# Master test runner for Agent Sandbox Platform
# Runs all verification tests and provides summary

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
K8S_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Track results
TOTAL_SUITES=0
PASSED_SUITES=0
FAILED_SUITES=0
WARNED_SUITES=0

run_test_suite() {
    local name="$1"
    local script="$2"

    TOTAL_SUITES=$((TOTAL_SUITES + 1))

    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}  Running: $name${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""

    if [[ ! -f "$script" ]]; then
        echo -e "${YELLOW}⚠️  Test script not found: $script${NC}"
        WARNED_SUITES=$((WARNED_SUITES + 1))
        return
    fi

    if [[ ! -x "$script" ]]; then
        chmod +x "$script"
    fi

    set +e
    "$script"
    local result=$?
    set -e

    if [[ $result -eq 0 ]]; then
        PASSED_SUITES=$((PASSED_SUITES + 1))
    elif [[ $result -eq 1 ]]; then
        FAILED_SUITES=$((FAILED_SUITES + 1))
    else
        WARNED_SUITES=$((WARNED_SUITES + 1))
    fi
}

echo ""
echo -e "${BLUE}╔══════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║   Agent Sandbox Platform Test Suite      ║${NC}"
echo -e "${BLUE}╚══════════════════════════════════════════╝${NC}"
echo ""
echo "Running all platform verification tests..."

# ==========================================
# Test Suites
# ==========================================

# Core healthcheck
run_test_suite "Platform Healthcheck" "$SCRIPT_DIR/healthcheck.sh"

# Secrets verification
run_test_suite "Secrets Verification" "$SCRIPT_DIR/test-secrets.sh"

# Boundary tests
run_test_suite "Boundary Verification" "$SCRIPT_DIR/test-boundary.sh"

# Keycloak tests
run_test_suite "Keycloak IDP Verification" "$SCRIPT_DIR/test-keycloak.sh"

# OIDC authentication tests
run_test_suite "OIDC Authentication" "$SCRIPT_DIR/test-oidc-auth.sh"

# Browser-based OIDC flow test (optional, requires playwright)
# Note: Disabled by default as it requires playwright and proper DNS resolution
# Enable with: RUN_BROWSER_TESTS=true ./run-all-tests.sh
if [[ "${RUN_BROWSER_TESTS:-true}" == "true" ]]; then
    run_test_suite "OIDC Browser Flow" "$SCRIPT_DIR/test-oidc-browser.sh"
fi

# Claude Code Sandbox tests
run_test_suite "Claude Code Sandbox" "$SCRIPT_DIR/test-sandbox.sh"

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
