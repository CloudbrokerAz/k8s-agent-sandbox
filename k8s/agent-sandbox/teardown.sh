#!/bin/bash
# teardown.sh - Remove Claude Code Sandbox deployment
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMESPACE="${NAMESPACE:-devenv}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }

echo "========================================="
echo "  Claude Code Sandbox Teardown"
echo "========================================="
echo ""

# Determine which kustomization to use
KUSTOMIZE_DIR="${SCRIPT_DIR}/base"
if [[ -n "${OVERLAY}" ]] && [[ -d "${SCRIPT_DIR}/overlays/${OVERLAY}" ]]; then
    KUSTOMIZE_DIR="${SCRIPT_DIR}/overlays/${OVERLAY}"
fi

log_info "Deleting sandbox resources..."
kubectl delete -k "${KUSTOMIZE_DIR}" --ignore-not-found=true

log_info "Deleting PVCs..."
kubectl delete pvc -n "${NAMESPACE}" -l app=claude-code-sandbox --ignore-not-found=true

log_warn "Note: Namespace '${NAMESPACE}' was NOT deleted (may contain other resources)"
log_warn "To delete namespace: kubectl delete namespace ${NAMESPACE}"

echo ""
log_info "Teardown complete"
echo ""
echo "To also remove the Agent-Sandbox controller:"
echo "  kubectl delete -f https://github.com/kubernetes-sigs/agent-sandbox/releases/download/v0.1.0/manifest.yaml"
