#!/bin/bash
# deploy.sh - End-to-end deployment script for Agent Sandboxes
# Follows kubernetes-sigs/agent-sandbox pattern
# Supports both Claude Code and Gemini sandboxes
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMESPACE="${NAMESPACE:-devenv}"
AGENT_SANDBOX_VERSION="${AGENT_SANDBOX_VERSION:-v0.1.0}"
MANIFEST_URL="https://github.com/kubernetes-sigs/agent-sandbox/releases/download/${AGENT_SANDBOX_VERSION}/manifest.yaml"

# SANDBOX_TYPE: claude (default) or gemini
SANDBOX_TYPE="${SANDBOX_TYPE:-claude}"

# Set sandbox-specific variables
case "$SANDBOX_TYPE" in
    claude)
        SANDBOX_NAME="claude-code-sandbox"
        KUSTOMIZE_SUBDIR="vscode-claude"
        ;;
    gemini)
        SANDBOX_NAME="gemini-sandbox"
        KUSTOMIZE_SUBDIR="vscode-gemini"
        ;;
    *)
        echo "ERROR: Invalid SANDBOX_TYPE='$SANDBOX_TYPE'. Must be 'claude' or 'gemini'"
        exit 1
        ;;
esac

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# -----------------------------------------------------------------------------
# Phase 0: Check Prerequisites
# -----------------------------------------------------------------------------
check_prerequisites() {
    log_info "Checking prerequisites..."

    # Check kubectl
    if ! command -v kubectl &> /dev/null; then
        log_error "kubectl not found. Please install kubectl first."
        exit 1
    fi

    # Check cluster connectivity
    if ! kubectl cluster-info &> /dev/null; then
        log_error "Cannot connect to Kubernetes cluster. Check your kubeconfig."
        exit 1
    fi

    log_info "Prerequisites OK"
}

# -----------------------------------------------------------------------------
# Phase 1: Install Agent-Sandbox CRD and Controller
# -----------------------------------------------------------------------------
install_agent_sandbox_crd() {
    log_info "Checking for Agent-Sandbox CRD and controller..."

    local crd_exists=false
    local controller_running=false

    if kubectl get crd sandboxes.agents.x-k8s.io &> /dev/null; then
        crd_exists=true
        log_info "Agent-Sandbox CRD already installed"
    fi

    # Also check if controller is running (CRD may exist without controller)
    if kubectl get pods -n agent-sandbox-system -l control-plane=controller-manager --no-headers 2>/dev/null | grep -q Running; then
        controller_running=true
        log_info "Agent-Sandbox controller is running"
    fi

    # If both CRD and controller are ready, skip installation
    if [[ "$crd_exists" == "true" ]] && [[ "$controller_running" == "true" ]]; then
        return 0
    fi

    log_info "Installing/updating Agent-Sandbox CRD and controller (${AGENT_SANDBOX_VERSION})..."

    # Try cached manifest first for faster/more reliable deployment
    # Use server-side apply with force-conflicts to handle idempotent re-deployments
    local cached_manifest="${SCRIPT_DIR}/cached-manifest.yaml"
    if [[ -f "$cached_manifest" ]]; then
        log_info "Using cached manifest: ${cached_manifest}"
        if kubectl apply --server-side --force-conflicts -f "$cached_manifest"; then
            log_info "Waiting for CRD to be established..."
            kubectl wait --for=condition=established --timeout=60s crd/sandboxes.agents.x-k8s.io
            log_info "Agent-Sandbox CRD installed successfully"
            return 0
        fi
        log_warn "Cached manifest failed, trying remote..."
    fi

    log_info "Downloading from: ${MANIFEST_URL}"
    if ! kubectl apply --server-side --force-conflicts -f "${MANIFEST_URL}"; then
        log_error "Failed to install Agent-Sandbox CRD"
        exit 1
    fi

    log_info "Waiting for CRD to be established..."
    kubectl wait --for=condition=established --timeout=60s crd/sandboxes.agents.x-k8s.io

    log_info "Agent-Sandbox CRD installed successfully"
}

# -----------------------------------------------------------------------------
# Phase 2: Wait for Controller to be Ready
# -----------------------------------------------------------------------------
wait_for_controller() {
    log_info "Waiting for Agent-Sandbox controller to be ready..."

    # The controller runs in agent-sandbox-system namespace
    local controller_ns="agent-sandbox-system"
    local max_wait=120
    local waited=0

    while [[ $waited -lt $max_wait ]]; do
        local ready=$(kubectl get pods -n "${controller_ns}" -l control-plane=controller-manager -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "False")

        if [[ "$ready" == "True" ]]; then
            log_info "Controller is ready"
            return 0
        fi

        echo -n "."
        sleep 5
        waited=$((waited + 5))
    done

    log_warn "Controller may not be fully ready, proceeding anyway..."
}

