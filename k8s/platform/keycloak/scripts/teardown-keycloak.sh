#!/bin/bash
set -e

# Keycloak Teardown Script
# This script removes Keycloak and all related resources

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFESTS_DIR="${SCRIPT_DIR}/../manifests"

echo "========================================="
echo "Keycloak Teardown"
echo "========================================="
echo ""
echo "WARNING: This will delete all Keycloak resources including:"
echo "  - Keycloak deployment and services"
echo "  - PostgreSQL database and data"
echo "  - All realms, clients, and users"
echo "  - Persistent volume claims (data will be lost)"
echo ""

# Prompt for confirmation
read -p "Are you sure you want to continue? (yes/no): " -r
echo ""

if [[ ! $REPLY =~ ^[Yy][Ee][Ss]$ ]]; then
    echo "Teardown cancelled."
    exit 0
fi

echo "Proceeding with teardown..."
echo ""

# Delete resources in reverse order
echo "1. Deleting Keycloak services..."
kubectl delete -f "${MANIFESTS_DIR}/05-service.yaml" --ignore-not-found=true

echo ""
echo "2. Deleting Keycloak deployment..."
kubectl delete -f "${MANIFESTS_DIR}/04-deployment.yaml" --ignore-not-found=true

echo ""
echo "3. Deleting PostgreSQL..."
kubectl delete -f "${MANIFESTS_DIR}/03-postgres.yaml" --ignore-not-found=true

echo ""
echo "4. Deleting secrets..."
kubectl delete -f "${MANIFESTS_DIR}/02-secrets.yaml" --ignore-not-found=true

echo ""
echo "5. Waiting for pods to terminate..."
kubectl wait --for=delete pod -l app.kubernetes.io/name=keycloak -n keycloak --timeout=60s || true

echo ""
read -p "Do you want to delete the namespace and all remaining resources? (yes/no): " -r
echo ""

if [[ $REPLY =~ ^[Yy][Ee][Ss]$ ]]; then
    echo "6. Deleting namespace..."
    kubectl delete -f "${MANIFESTS_DIR}/01-namespace.yaml" --ignore-not-found=true

    echo ""
    echo "Waiting for namespace deletion..."
    kubectl wait --for=delete namespace/keycloak --timeout=120s || {
        echo "Warning: Namespace deletion is taking longer than expected"
        echo "You can check status with: kubectl get namespace keycloak"
    }
else
    echo "6. Keeping namespace (manual cleanup required)"
fi

echo ""
echo "========================================="
echo "Teardown Complete"
echo "========================================="
echo ""
echo "Remaining resources in keycloak namespace (if any):"
kubectl get all -n keycloak 2>/dev/null || echo "Namespace deleted or empty"
echo ""
