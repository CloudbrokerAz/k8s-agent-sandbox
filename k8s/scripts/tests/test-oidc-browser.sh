#!/bin/bash
set -euo pipefail

# Browser-based OIDC test wrapper
# Runs test-oidc-browser.py with proper environment setup

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo ""
echo "=========================================="
echo "  Browser OIDC Flow Test"
echo "=========================================="
echo ""

# Check if playwright is available
PLAYWRIGHT_VENV="/tmp/playwright_venv"
if [[ ! -d "$PLAYWRIGHT_VENV" ]]; then
    echo -e "${YELLOW}⚠️  Playwright venv not found, creating...${NC}"
    python3 -m venv "$PLAYWRIGHT_VENV"
    source "$PLAYWRIGHT_VENV/bin/activate"
    pip install playwright --quiet
    playwright install chromium --quiet 2>/dev/null || true
    deactivate
fi

# Check if the test script exists
TEST_SCRIPT="$SCRIPT_DIR/test-oidc-browser.py"
if [[ ! -f "$TEST_SCRIPT" ]]; then
    echo -e "${RED}❌ FAIL${NC}: test-oidc-browser.py not found"
    exit 1
fi

# Activate venv and run test
source "$PLAYWRIGHT_VENV/bin/activate"

# Use ingress directly (boundary.local and keycloak.local must resolve to ingress)
# Verify /etc/hosts entries or external DNS are configured correctly

echo "Verifying ingress accessibility..."
INGRESS_IP=$(kubectl get svc -n ingress-nginx ingress-nginx-controller -o jsonpath='{.spec.clusterIP}' 2>/dev/null || echo "")
if [[ -z "$INGRESS_IP" ]]; then
    echo -e "${RED}❌ FAIL${NC}: Cannot find ingress-nginx controller service"
    exit 1
fi
echo "  Ingress ClusterIP: $INGRESS_IP"

# Test that boundary.local and keycloak.local are accessible
if ! curl -sk --connect-timeout 5 "https://boundary.local" -o /dev/null 2>&1; then
    echo -e "${BLUE}ℹ️  Info: boundary.local may not be accessible${NC}"
    echo "  Ensure /etc/hosts contains: 127.0.0.1 boundary.local keycloak.local"
fi

# Run the test using ingress URLs (default port 443)
export BOUNDARY_PORT=443
export KEYCLOAK_PORT=443
export BOUNDARY_HOST="boundary.local"
export KEYCLOAK_HOST="keycloak.local"

echo ""
echo "Running browser OIDC flow test via ingress..."
echo "  Boundary: https://$BOUNDARY_HOST"
echo "  Keycloak: https://$KEYCLOAK_HOST"
echo ""

set +e
python3 "$TEST_SCRIPT" --headless 2>&1
TEST_RESULT=$?
set -e

deactivate

echo ""
echo "=========================================="
echo "  Test Summary"
echo "=========================================="
echo ""

if [[ $TEST_RESULT -eq 0 ]]; then
    echo -e "${GREEN}Passed${NC}: OIDC browser flow"
    echo -e "${GREEN}RESULT: PASSED${NC}"
    exit 0
else
    echo -e "${RED}Failed${NC}: OIDC browser flow"
    echo -e "${RED}RESULT: FAILED${NC}"
    echo ""
    echo "Troubleshooting:"
    echo "  1. Ensure boundary.local and keycloak.local resolve correctly"
    echo "  2. Check Keycloak users are configured: ./platform/keycloak/scripts/configure-realm.sh"
    echo "  3. Check OIDC auth method: boundary auth-methods list"
    exit 1
fi