# -----------------------------------------------------------------------------
# Phase 3: Create Namespace
# -----------------------------------------------------------------------------
create_namespace() {
    log_info "Creating namespace ${NAMESPACE}..."

    if kubectl get namespace "${NAMESPACE}" &> /dev/null; then
        log_info "Namespace ${NAMESPACE} already exists"
    else
        kubectl create namespace "${NAMESPACE}"
        log_info "Namespace ${NAMESPACE} created"
    fi
}

# -----------------------------------------------------------------------------
# Phase 4: Apply Kustomize Manifests
# -----------------------------------------------------------------------------
apply_manifests() {
    log_info "Applying ${SANDBOX_NAME} manifests..."

    # Check if we should use base or an overlay
    local kustomize_dir="${SCRIPT_DIR}/${KUSTOMIZE_SUBDIR}/base"

    if [[ -n "${OVERLAY}" ]] && [[ -d "${SCRIPT_DIR}/${KUSTOMIZE_SUBDIR}/overlays/${OVERLAY}" ]]; then
        kustomize_dir="${SCRIPT_DIR}/${KUSTOMIZE_SUBDIR}/overlays/${OVERLAY}"
        log_info "Using overlay: ${OVERLAY}"
    fi

    if [[ ! -f "${kustomize_dir}/kustomization.yaml" ]]; then
        log_error "Kustomization not found at ${kustomize_dir}"
        exit 1
    fi

    kubectl apply -k "${kustomize_dir}"
    log_info "Manifests applied successfully"
}

