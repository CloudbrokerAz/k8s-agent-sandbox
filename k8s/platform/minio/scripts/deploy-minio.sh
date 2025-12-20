#!/bin/bash
set -euo pipefail

NAMESPACE="${1:-minio}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFESTS_DIR="$SCRIPT_DIR/../manifests"
TEMP_DIR=$(mktemp -d)

# Cleanup temporary directory on exit
cleanup() {
    rm -rf "$TEMP_DIR"
}
trap cleanup EXIT

echo "=========================================="
echo "  MinIO Deployment"
echo "=========================================="
echo ""

# Check cluster connectivity
if ! kubectl cluster-info &> /dev/null; then
    echo "❌ Cannot connect to Kubernetes cluster"
    exit 1
fi

echo "✅ Connected to Kubernetes cluster"
echo ""

# Generate TLS certificates if they don't exist
echo "🔒 Checking TLS certificates..."
if kubectl get secret minio-tls -n "$NAMESPACE" &> /dev/null; then
    echo "  → TLS certificates already exist, skipping generation"
else
    echo "  → Generating self-signed TLS certificates..."

    # MinIO API certificate
    openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
        -keyout "$TEMP_DIR/minio.key" \
        -out "$TEMP_DIR/minio.crt" \
        -subj "/CN=minio.hashicorp.lab" \
        -addext "subjectAltName=DNS:minio.hashicorp.lab,DNS:localhost,IP:127.0.0.1" \
        2>/dev/null

    # MinIO Console certificate
    openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
        -keyout "$TEMP_DIR/minio-console.key" \
        -out "$TEMP_DIR/minio-console.crt" \
        -subj "/CN=minio-console.hashicorp.lab" \
        -addext "subjectAltName=DNS:minio-console.hashicorp.lab,DNS:localhost,IP:127.0.0.1" \
        2>/dev/null

    echo "  → TLS certificates generated"
fi

echo ""
echo "📦 Deploying MinIO components..."

# Apply namespace first
echo "  → Applying namespace..."
kubectl apply -f "$MANIFESTS_DIR/01-namespace.yaml"

# Apply deployment and service
echo "  → Applying deployment and service..."
kubectl apply -f "$MANIFESTS_DIR/02-deployment.yaml"

# Wait for deployment to be ready
echo ""
echo "⏳ Waiting for MinIO deployment..."
kubectl rollout status deployment/minio -n "$NAMESPACE" --timeout=180s

# Apply TLS certificates
echo ""
echo "  → Applying TLS certificates..."
if [ -f "$TEMP_DIR/minio.crt" ]; then
    kubectl create secret tls minio-tls \
        -n "$NAMESPACE" \
        --cert="$TEMP_DIR/minio.crt" \
        --key="$TEMP_DIR/minio.key" \
        --dry-run=client -o yaml | kubectl apply -f -

    kubectl create secret tls minio-console-tls \
        -n "$NAMESPACE" \
        --cert="$TEMP_DIR/minio-console.crt" \
        --key="$TEMP_DIR/minio-console.key" \
        --dry-run=client -o yaml | kubectl apply -f -
else
    kubectl apply -f "$MANIFESTS_DIR/04-tls-secret.yaml"
fi

# Apply ingress
echo "  → Applying ingress..."
kubectl apply -f "$MANIFESTS_DIR/03-ingress.yaml"

echo ""
echo "=========================================="
echo "  ✅ MinIO Deployed"
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
echo "  External: https://minio.hashicorp.lab"
echo "  Internal: http://minio.minio.svc.cluster.local:9000"
echo ""
echo "MinIO Console:"
echo "  External: https://minio-console.hashicorp.lab"
echo ""
echo "S3 Credentials:"
echo "  Access Key: boundary-access"
echo "  Secret Key: boundary-secret-key-change-me"
echo ""
echo "⚠️  Notes:"
echo "  1. Add to /etc/hosts:"
echo "     127.0.0.1 minio.hashicorp.lab minio-console.hashicorp.lab"
echo "  2. Change default credentials in production"
echo "  3. Certificates are self-signed - add to trusted store or use -k with curl"
echo ""
echo "Testing S3 API:"
echo "  aws s3 --endpoint-url=https://minio.hashicorp.lab \\"
echo "      --no-verify-ssl \\"
echo "      mb s3://boundary-recordings"
echo ""
