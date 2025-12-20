#!/bin/bash
set -euo pipefail

# Configuration
BOUNDARY_NAMESPACE="${1:-boundary}"

echo "=========================================="
echo "  Configure BSR KMS for Session Recording"
echo "=========================================="
echo ""

# Check if boundary namespace exists
if ! kubectl get namespace "$BOUNDARY_NAMESPACE" &> /dev/null; then
    echo "❌ Boundary namespace not found: $BOUNDARY_NAMESPACE"
    exit 1
fi

echo "🔍 Checking current controller configuration..."

# Get current controller config
CURRENT_CONFIG=$(kubectl get configmap boundary-controller-config -n "$BOUNDARY_NAMESPACE" -o jsonpath='{.data.controller\.hcl}')

# Check if BSR KMS already exists
if echo "$CURRENT_CONFIG" | grep -q 'purpose = "bsr"'; then
    echo "✅ BSR KMS configuration already exists"
    echo ""
    echo "Current BSR KMS configuration:"
    echo "$CURRENT_CONFIG" | grep -A 4 'purpose = "bsr"'
    exit 0
fi

echo "📝 Adding BSR KMS configuration..."

# Generate a random key for BSR
BSR_KEY=$(openssl rand -hex 16)
BSR_KEY_ID="global_bsr"

echo "  Generated BSR key: $BSR_KEY"
echo "  Key ID: $BSR_KEY_ID"
echo ""

# Create new config with BSR KMS block
NEW_CONFIG=$(cat <<EOF
disable_mlock = true

controller {
  name = "kubernetes-controller"
  description = "Boundary controller running in Kubernetes"
  public_cluster_addr = "boundary-controller-cluster.boundary.svc.cluster.local:9201"
  database {
    url = "postgresql://boundary:60cff98427904364143517b6b32bf404@boundary-postgres.boundary.svc.cluster.local:5432/boundary?sslmode=disable"
  }
}

listener "tcp" {
  address = "0.0.0.0:9200"
  purpose = "api"
  tls_disable = true
}

listener "tcp" {
  address = "0.0.0.0:9201"
  purpose = "cluster"
  tls_disable = true
}

listener "tcp" {
  address = "0.0.0.0:9203"
  purpose = "ops"
  tls_disable = true
}

kms "aead" {
  purpose = "root"
  aead_type = "aes-gcm"
  key = "0d2eda11552c9689d88df25ef90f22ec"
  key_id = "global_root"
}

kms "aead" {
  purpose = "worker-auth"
  aead_type = "aes-gcm"
  key = "154136488afcad54ccf54df95342a6a5"
  key_id = "global_worker-auth"
}

kms "aead" {
  purpose = "recovery"
  aead_type = "aes-gcm"
  key = "a9eff918b0f2d0fc063cb7870d815482"
  key_id = "global_recovery"
}

kms "aead" {
  purpose = "bsr"
  aead_type = "aes-gcm"
  key = "$BSR_KEY"
  key_id = "$BSR_KEY_ID"
}
EOF
)

# Update the configmap
echo "📝 Updating controller ConfigMap..."
kubectl create configmap boundary-controller-config \
  --from-literal=controller.hcl="$NEW_CONFIG" \
  -n "$BOUNDARY_NAMESPACE" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "✅ ConfigMap updated"
echo ""

# Restart controller to apply new configuration
echo "🔄 Restarting Boundary controller..."
kubectl rollout restart deployment/boundary-controller -n "$BOUNDARY_NAMESPACE"

echo "⏳ Waiting for controller to be ready..."
kubectl rollout status deployment/boundary-controller -n "$BOUNDARY_NAMESPACE" --timeout=180s

echo ""
echo "=========================================="
echo "  ✅ BSR KMS Configured"
echo "=========================================="
echo ""
echo "BSR KMS Details:"
echo "  Purpose: bsr (Boundary Session Recording)"
echo "  Algorithm: aes-gcm"
echo "  Key ID: $BSR_KEY_ID"
echo "  Key: $BSR_KEY"
echo ""
echo "⚠️  IMPORTANT: Save this key securely!"
echo "   Add to your credentials file for backup"
echo ""
echo "Next Steps:"
echo "  1. Test session recording connection:"
echo "     boundary connect ssh -target-id=tssh_RrlYVTBgBN"
echo ""
echo "  2. Verify recording is created in MinIO"
echo ""
