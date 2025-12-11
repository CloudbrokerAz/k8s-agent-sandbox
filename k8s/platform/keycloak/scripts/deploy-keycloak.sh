#!/bin/bash
set -e

# Keycloak Deployment Script
# This script deploys Keycloak with PostgreSQL to Kubernetes

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFESTS_DIR="${SCRIPT_DIR}/../manifests"

echo "========================================="
echo "Deploying Keycloak Identity Provider"
echo "========================================="
echo ""

# Check if kubectl is available
if ! command -v kubectl &> /dev/null; then
    echo "Error: kubectl is not installed or not in PATH"
    exit 1
fi

# Apply manifests in order
echo "1. Creating namespace..."
kubectl apply -f "${MANIFESTS_DIR}/01-namespace.yaml"

echo ""
echo "2. Creating secrets..."
kubectl apply -f "${MANIFESTS_DIR}/02-secrets.yaml"

echo ""
echo "3. Deploying PostgreSQL database..."
kubectl apply -f "${MANIFESTS_DIR}/03-postgres.yaml"

echo ""
echo "4. Waiting for PostgreSQL to be ready..."
kubectl wait --for=condition=ready pod \
    -l app=keycloak-postgres \
    -n keycloak \
    --timeout=300s || {
    echo "Warning: PostgreSQL pod did not become ready in time"
    echo "Checking pod status:"
    kubectl get pods -n keycloak -l app=keycloak-postgres
}

echo ""
echo "5. Deploying Keycloak..."
kubectl apply -f "${MANIFESTS_DIR}/04-deployment.yaml"

echo ""
echo "6. Creating services..."
kubectl apply -f "${MANIFESTS_DIR}/05-service.yaml"

echo ""
echo "7. Creating TLS certificate and Ingress..."
kubectl apply -f "${MANIFESTS_DIR}/07-tls-secret.yaml"
kubectl apply -f "${MANIFESTS_DIR}/08-ingress.yaml"

echo ""
echo "8. Waiting for Keycloak to be ready..."
kubectl wait --for=condition=ready pod \
    -l app=keycloak \
    -n keycloak \
    --timeout=300s || {
    echo "Warning: Keycloak pod did not become ready in time"
    echo "Checking pod status:"
    kubectl get pods -n keycloak -l app=keycloak
}

echo ""
echo "========================================="
echo "Deployment Status"
echo "========================================="
kubectl get pods -n keycloak
echo ""
kubectl get svc -n keycloak
echo ""
kubectl get ingress -n keycloak

echo ""
echo "========================================="
echo "Access Information"
echo "========================================="
echo "Keycloak Admin Console:"
echo "  URL: https://keycloak.local"
echo "  Username: admin"
echo "  Password: admin123!@#"
echo ""
echo "To access Keycloak via Ingress:"
echo "  Add '127.0.0.1 keycloak.local' to /etc/hosts if needed"
echo ""
echo "Or port-forward to access Keycloak:"
echo "  kubectl port-forward -n keycloak svc/keycloak 8080:8080"
echo ""
echo "Next steps:"
echo "  1. Access Keycloak via Ingress or port-forward"
echo "  2. Run configure-realm.sh to set up the agent-sandbox realm"
echo "  3. Configure Boundary OIDC auth method"
echo ""
