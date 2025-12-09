#!/bin/bash
set -euo pipefail

# Prerequisite check and auto-install script for Agent Sandbox Platform
# Run this before deployment to validate and install prerequisites
#
# USAGE:
#   ./check-prereqs.sh              # Check and auto-install missing tools
#   ./check-prereqs.sh --check-only # Only check, don't install
#   ./check-prereqs.sh --install    # Force install all tools (even if present)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Parse arguments
CHECK_ONLY="${CHECK_ONLY:-false}"
FORCE_INSTALL="${FORCE_INSTALL:-false}"

for arg in "$@"; do
    case $arg in
        --check-only)
            CHECK_ONLY="true"
            ;;
        --install)
            FORCE_INSTALL="true"
            ;;
        --help|-h)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --check-only  Only check prerequisites, don't install"
            echo "  --install     Force install all tools (even if present)"
            echo "  --help        Show this help message"
            exit 0
            ;;
    esac
done

echo "=========================================="
echo "  Agent Sandbox Platform Prerequisites"
echo "=========================================="
echo ""

ERRORS=0
WARNINGS=0
INSTALLED=0

# Detect OS and package manager
detect_os() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        OS=$ID
    elif [[ "$OSTYPE" == "darwin"* ]]; then
        OS="macos"
    else
        OS="unknown"
    fi

    # Detect package manager
    if command -v apt-get &> /dev/null; then
        PKG_MANAGER="apt"
    elif command -v yum &> /dev/null; then
        PKG_MANAGER="yum"
    elif command -v dnf &> /dev/null; then
        PKG_MANAGER="dnf"
    elif command -v brew &> /dev/null; then
        PKG_MANAGER="brew"
    elif command -v apk &> /dev/null; then
        PKG_MANAGER="apk"
    else
        PKG_MANAGER="unknown"
    fi

    # Detect architecture
    ARCH=$(uname -m)
    case $ARCH in
        x86_64) ARCH="amd64" ;;
        aarch64|arm64) ARCH="arm64" ;;
    esac
}

# Install kubectl
install_kubectl() {
    echo "  Installing kubectl..."

    # Get latest stable version
    KUBECTL_VERSION=$(curl -fsSL https://dl.k8s.io/release/stable.txt 2>/dev/null || echo "v1.31.0")

    case $OS in
        macos)
            if [[ "$PKG_MANAGER" == "brew" ]]; then
                brew install kubectl
            else
                curl -fsSLO "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/darwin/${ARCH}/kubectl"
                chmod +x kubectl
                sudo mv kubectl /usr/local/bin/
            fi
            ;;
        *)
            curl -fsSLO "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${ARCH}/kubectl"
            chmod +x kubectl
            sudo mv kubectl /usr/local/bin/
            ;;
    esac

    if command -v kubectl &> /dev/null; then
        echo "  kubectl installed successfully"
        INSTALLED=$((INSTALLED + 1))
        return 0
    else
        echo "  Failed to install kubectl"
        return 1
    fi
}

# Install Helm
install_helm() {
    echo "  Installing Helm..."

    case $OS in
        macos)
            if [[ "$PKG_MANAGER" == "brew" ]]; then
                brew install helm
            else
                curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
            fi
            ;;
        *)
            curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
            ;;
    esac

    if command -v helm &> /dev/null; then
        echo "  Helm installed successfully"
        INSTALLED=$((INSTALLED + 1))
        return 0
    else
        echo "  Failed to install Helm"
        return 1
    fi
}

# Install jq
install_jq() {
    echo "  Installing jq..."

    case $PKG_MANAGER in
        apt)
            sudo apt-get update -qq && sudo apt-get install -y -qq jq
            ;;
        yum)
            sudo yum install -y jq
            ;;
        dnf)
            sudo dnf install -y jq
            ;;
        brew)
            brew install jq
            ;;
        apk)
            sudo apk add --no-cache jq
            ;;
        *)
            # Download binary directly
            JQ_VERSION="1.7.1"
            case $OS in
                macos)
                    curl -fsSLo jq "https://github.com/jqlang/jq/releases/download/jq-${JQ_VERSION}/jq-macos-${ARCH}"
                    ;;
                *)
                    curl -fsSLo jq "https://github.com/jqlang/jq/releases/download/jq-${JQ_VERSION}/jq-linux-${ARCH}"
                    ;;
            esac
            chmod +x jq
            sudo mv jq /usr/local/bin/
            ;;
    esac

    if command -v jq &> /dev/null; then
        echo "  jq installed successfully"
        INSTALLED=$((INSTALLED + 1))
        return 0
    else
        echo "  Failed to install jq"
        return 1
    fi
}

