#!/bin/bash
set -euo pipefail

# Create Boundary secrets for Kubernetes deployment
# Following pattern from scripts/create-secrets.sh in the k8s root

NAMESPACE="${1:-boundary}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=========================================="
echo "  Boundary Secrets Creation"
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

# Create namespace if it doesn't exist
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f - > /dev/null 2>&1
echo "✅ Namespace '$NAMESPACE' ready"
echo ""

# Function to generate random base64 key
generate_key() {
    openssl rand -base64 32 | tr -d '\n'
}

# Function to read secret with prompt
read_secret() {
    local prompt="$1"
    local var_name="$2"
    local default="$3"

    if [[ -n "$default" ]]; then
        echo -n "$prompt [auto-generated]: "
        read -r value
        if [[ -z "$value" ]]; then
            value="$default"
            echo "  → Using generated value"
        fi
    else
        echo -n "$prompt: "
        read -rs value
        echo ""
    fi

    eval "$var_name='$value'"
}

echo "📦 Database Credentials"
echo "------------------------"
read_secret "PostgreSQL username" POSTGRES_USER "boundary"
read_secret "PostgreSQL password (leave blank to generate)" POSTGRES_PASSWORD "$(generate_key)"

echo ""
echo "🔐 KMS Keys (AEAD)"
echo "------------------------"
echo "Generating cryptographic keys for Boundary..."
BOUNDARY_ROOT_KEY=$(generate_key)
BOUNDARY_WORKER_AUTH_KEY=$(generate_key)
BOUNDARY_RECOVERY_KEY=$(generate_key)
echo "✅ Keys generated"

echo ""
echo "Creating Kubernetes secrets..."

# Create database secrets
kubectl create secret generic boundary-db-secrets \
    --namespace="$NAMESPACE" \
    --from-literal=POSTGRES_USER="$POSTGRES_USER" \
    --from-literal=POSTGRES_PASSWORD="$POSTGRES_PASSWORD" \
    --dry-run=client -o yaml | kubectl apply -f -

echo "✅ Database secrets created"

# Create KMS keys secrets
kubectl create secret generic boundary-kms-keys \
    --namespace="$NAMESPACE" \
    --from-literal=BOUNDARY_ROOT_KEY="$BOUNDARY_ROOT_KEY" \
    --from-literal=BOUNDARY_WORKER_AUTH_KEY="$BOUNDARY_WORKER_AUTH_KEY" \
    --from-literal=BOUNDARY_RECOVERY_KEY="$BOUNDARY_RECOVERY_KEY" \
    --dry-run=client -o yaml | kubectl apply -f -

echo "✅ KMS keys created"

# Create Enterprise license secret if license file is provided
# Default location: k8s/scripts/license/boundary.hclic
DEFAULT_LICENSE_FILE="$SCRIPT_DIR/../../scripts/license/boundary.hclic"
BOUNDARY_LICENSE_FILE="${BOUNDARY_LICENSE_FILE:-$DEFAULT_LICENSE_FILE}"

if [[ -f "$BOUNDARY_LICENSE_FILE" ]]; then
    echo ""
    echo "🔑 Enterprise License"
    echo "------------------------"
    echo "   Using: $BOUNDARY_LICENSE_FILE"
    kubectl create secret generic boundary-license \
        --namespace="$NAMESPACE" \
        --from-file=license="$BOUNDARY_LICENSE_FILE" \
        --dry-run=client -o yaml | kubectl apply -f -
    echo "✅ Enterprise license secret created"
elif [[ -n "${BOUNDARY_LICENSE:-}" ]]; then
    echo ""
    echo "🔑 Enterprise License"
    echo "------------------------"
    kubectl create secret generic boundary-license \
        --namespace="$NAMESPACE" \
        --from-literal=license="$BOUNDARY_LICENSE" \
        --dry-run=client -o yaml | kubectl apply -f -
    echo "✅ Enterprise license secret created"
else
    echo ""
    echo "ℹ️  No Enterprise license found"
    echo "   Place license at: k8s/scripts/license/boundary.hclic"
    echo "   Or set BOUNDARY_LICENSE_FILE env var"
fi

echo ""
echo "=========================================="
echo "  ⚠️  IMPORTANT: Save Recovery Key!"
echo "=========================================="
echo ""
echo "Recovery Key (save this securely):"
echo "$BOUNDARY_RECOVERY_KEY"
echo ""
echo "This key is required for emergency recovery access."
echo "Store it in a secure location (password manager, vault, etc.)"
echo ""
echo "=========================================="
echo "  ✅ Secrets Created Successfully"
echo "=========================================="
echo ""
echo "Next step: ./deploy-boundary.sh"
