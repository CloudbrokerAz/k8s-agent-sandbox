#!/bin/bash
set -euo pipefail

# Master deployment script for the complete K8s platform
# Deploys: DevEnv, Boundary, Vault, and Vault Secrets Operator

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
K8S_DIR="$(dirname "$SCRIPT_DIR")"

# Source configuration
# Copy platform.env.example to .env and customize for your environment
if [[ -f "$SCRIPT_DIR/.env" ]]; then
    source "$SCRIPT_DIR/.env"
elif [[ -f "$SCRIPT_DIR/platform.env.example" ]]; then
    source "$SCRIPT_DIR/platform.env.example"
fi

# Apply configuration defaults
DEVENV_NAMESPACE="${DEVENV_NAMESPACE:-devenv}"
VAULT_NAMESPACE="${VAULT_NAMESPACE:-vault}"
BOUNDARY_NAMESPACE="${BOUNDARY_NAMESPACE:-boundary}"
VSO_NAMESPACE="${VSO_NAMESPACE:-vault-secrets-operator-system}"
DEPLOY_BOUNDARY="${DEPLOY_BOUNDARY:-true}"
DEPLOY_VAULT="${DEPLOY_VAULT:-true}"
DEPLOY_VSO="${DEPLOY_VSO:-true}"
BUILD_IMAGE="${BUILD_IMAGE:-true}"
DOCKER_REGISTRY="${DOCKER_REGISTRY:-}"
IMAGE_NAME="${IMAGE_NAME:-agent-sandbox}"
IMAGE_TAG="${IMAGE_TAG:-latest}"
DEBUG="${DEBUG:-false}"

[[ "$DEBUG" == "true" ]] && set -x

echo "=========================================="
echo "  Complete Platform Deployment"
echo "=========================================="
echo ""
echo "This script will deploy:"
echo "  0. Build Agent Sandbox image (optional)"
echo "  1. Agent Sandbox - Multi-user development environment"
echo "  2. Vault - Secrets management"
echo "  3. Boundary - Secure access management"
echo "  4. Vault Secrets Operator - Secret synchronization"
echo ""

# Check prerequisites
echo "Checking prerequisites..."

if ! command -v kubectl &> /dev/null; then
    echo "❌ kubectl not found"
    exit 1
fi

if ! command -v helm &> /dev/null; then
    echo "📦 Installing Helm..."
    curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
fi

if ! kubectl cluster-info &> /dev/null; then
    echo "❌ Cannot connect to Kubernetes cluster"
    echo ""
    echo "To create a local cluster:"
    echo "  ./setup-kind.sh"
    exit 1
fi

echo "✅ Prerequisites met"
echo ""

# Check for existing deployments
EXISTING=""
kubectl get ns devenv &>/dev/null && EXISTING="$EXISTING devenv"
kubectl get ns boundary &>/dev/null && EXISTING="$EXISTING boundary"
kubectl get ns vault &>/dev/null && EXISTING="$EXISTING vault"
kubectl get ns vault-secrets-operator-system &>/dev/null && EXISTING="$EXISTING vso"

if [[ -n "$EXISTING" ]]; then
    echo "⚠️  Existing deployments found:$EXISTING"
    read -p "Continue and update? (yes/no): " confirm
    if [[ "$confirm" != "yes" ]]; then
        echo "Cancelled"
        exit 0
    fi
fi

# ==========================================
# Step 0: Build Agent Sandbox Image
# ==========================================

