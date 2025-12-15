#!/bin/bash
set -euo pipefail

# Browser-based OIDC + SSH test wrapper
# Tests: Boundary OIDC Login -> Navigate to Targets -> Verify SSH connectivity

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo ""
echo "=========================================="
echo "  OIDC + SSH Browser Flow Test"
echo "=========================================="
echo ""

# Prerequisites check with auto-install
echo "Checking prerequisites..."

# Detect package manager
detect_pkg_manager() {
    if [[ "$OSTYPE" == "darwin"* ]] && command -v brew &>/dev/null; then
        echo "brew"
    elif command -v apt-get &>/dev/null; then
        echo "apt"
    elif command -v dnf &>/dev/null; then
        echo "dnf"
    else
        echo "unknown"
    fi
}

PKG_MANAGER=$(detect_pkg_manager)

# Check python3
if ! command -v python3 &>/dev/null; then
    echo -e "${YELLOW}⚠️  python3 not found, attempting install...${NC}"
    case $PKG_MANAGER in
        brew) brew install python3 ;;
        apt) sudo apt-get install -y python3 python3-venv ;;
        *) echo -e "${RED}❌ Install python3 manually${NC}"; exit 1 ;;
    esac
fi
echo -e "${GREEN}✓${NC} python3 found"

# Check kubectl
if ! command -v kubectl &>/dev/null; then
    echo -e "${RED}❌ kubectl not found${NC}"
    exit 1
fi
echo -e "${GREEN}✓${NC} kubectl found"

# Check boundary CLI (optional but recommended)
if command -v boundary &>/dev/null; then
    echo -e "${GREEN}✓${NC} boundary CLI found"
else
    echo -e "${YELLOW}⚠${NC} boundary CLI not found (SSH test via CLI will be skipped)"
fi

# Check pip
if ! python3 -m pip --version &>/dev/null; then
    echo -e "${YELLOW}⚠️  pip not found, attempting install...${NC}"
    python3 -m ensurepip --upgrade 2>/dev/null || {
        case $PKG_MANAGER in
            brew) brew reinstall python3 ;;
            apt) sudo apt-get install -y python3-pip ;;
        esac
    }
fi
echo -e "${GREEN}✓${NC} pip found"
echo ""

# Setup Playwright venv
PLAYWRIGHT_VENV="/tmp/playwright_venv"
if [[ ! -d "$PLAYWRIGHT_VENV" ]]; then
    echo -e "${BLUE}ℹ️  Creating Playwright venv...${NC}"
    python3 -m venv "$PLAYWRIGHT_VENV"
    source "$PLAYWRIGHT_VENV/bin/activate"
    pip install playwright --quiet
    echo "Installing Playwright browsers..."
    if ! playwright install chromium 2>&1; then
        echo -e "${YELLOW}⚠️  Warning: Playwright browser installation failed${NC}"
        echo "  This test requires Playwright browsers. Skipping..."
        deactivate
        exit 2  # Exit with warning code
    fi
    deactivate
    echo -e "${GREEN}✓${NC} Playwright browsers installed"
fi

# Verify playwright can run before attempting test
source "$PLAYWRIGHT_VENV/bin/activate"
if ! python3 -c "from playwright.sync_api import sync_playwright" 2>/dev/null; then
    echo -e "${YELLOW}⚠️  Warning: Playwright not properly installed${NC}"
    echo "  Skipping browser test..."
    deactivate
    exit 2  # Exit with warning code
fi
deactivate

# Check test script
TEST_SCRIPT="$SCRIPT_DIR/test-ssh-oidc-browser.py"
if [[ ! -f "$TEST_SCRIPT" ]]; then
    echo -e "${RED}❌ test-ssh-oidc-browser.py not found${NC}"
    exit 1
fi

# Verify /etc/hosts entries
echo "Verifying ingress accessibility..."
if ! grep -q "boundary.hashicorp.lab" /etc/hosts 2>/dev/null; then
    echo -e "${YELLOW}⚠️  boundary.hashicorp.lab not in /etc/hosts${NC}"
    echo "  Add: 127.0.0.1 boundary.hashicorp.lab keycloak.hashicorp.lab"
    exit 1
fi
echo -e "${GREEN}✓${NC} boundary.hashicorp.lab configured"

# Check ingress
INGRESS_IP=$(kubectl get svc -n ingress-nginx ingress-nginx-controller -o jsonpath='{.spec.clusterIP}' 2>/dev/null || echo "")
if [[ -n "$INGRESS_IP" ]]; then
    echo "  Ingress ClusterIP: $INGRESS_IP"
fi

# Activate venv and run test
source "$PLAYWRIGHT_VENV/bin/activate"

# Set environment
export BOUNDARY_URL="https://boundary.hashicorp.lab"
export KEYCLOAK_URL="https://keycloak.hashicorp.lab"
export BOUNDARY_ADDR="https://boundary.hashicorp.lab"
export BOUNDARY_TLS_INSECURE=true

echo ""
echo "Running OIDC + SSH browser flow test..."
echo "  Boundary: $BOUNDARY_URL"
echo "  Keycloak: $KEYCLOAK_URL"
echo ""

set +e
python3 "$TEST_SCRIPT" "$@" 2>&1
TEST_RESULT=$?
set -e

deactivate

echo ""
echo "=========================================="
echo "  Test Summary"
echo "=========================================="
echo ""

if [[ $TEST_RESULT -eq 0 ]]; then
    echo -e "${GREEN}✅ PASSED${NC}: OIDC + SSH browser flow"
    exit 0
else
    echo -e "${RED}❌ FAILED${NC}: OIDC + SSH browser flow"
    echo ""
    echo "Troubleshooting:"
    echo "  1. Check screenshots: ls -la /tmp/ssh-oidc-test-*.png"
    echo "  2. Run with visible browser: $0 --headed"
    echo "  3. Verify Keycloak users: ./platform/keycloak/scripts/configure-realm.sh"
    echo "  4. Check OIDC config: boundary auth-methods list"
    exit 1
fi
