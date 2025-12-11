#!/bin/bash
set -euo pipefail

# Deploy HashiCorp Boundary to Kubernetes
# Following pattern from scripts/deploy.sh in the k8s root

NAMESPACE="${1:-boundary}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFESTS_DIR="$SCRIPT_DIR/../manifests"

echo "=========================================="
echo "  Boundary Deployment"
echo "=========================================="
echo ""

# Check for kubectl
if ! command -v kubectl &> /dev/null; then
    echo "❌ kubectl is required but not installed"
    exit 1
fi

# Check cluster connectivity
if ! kubectl cluster-info &> /dev/null; then
    echo "❌ Cannot connect to Kubernetes cluster"
    exit 1
fi

echo "✅ Connected to Kubernetes cluster"
echo ""

# Verify secrets exist
if ! kubectl get secret boundary-db-secrets -n "$NAMESPACE" &> /dev/null; then
    echo "❌ Database secrets not found. Run ./create-boundary-secrets.sh first"
    exit 1
fi

if ! kubectl get secret boundary-kms-keys -n "$NAMESPACE" &> /dev/null; then
    echo "❌ KMS secrets not found. Run ./create-boundary-secrets.sh first"
    exit 1
fi

echo "✅ Secrets verified"
echo ""

# Check manifests directory
if [[ ! -d "$MANIFESTS_DIR" ]]; then
    echo "❌ Manifests directory not found: $MANIFESTS_DIR"
    exit 1
fi

echo "📦 Deploying Boundary components..."
echo ""

# Apply manifests in order
echo "  → Applying namespace..."
kubectl apply -f "$MANIFESTS_DIR/01-namespace.yaml"

echo "  → Applying ConfigMaps..."
kubectl apply -f "$MANIFESTS_DIR/03-configmap.yaml"

echo "  → Deploying PostgreSQL..."
kubectl apply -f "$MANIFESTS_DIR/04-postgres.yaml"

echo "  → Waiting for PostgreSQL to be ready..."
kubectl rollout status statefulset/boundary-postgres -n "$NAMESPACE" --timeout=120s

echo "  → Initializing Boundary database..."
# Run database init as a one-time job
kubectl run boundary-db-init \
    --namespace="$NAMESPACE" \
    --image=hashicorp/boundary:0.17 \
    --restart=Never \
    --env="POSTGRES_USER=$(kubectl get secret boundary-db-secrets -n $NAMESPACE -o jsonpath='{.data.POSTGRES_USER}' | base64 -d)" \
    --env="POSTGRES_PASSWORD=$(kubectl get secret boundary-db-secrets -n $NAMESPACE -o jsonpath='{.data.POSTGRES_PASSWORD}' | base64 -d)" \
    --env="BOUNDARY_ROOT_KEY=$(kubectl get secret boundary-kms-keys -n $NAMESPACE -o jsonpath='{.data.BOUNDARY_ROOT_KEY}' | base64 -d)" \
    --env="BOUNDARY_WORKER_AUTH_KEY=$(kubectl get secret boundary-kms-keys -n $NAMESPACE -o jsonpath='{.data.BOUNDARY_WORKER_AUTH_KEY}' | base64 -d)" \
    --env="BOUNDARY_RECOVERY_KEY=$(kubectl get secret boundary-kms-keys -n $NAMESPACE -o jsonpath='{.data.BOUNDARY_RECOVERY_KEY}' | base64 -d)" \
    --command -- sh -c '
cat > /tmp/init.hcl << EOF
disable_mlock = true
controller {
  name = "init"
  database {
    url = "postgresql://${POSTGRES_USER}:${POSTGRES_PASSWORD}@boundary-postgres.boundary.svc.cluster.local:5432/boundary?sslmode=disable"
  }
}
kms "aead" {
  purpose = "root"
  aead_type = "aes-gcm"
  key = "${BOUNDARY_ROOT_KEY}"
  key_id = "global_root"
}
kms "aead" {
  purpose = "worker-auth"
  aead_type = "aes-gcm"
  key = "${BOUNDARY_WORKER_AUTH_KEY}"
  key_id = "global_worker-auth"
}
kms "aead" {
  purpose = "recovery"
  aead_type = "aes-gcm"
  key = "${BOUNDARY_RECOVERY_KEY}"
  key_id = "global_recovery"
}
EOF
boundary database init -config=/tmp/init.hcl || echo "Database may already be initialized"
' 2>/dev/null || true

# Wait for init job to complete
echo "  → Waiting for database initialization..."
kubectl wait --for=condition=Ready pod/boundary-db-init -n "$NAMESPACE" --timeout=60s 2>/dev/null || true
sleep 5

# Get init output
echo ""
echo "  Database init output:"
kubectl logs boundary-db-init -n "$NAMESPACE" 2>/dev/null | tail -20 || true

# Cleanup init pod
kubectl delete pod boundary-db-init -n "$NAMESPACE" --ignore-not-found=true 2>/dev/null || true

echo ""
echo "  → Deploying Boundary Controller..."
kubectl apply -f "$MANIFESTS_DIR/05-controller.yaml"

echo "  → Deploying Boundary Worker..."
kubectl apply -f "$MANIFESTS_DIR/06-worker.yaml"

echo "  → Applying Services..."
kubectl apply -f "$MANIFESTS_DIR/07-service.yaml"

echo "  → Applying NetworkPolicy..."
if kubectl apply -f "$MANIFESTS_DIR/08-networkpolicy.yaml" 2>/dev/null; then
    echo "  ✅ NetworkPolicy applied"
else
    echo "  ⚠️  NetworkPolicy skipped (CNI may not support it)"
fi

echo "  → Applying TLS Certificate..."
kubectl apply -f "$MANIFESTS_DIR/09-tls-secret.yaml"

echo "  → Applying Ingress Resource..."
kubectl apply -f "$MANIFESTS_DIR/10-ingress.yaml"

echo "  → Applying Worker TLS Certificate..."
kubectl apply -f "$MANIFESTS_DIR/11-worker-tls-secret.yaml"

echo "  → Applying Worker Ingress Resource..."
kubectl apply -f "$MANIFESTS_DIR/12-worker-ingress.yaml"

echo ""
echo "  → Waiting for Controller to be ready..."
kubectl rollout status deployment/boundary-controller -n "$NAMESPACE" --timeout=180s

echo "  → Waiting for Worker to be ready..."
kubectl rollout status deployment/boundary-worker -n "$NAMESPACE" --timeout=120s

echo ""
echo "=========================================="
echo "  ✅ Boundary Deployed Successfully"
echo "=========================================="
echo ""
echo "Components:"
kubectl get pods -n "$NAMESPACE"
echo ""
echo "Services:"
kubectl get svc -n "$NAMESPACE"
echo ""
echo "Ingress:"
kubectl get ingress -n "$NAMESPACE"
echo ""
echo "Next steps:"
echo "  1. Access Boundary via Ingress at: https://boundary.local"
echo "     Worker available at: https://boundary-worker.local"
echo "     (Add '127.0.0.1 boundary.local boundary-worker.local' to /etc/hosts if needed)"
echo ""
echo "  2. Or port-forward to access Boundary API:"
echo "     kubectl port-forward -n boundary svc/boundary-controller-api 9200:9200"
echo ""
echo "  3. Initialize Boundary configuration:"
echo "     ./init-boundary.sh"