# Install openssl
install_openssl() {
    echo "  Installing openssl..."

    case $PKG_MANAGER in
        apt)
            sudo apt-get update -qq && sudo apt-get install -y -qq openssl
            ;;
        yum)
            sudo yum install -y openssl
            ;;
        dnf)
            sudo dnf install -y openssl
            ;;
        brew)
            brew install openssl
            ;;
        apk)
            sudo apk add --no-cache openssl
            ;;
        *)
            echo "  Cannot auto-install openssl on this system"
            return 1
            ;;
    esac

    if command -v openssl &> /dev/null; then
        echo "  openssl installed successfully"
        INSTALLED=$((INSTALLED + 1))
        return 0
    else
        echo "  Failed to install openssl"
        return 1
    fi
}

# Install Kind
install_kind() {
    echo "  Installing Kind..."

    KIND_VERSION="v0.25.0"

    case $OS in
        macos)
            if [[ "$PKG_MANAGER" == "brew" ]]; then
                brew install kind
            else
                curl -fsSLo kind "https://kind.sigs.k8s.io/dl/${KIND_VERSION}/kind-darwin-${ARCH}"
                chmod +x kind
                sudo mv kind /usr/local/bin/
            fi
            ;;
        *)
            curl -fsSLo kind "https://kind.sigs.k8s.io/dl/${KIND_VERSION}/kind-linux-${ARCH}"
            chmod +x kind
            sudo mv kind /usr/local/bin/
            ;;
    esac

    if command -v kind &> /dev/null; then
        echo "  Kind installed successfully"
        INSTALLED=$((INSTALLED + 1))
        return 0
    else
        echo "  Failed to install Kind"
        return 1
    fi
}

# Install Docker (provides instructions only - too complex for auto-install)
install_docker() {
    echo "  Docker requires manual installation:"
    echo "    - Linux: https://docs.docker.com/engine/install/"
    echo "    - macOS: https://docs.docker.com/desktop/install/mac-install/"
    echo "    - Or use: curl -fsSL https://get.docker.com | sh"
    return 1
}

# Detect OS first
detect_os
echo "Detected: OS=$OS, Package Manager=$PKG_MANAGER, Arch=$ARCH"
echo ""

# Check and install kubectl
echo -n "Checking kubectl... "
if command -v kubectl &> /dev/null && [[ "$FORCE_INSTALL" != "true" ]]; then
    VERSION=$(kubectl version --client --short 2>/dev/null | head -1 || kubectl version --client -o json 2>/dev/null | jq -r '.clientVersion.gitVersion' 2>/dev/null || echo "unknown")
    echo "OK ($VERSION)"
else
    if [[ "$CHECK_ONLY" == "true" ]]; then
        echo "MISSING"
        echo "  Install: https://kubernetes.io/docs/tasks/tools/"
        ERRORS=$((ERRORS + 1))
    else
        echo "MISSING - installing..."
        if install_kubectl; then
            VERSION=$(kubectl version --client -o json 2>/dev/null | jq -r '.clientVersion.gitVersion' 2>/dev/null || echo "installed")
            echo "  Installed: $VERSION"
        else
            ERRORS=$((ERRORS + 1))
        fi
    fi
fi

# Check cluster connectivity (can't auto-install a cluster here)
echo -n "Checking cluster connectivity... "
if kubectl cluster-info &> /dev/null 2>&1; then
    CONTEXT=$(kubectl config current-context 2>/dev/null || echo "unknown")
    echo "OK (context: $CONTEXT)"
else
    echo "NO CLUSTER"
    echo "  No cluster available. A Kind cluster will be created during deployment."
    echo "  Or run: ./setup-kind.sh"
    WARNINGS=$((WARNINGS + 1))
fi

# Check Helm
echo -n "Checking Helm... "
if command -v helm &> /dev/null && [[ "$FORCE_INSTALL" != "true" ]]; then
    VERSION=$(helm version --short 2>/dev/null | cut -d'+' -f1 || echo "unknown")
    echo "OK ($VERSION)"
else
    if [[ "$CHECK_ONLY" == "true" ]]; then
        echo "MISSING"
        echo "  Install: https://helm.sh/docs/intro/install/"
        ERRORS=$((ERRORS + 1))
    else
        echo "MISSING - installing..."
        if install_helm; then
            VERSION=$(helm version --short 2>/dev/null | cut -d'+' -f1 || echo "installed")
            echo "  Installed: $VERSION"
        else
            ERRORS=$((ERRORS + 1))
        fi
    fi
fi

# Check Docker
echo -n "Checking Docker... "
if command -v docker &> /dev/null; then
    if docker info &> /dev/null 2>&1; then
        VERSION=$(docker version --format '{{.Server.Version}}' 2>/dev/null || echo "unknown")
        echo "OK ($VERSION)"
    else
        echo "NOT RUNNING"
        echo "  Docker is installed but not running. Please start Docker."
        WARNINGS=$((WARNINGS + 1))
    fi