# -----------------------------------------------------------------------------
# Phase 5: Wait for Sandbox Pod to be Ready
# -----------------------------------------------------------------------------
wait_for_sandbox() {
    log_info "Waiting for ${SANDBOX_NAME} to be ready..."
    log_warn "This may take 5-10 minutes on first run (envbuilder builds the devcontainer)"

    local max_wait=600  # 10 minutes
    local waited=0

    # Wait for the pod to exist
    while [[ $waited -lt 60 ]]; do
        if kubectl get pod -n "${NAMESPACE}" -l sandbox="${SANDBOX_NAME}" &> /dev/null; then
            break
        fi
        echo -n "."
        sleep 5
        waited=$((waited + 5))
    done
    echo ""

    # Get the pod name
    local pod_name=$(kubectl get pod -n "${NAMESPACE}" -l sandbox="${SANDBOX_NAME}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

    if [[ -z "$pod_name" ]]; then
        # Fallback: try to find by app label
        pod_name=$(kubectl get pod -n "${NAMESPACE}" -l app="${SANDBOX_NAME}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    fi

    if [[ -z "$pod_name" ]]; then
        log_warn "Could not find sandbox pod. Check with: kubectl get pods -n ${NAMESPACE}"
        return 1
    fi

    log_info "Found pod: ${pod_name}"
    log_info "Streaming logs (Ctrl+C to stop watching, deployment continues)..."

    # Stream logs in background
    kubectl logs -f -n "${NAMESPACE}" "${pod_name}" --tail=50 2>/dev/null &
    local logs_pid=$!

    # Wait for ready
    waited=0
    while [[ $waited -lt $max_wait ]]; do
        local phase=$(kubectl get pod -n "${NAMESPACE}" "${pod_name}" -o jsonpath='{.status.phase}' 2>/dev/null)
        local ready=$(kubectl get pod -n "${NAMESPACE}" "${pod_name}" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)

        if [[ "$ready" == "True" ]]; then
            kill $logs_pid 2>/dev/null || true
            echo ""
            log_info "Sandbox is ready!"
            return 0
        fi

        if [[ "$phase" == "Failed" ]] || [[ "$phase" == "Error" ]]; then
            kill $logs_pid 2>/dev/null || true
            log_error "Sandbox pod failed. Check logs with: kubectl logs -n ${NAMESPACE} ${pod_name}"
            return 1
        fi

        sleep 10
        waited=$((waited + 10))
    done

    kill $logs_pid 2>/dev/null || true
    log_warn "Timeout waiting for sandbox. It may still be building."
    log_info "Check status with: kubectl get pods -n ${NAMESPACE}"
}

# -----------------------------------------------------------------------------
# Phase 6: Capture Sandbox Configuration
# -----------------------------------------------------------------------------
capture_sandbox_config() {
    local pod_name=$(kubectl get pod -n "${NAMESPACE}" -l app="${SANDBOX_NAME}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

    echo ""
    echo "========================================="
    echo "  Sandbox Configuration"
    echo "========================================="
    echo ""

    # Sandbox resource
    echo "--- Sandbox Resource ---"
    kubectl get sandbox "${SANDBOX_NAME}" -n "${NAMESPACE}" -o wide 2>/dev/null || echo "  (not available)"
    echo ""

    # Pod details
    echo "--- Pod Details ---"
    if [[ -n "$pod_name" ]]; then
        echo "  Name:      ${pod_name}"
        echo "  Status:    $(kubectl get pod -n "${NAMESPACE}" "${pod_name}" -o jsonpath='{.status.phase}' 2>/dev/null)"
        echo "  Node:      $(kubectl get pod -n "${NAMESPACE}" "${pod_name}" -o jsonpath='{.spec.nodeName}' 2>/dev/null)"
        echo "  IP:        $(kubectl get pod -n "${NAMESPACE}" "${pod_name}" -o jsonpath='{.status.podIP}' 2>/dev/null)"
        echo "  Image:     $(kubectl get pod -n "${NAMESPACE}" "${pod_name}" -o jsonpath='{.spec.containers[0].image}' 2>/dev/null)"
    else
        echo "  (pod not found)"
    fi
    echo ""

    # PVCs
    echo "--- Persistent Volume Claims ---"
    kubectl get pvc -n "${NAMESPACE}" 2>/dev/null | grep -E "NAME|${SANDBOX_NAME}" || echo "  (none found)"
    echo ""

    # Services
    echo "--- Services ---"
    kubectl get svc "${SANDBOX_NAME}" -n "${NAMESPACE}" -o wide 2>/dev/null || echo "  (not found)"
    echo ""

    # Environment variables (non-sensitive)
    echo "--- Environment Configuration ---"
    if [[ -n "$pod_name" ]]; then
        echo "  CLAUDE_CONFIG_DIR: $(kubectl exec -n "${NAMESPACE}" "${pod_name}" -- printenv CLAUDE_CONFIG_DIR 2>/dev/null || echo 'not set')"
        echo "  VAULT_ADDR:        $(kubectl exec -n "${NAMESPACE}" "${pod_name}" -- printenv VAULT_ADDR 2>/dev/null || echo 'not set')"
        echo "  GITHUB_TOKEN:      $(kubectl exec -n "${NAMESPACE}" "${pod_name}" -- sh -c 'if [ -n "$GITHUB_TOKEN" ]; then echo "configured"; else echo "not set"; fi' 2>/dev/null)"
        echo "  TFE_TOKEN:         $(kubectl exec -n "${NAMESPACE}" "${pod_name}" -- sh -c 'if [ -n "$TFE_TOKEN" ]; then echo "configured"; else echo "not set"; fi' 2>/dev/null)"
    fi
    echo ""

    # Installed tools - wait for envbuilder init to complete
    echo "--- Installed Tools ---"
    if [[ -n "$pod_name" ]]; then
        # Wait for tools to be available (entrypoint.sh may still be running after pod is Ready)
        local max_tool_wait=60
        local tool_waited=0
        echo "  (waiting for tool installation to complete...)"
        while [[ $tool_waited -lt $max_tool_wait ]]; do
            if kubectl exec -n "${NAMESPACE}" "${pod_name}" -- test -x /usr/local/share/npm-global/bin/claude 2>/dev/null; then
                break
            fi
            sleep 5
            tool_waited=$((tool_waited + 5))
        done

        local claude_version=$(kubectl exec -n "${NAMESPACE}" "${pod_name}" -- claude --version 2>/dev/null || echo "not found")
        local node_version=$(kubectl exec -n "${NAMESPACE}" "${pod_name}" -- node --version 2>/dev/null || echo "not found")
        local terraform_version=$(kubectl exec -n "${NAMESPACE}" "${pod_name}" -- sh -c 'terraform version -json 2>/dev/null | jq -r .terraform_version' 2>/dev/null || echo "not found")
        echo "  Claude Code: ${claude_version}"
        echo "  Node.js:     ${node_version}"
        echo "  Terraform:   ${terraform_version}"
    fi
    echo ""
}

# -----------------------------------------------------------------------------
# Phase 7: Print Access Instructions
# -----------------------------------------------------------------------------
print_access_instructions() {
    echo "========================================="
    echo "  Access Methods"
    echo "========================================="
    echo ""
    echo "1. kubectl exec (direct shell):"
    echo "   kubectl exec -it -n ${NAMESPACE} \$(kubectl get pod -n ${NAMESPACE} -l app=${SANDBOX_NAME} -o jsonpath='{.items[0].metadata.name}') -- /bin/bash"
    echo ""
    echo "2. code-server (browser IDE):"
    echo "   kubectl port-forward -n ${NAMESPACE} svc/${SANDBOX_NAME} 13337:13337"
    echo "   Then open: http://localhost:13337"
    echo ""
    echo "3. SSH via Boundary (if configured):"
    echo "   boundary connect ssh -target-id=<target> -- -l node"
    echo ""
    echo "Useful Commands:"
    echo "  kubectl get sandbox -n ${NAMESPACE}"
    echo "  kubectl get pods -n ${NAMESPACE}"
    echo "  kubectl logs -f -n ${NAMESPACE} -l app=${SANDBOX_NAME}"
    echo ""
    echo "========================================="
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
main() {
    echo "========================================="
    echo "  ${SANDBOX_NAME} Deployment"
    echo "  Using kubernetes-sigs/agent-sandbox"
    echo "========================================="
    echo ""

    check_prerequisites
    install_agent_sandbox_crd
    wait_for_controller
    create_namespace
    apply_manifests
    wait_for_sandbox
    capture_sandbox_config
    print_access_instructions
}

# Run main unless sourced
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
