#!/bin/bash
set -euo pipefail

# Setup kind cluster for local development
# Creates a local Kubernetes cluster using kind (Kubernetes in Docker)

CLUSTER_NAME="${1:-sandbox}"

echo "=========================================="
echo "  Kind Cluster Setup"
echo "=========================================="
echo ""

# Check Docker
if ! command -v docker &> /dev/null; then
    echo "❌ Docker is required but not installed"
    exit 1
fi

if ! docker info &> /dev/null; then
    echo "❌ Docker is not running"
    exit 1
fi

echo "✅ Docker is running"

# Check/Install kind
if ! command -v kind &> /dev/null; then
    echo "📦 Installing kind..."
    curl -sLo ./kind https://kind.sigs.k8s.io/dl/v0.24.0/kind-linux-amd64
    chmod +x ./kind
    sudo mv ./kind /usr/local/bin/kind
fi

echo "✅ kind $(kind version | cut -d' ' -f2) installed"

# Check/Install kubectl
if ! command -v kubectl &> /dev/null; then
    echo "📦 Installing kubectl..."
    curl -sLO "https://dl.k8s.io/release/$(curl -sL https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
    chmod +x kubectl
    sudo mv kubectl /usr/local/bin/
fi

echo "✅ kubectl installed"

# Check if cluster exists
if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
    echo ""
    echo "⚠️  Cluster '$CLUSTER_NAME' already exists"
    read -p "Delete and recreate? (yes/no): " confirm
    if [[ "$confirm" == "yes" ]]; then
        kind delete cluster --name "$CLUSTER_NAME"
    else
        echo "Using existing cluster"
        kubectl cluster-info --context "kind-${CLUSTER_NAME}"
        exit 0
    fi
fi

echo ""
echo "🚀 Creating kind cluster '$CLUSTER_NAME'..."
echo ""

# Create cluster with custom config for better storage support
cat <<EOF | kind create cluster --name "$CLUSTER_NAME" --config=-
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
    kubeadmConfigPatches:
      - |
        kind: InitConfiguration
        nodeRegistration:
          kubeletExtraArgs:
            node-labels: "ingress-ready=true"
    extraPortMappings:
      - containerPort: 80
        hostPort: 80
        protocol: TCP
      - containerPort: 443
        hostPort: 443
        protocol: TCP
      - containerPort: 9200
        hostPort: 9200
        protocol: TCP
      - containerPort: 9202
        hostPort: 9202
        protocol: TCP
EOF

echo ""
echo "⏳ Waiting for cluster to be ready..."
kubectl wait --for=condition=Ready nodes --all --timeout=60s

echo ""
echo "=========================================="
echo "  ✅ Kind Cluster Ready"
echo "=========================================="
echo ""
echo "Cluster: $CLUSTER_NAME"
kubectl get nodes
echo ""
echo "Storage classes:"
kubectl get storageclass
echo ""
echo "Context set to: kind-${CLUSTER_NAME}"
echo ""
echo "Next steps:"
echo "  1. Deploy devenv:   ./deploy.sh"
echo "  2. Deploy Boundary: ../boundary/scripts/deploy-boundary.sh"
