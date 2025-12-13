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

# Check for Enterprise license (optional)
if kubectl get secret boundary-license -n "$NAMESPACE" &> /dev/null; then
    echo "✅ Secrets verified (Enterprise license found)"
    ENTERPRISE_MODE=true
else
    echo "✅ Secrets verified (Community Edition - no license)"
    ENTERPRISE_MODE=false
fi
echo ""

# Check manifests directory
if [[ ! -d "$MANIFESTS_DIR" ]]; then
    echo "❌ Manifests directory not found: $MANIFESTS_DIR"
    exit 1
fi

echo "📦 Deploying Boundary components..."
echo ""

# Get ingress-nginx ClusterIP for hostAliases (required for OIDC)
echo "  → Detecting ingress-nginx ClusterIP for OIDC..."
INGRESS_NGINX_IP=$(kubectl get svc -n ingress-nginx ingress-nginx-controller -o jsonpath='{.spec.clusterIP}' 2>/dev/null || echo "")
if [[ -z "$INGRESS_NGINX_IP" ]]; then
    # Try alternate service name
    INGRESS_NGINX_IP=$(kubectl get svc -n ingress-nginx nginx-ingress-controller -o jsonpath='{.spec.clusterIP}' 2>/dev/null || echo "")
fi
if [[ -z "$INGRESS_NGINX_IP" ]]; then
    echo "  ⚠️  Could not detect ingress-nginx ClusterIP"
    echo "      OIDC authentication may not work correctly"
    echo "      Set INGRESS_NGINX_IP environment variable or fix ingress-nginx deployment"
    INGRESS_NGINX_IP="127.0.0.1"
else
    echo "  ✅ Ingress ClusterIP: $INGRESS_NGINX_IP"
fi
export INGRESS_NGINX_IP

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
# Use matching image version (Enterprise or Community) to avoid mismatch
if [[ "$ENTERPRISE_MODE" == "true" ]]; then
    BOUNDARY_INIT_IMAGE="hashicorp/boundary-enterprise:0.20.1-ent"
else
    BOUNDARY_INIT_IMAGE="hashicorp/boundary:0.20.1"
fi
kubectl run boundary-db-init \
    --namespace="$NAMESPACE" \
    --image="$BOUNDARY_INIT_IMAGE" \
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

# Get init output and save credentials
echo ""
echo "  → Capturing admin credentials..."
INIT_OUTPUT=$(kubectl logs boundary-db-init -n "$NAMESPACE" 2>/dev/null || echo "")
echo "$INIT_OUTPUT" | tail -20

# Extract and save credentials
AUTH_METHOD_ID=$(echo "$INIT_OUTPUT" | grep -E "Auth Method ID:" | head -1 | awk -F': ' '{print $2}' | tr -d ' ')
LOGIN_NAME=$(echo "$INIT_OUTPUT" | grep -E "Login Name:" | head -1 | awk -F': ' '{print $2}' | tr -d ' ')
PASSWORD=$(echo "$INIT_OUTPUT" | grep -E "Password:" | head -1 | awk -F': ' '{print $2}' | tr -d ' ')

if [[ -n "$AUTH_METHOD_ID" ]] && [[ -n "$PASSWORD" ]]; then
    cat > "$SCRIPT_DIR/boundary-credentials.txt" << EOF
==========================================
  Boundary Admin Credentials
==========================================

Auth Method ID: $AUTH_METHOD_ID
Login Name:     ${LOGIN_NAME:-admin}
Password:       $PASSWORD

==========================================
EOF
    chmod 600 "$SCRIPT_DIR/boundary-credentials.txt"
    echo "  ✅ Credentials saved to boundary-credentials.txt"
fi

# Cleanup init pod
kubectl delete pod boundary-db-init -n "$NAMESPACE" --ignore-not-found=true 2>/dev/null || true

echo ""
echo "  → Deploying Boundary Controller..."
# Substitute ingress IP in controller manifest before applying
echo "    Using ingress IP: $INGRESS_NGINX_IP"

# Create temp file with substitution (most reliable method)
TEMP_MANIFEST=$(mktemp)
sed "s/\${INGRESS_NGINX_IP}/${INGRESS_NGINX_IP}/g" "$MANIFESTS_DIR/05-controller.yaml" > "$TEMP_MANIFEST"

