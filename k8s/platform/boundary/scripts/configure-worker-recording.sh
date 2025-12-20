#!/bin/bash
set -euo pipefail

# Configuration
BOUNDARY_NAMESPACE="${1:-boundary}"

echo "=========================================="
echo "  Configure Boundary Worker for Recording"
echo "=========================================="
echo ""

# Check if boundary namespace exists
if ! kubectl get namespace "$BOUNDARY_NAMESPACE" &> /dev/null; then
    echo "❌ Boundary namespace not found: $BOUNDARY_NAMESPACE"
    exit 1
fi

# Check if worker ConfigMap exists
if ! kubectl get configmap boundary-worker-config -n "$BOUNDARY_NAMESPACE" &> /dev/null; then
    echo "❌ Worker ConfigMap not found: boundary-worker-config"
    exit 1
fi

# Get current worker config
echo "📋 Reading current worker configuration..."
CURRENT_CONFIG=$(kubectl get configmap boundary-worker-config -n "$BOUNDARY_NAMESPACE" -o jsonpath='{.data.worker\.hcl}')

# Check if recording block already exists
if echo "$CURRENT_CONFIG" | grep -q "recording {"; then
    echo "✅ Worker recording configuration already exists"
    echo ""
    echo "Current recording configuration:"
    echo "$CURRENT_CONFIG" | sed -n '/recording {/,/^}/p' | sed 's/^/  /'
    echo ""
    echo "ℹ️  To update the configuration, edit the ConfigMap manually or delete the recording block first"
    exit 0
fi

# Add recording block to worker config
echo "📝 Adding recording configuration to worker..."

# Create new config with recording block
NEW_CONFIG=$(cat <<'EOF'
disable_mlock = true

worker {
  name = "kubernetes-worker"
  initial_upstreams = ["boundary-controller-cluster.boundary.svc.cluster.local:9201"]
  # Uses hostPort exposed via Kind extraPortMappings (see k8s/scripts/kind-config.yaml)
  public_addr = "127.0.0.1:9202"

  recording_storage_path = "/boundary/recordings"
}

listener "tcp" {
  address = "0.0.0.0:9202"
  purpose = "proxy"
  tls_disable = true
}

listener "tcp" {
  address = "0.0.0.0:9203"
  purpose = "ops"
  tls_disable = true
}

kms "aead" {
  purpose = "worker-auth"
  aead_type = "aes-gcm"
  key = "154136488afcad54ccf54df95342a6a5"
  key_id = "global_worker-auth"
}
EOF
)

# Update ConfigMap
echo "  → Updating worker ConfigMap..."
kubectl create configmap boundary-worker-config \
    --from-literal=worker.hcl="$NEW_CONFIG" \
    -n "$BOUNDARY_NAMESPACE" \
    --dry-run=client -o yaml | \
    kubectl apply -f - > /dev/null

echo "✅ Worker ConfigMap updated"
echo ""

# Restart worker to apply new configuration
echo "🔄 Restarting worker to apply configuration..."
WORKER_POD=$(kubectl get pods -n "$BOUNDARY_NAMESPACE" -o name | grep "boundary-worker" | head -1 | cut -d'/' -f2)

if [ -z "$WORKER_POD" ]; then
    echo "⚠️  No worker pod found - configuration will apply on next pod start"
else
    kubectl delete pod "$WORKER_POD" -n "$BOUNDARY_NAMESPACE"
    echo "✅ Worker pod deleted (will be recreated automatically)"
    echo ""

    # Wait for new pod to be ready
    echo "⏳ Waiting for new worker pod to be ready..."
    kubectl wait --for=condition=ready pod \
        -l app=boundary-worker \
        -n "$BOUNDARY_NAMESPACE" \
        --timeout=120s 2>&1 | grep -v "error:" || true

    NEW_WORKER_POD=$(kubectl get pods -n "$BOUNDARY_NAMESPACE" -o name | grep "boundary-worker" | head -1 | cut -d'/' -f2)

    if [ -n "$NEW_WORKER_POD" ]; then
        echo "✅ New worker pod ready: $NEW_WORKER_POD"
    fi
fi

echo ""
echo "=========================================="
echo "  ✅ Worker Recording Configured"
echo "=========================================="
echo ""
echo "Worker configuration updated with:"
echo "  • Recording storage path: /boundary/recordings"
echo ""
echo "Next Steps:"
echo "  1. Create storage bucket: ./configure-storage-bucket.sh"
echo "  2. Enable recording on target: ./configure-session-recording.sh"
echo ""
