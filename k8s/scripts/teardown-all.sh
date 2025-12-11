#!/bin/bash
set -euo pipefail

# Master teardown script for the complete K8s platform
# Removes: Keycloak, VSO, Boundary, Vault, and DevEnv
# Dependencies are handled in reverse order

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
K8S_DIR="$(dirname "$SCRIPT_DIR")"

# Source configuration
if [[ -f "$SCRIPT_DIR/.env" ]]; then
    source "$SCRIPT_DIR/.env"
elif [[ -f "$SCRIPT_DIR/platform.env.example" ]]; then
    source "$SCRIPT_DIR/platform.env.example"
fi

echo "=========================================="
echo "  Complete Platform Teardown"
echo "=========================================="
echo ""
echo "This will remove (in order):"
echo "  1. Keycloak (if deployed)"
echo "  2. Vault Secrets Operator"
echo "  3. Boundary (controller, worker, postgres)"
echo "  4. Vault"
echo "  5. Agent Sandbox (devenv)"
echo "  6. Nginx Ingress Controller"
echo ""
echo "WARNING: This will delete all data!"
echo ""

# Skip confirmation in non-interactive mode or if AUTO_CONFIRM/FORCE_YES is set
if [[ "${AUTO_CONFIRM:-}" == "true" ]] || [[ "${FORCE_YES:-}" == "true" ]] || [[ ! -t 0 ]]; then
    echo "Proceeding automatically (non-interactive mode)..."
else
    read -p "Are you sure you want to proceed? (yes/no): " confirm
    if [[ "$confirm" != "yes" ]]; then
        echo "Cancelled"
        exit 0
    fi
fi

# ==========================================
# Step 0: Remove Keycloak (if exists)
# ==========================================

if kubectl get namespace keycloak &>/dev/null; then
    echo ""
    echo "=========================================="
    echo "  Step 0: Remove Keycloak"
    echo "=========================================="
    echo ""

    kubectl delete deployment keycloak -n keycloak 2>/dev/null || true
    kubectl delete statefulset keycloak-postgres -n keycloak 2>/dev/null || true
    kubectl delete pvc -l app=keycloak-postgres -n keycloak 2>/dev/null || true
    kubectl delete namespace keycloak --timeout=60s 2>/dev/null || true
    echo "Keycloak removed"
fi

echo ""
echo "=========================================="
echo "  Step 1: Remove Vault Secrets Operator"
echo "=========================================="
echo ""

# Remove VSO custom resources first
kubectl delete vaultstaticsecret --all -n devenv 2>/dev/null || true
kubectl delete vaultauth --all -n devenv 2>/dev/null || true
kubectl delete vaultconnection --all -n devenv 2>/dev/null || true
kubectl delete vaultauth --all -n vault-secrets-operator-system 2>/dev/null || true
kubectl delete vaultconnection --all -n vault-secrets-operator-system 2>/dev/null || true

# Uninstall Helm release
if helm status vault-secrets-operator -n vault-secrets-operator-system &>/dev/null; then
    helm uninstall vault-secrets-operator -n vault-secrets-operator-system --wait
fi

# Delete namespace
kubectl delete namespace vault-secrets-operator-system --timeout=60s 2>/dev/null || true
echo "Vault Secrets Operator removed"

echo ""
echo "=========================================="
echo "  Step 2: Remove Boundary"
echo "=========================================="
echo ""

# Delete Boundary components
kubectl delete deployment boundary-controller -n boundary 2>/dev/null || true
kubectl delete deployment boundary-worker -n boundary 2>/dev/null || true
kubectl delete statefulset boundary-postgres -n boundary 2>/dev/null || true
kubectl delete job boundary-db-init -n boundary 2>/dev/null || true
kubectl delete pvc -l app=boundary-postgres -n boundary 2>/dev/null || true
kubectl delete namespace boundary --timeout=60s 2>/dev/null || true
echo "Boundary removed"

echo ""
echo "=========================================="
echo "  Step 3: Remove Vault"
echo "=========================================="
echo ""

kubectl delete statefulset vault -n vault 2>/dev/null || true
kubectl delete pvc -l app=vault -n vault 2>/dev/null || true
kubectl delete namespace vault --timeout=60s 2>/dev/null || true

# Remove vault keys file
rm -f "$K8S_DIR/platform/vault/scripts/vault-keys.txt" 2>/dev/null || true
rm -f "$K8S_DIR/platform/vault/scripts/vault-ssh-ca.pub" 2>/dev/null || true
rm -f "$K8S_DIR/platform/vault/scripts/vault-ca.crt" 2>/dev/null || true
echo "Vault removed"

echo ""
echo "=========================================="
echo "  Step 4: Remove Agent Sandbox (DevEnv)"
echo "=========================================="
echo ""

kubectl delete statefulset devenv -n devenv 2>/dev/null || true
kubectl delete pvc -l app=devenv -n devenv 2>/dev/null || true
kubectl delete namespace devenv --timeout=60s 2>/dev/null || true
echo "Agent Sandbox removed"

# Remove Boundary credentials files
rm -f "$K8S_DIR/platform/boundary/scripts/boundary-credentials.txt" 2>/dev/null || true
rm -f "$K8S_DIR/platform/boundary/scripts/boundary-oidc-config.txt" 2>/dev/null || true

echo ""
echo "=========================================="
echo "  Step 5: Remove Nginx Ingress Controller"
echo "=========================================="
echo ""

if kubectl get namespace ingress-nginx &>/dev/null; then
    kubectl delete namespace ingress-nginx --timeout=60s 2>/dev/null || true
    echo "Nginx Ingress Controller removed"
else
    echo "Nginx Ingress Controller not installed"
fi

echo ""
echo "=========================================="
echo "  Cleanup Complete"
echo "=========================================="
echo ""

# Show remaining resources
REMAINING=$(kubectl get ns 2>/dev/null | grep -E "(devenv|boundary|vault|keycloak|ingress-nginx)" || true)
if [[ -n "$REMAINING" ]]; then
    echo "Remaining namespaces (may still be terminating):"
    echo "$REMAINING"
else
    echo "All platform namespaces removed"
fi

echo ""
echo "Credential files cleaned up:"
echo "  - platform/vault/scripts/vault-keys.txt"
echo "  - platform/vault/scripts/vault-ssh-ca.pub"
echo "  - platform/vault/scripts/vault-ca.crt"
echo "  - platform/boundary/scripts/boundary-credentials.txt"
echo "  - platform/boundary/scripts/boundary-oidc-config.txt"
echo ""
echo "To also remove the Kind cluster:"
echo "  kind delete cluster --name sandbox"
echo ""
