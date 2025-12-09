#!/bin/bash
set -euo pipefail

# Test script to verify Claude Code Sandbox deployment
# Tests CRD, sandbox resource, pod health, code-server, and CLI availability

SANDBOX_NAMESPACE="${1:-devenv}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
K8S_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")"
SANDBOX_NAME="claude-code-sandbox"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

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
echo "  Claude Code Sandbox Test Suite"
echo "=========================================="
echo ""

# ==========================================
# CRD Tests
# ==========================================
echo "--- CRD Tests ---"

# Check if Sandbox CRD exists
if kubectl get crd sandboxes.agents.x-k8s.io &>/dev/null; then
    test_pass "Sandbox CRD exists (sandboxes.agents.x-k8s.io)"

    # Get CRD version
    CRD_VERSION=$(kubectl get crd sandboxes.agents.x-k8s.io -o jsonpath='{.spec.versions[0].name}' 2>/dev/null || echo "unknown")
    test_info "CRD version: $CRD_VERSION"
else
    test_fail "Sandbox CRD does not exist"
    echo ""
    echo "To install the CRD, run:"
    echo "  kubectl apply -f https://github.com/kubernetes-sigs/agent-sandbox/releases/download/v0.1.0/manifest.yaml"
    exit 1
fi

# Check CRD is established
CRD_ESTABLISHED=$(kubectl get crd sandboxes.agents.x-k8s.io -o jsonpath='{.status.conditions[?(@.type=="Established")].status}' 2>/dev/null || echo "False")
if [[ "$CRD_ESTABLISHED" == "True" ]]; then
    test_pass "Sandbox CRD is established"
else
    test_fail "Sandbox CRD is not established"
fi

echo ""

# ==========================================
# Namespace Tests
# ==========================================
echo "--- Namespace Tests ---"

if kubectl get namespace "$SANDBOX_NAMESPACE" &>/dev/null; then
    test_pass "Namespace '$SANDBOX_NAMESPACE' exists"
else
    test_fail "Namespace '$SANDBOX_NAMESPACE' does not exist"
    echo ""
    echo "To create the namespace, run:"
    echo "  kubectl create namespace $SANDBOX_NAMESPACE"
    exit 1
fi

echo ""

# ==========================================
# Sandbox Resource Tests
# ==========================================
echo "--- Sandbox Resource Tests ---"

