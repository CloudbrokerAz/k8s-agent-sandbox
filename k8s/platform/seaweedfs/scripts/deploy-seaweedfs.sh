#!/bin/bash
set -euo pipefail

NAMESPACE="${1:-seaweedfs}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFESTS_DIR="$SCRIPT_DIR/../manifests"
TEMP_DIR=$(mktemp -d)

# Cleanup temporary directory on exit
cleanup() {
    rm -rf "$TEMP_DIR"
}
trap cleanup EXIT

echo "=========================================="
echo "  SeaweedFS Deployment"
echo "=========================================="
echo ""

# Check cluster connectivity
if ! kubectl cluster-info &> /dev/null; then
    echo "❌ Cannot connect to Kubernetes cluster"
    exit 1
fi

echo "✅ Connected to Kubernetes cluster"
echo ""

# Generate TLS certificate if it doesn't exist
echo "🔒 Checking TLS certificate..."
if kubectl get secret seaweedfs-s3-tls -n "$NAMESPACE" &> /dev/null; then
    echo "  → TLS certificate already exists, skipping generation"
else
    echo "  → Generating self-signed TLS certificate..."
    openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
        -keyout "$TEMP_DIR/seaweedfs-s3.key" \
        -out "$TEMP_DIR/seaweedfs-s3.crt" \
        -subj "/CN=seaweedfs-s3.hashicorp.lab" \
        -addext "subjectAltName=DNS:seaweedfs-s3.hashicorp.lab,DNS:localhost,IP:127.0.0.1" \
        2>/dev/null

    # Base64 encode the certificate and key
    TLS_CRT=$(base64 < "$TEMP_DIR/seaweedfs-s3.crt" | tr -d '\n')
    TLS_KEY=$(base64 < "$TEMP_DIR/seaweedfs-s3.key" | tr -d '\n')

    # Create temporary manifest with actual certificate data
    sed -e "s|tls.crt: \"\"|tls.crt: $TLS_CRT|" \
        -e "s|tls.key: \"\"|tls.key: $TLS_KEY|" \
        "$MANIFESTS_DIR/07-tls-secret.yaml" > "$TEMP_DIR/07-tls-secret.yaml"

    echo "  → TLS certificate generated"
fi

echo ""
echo "📦 Deploying SeaweedFS components..."

# Apply namespace first
echo "  → Applying namespace..."
kubectl apply -f "$MANIFESTS_DIR/01-namespace.yaml"

# Apply master components
echo "  → Applying master server..."
kubectl apply -f "$MANIFESTS_DIR/02-master.yaml"

# Wait for master to be ready before deploying volume servers
echo ""
echo "⏳ Waiting for master server..."
kubectl rollout status statefulset/seaweedfs-master -n "$NAMESPACE" --timeout=180s

# Apply volume server
echo ""
echo "  → Applying volume servers..."
kubectl apply -f "$MANIFESTS_DIR/03-volume.yaml"

# Wait for volume servers to be ready
echo ""
echo "⏳ Waiting for volume servers..."
kubectl rollout status statefulset/seaweedfs-volume -n "$NAMESPACE" --timeout=180s

# Apply filer with S3 API
echo ""
echo "  → Applying filer and S3 API..."
kubectl apply -f "$MANIFESTS_DIR/04-filer.yaml"

# Wait for filer to be ready
echo ""
echo "⏳ Waiting for filer..."
kubectl rollout status statefulset/seaweedfs-filer -n "$NAMESPACE" --timeout=180s

# Apply services
echo ""
echo "  → Applying services..."
kubectl apply -f "$MANIFESTS_DIR/05-service.yaml"

# Apply TLS certificate
echo "  → Applying TLS certificate..."
if [ -f "$TEMP_DIR/07-tls-secret.yaml" ]; then
    kubectl apply -f "$TEMP_DIR/07-tls-secret.yaml"
else
    kubectl apply -f "$MANIFESTS_DIR/07-tls-secret.yaml"
fi

# Apply ingress
echo "  → Applying ingress..."
kubectl apply -f "$MANIFESTS_DIR/06-ingress.yaml"

echo ""
echo "=========================================="
echo "  ✅ SeaweedFS Deployed"
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
echo "=========================================="
echo "  Access Information"
echo "=========================================="
echo ""
echo "S3 API Endpoint:"
echo "  External: https://seaweedfs-s3.hashicorp.lab"
echo "  Internal: http://seaweedfs-s3.seaweedfs.svc.cluster.local:8333"
echo ""
echo "S3 Credentials (configured in s3.json):"
echo "  Access Key: boundary-access"
echo "  Secret Key: boundary-secret-key-change-me"
echo ""
echo "Filer UI:"
echo "  Internal: http://seaweedfs-filer.seaweedfs.svc.cluster.local:8888"
echo ""
echo "Master UI:"
echo "  Internal: http://seaweedfs-master.seaweedfs.svc.cluster.local:9333"
echo ""
echo "⚠️  Notes:"
echo "  1. Add '127.0.0.1 seaweedfs-s3.hashicorp.lab' to /etc/hosts"
echo "  2. Change default S3 credentials in production"
echo "  3. Certificate is self-signed - add to trusted store or use -k with curl"
echo ""
echo "Testing S3 API:"
echo "  aws s3 --endpoint-url=https://seaweedfs-s3.hashicorp.lab \\"
echo "      --no-verify-ssl \\"
echo "      ls s3://"
echo ""