if [[ "$BUILD_IMAGE" == "true" ]]; then
    echo ""
    echo "=========================================="
    echo "  Step 0: Build Agent Sandbox Image"
    echo "=========================================="
    echo ""

    if ! command -v docker &> /dev/null; then
        echo "Docker not found, skipping image build"
        echo "Using sandbox-override.yaml with ubuntu:22.04"
        BUILD_IMAGE="false"
    else
        DOCKERFILE="$K8S_DIR/Dockerfile.production"
        if [[ ! -f "$DOCKERFILE" ]]; then
            echo "Dockerfile not found at $DOCKERFILE"
            echo "Using sandbox-override.yaml with ubuntu:22.04"
            BUILD_IMAGE="false"
        else
            # Determine full image name
            if [[ -n "$DOCKER_REGISTRY" ]]; then
                FULL_IMAGE="${DOCKER_REGISTRY}/${IMAGE_NAME}:${IMAGE_TAG}"
            else
                FULL_IMAGE="${IMAGE_NAME}:${IMAGE_TAG}"
            fi

            echo "Building image: $FULL_IMAGE"
            echo "Using Dockerfile: $DOCKERFILE"
            echo ""

            # Build the image
            if docker build -t "$FULL_IMAGE" -f "$DOCKERFILE" "$K8S_DIR/.." ; then
                echo "✅ Image built successfully: $FULL_IMAGE"

                # Load into Kind cluster if using Kind
                if kind get clusters 2>/dev/null | grep -q "${KIND_CLUSTER_NAME:-sandbox}"; then
                    echo "Loading image into Kind cluster..."
                    kind load docker-image "$FULL_IMAGE" --name "${KIND_CLUSTER_NAME:-sandbox}"
                    echo "✅ Image loaded into Kind"
                elif [[ -n "$DOCKER_REGISTRY" ]]; then
                    echo "Pushing image to registry..."
                    if docker push "$FULL_IMAGE"; then
                        echo "✅ Image pushed to registry"
                    else
                        echo "⚠️  Failed to push image, continuing with local image"
                    fi
                fi

                # Update the image reference in the statefulset
                USE_CUSTOM_IMAGE="true"
            else
                echo "❌ Image build failed"
                echo "Falling back to ubuntu:22.04"
                BUILD_IMAGE="false"
            fi
        fi
    fi
fi

echo ""
echo "=========================================="
echo "  Step 1: Deploy Agent Sandbox"
echo "=========================================="
echo ""

# Create devenv namespace and secrets
kubectl create namespace devenv --dry-run=client -o yaml | kubectl apply -f -

# Check if secrets exist
if ! kubectl get secret devenv-secrets -n devenv &>/dev/null; then
    echo "Creating placeholder secrets..."
    kubectl create secret generic devenv-secrets \
        --namespace=devenv \
        --from-literal=GITHUB_TOKEN=placeholder \
        --from-literal=TFE_TOKEN=placeholder \
        --from-literal=AWS_ACCESS_KEY_ID=placeholder \
        --from-literal=AWS_SECRET_ACCESS_KEY=placeholder \
        --dry-run=client -o yaml | kubectl apply -f -
    echo "⚠️  Update devenv-secrets with real values later"
fi

# Apply devenv manifests
kubectl apply -f "$K8S_DIR/agent-sandbox/manifests/01-namespace.yaml"
kubectl apply -f "$K8S_DIR/agent-sandbox/manifests/06-service.yaml"

# Deploy with appropriate image
if [[ "${USE_CUSTOM_IMAGE:-false}" == "true" ]]; then
    echo "Deploying with custom image: $FULL_IMAGE"
    # Create a temporary manifest with the custom image
    sed "s|image:.*|image: ${FULL_IMAGE}|g" "$K8S_DIR/agent-sandbox/manifests/05-statefulset.yaml" | kubectl apply -f -
elif [[ -f "$K8S_DIR/agent-sandbox/manifests/sandbox-override.yaml" ]]; then
    echo "Deploying with sandbox override (ubuntu:22.04)"
    kubectl apply -f "$K8S_DIR/agent-sandbox/manifests/sandbox-override.yaml"
else
    kubectl apply -f "$K8S_DIR/agent-sandbox/manifests/05-statefulset.yaml"
fi

# Wait for pod to be ready
echo "Waiting for agent-sandbox pod..."
kubectl rollout status statefulset/devenv -n devenv --timeout=300s || true

echo "✅ DevEnv deployed"

echo ""
echo "=========================================="
echo "  Step 2: Deploy Vault"
echo "=========================================="
echo ""

kubectl apply -f "$K8S_DIR/platform/vault/manifests/01-namespace.yaml"
kubectl apply -f "$K8S_DIR/platform/vault/manifests/03-configmap.yaml"
kubectl apply -f "$K8S_DIR/platform/vault/manifests/04-rbac.yaml"
kubectl apply -f "$K8S_DIR/platform/vault/manifests/05-statefulset.yaml"
kubectl apply -f "$K8S_DIR/platform/vault/manifests/06-service.yaml"

echo "⏳ Waiting for Vault..."
kubectl rollout status statefulset/vault -n vault --timeout=180s