# Check if sandbox resource exists
if kubectl get sandbox "$SANDBOX_NAME" -n "$SANDBOX_NAMESPACE" &>/dev/null; then
    test_pass "Sandbox resource '$SANDBOX_NAME' exists"

    # Get sandbox details
    SANDBOX_PHASE=$(kubectl get sandbox "$SANDBOX_NAME" -n "$SANDBOX_NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
    test_info "Sandbox phase: $SANDBOX_PHASE"

    # Check if sandbox is ready
    if [[ "$SANDBOX_PHASE" == "Running" ]]; then
        test_pass "Sandbox is in Running phase"
    elif [[ "$SANDBOX_PHASE" == "Pending" ]]; then
        test_warn "Sandbox is still Pending (may be initializing)"
    else
        test_warn "Sandbox phase: $SANDBOX_PHASE"
    fi
else
    test_fail "Sandbox resource '$SANDBOX_NAME' does not exist"
    echo ""
    echo "To deploy the sandbox, run:"
    echo "  cd $K8S_DIR/agent-sandbox && ./deploy.sh"
    exit 1
fi

echo ""

# ==========================================
# Pod Tests
# ==========================================
echo "--- Pod Tests ---"

# Check if pod exists
POD_NAME=$(kubectl get pod -l app="$SANDBOX_NAME" -n "$SANDBOX_NAMESPACE" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

if [[ -n "$POD_NAME" ]]; then
    test_pass "Pod found: $POD_NAME"

    # Check pod status
    POD_STATUS=$(kubectl get pod "$POD_NAME" -n "$SANDBOX_NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
    if [[ "$POD_STATUS" == "Running" ]]; then
        test_pass "Pod is Running"
    elif [[ "$POD_STATUS" == "Pending" ]]; then
        test_warn "Pod is Pending (may be pulling image or building)"

        # Check container statuses
        CONTAINER_STATUS=$(kubectl get pod "$POD_NAME" -n "$SANDBOX_NAMESPACE" -o jsonpath='{.status.containerStatuses[0].state}' 2>/dev/null || echo "")
        if echo "$CONTAINER_STATUS" | grep -q "waiting"; then
            REASON=$(kubectl get pod "$POD_NAME" -n "$SANDBOX_NAMESPACE" -o jsonpath='{.status.containerStatuses[0].state.waiting.reason}' 2>/dev/null || echo "Unknown")
            test_info "Container waiting reason: $REASON"
        fi
    else
        test_fail "Pod status: $POD_STATUS"
    fi

    # Check pod ready status
    POD_READY=$(kubectl get pod "$POD_NAME" -n "$SANDBOX_NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "False")
    if [[ "$POD_READY" == "True" ]]; then
        test_pass "Pod is ready"
    else
        test_warn "Pod is not ready yet"
    fi

    # Check container restarts
    RESTART_COUNT=$(kubectl get pod "$POD_NAME" -n "$SANDBOX_NAMESPACE" -o jsonpath='{.status.containerStatuses[0].restartCount}' 2>/dev/null || echo "0")
    if [[ "$RESTART_COUNT" -eq 0 ]]; then
        test_pass "Container has not restarted"
    else
        test_warn "Container has restarted $RESTART_COUNT times"
    fi
else
    test_fail "No pod found with label app=$SANDBOX_NAME"
    echo ""
    echo "Check sandbox status:"
    echo "  kubectl get sandbox -n $SANDBOX_NAMESPACE"
    echo "  kubectl describe sandbox $SANDBOX_NAME -n $SANDBOX_NAMESPACE"
fi

echo ""

# ==========================================
# Service Tests
# ==========================================
echo "--- Service Tests ---"

# Check if service exists
if kubectl get svc "$SANDBOX_NAME" -n "$SANDBOX_NAMESPACE" &>/dev/null; then
    test_pass "Service '$SANDBOX_NAME' exists"

    # Check service endpoints
    ENDPOINTS=$(kubectl get endpoints "$SANDBOX_NAME" -n "$SANDBOX_NAMESPACE" -o jsonpath='{.subsets[0].addresses[0].ip}' 2>/dev/null || echo "")
    if [[ -n "$ENDPOINTS" ]]; then
        test_pass "Service has endpoints ($ENDPOINTS)"
    else
        test_warn "Service has no endpoints (pod may not be ready)"
    fi

    # Check SSH port (22)
    SSH_PORT=$(kubectl get svc "$SANDBOX_NAME" -n "$SANDBOX_NAMESPACE" -o jsonpath='{.spec.ports[?(@.name=="ssh")].port}' 2>/dev/null || echo "")
    if [[ "$SSH_PORT" == "22" ]]; then
        test_pass "SSH port (22) is configured"
    else
        test_fail "SSH port is not configured"
    fi

    # Check code-server port (13337)
    CODE_SERVER_PORT=$(kubectl get svc "$SANDBOX_NAME" -n "$SANDBOX_NAMESPACE" -o jsonpath='{.spec.ports[?(@.name=="code-server")].port}' 2>/dev/null || echo "")
    if [[ "$CODE_SERVER_PORT" == "13337" ]]; then
        test_pass "code-server port (13337) is configured"
    else
        test_fail "code-server port is not configured"
    fi
else
    test_fail "Service '$SANDBOX_NAME' does not exist"
fi

echo ""

# ==========================================
# Connectivity Tests
# ==========================================
echo "--- Connectivity Tests ---"

if [[ -n "$POD_NAME" ]] && [[ "$POD_READY" == "True" ]]; then
    # Test code-server port 13337
    # Check if port is listening
    if kubectl exec -n "$SANDBOX_NAMESPACE" "$POD_NAME" -- sh -c "command -v netstat >/dev/null 2>&1 && netstat -ln | grep -q ':13337' || ss -ln 2>/dev/null | grep -q ':13337' || (cat < /dev/tcp/127.0.0.1/13337) 2>/dev/null" &>/dev/null; then
        test_pass "code-server port 13337 is listening"
    else
        # Give it a moment if just started
        sleep 2
        if kubectl exec -n "$SANDBOX_NAMESPACE" "$POD_NAME" -- sh -c "(cat < /dev/tcp/127.0.0.1/13337) 2>/dev/null" &>/dev/null; then
            test_pass "code-server port 13337 is listening"
        else
            test_warn "code-server port 13337 is not listening (may still be starting)"
        fi
    fi

    # Test SSH port 22
    if kubectl exec -n "$SANDBOX_NAMESPACE" "$POD_NAME" -- pgrep sshd &>/dev/null; then
        test_pass "SSH server is running"
    else
        # Check if port is listening even if sshd process not found
        if kubectl exec -n "$SANDBOX_NAMESPACE" "$POD_NAME" -- sh -c "(cat < /dev/tcp/127.0.0.1/22) 2>/dev/null" &>/dev/null; then
            test_pass "SSH port 22 is listening"
        else
            test_warn "SSH server is not running"
        fi
    fi
else
    test_warn "Skipping connectivity tests (pod not ready)"
fi

echo ""

# ==========================================
# Tool Installation Tests
# ==========================================
echo "--- Tool Installation Tests ---"

if [[ -n "$POD_NAME" ]] && [[ "$POD_READY" == "True" ]]; then
    # Check Claude Code CLI
    if kubectl exec -n "$SANDBOX_NAMESPACE" "$POD_NAME" -- sh -c "command -v claude >/dev/null 2>&1" &>/dev/null; then
        test_pass "Claude Code CLI is available"

        # Get Claude version
        CLAUDE_VERSION=$(kubectl exec -n "$SANDBOX_NAMESPACE" "$POD_NAME" -- claude --version 2>/dev/null | head -1 || echo "unknown")
        test_info "Claude version: $CLAUDE_VERSION"
    else
        test_warn "Claude Code CLI not found (may still be installing)"
    fi

    # Check Node.js
    if kubectl exec -n "$SANDBOX_NAMESPACE" "$POD_NAME" -- sh -c "command -v node >/dev/null 2>&1" &>/dev/null; then
        NODE_VERSION=$(kubectl exec -n "$SANDBOX_NAMESPACE" "$POD_NAME" -- node --version 2>/dev/null || echo "unknown")
        test_pass "Node.js is installed ($NODE_VERSION)"
    else
        test_warn "Node.js not found"
    fi

    # Check npm
    if kubectl exec -n "$SANDBOX_NAMESPACE" "$POD_NAME" -- sh -c "command -v npm >/dev/null 2>&1" &>/dev/null; then
        NPM_VERSION=$(kubectl exec -n "$SANDBOX_NAMESPACE" "$POD_NAME" -- npm --version 2>/dev/null || echo "unknown")
        test_pass "npm is installed ($NPM_VERSION)"
    else
        test_warn "npm not found"
    fi

    # Check Docker
    if kubectl exec -n "$SANDBOX_NAMESPACE" "$POD_NAME" -- sh -c "command -v docker >/dev/null 2>&1" &>/dev/null; then
        test_pass "Docker CLI is installed"
    else
        test_info "Docker CLI not installed (optional)"
    fi

    # Check git
    if kubectl exec -n "$SANDBOX_NAMESPACE" "$POD_NAME" -- sh -c "command -v git >/dev/null 2>&1" &>/dev/null; then
        GIT_VERSION=$(kubectl exec -n "$SANDBOX_NAMESPACE" "$POD_NAME" -- git --version 2>/dev/null | awk '{print $3}' || echo "unknown")
        test_pass "git is installed ($GIT_VERSION)"
    else
        test_warn "git not found"
    fi

    # Check Terraform (optional)
    if kubectl exec -n "$SANDBOX_NAMESPACE" "$POD_NAME" -- sh -c "command -v terraform >/dev/null 2>&1" &>/dev/null; then
        TF_VERSION=$(kubectl exec -n "$SANDBOX_NAMESPACE" "$POD_NAME" -- terraform version -json 2>/dev/null | grep -o '"terraform_version":"[^"]*"' | cut -d'"' -f4 || echo "unknown")
        test_pass "Terraform is installed ($TF_VERSION)"
    else
        test_info "Terraform not installed (optional)"
    fi
else
    test_warn "Skipping tool installation tests (pod not ready)"
fi

echo ""

# ==========================================
# Environment Configuration Tests
# ==========================================
echo "--- Environment Configuration Tests ---"

if [[ -n "$POD_NAME" ]] && [[ "$POD_READY" == "True" ]]; then
    # Check workspace directory
    if kubectl exec -n "$SANDBOX_NAMESPACE" "$POD_NAME" -- test -d /workspaces &>/dev/null; then
        test_pass "Workspace directory exists (/workspaces)"
    else
        test_warn "Workspace directory not found"
    fi

    # Check Claude config directory
    CLAUDE_CONFIG_DIR=$(kubectl exec -n "$SANDBOX_NAMESPACE" "$POD_NAME" -- printenv CLAUDE_CONFIG_DIR 2>/dev/null || echo "")
    if [[ -n "$CLAUDE_CONFIG_DIR" ]]; then
        test_pass "CLAUDE_CONFIG_DIR is set ($CLAUDE_CONFIG_DIR)"

        # Check if directory exists
        if kubectl exec -n "$SANDBOX_NAMESPACE" "$POD_NAME" -- test -d "$CLAUDE_CONFIG_DIR" &>/dev/null; then
            test_pass "Claude config directory exists"
        else
            test_info "Claude config directory will be created on first use"
        fi
    else
        test_warn "CLAUDE_CONFIG_DIR not set"
    fi

    # Check Vault integration
    VAULT_ADDR=$(kubectl exec -n "$SANDBOX_NAMESPACE" "$POD_NAME" -- printenv VAULT_ADDR 2>/dev/null || echo "")
    if [[ -n "$VAULT_ADDR" ]]; then
        test_pass "VAULT_ADDR is set ($VAULT_ADDR)"
    else
        test_info "VAULT_ADDR not set (optional)"
    fi

    # Check GitHub token
    if kubectl exec -n "$SANDBOX_NAMESPACE" "$POD_NAME" -- printenv GITHUB_TOKEN &>/dev/null 2>&1; then
        GH_TOKEN_VALUE=$(kubectl exec -n "$SANDBOX_NAMESPACE" "$POD_NAME" -- printenv GITHUB_TOKEN 2>/dev/null || echo "")
        if [[ -n "$GH_TOKEN_VALUE" ]] && [[ "$GH_TOKEN_VALUE" != "placeholder"* ]]; then
            test_pass "GITHUB_TOKEN is configured"
        else
            test_warn "GITHUB_TOKEN is placeholder or empty"
        fi
    else
        test_info "GITHUB_TOKEN not set (optional)"
    fi

    # Check TFE token
    if kubectl exec -n "$SANDBOX_NAMESPACE" "$POD_NAME" -- printenv TFE_TOKEN &>/dev/null 2>&1; then
        test_pass "TFE_TOKEN is configured"
    else
        test_info "TFE_TOKEN not set (optional)"
    fi
else
    test_warn "Skipping environment configuration tests (pod not ready)"
fi

echo ""

# ==========================================
# Volume Tests
# ==========================================
echo "--- Persistent Volume Tests ---"

if [[ -n "$POD_NAME" ]]; then
    # Check workspaces PVC
    if kubectl get pvc -n "$SANDBOX_NAMESPACE" -l app="$SANDBOX_NAME" 2>/dev/null | grep -q "workspaces"; then
        PVC_STATUS=$(kubectl get pvc -n "$SANDBOX_NAMESPACE" -l app="$SANDBOX_NAME" -o jsonpath='{.items[?(@.metadata.name contains "workspaces")].status.phase}' 2>/dev/null || echo "Unknown")
        if [[ "$PVC_STATUS" == "Bound" ]]; then
            test_pass "Workspaces PVC is bound"
        else
            test_warn "Workspaces PVC status: $PVC_STATUS"
        fi
    else
        test_warn "Workspaces PVC not found"
    fi

    # Check claude-config PVC
    if kubectl get pvc -n "$SANDBOX_NAMESPACE" -l app="$SANDBOX_NAME" 2>/dev/null | grep -q "claude-config"; then
        PVC_STATUS=$(kubectl get pvc -n "$SANDBOX_NAMESPACE" -l app="$SANDBOX_NAME" -o jsonpath='{.items[?(@.metadata.name contains "claude-config")].status.phase}' 2>/dev/null || echo "Unknown")
        if [[ "$PVC_STATUS" == "Bound" ]]; then
            test_pass "Claude config PVC is bound"
        else
            test_warn "Claude config PVC status: $PVC_STATUS"
        fi
    else
        test_warn "Claude config PVC not found"
    fi

    # Check bash-history PVC
    if kubectl get pvc -n "$SANDBOX_NAMESPACE" -l app="$SANDBOX_NAME" 2>/dev/null | grep -q "bash-history"; then
        PVC_STATUS=$(kubectl get pvc -n "$SANDBOX_NAMESPACE" -l app="$SANDBOX_NAME" -o jsonpath='{.items[?(@.metadata.name contains "bash-history")].status.phase}' 2>/dev/null || echo "Unknown")
        if [[ "$PVC_STATUS" == "Bound" ]]; then
            test_pass "Bash history PVC is bound"
        else
            test_warn "Bash history PVC status: $PVC_STATUS"
        fi
    else
        test_warn "Bash history PVC not found"
    fi
fi

echo ""

# ==========================================
# Summary
# ==========================================
echo "=========================================="
echo "  Test Summary"
echo "=========================================="
echo ""
echo -e "${GREEN}Passed${NC}: $PASSED"
echo -e "${YELLOW}Warnings${NC}: $WARNINGS"
echo -e "${RED}Failed${NC}: $FAILED"
echo ""

if [[ $FAILED -gt 0 ]]; then
    echo -e "${RED}RESULT: SOME TESTS FAILED${NC}"
    echo ""
    echo "To troubleshoot:"
    echo "  kubectl describe sandbox $SANDBOX_NAME -n $SANDBOX_NAMESPACE"
    echo "  kubectl logs -f -n $SANDBOX_NAMESPACE -l app=$SANDBOX_NAME"
    echo ""
    echo "To redeploy:"
    echo "  cd $K8S_DIR/agent-sandbox"
    echo "  ./teardown.sh && ./deploy.sh"
    exit 1
elif [[ $WARNINGS -gt 0 ]]; then
    echo -e "${YELLOW}RESULT: PASSED WITH WARNINGS${NC}"
    echo ""
    echo "Some components may still be initializing."
    echo "If issues persist, check logs:"
    echo "  kubectl logs -f -n $SANDBOX_NAMESPACE $POD_NAME"
    exit 0
else
    echo -e "${GREEN}RESULT: ALL TESTS PASSED${NC}"
    echo ""
    echo "Access your sandbox:"
    echo "  code-server: kubectl port-forward -n $SANDBOX_NAMESPACE svc/$SANDBOX_NAME 13337:13337"
    echo "  shell:       kubectl exec -it -n $SANDBOX_NAMESPACE $POD_NAME -- /bin/bash"
    exit 0
fi