else
    echo "MISSING"
    if [[ "$CHECK_ONLY" != "true" ]]; then
        install_docker
    else
        echo "  Install: https://docs.docker.com/get-docker/"
    fi
    WARNINGS=$((WARNINGS + 1))
fi

# Check jq
echo -n "Checking jq... "
if command -v jq &> /dev/null && [[ "$FORCE_INSTALL" != "true" ]]; then
    VERSION=$(jq --version 2>/dev/null || echo "unknown")
    echo "OK ($VERSION)"
else
    if [[ "$CHECK_ONLY" == "true" ]]; then
        echo "MISSING"
        echo "  Install: apt install jq / brew install jq"
        ERRORS=$((ERRORS + 1))
    else
        echo "MISSING - installing..."
        if install_jq; then
            VERSION=$(jq --version 2>/dev/null || echo "installed")
            echo "  Installed: $VERSION"
        else
            ERRORS=$((ERRORS + 1))
        fi
    fi
fi

# Check openssl
echo -n "Checking openssl... "
if command -v openssl &> /dev/null && [[ "$FORCE_INSTALL" != "true" ]]; then
    VERSION=$(openssl version 2>/dev/null | awk '{print $2}' || echo "unknown")
    echo "OK ($VERSION)"
else
    if [[ "$CHECK_ONLY" == "true" ]]; then
        echo "MISSING"
        echo "  Install: apt install openssl / brew install openssl"
        ERRORS=$((ERRORS + 1))
    else
        echo "MISSING - installing..."
        if install_openssl; then
            VERSION=$(openssl version 2>/dev/null | awk '{print $2}' || echo "installed")
            echo "  Installed: $VERSION"
        else
            ERRORS=$((ERRORS + 1))
        fi
    fi
fi

# Check Kind (optional but install if Docker is available)
echo -n "Checking Kind... "
if command -v kind &> /dev/null && [[ "$FORCE_INSTALL" != "true" ]]; then
    VERSION=$(kind version 2>/dev/null | awk '{print $2}' || echo "unknown")
    echo "OK ($VERSION)"
else
    if [[ "$CHECK_ONLY" == "true" ]]; then
        echo "NOT INSTALLED [optional]"
        echo "  Install for local clusters: https://kind.sigs.k8s.io/"
    else
        # Install Kind if Docker is available (needed for local clusters)
        if command -v docker &> /dev/null; then
            echo "MISSING - installing..."
            if install_kind; then
                VERSION=$(kind version 2>/dev/null | awk '{print $2}' || echo "installed")
                echo "  Installed: $VERSION"
            fi
        else
            echo "NOT INSTALLED [optional - requires Docker]"
        fi
    fi
fi

# Check curl (usually present, but verify)
echo -n "Checking curl... "
if command -v curl &> /dev/null; then
    VERSION=$(curl --version 2>/dev/null | head -1 | awk '{print $2}' || echo "unknown")
    echo "OK ($VERSION)"
else
    echo "MISSING"
    echo "  curl is required for installation scripts"
    ERRORS=$((ERRORS + 1))
fi

echo ""

# Check for existing deployments (only if cluster is available)
if kubectl cluster-info &> /dev/null 2>&1; then
    echo "Checking existing deployments..."
    EXISTING=""
    kubectl get ns devenv &>/dev/null 2>&1 && EXISTING="$EXISTING devenv"
    kubectl get ns boundary &>/dev/null 2>&1 && EXISTING="$EXISTING boundary"
    kubectl get ns vault &>/dev/null 2>&1 && EXISTING="$EXISTING vault"
    kubectl get ns vault-secrets-operator-system &>/dev/null 2>&1 && EXISTING="$EXISTING vso"

    if [[ -n "$EXISTING" ]]; then
        echo "  Found existing namespaces:$EXISTING"
        echo "  These will be updated during deployment"
    else
        echo "  No existing platform deployments found"
    fi
    echo ""
fi

echo "=========================================="

if [[ $INSTALLED -gt 0 ]]; then
    echo "  Installed $INSTALLED tool(s)"
fi

if [[ $ERRORS -eq 0 ]]; then
    if [[ $WARNINGS -gt 0 ]]; then
        echo "  Prerequisites met ($WARNINGS warning(s))"
        echo "=========================================="
        echo ""
        echo "Ready to deploy. Run:"
        echo "  ./deploy-all.sh"
        echo ""
        echo "Note: A Kind cluster will be created if no cluster is available."
        exit 0
    else
        echo "  All prerequisites met"
        echo "=========================================="
        echo ""
        echo "Ready to deploy. Run:"
        echo "  ./deploy-all.sh"
        exit 0
    fi
else
    echo "  $ERRORS prerequisite(s) missing"
    echo "=========================================="
    echo ""
    if [[ "$CHECK_ONLY" == "true" ]]; then
        echo "Run without --check-only to auto-install missing tools."
    else
        echo "Please install missing prerequisites manually and try again."
    fi
    exit 1
fi