# Initialize Vault
echo "Initializing Vault..."
sleep 5
VAULT_STATUS=$(kubectl exec -n vault vault-0 -- vault status -format=json 2>/dev/null || echo '{"initialized":false}')
INITIALIZED=$(echo "$VAULT_STATUS" | jq -r '.initialized')

if [[ "$INITIALIZED" == "false" ]]; then
    INIT_OUTPUT=$(kubectl exec -n vault vault-0 -- vault operator init -key-shares=1 -key-threshold=1 -format=json)
    UNSEAL_KEY=$(echo "$INIT_OUTPUT" | jq -r '.unseal_keys_b64[0]')
    ROOT_TOKEN=$(echo "$INIT_OUTPUT" | jq -r '.root_token')

    kubectl exec -n vault vault-0 -- vault operator unseal "$UNSEAL_KEY"

    cat > "$K8S_DIR/platform/vault/scripts/vault-keys.txt" << EOF
========================================
  VAULT KEYS - SAVE SECURELY!
========================================
Unseal Key: $UNSEAL_KEY
Root Token: $ROOT_TOKEN
========================================
EOF
    chmod 600 "$K8S_DIR/platform/vault/scripts/vault-keys.txt"
    echo "✅ Vault initialized - keys saved to platform/vault/scripts/vault-keys.txt"
else
    echo "✅ Vault already initialized"
    ROOT_TOKEN=$(grep "Root Token:" "$K8S_DIR/platform/vault/scripts/vault-keys.txt" 2>/dev/null | awk '{print $3}' || echo "")
fi

