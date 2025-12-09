#!/bin/bash
set -euo pipefail

# Prerequisite check script for Agent Sandbox Platform
# Run this before deployment to validate environment

echo "=========================================="
echo "  Agent Sandbox Platform Prerequisites"
echo "=========================================="
echo ""

ERRORS=0

# Check kubectl
echo -n "Checking kubectl... "
if command -v kubectl &> /dev/null; then
    VERSION=$(kubectl version --client --short 2>/dev/null | head -1 || kubectl version --client -o json 2>/dev/null | jq -r '.clientVersion.gitVersion' || echo "unknown")
    echo "OK ($VERSION)"
else
    echo "MISSING"
    echo "  Install: https://kubernetes.io/docs/tasks/tools/"
    ((ERRORS++))
fi

# Check cluster connectivity
echo -n "Checking cluster connectivity... "
if kubectl cluster-info &> /dev/null; then
    CONTEXT=$(kubectl config current-context 2>/dev/null || echo "unknown")
    echo "OK (context: $CONTEXT)"
else
    echo "FAILED"
    echo "  No cluster available. Run ./setup-kind.sh to create a local cluster"
    ((ERRORS++))
fi

# Check Helm
echo -n "Checking Helm... "
if command -v helm &> /dev/null; then
    VERSION=$(helm version --short 2>/dev/null | cut -d'+' -f1 || echo "unknown")
    echo "OK ($VERSION)"
else
    echo "MISSING"
    echo "  Install: https://helm.sh/docs/intro/install/"
    ((ERRORS++))
fi

# Check Docker
echo -n "Checking Docker... "
if command -v docker &> /dev/null; then
    if docker info &> /dev/null; then
        VERSION=$(docker version --format '{{.Server.Version}}' 2>/dev/null || echo "unknown")
        echo "OK ($VERSION)"
    else
        echo "NOT RUNNING"
        echo "  Docker is installed but not running"
        ((ERRORS++))
    fi
else
    echo "MISSING"
    echo "  Install: https://docs.docker.com/get-docker/"
    ((ERRORS++))
fi

# Check jq
echo -n "Checking jq... "
if command -v jq &> /dev/null; then
    VERSION=$(jq --version 2>/dev/null || echo "unknown")
    echo "OK ($VERSION)"
else
    echo "MISSING"
    echo "  Install: apt install jq / brew install jq"
    ((ERRORS++))
fi

# Check openssl
echo -n "Checking openssl... "
if command -v openssl &> /dev/null; then
    VERSION=$(openssl version 2>/dev/null | awk '{print $2}' || echo "unknown")
    echo "OK ($VERSION)"
else
    echo "MISSING"
    echo "  Install: apt install openssl / brew install openssl"
    ((ERRORS++))
fi

# Check Kind (optional)
echo -n "Checking Kind... "
if command -v kind &> /dev/null; then
    VERSION=$(kind version 2>/dev/null | awk '{print $2}' || echo "unknown")
    echo "OK ($VERSION) [optional]"
else
    echo "NOT INSTALLED [optional]"
    echo "  Install for local clusters: https://kind.sigs.k8s.io/"
fi

echo ""

# Check for existing deployments
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
echo "=========================================="

if [[ $ERRORS -eq 0 ]]; then
    echo "  All prerequisites met"
    echo "=========================================="
    echo ""
    echo "Ready to deploy. Run:"
    echo "  ./deploy-all.sh"
    exit 0
else
    echo "  $ERRORS prerequisite(s) missing"
    echo "=========================================="
    echo ""
    echo "Please install missing prerequisites and try again."
    exit 1
fi