# Verify substitution worked
if grep -q '\${INGRESS_NGINX_IP}' "$TEMP_MANIFEST"; then
    echo "    ⚠️  Warning: Variable substitution may have failed"
    cat "$TEMP_MANIFEST" | grep -A2 "hostAliases"
fi

kubectl apply -f "$TEMP_MANIFEST"
rm -f "$TEMP_MANIFEST"

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
if [[ "$ENTERPRISE_MODE" == "true" ]]; then
    echo "  ✅ Boundary Enterprise Deployed Successfully"
    echo "     (Credential Injection enabled)"
else
    echo "  ✅ Boundary Community Deployed Successfully"
    echo "     (Credential Brokering only - no injection)"
fi
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
# ==========================================
# Configure Boundary Resources
# ==========================================

echo ""
echo "==========================================="
echo "  Configuring Boundary Resources"
echo "==========================================="
echo ""

# Wait for controller to be fully ready
echo "Waiting for controller to be fully ready..."
sleep 5

# Configure targets (scopes, hosts, targets)
if [[ -x "$SCRIPT_DIR/configure-targets.sh" ]]; then
    echo "Running target configuration..."
    if "$SCRIPT_DIR/configure-targets.sh" "$NAMESPACE"; then
        echo "✅ Targets configured successfully"
    else
        echo "⚠️  Target configuration had issues (may already be configured)"
    fi
else
    echo "⚠️  configure-targets.sh not found, skipping target configuration"
fi

# Configure OIDC with Keycloak if available
KEYCLOAK_STATUS=$(kubectl get pod -l app=keycloak -n keycloak -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "NotFound")
if [[ "$KEYCLOAK_STATUS" == "Running" ]]; then
    echo ""
    echo "Keycloak detected - configuring OIDC authentication..."
    if [[ -x "$SCRIPT_DIR/configure-oidc-auth.sh" ]]; then
        if "$SCRIPT_DIR/configure-oidc-auth.sh" "$NAMESPACE" keycloak; then
            echo "✅ OIDC configured with Keycloak"
        else
            echo "⚠️  OIDC configuration had issues (may already be configured)"
        fi
    fi
else
    echo ""
    echo "ℹ️  Keycloak not detected - skipping OIDC configuration"
    echo "   (Password authentication is available)"
fi

# Configure Credential Injection (Enterprise only)
if [[ "$ENTERPRISE_MODE" == "true" ]]; then
    echo ""
    echo "Configuring credential injection (Enterprise)..."
    if [[ -x "$SCRIPT_DIR/configure-credential-injection.sh" ]]; then
        if "$SCRIPT_DIR/configure-credential-injection.sh" "$NAMESPACE" devenv; then
            echo "✅ Credential injection configured"
        else
            echo "⚠️  Credential injection configuration had issues"
        fi
    fi
else
    echo ""
    echo "ℹ️  Credential injection skipped (Community Edition)"
    echo "   (Credential brokering with Vault available if configured)"
fi

# ==========================================
# Run Tests
# ==========================================

echo ""
echo "==========================================="
echo "  Running Deployment Tests"
echo "==========================================="
echo ""

if [[ -x "$SCRIPT_DIR/tests/run-all-tests.sh" ]]; then
    if "$SCRIPT_DIR/tests/run-all-tests.sh" "$NAMESPACE" devenv; then
        echo ""
        echo "✅ All tests passed"
    else
        echo ""
        echo "⚠️  Some tests failed - check output above"
    fi
else
    echo "⚠️  Test suite not found, skipping tests"
fi

echo ""
echo "==========================================="
if [[ "$ENTERPRISE_MODE" == "true" ]]; then
    echo "  ✅ Boundary Enterprise Ready"
    echo "     (Credential Injection enabled)"
else
    echo "  ✅ Boundary Community Ready"
    echo "     (Credential Brokering only)"
fi
echo "==========================================="
echo ""
echo "Access:"
echo "  • Ingress: https://boundary.local"
echo "  • Worker:  https://boundary-worker.local"
echo "  • API:     kubectl port-forward -n boundary svc/boundary-controller-api 9200:9200"
echo ""
echo "Credentials saved to: $SCRIPT_DIR/boundary-credentials.txt"
echo ""
if [[ -f "$SCRIPT_DIR/boundary-oidc-config.txt" ]]; then
    echo "OIDC config saved to: $SCRIPT_DIR/boundary-oidc-config.txt"
    echo ""
fi