# Configure Vault basics
if [[ -n "$ROOT_TOKEN" ]]; then
    K8S_HOST="https://kubernetes.default.svc"
    K8S_CA_CERT=$(kubectl config view --raw --minify --flatten -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' | base64 -d)

    kubectl exec -n vault vault-0 -- sh -c "
        export VAULT_TOKEN='$ROOT_TOKEN'
        vault auth enable kubernetes 2>/dev/null || true
        vault write auth/kubernetes/config kubernetes_host='$K8S_HOST' kubernetes_ca_cert='$K8S_CA_CERT' disable_local_ca_jwt=false
        vault secrets enable -path=secret kv-v2 2>/dev/null || true
        vault secrets enable -path=ssh ssh 2>/dev/null || true
        vault secrets enable -path=terraform terraform 2>/dev/null || true
    " 2>/dev/null
    echo "✅ Vault configured"
fi

echo ""
echo "=========================================="
echo "  Step 3: Deploy Boundary"
echo "=========================================="
echo ""

# Create boundary namespace and secrets
kubectl create namespace boundary --dry-run=client -o yaml | kubectl apply -f -

if ! kubectl get secret boundary-db-secrets -n boundary &>/dev/null; then
    ROOT_KEY=$(openssl rand -hex 16)
    WORKER_KEY=$(openssl rand -hex 16)
    RECOVERY_KEY=$(openssl rand -hex 16)
    POSTGRES_PASSWORD=$(openssl rand -base64 16 | tr -d '\n')

    kubectl create secret generic boundary-db-secrets \
        --namespace=boundary \
        --from-literal=POSTGRES_USER=boundary \
        --from-literal=POSTGRES_PASSWORD="$POSTGRES_PASSWORD" \
        --dry-run=client -o yaml | kubectl apply -f -

    kubectl create secret generic boundary-kms-keys \
        --namespace=boundary \
        --from-literal=BOUNDARY_ROOT_KEY="$ROOT_KEY" \
        --from-literal=BOUNDARY_WORKER_AUTH_KEY="$WORKER_KEY" \
        --from-literal=BOUNDARY_RECOVERY_KEY="$RECOVERY_KEY" \
        --dry-run=client -o yaml | kubectl apply -f -

    # Create configmaps with embedded keys
    POSTGRES_USER="boundary"
    cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: boundary-controller-config
  namespace: boundary
data:
  controller.hcl: |
    disable_mlock = true
    controller {
      name = "kubernetes-controller"
      database {
        url = "postgresql://${POSTGRES_USER}:${POSTGRES_PASSWORD}@boundary-postgres.boundary.svc.cluster.local:5432/boundary?sslmode=disable"
      }
    }
    listener "tcp" { address = "0.0.0.0:9200"; purpose = "api"; tls_disable = true }
    listener "tcp" { address = "0.0.0.0:9201"; purpose = "cluster"; tls_disable = true }
    listener "tcp" { address = "0.0.0.0:9203"; purpose = "ops"; tls_disable = true }
    kms "aead" { purpose = "root"; aead_type = "aes-gcm"; key = "${ROOT_KEY}"; key_id = "global_root" }
    kms "aead" { purpose = "worker-auth"; aead_type = "aes-gcm"; key = "${WORKER_KEY}"; key_id = "global_worker-auth" }
    kms "aead" { purpose = "recovery"; aead_type = "aes-gcm"; key = "${RECOVERY_KEY}"; key_id = "global_recovery" }
EOF

    cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: boundary-worker-config
  namespace: boundary
data:
  worker.hcl: |
    disable_mlock = true
    worker {
      name = "kubernetes-worker"
      controllers = ["boundary-controller-cluster.boundary.svc.cluster.local:9201"]
      public_addr = "boundary-worker.boundary.svc.cluster.local:9202"
    }
    listener "tcp" { address = "0.0.0.0:9202"; purpose = "proxy"; tls_disable = true }
    listener "tcp" { address = "0.0.0.0:9203"; purpose = "ops"; tls_disable = true }
    kms "aead" { purpose = "worker-auth"; aead_type = "aes-gcm"; key = "${WORKER_KEY}"; key_id = "global_worker-auth" }
EOF
fi

# Deploy Boundary components
kubectl apply -f "$K8S_DIR/platform/boundary/manifests/01-namespace.yaml"
kubectl apply -f "$K8S_DIR/platform/boundary/manifests/04-postgres.yaml"

echo "⏳ Waiting for PostgreSQL..."
kubectl rollout status statefulset/boundary-postgres -n boundary --timeout=120s

# Initialize database
if ! kubectl get job boundary-db-init -n boundary &>/dev/null; then
    ROOT_KEY=$(kubectl get secret boundary-kms-keys -n boundary -o jsonpath='{.data.BOUNDARY_ROOT_KEY}' | base64 -d)
    WORKER_KEY=$(kubectl get secret boundary-kms-keys -n boundary -o jsonpath='{.data.BOUNDARY_WORKER_AUTH_KEY}' | base64 -d)
    RECOVERY_KEY=$(kubectl get secret boundary-kms-keys -n boundary -o jsonpath='{.data.BOUNDARY_RECOVERY_KEY}' | base64 -d)
    POSTGRES_USER=$(kubectl get secret boundary-db-secrets -n boundary -o jsonpath='{.data.POSTGRES_USER}' | base64 -d)
    POSTGRES_PASSWORD=$(kubectl get secret boundary-db-secrets -n boundary -o jsonpath='{.data.POSTGRES_PASSWORD}' | base64 -d)

    cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: boundary-init-config
  namespace: boundary
data:
  init.hcl: |
    disable_mlock = true
    controller {
      name = "init"
      database { url = "postgresql://${POSTGRES_USER}:${POSTGRES_PASSWORD}@boundary-postgres.boundary.svc.cluster.local:5432/boundary?sslmode=disable" }
    }
    kms "aead" { purpose = "root"; aead_type = "aes-gcm"; key = "${ROOT_KEY}"; key_id = "global_root" }
    kms "aead" { purpose = "worker-auth"; aead_type = "aes-gcm"; key = "${WORKER_KEY}"; key_id = "global_worker-auth" }
    kms "aead" { purpose = "recovery"; aead_type = "aes-gcm"; key = "${RECOVERY_KEY}"; key_id = "global_recovery" }
EOF

    cat <<EOF | kubectl apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: boundary-db-init
  namespace: boundary
spec:
  template:
    spec:
      restartPolicy: Never
      containers:
      - name: init
        image: hashicorp/boundary:0.17
        command: ["boundary", "database", "init", "-config=/config/init.hcl"]
        volumeMounts:
        - name: config
          mountPath: /config
      volumes:
      - name: config
        configMap:
          name: boundary-init-config
  backoffLimit: 1
EOF
    echo "⏳ Initializing Boundary database..."
    kubectl wait --for=condition=complete job/boundary-db-init -n boundary --timeout=60s || true
fi

kubectl apply -f "$K8S_DIR/platform/boundary/manifests/05-controller.yaml"
kubectl apply -f "$K8S_DIR/platform/boundary/manifests/06-worker.yaml"
kubectl apply -f "$K8S_DIR/platform/boundary/manifests/07-service.yaml"

echo "✅ Boundary deployed"

echo ""
echo "=========================================="
echo "  Step 4: Deploy Vault Secrets Operator"
echo "=========================================="
echo ""

helm repo add hashicorp https://helm.releases.hashicorp.com 2>/dev/null || true
helm repo update

kubectl apply -f "$K8S_DIR/platform/vault-secrets-operator/manifests/01-namespace.yaml"

helm upgrade --install vault-secrets-operator hashicorp/vault-secrets-operator \
    --namespace vault-secrets-operator-system \
    --set defaultVaultConnection.enabled=false \
    --set defaultAuthMethod.enabled=false \
    --wait --timeout 5m

# Apply VSO custom resources
kubectl apply -f "$K8S_DIR/platform/vault-secrets-operator/manifests/02-vaultconnection.yaml"
kubectl apply -f "$K8S_DIR/platform/vault-secrets-operator/manifests/03-vaultauth.yaml"

# Configure Vault for VSO
if [[ -n "$ROOT_TOKEN" ]]; then
    kubectl exec -n vault vault-0 -- sh -c "
        export VAULT_TOKEN='$ROOT_TOKEN'
        vault policy write vault-secrets-operator - <<'POLICY'
path \"secret/*\" { capabilities = [\"read\", \"list\"] }
path \"ssh/*\" { capabilities = [\"read\", \"list\", \"create\", \"update\"] }
path \"terraform/*\" { capabilities = [\"read\", \"list\"] }
POLICY
        vault policy write devenv-secrets - <<'POLICY'
path \"secret/data/devenv/*\" { capabilities = [\"read\", \"list\"] }
path \"ssh/sign/devenv-access\" { capabilities = [\"create\", \"update\"] }
path \"terraform/creds/*\" { capabilities = [\"read\"] }
POLICY
        vault write auth/kubernetes/role/vault-secrets-operator bound_service_account_names=vault-secrets-operator-controller-manager bound_service_account_namespaces=vault-secrets-operator-system policies=vault-secrets-operator ttl=1h
        vault write auth/kubernetes/role/devenv-secrets bound_service_account_names='*' bound_service_account_namespaces=devenv policies=devenv-secrets ttl=1h
        vault kv put secret/devenv/credentials username=devenv-user password=change-me api_key=change-me
    " 2>/dev/null
fi

# Apply example secret sync
kubectl apply -f "$K8S_DIR/platform/vault-secrets-operator/manifests/04-vaultstaticsecret-example.yaml"

echo "✅ Vault Secrets Operator deployed"

echo ""
echo "=========================================="
echo "  Waiting for all pods..."
echo "=========================================="
sleep 15

echo ""
echo "=========================================="
echo "  ✅ DEPLOYMENT COMPLETE"
echo "=========================================="
echo ""
echo "Status:"
kubectl get pods -A 2>/dev/null | grep -E "(devenv|boundary|vault)" || true
echo ""
echo "Services:"
kubectl get svc -n devenv 2>/dev/null || true
kubectl get svc -n boundary 2>/dev/null || true
kubectl get svc -n vault 2>/dev/null || true
echo ""
echo "=========================================="
echo "  Next Steps"
echo "=========================================="
echo ""
echo "1. Access DevEnv:"
echo "   kubectl exec -it -n devenv devenv-0 -- /bin/bash"
echo ""
echo "2. Port-forward to Vault UI:"
echo "   kubectl port-forward -n vault vault-0 8200:8200"
echo "   Open: http://localhost:8200"
echo ""
echo "3. Configure additional secrets engines:"
echo "   ./platform/vault/scripts/configure-ssh-engine.sh"
echo "   ./platform/vault/scripts/configure-tfe-engine.sh"
echo ""
echo "4. View synced secrets:"
echo "   kubectl get secret devenv-vault-secrets -n devenv -o yaml"
echo ""
echo "5. Update real credentials:"
echo "   kubectl edit secret devenv-secrets -n devenv"
echo ""
