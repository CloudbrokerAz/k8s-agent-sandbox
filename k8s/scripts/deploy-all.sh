#!/bin/bash
set -euo pipefail

# Master deployment script for the complete K8s platform
# Deploys: DevEnv, Boundary, Vault, Vault Secrets Operator, and Keycloak
#
# USAGE:
#   ./deploy-all.sh                     # Full deployment
#   RESUME=auto ./deploy-all.sh         # Resume partial deployment (skip running components)
#   PARALLEL=true ./deploy-all.sh       # Run independent deployments in parallel
#   SKIP_VAULT=true ./deploy-all.sh     # Skip specific components
#
# ENVIRONMENT VARIABLES:
#   RESUME=auto|false     - Auto-detect and skip already-running components
#   PARALLEL=true|false   - Run independent deployments concurrently (default: true)
#   SKIP_DEVENV=true      - Skip Agent Sandbox deployment
#   SKIP_VAULT=true       - Skip Vault deployment
#   SKIP_BOUNDARY=true    - Skip Boundary deployment
#   SKIP_VSO=true         - Skip Vault Secrets Operator deployment
#   BASE_IMAGE=<image>    - Override base image (default: srlynch1/terraform-ai-tools:latest)
#   DEBUG=true            - Enable verbose output
#
# EXAMPLES:
#   # Fresh full deployment
#   ./deploy-all.sh
#
#   # Resume after failure (skips running components)
#   RESUME=auto ./deploy-all.sh
#
#   # Deploy only DevEnv and Vault
#   SKIP_BOUNDARY=true SKIP_VSO=true ./deploy-all.sh
#
#   # Fast parallel deployment with resume
#   RESUME=auto PARALLEL=true ./deploy-all.sh

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
KEYCLOAK_NAMESPACE="${KEYCLOAK_NAMESPACE:-keycloak}"
VSO_NAMESPACE="${VSO_NAMESPACE:-vault-secrets-operator-system}"
DEPLOY_BOUNDARY="${DEPLOY_BOUNDARY:-true}"
DEPLOY_VAULT="${DEPLOY_VAULT:-true}"
DEPLOY_VSO="${DEPLOY_VSO:-true}"
DEPLOY_KEYCLOAK="${DEPLOY_KEYCLOAK:-true}"
CONFIGURE_BOUNDARY_TARGETS="${CONFIGURE_BOUNDARY_TARGETS:-true}"
BASE_IMAGE="${BASE_IMAGE:-srlynch1/terraform-ai-tools:latest}"
DEBUG="${DEBUG:-false}"

[[ "$DEBUG" == "true" ]] && set -x

PARALLEL="${PARALLEL:-true}"
RESUME="${RESUME:-false}"
SKIP_DEVENV="${SKIP_DEVENV:-false}"
SKIP_VAULT="${SKIP_VAULT:-false}"
SKIP_BOUNDARY="${SKIP_BOUNDARY:-false}"
SKIP_VSO="${SKIP_VSO:-false}"

# Auto-detect resume mode based on existing deployments
auto_detect_resume() {
    if kubectl get statefulset vault -n vault &>/dev/null && \
       kubectl get statefulset/vault -n vault -o jsonpath='{.status.readyReplicas}' 2>/dev/null | grep -q "1"; then
        SKIP_VAULT="true"
        echo "  - Vault: running (skip)"
    fi
    if kubectl get deployment boundary-controller -n boundary &>/dev/null && \
       kubectl get deployment/boundary-controller -n boundary -o jsonpath='{.status.readyReplicas}' 2>/dev/null | grep -q "1"; then
        SKIP_BOUNDARY="true"
        echo "  - Boundary: running (skip)"
    fi
    # Check for new Sandbox CRD or legacy StatefulSet
    if kubectl get sandbox claude-code-sandbox -n devenv &>/dev/null || \
       kubectl get pod -l app=claude-code-sandbox -n devenv -o jsonpath='{.items[0].status.phase}' 2>/dev/null | grep -q "Running"; then
        SKIP_DEVENV="true"
        echo "  - Claude Code Sandbox: running (skip)"
    elif kubectl get statefulset devenv -n devenv &>/dev/null && \
       kubectl get statefulset/devenv -n devenv -o jsonpath='{.status.readyReplicas}' 2>/dev/null | grep -q "1"; then
        SKIP_DEVENV="true"
        echo "  - DevEnv (legacy): running (skip)"
    fi
}

echo "=========================================="
echo "  Complete Platform Deployment"
echo "=========================================="
echo ""
echo "This script will deploy:"
echo "  1. Agent Sandbox - Multi-user development environment"
echo "  2. Vault - Secrets management"
echo "  3. Boundary - Secure access management"
echo "  4. Vault Secrets Operator - Secret synchronization"
echo "  5. Keycloak - Identity Provider (optional)"
echo "  6. Boundary Targets & OIDC - Access configuration"
echo ""
echo "Parallel mode: $PARALLEL"
echo ""

# Auto-detect resume if RESUME=auto or existing deployments found
if [[ "$RESUME" == "auto" ]] || [[ -n "${EXISTING:-}" ]]; then
    echo "Detecting existing deployments..."
    auto_detect_resume
    echo ""
fi

# Helper function to run commands in background if parallel mode
run_parallel() {
    if [[ "$PARALLEL" == "true" ]]; then
        "$@" &
    else
        "$@"
    fi
}

# Wait for background jobs if parallel mode and check for failures
wait_parallel() {
    if [[ "$PARALLEL" == "true" ]]; then
        local failed=0
        local job_pids=$(jobs -p)
        for pid in $job_pids; do
            if ! wait "$pid"; then
                ((failed++))
            fi
        done
        if [[ $failed -gt 0 ]]; then
            echo "❌ $failed parallel task(s) failed"
            return 1
        fi
    fi
}

# Get Vault status with retries
# Returns valid JSON or default on failure
# Usage: VAULT_STATUS=$(get_vault_status [max_attempts] [sleep_interval])
get_vault_status() {
    local max_attempts="${1:-5}"
    local sleep_interval="${2:-5}"
    local attempt=1
    local vault_output=""

    while [[ $attempt -le $max_attempts ]]; do
        vault_output=$(kubectl exec -n vault vault-0 -- vault status -format=json 2>/dev/null) || true

        # Check if we got valid JSON
        if echo "$vault_output" | jq -e . >/dev/null 2>&1; then
            echo "$vault_output"
            return 0
        fi

        if [[ $attempt -lt $max_attempts ]]; then
            echo "⚠️  Vault not responding (attempt $attempt/$max_attempts), waiting ${sleep_interval}s..." >&2
            sleep "$sleep_interval"
        fi
        ((attempt++))
    done

    # Return default if all attempts failed
    echo '{"initialized":false,"sealed":true}'
    return 1
}

# Check and install prerequisites
echo "Checking prerequisites..."

# Run the prerequisite check/install script
if [[ -f "$SCRIPT_DIR/check-prereqs.sh" ]]; then
    # Run prereqs script - it will auto-install missing tools
    if ! "$SCRIPT_DIR/check-prereqs.sh"; then
        echo ""
        echo "❌ Prerequisites check failed. Please resolve issues above."
        exit 1
    fi
    echo ""
else
    # Fallback: inline prerequisite checks if script is missing
    echo "⚠️  check-prereqs.sh not found, running inline checks..."

    if ! command -v kubectl &> /dev/null; then
        echo "📦 Installing kubectl..."
        KUBECTL_VERSION=$(curl -fsSL https://dl.k8s.io/release/stable.txt 2>/dev/null || echo "v1.31.0")
        curl -fsSLO "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl"
        chmod +x kubectl
        sudo mv kubectl /usr/local/bin/
        if ! command -v kubectl &> /dev/null; then
            echo "❌ Failed to install kubectl"
            exit 1
        fi
        echo "✅ kubectl installed"
    fi

    if ! command -v helm &> /dev/null; then
        echo "📦 Installing Helm..."
        curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
    fi

    if ! command -v jq &> /dev/null; then
        echo "📦 Installing jq..."
        if command -v apt-get &> /dev/null; then
            sudo apt-get update -qq && sudo apt-get install -y -qq jq
        elif command -v apk &> /dev/null; then
            sudo apk add --no-cache jq
        else
            echo "❌ jq not found and cannot auto-install"
            exit 1
        fi
    fi

    if ! command -v openssl &> /dev/null; then
        echo "📦 Installing openssl..."
        if command -v apt-get &> /dev/null; then
            sudo apt-get update -qq && sudo apt-get install -y -qq openssl
        elif command -v apk &> /dev/null; then
            sudo apk add --no-cache openssl
        else
            echo "❌ openssl not found and cannot auto-install"
            exit 1
        fi
    fi
fi

# Check for Kubernetes cluster - auto-create Kind cluster if not available
if ! kubectl cluster-info &> /dev/null; then
    echo "⚠️  No Kubernetes cluster available"
    echo ""

    # Check if Kind is installed or can be installed
    if command -v docker &> /dev/null && docker info &> /dev/null; then
        echo "Docker is available. Creating Kind cluster..."
        echo ""

        # Run setup-kind.sh to create the cluster
        if [[ -f "$SCRIPT_DIR/setup-kind.sh" ]]; then
            "$SCRIPT_DIR/setup-kind.sh" "${KIND_CLUSTER_NAME:-sandbox}"
        else
            # Fallback: inline Kind cluster creation
            if ! command -v kind &> /dev/null; then
                echo "📦 Installing kind..."
                curl -sLo ./kind https://kind.sigs.k8s.io/dl/v0.24.0/kind-linux-amd64
                chmod +x ./kind
                sudo mv ./kind /usr/local/bin/kind
            fi

            CLUSTER_NAME="${KIND_CLUSTER_NAME:-sandbox}"
            KIND_CONFIG_FILE="$SCRIPT_DIR/kind-config.yaml"
            echo "🚀 Creating kind cluster '$CLUSTER_NAME'..."

            if [[ -f "$KIND_CONFIG_FILE" ]]; then
                echo "   Using config: $KIND_CONFIG_FILE"
                kind create cluster --name "$CLUSTER_NAME" --config="$KIND_CONFIG_FILE"
            else
                echo "   ⚠️  kind-config.yaml not found, using inline config"
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
            fi
            echo "⏳ Waiting for cluster to be ready..."
            kubectl wait --for=condition=Ready nodes --all --timeout=60s
        fi

        echo "✅ Kind cluster created"
    else
        echo "❌ Cannot connect to Kubernetes cluster and Docker is not available"
        echo ""
        echo "Options:"
        echo "  1. Start Docker and run: ./setup-kind.sh"
        echo "  2. Configure kubectl to connect to an existing cluster"
        exit 1
    fi
fi

echo "✅ Prerequisites met"
echo ""

# ==========================================
# Install Nginx Ingress Controller (if not present)
# ==========================================
echo "Checking for ingress controller..."
if ! kubectl get namespace ingress-nginx &>/dev/null; then
    echo "Installing nginx ingress controller for Kind..."

    # Use the Kind-specific ingress controller manifest
    kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml

    echo "⏳ Waiting for ingress controller to be ready..."
    kubectl wait --namespace ingress-nginx \
        --for=condition=ready pod \
        --selector=app.kubernetes.io/component=controller \
        --timeout=60s 2>/dev/null || echo "  ⚠️  Ingress controller may still be starting..."

    echo "✅ Nginx ingress controller installed"
else
    echo "✅ Ingress controller already installed"
fi
echo ""

# Check for Boundary Enterprise license file (only if Boundary will be deployed)
if [[ "${SKIP_BOUNDARY:-false}" != "true" ]]; then
    echo "Checking for Boundary Enterprise license..."
    LICENSE_FILE="$SCRIPT_DIR/license/boundary.hclic"
    if [[ ! -f "$LICENSE_FILE" ]]; then
        echo "❌ Boundary Enterprise license file not found: $LICENSE_FILE"
        echo ""
        echo "   Please ensure the Boundary license file exists at:"
        echo "   k8s/scripts/license/boundary.hclic"
        echo ""
        echo "   To obtain a license:"
        echo "   1. Visit: https://www.hashicorp.com/products/boundary"
        echo "   2. Request a trial or commercial license"
        echo "   3. Save the license file to: $LICENSE_FILE"
        echo ""
        echo "   Or skip Boundary deployment with: SKIP_BOUNDARY=true ./deploy-all.sh"
        exit 1
    fi

    if [[ ! -s "$LICENSE_FILE" ]]; then
        echo "❌ Boundary Enterprise license file is empty: $LICENSE_FILE"
        echo ""
        echo "   Please add a valid Boundary Enterprise license to the file"
        exit 1
    fi

    echo "✅ Boundary Enterprise license file found"
    echo ""
fi

# Check for existing deployments
EXISTING=""
kubectl get ns devenv &>/dev/null && EXISTING="$EXISTING devenv"
kubectl get ns boundary &>/dev/null && EXISTING="$EXISTING boundary"
kubectl get ns vault &>/dev/null && EXISTING="$EXISTING vault"
kubectl get ns vault-secrets-operator-system &>/dev/null && EXISTING="$EXISTING vso"

if [[ -n "$EXISTING" ]]; then
    echo "⚠️  Existing deployments found:$EXISTING"
    if [[ -t 0 ]]; then
        # Interactive mode - ask user
        read -p "Continue and update? (yes/no): " confirm
        if [[ "$confirm" != "yes" ]]; then
            echo "Cancelled"
            exit 0
        fi
    else
        # Non-interactive mode - continue automatically
        echo "Non-interactive mode: continuing with update..."
    fi
fi

echo ""
echo "=========================================="
echo "  Step 1-3: Deploy All Base Components (Parallel)"
echo "=========================================="
echo ""
echo "Deploying Agent Sandbox, Vault, and Boundary in parallel..."
echo ""

# Load base image into Kind cluster (can run in parallel)
load_base_image() {
    echo "[Image] Using image: $BASE_IMAGE"

    # Load into Kind cluster if using Kind
    if kind get clusters 2>/dev/null | grep -q "${KIND_CLUSTER_NAME:-sandbox}"; then
        echo "[Image] Loading into Kind cluster..."
        if docker pull "$BASE_IMAGE" 2>/dev/null && kind load docker-image "$BASE_IMAGE" --name "${KIND_CLUSTER_NAME:-sandbox}"; then
            echo "[Image] ✅ Loaded into Kind cluster"
        else
            echo "[Image] ⚠️  Failed to load, cluster will pull from registry"
        fi
    else
        echo "[Image] Not using Kind cluster, skipping load"
    fi
}

# Deploy Agent Sandbox in background (no dependencies on Vault/Boundary)
deploy_agent_sandbox() {
    if [[ "$SKIP_DEVENV" != "true" ]]; then
        # Use the new kubernetes-sigs/agent-sandbox pattern
        AGENT_SANDBOX_DIR="$K8S_DIR/agent-sandbox"

        if [[ -f "$AGENT_SANDBOX_DIR/deploy.sh" ]]; then
            # Use the new deploy.sh which handles CRD installation
            echo "[AgentSandbox] Deploying using kubernetes-sigs/agent-sandbox pattern..."
            NAMESPACE="$DEVENV_NAMESPACE" "$AGENT_SANDBOX_DIR/deploy.sh"
        else
            # Fallback: manual deployment
            echo "[AgentSandbox] Deploying manually..."

            # Create devenv namespace and secrets
            kubectl create namespace devenv --dry-run=client -o yaml | kubectl apply -f -

            # Check if secrets exist
            if ! kubectl get secret devenv-vault-secrets -n devenv &>/dev/null; then
                echo "[AgentSandbox] Creating placeholder secrets..."
                kubectl create secret generic devenv-vault-secrets \
                    --namespace=devenv \
                    --from-literal=GITHUB_TOKEN=placeholder \
                    --from-literal=TFE_TOKEN=placeholder \
                    --dry-run=client -o yaml | kubectl apply -f -
            fi

            # Apply kustomize manifests
            if [[ -d "$AGENT_SANDBOX_DIR/base" ]]; then
                kubectl apply -k "$AGENT_SANDBOX_DIR/base"
            fi
        fi

        echo "[AgentSandbox] ✅ Deployment initiated"
    else
        echo "[AgentSandbox] Skipping (SKIP_DEVENV=true)"
    fi
}

# Deploy Vault in background
deploy_vault() {
    if [[ "$SKIP_VAULT" != "true" ]]; then
        echo "[Vault] Deploying..."
        kubectl apply -f "$K8S_DIR/platform/vault/manifests/01-namespace.yaml"
        # Apply remaining vault manifests in parallel (all depend on namespace only)
        {
            kubectl apply -f "$K8S_DIR/platform/vault/manifests/03-configmap.yaml" &
            kubectl apply -f "$K8S_DIR/platform/vault/manifests/04-rbac.yaml" &
            kubectl apply -f "$K8S_DIR/platform/vault/manifests/05-statefulset.yaml" &
            kubectl apply -f "$K8S_DIR/platform/vault/manifests/06-service.yaml" &
            kubectl apply -f "$K8S_DIR/platform/vault/manifests/08-tls-secret.yaml" 2>/dev/null &
            kubectl apply -f "$K8S_DIR/platform/vault/manifests/07-ingress.yaml" 2>/dev/null &
            wait
        }
        echo "[Vault] ✅ Manifests applied"
    else
        echo "[Vault] Skipping (SKIP_VAULT=true)"
    fi
}

# Deploy Boundary base (namespace + postgres) in background
deploy_boundary_base() {
    if [[ "$SKIP_BOUNDARY" != "true" ]]; then
        echo "[Boundary] Creating namespace and secrets..."
        kubectl create namespace boundary --dry-run=client -o yaml | kubectl apply -f -
        echo "[Boundary] ✅ Namespace ready"
    else
        echo "[Boundary] Skipping (SKIP_BOUNDARY=true)"
    fi
}

# Add Helm repos in background (for later VSO install)
setup_helm_repos() {
    echo "[Helm] Setting up repositories..."
    helm repo add hashicorp https://helm.releases.hashicorp.com 2>/dev/null || true
    helm repo update >/dev/null 2>&1
    echo "[Helm] ✅ Repositories ready"
}

# Run ALL initial deployments in parallel (all independent tasks)
run_parallel load_base_image
run_parallel deploy_agent_sandbox
run_parallel deploy_vault
run_parallel deploy_boundary_base
run_parallel setup_helm_repos
wait_parallel

echo ""
echo "✅ All base component deployments initiated"
echo ""

if [[ "$SKIP_VAULT" != "true" ]]; then
    echo "⏳ Waiting for Vault..."
    kubectl rollout status statefulset/vault -n vault --timeout=120s

    # Initialize and/or unseal Vault
    echo "Checking Vault status..."
    VAULT_STATUS=$(get_vault_status 3 2)  # 3 attempts, 2 seconds apart (pod already ready)
    INITIALIZED=$(echo "$VAULT_STATUS" | jq -r '.initialized // false')
    # Note: Cannot use '.sealed // true' because jq's // operator treats false as falsy
    SEALED=$(echo "$VAULT_STATUS" | jq -r 'if .sealed == null then true else .sealed end')

    if [[ "$INITIALIZED" == "false" ]]; then
        echo "Initializing Vault..."
        INIT_OUTPUT=$(kubectl exec -n vault vault-0 -- vault operator init -key-shares=1 -key-threshold=1 -format=json 2>&1)
        INIT_EXIT_CODE=$?

        if [[ $INIT_EXIT_CODE -ne 0 ]] || ! echo "$INIT_OUTPUT" | jq -e . >/dev/null 2>&1; then
            echo "❌ Failed to initialize Vault"
            echo "   Output: $INIT_OUTPUT"
            echo "   You can initialize manually later with: ./platform/vault/scripts/init-vault.sh"
            echo ""
            echo "⚠️  Continuing deployment, but Vault will need manual initialization"
        else
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
        fi
    else
        echo "✅ Vault already initialized"
        # Load keys from saved file
        VAULT_KEYS_FILE="$K8S_DIR/platform/vault/scripts/vault-keys.txt"
        if [[ -f "$VAULT_KEYS_FILE" ]]; then
            UNSEAL_KEY=$(grep "Unseal Key:" "$VAULT_KEYS_FILE" 2>/dev/null | awk '{print $3}' || echo "")
            ROOT_TOKEN=$(grep "Root Token:" "$VAULT_KEYS_FILE" 2>/dev/null | awk '{print $3}' || echo "")
            if [[ -z "$UNSEAL_KEY" ]] || [[ -z "$ROOT_TOKEN" ]]; then
                echo "⚠️  vault-keys.txt exists but keys could not be parsed"
                echo "   File: $VAULT_KEYS_FILE"
            fi
        else
            echo "⚠️  vault-keys.txt not found - Vault was initialized elsewhere"
            echo "   Expected: $VAULT_KEYS_FILE"
            echo "   You may need to unseal/configure Vault manually"
            UNSEAL_KEY=""
            ROOT_TOKEN=""
        fi

        # Check if Vault needs unsealing (after pod restart)
        if [[ "$SEALED" == "true" ]]; then
            echo "🔒 Vault is sealed - unsealing..."
            if [[ -n "$UNSEAL_KEY" ]]; then
                kubectl exec -n vault vault-0 -- vault operator unseal "$UNSEAL_KEY"
                echo "✅ Vault unsealed"
            else
                echo "❌ No unseal key found in vault-keys.txt"
                echo "   Please unseal manually: kubectl exec -n vault vault-0 -- vault operator unseal <key>"
            fi
        else
            echo "✅ Vault is already unsealed"
        fi
    fi

    # Configure Vault basics
    if [[ -n "$ROOT_TOKEN" ]]; then
        K8S_HOST="https://kubernetes.default.svc"
        K8S_CA_CERT=$(kubectl config view --raw --minify --flatten -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' 2>/dev/null | base64 -d 2>/dev/null) || true

        if [[ -z "$K8S_CA_CERT" ]]; then
            echo "⚠️  Failed to retrieve Kubernetes CA certificate"
            echo "   Vault Kubernetes auth may not work correctly"
            echo "   You can configure manually later with: ./platform/vault/scripts/configure-k8s-auth.sh"
        fi

        kubectl exec -n vault vault-0 -- sh -c "
            export VAULT_TOKEN='$ROOT_TOKEN'
            vault auth enable kubernetes 2>/dev/null || true
            vault write auth/kubernetes/config kubernetes_host='$K8S_HOST' kubernetes_ca_cert='$K8S_CA_CERT' disable_local_ca_jwt=false
            vault secrets enable -path=secret kv-v2 2>/dev/null || true
            vault secrets enable -path=ssh ssh 2>/dev/null || true
            vault secrets enable -path=terraform terraform 2>/dev/null || true
        " 2>/dev/null
        echo "✅ Vault secrets engines configured"

        # Configure SSH CA for certificate-based authentication
        echo "Configuring SSH CA..."
        kubectl exec -n vault vault-0 -- sh -c "
            export VAULT_TOKEN='$ROOT_TOKEN'
            vault write ssh/config/ca generate_signing_key=true 2>/dev/null || echo '  (CA already configured)'
            vault write ssh/roles/devenv-access \
                key_type=ca \
                ttl=1h \
                max_ttl=24h \
                allow_user_certificates=true \
                allowed_users='node,root' \
                default_user=node 2>/dev/null || true
        " 2>/dev/null

        # Export SSH CA public key and create secret
        SSH_CA_KEY=$(kubectl exec -n vault vault-0 -- sh -c "
            export VAULT_TOKEN='$ROOT_TOKEN'
            vault read -field=public_key ssh/config/ca 2>/dev/null
        " || echo "")

        if [[ -n "$SSH_CA_KEY" ]]; then
            echo "$SSH_CA_KEY" > "$K8S_DIR/platform/vault/scripts/vault-ssh-ca.pub"
            kubectl create namespace devenv --dry-run=client -o yaml | kubectl apply -f -
            kubectl create secret generic vault-ssh-ca \
                --namespace=devenv \
                --from-literal=vault-ssh-ca.pub="$SSH_CA_KEY" \
                --dry-run=client -o yaml | kubectl apply -f -
            echo "✅ SSH CA configured and secret created"
            # Note: devenv pod restart moved to after VSO config to avoid double restart
        fi

        # Export Vault CA certificate for devenv pods
        echo "Exporting Vault CA certificate..."
        "$K8S_DIR/platform/vault/scripts/export-vault-ca.sh" vault devenv 2>/dev/null || true
        echo "✅ Vault TLS CA exported"
    else
        echo "⚠️  No Vault root token available - skipping Vault configuration"
        echo "   Run ./platform/vault/scripts/configure-ssh-engine.sh manually after unsealing"
    fi
else
    echo "⏭️  Skipping Vault deployment (SKIP_VAULT=true)"

    # Even when skipping deployment, ensure Vault is initialized and unsealed
    if kubectl get statefulset vault -n vault &>/dev/null; then
        echo "Checking Vault status..."
        VAULT_STATUS=$(get_vault_status 5 5)  # 5 attempts, 5 seconds apart
        INITIALIZED=$(echo "$VAULT_STATUS" | jq -r '.initialized // false')
        # Note: Cannot use '.sealed // true' because jq's // operator treats false as falsy
    SEALED=$(echo "$VAULT_STATUS" | jq -r 'if .sealed == null then true else .sealed end')

        if [[ "$INITIALIZED" == "false" ]]; then
            echo "⚠️  Vault not initialized - initializing now..."
            INIT_OUTPUT=$(kubectl exec -n vault vault-0 -- vault operator init -key-shares=1 -key-threshold=1 -format=json 2>&1)
            INIT_EXIT_CODE=$?

            if [[ $INIT_EXIT_CODE -ne 0 ]] || [[ -z "$INIT_OUTPUT" ]]; then
                echo "❌ Failed to initialize Vault"
                echo "   Output: $INIT_OUTPUT"
                echo "   You can initialize manually by running: ./platform/vault/scripts/init-vault.sh"
                # Continue deployment but warn user
            elif echo "$INIT_OUTPUT" | jq -e . >/dev/null 2>&1; then
                UNSEAL_KEY=$(echo "$INIT_OUTPUT" | jq -r '.unseal_keys_b64[0]')
                ROOT_TOKEN=$(echo "$INIT_OUTPUT" | jq -r '.root_token')

                kubectl exec -n vault vault-0 -- vault operator unseal "$UNSEAL_KEY" >/dev/null 2>&1

                cat > "$K8S_DIR/platform/vault/scripts/vault-keys.txt" << EOF
========================================
  VAULT KEYS - SAVE SECURELY!
========================================
Unseal Key: $UNSEAL_KEY
Root Token: $ROOT_TOKEN
========================================
EOF
                chmod 600 "$K8S_DIR/platform/vault/scripts/vault-keys.txt"
                echo "✅ Vault initialized and unsealed - keys saved"
                SEALED="false"

                # Configure Vault basics since it's newly initialized
                K8S_HOST="https://kubernetes.default.svc"
                K8S_CA_CERT=$(kubectl config view --raw --minify --flatten -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' 2>/dev/null | base64 -d 2>/dev/null) || true

                if [[ -z "$K8S_CA_CERT" ]]; then
                    echo "⚠️  Failed to retrieve Kubernetes CA certificate"
                    echo "   Vault Kubernetes auth may not work correctly"
                fi

                kubectl exec -n vault vault-0 -- sh -c "
                    export VAULT_TOKEN='$ROOT_TOKEN'
                    vault auth enable kubernetes 2>/dev/null || true
                    vault write auth/kubernetes/config kubernetes_host='$K8S_HOST' kubernetes_ca_cert='$K8S_CA_CERT' disable_local_ca_jwt=false
                    vault secrets enable -path=secret kv-v2 2>/dev/null || true
                    vault secrets enable -path=ssh ssh 2>/dev/null || true
                    vault secrets enable -path=terraform terraform 2>/dev/null || true
                " 2>/dev/null
                echo "✅ Vault configured"

                # Configure SSH CA
                echo "Configuring SSH CA..."
                kubectl exec -n vault vault-0 -- sh -c "
                    export VAULT_TOKEN='$ROOT_TOKEN'
                    vault write ssh/config/ca generate_signing_key=true 2>/dev/null || true
                    vault write ssh/roles/devenv-access key_type=ca ttl=1h max_ttl=24h allow_user_certificates=true allowed_users='node,root' default_user=node 2>/dev/null || true
                " 2>/dev/null

                # Export SSH CA public key
                SSH_CA_KEY=$(kubectl exec -n vault vault-0 -- sh -c "export VAULT_TOKEN='$ROOT_TOKEN'; vault read -field=public_key ssh/config/ca 2>/dev/null" || echo "")
                if [[ -n "$SSH_CA_KEY" ]]; then
                    echo "$SSH_CA_KEY" > "$K8S_DIR/platform/vault/scripts/vault-ssh-ca.pub"
                    kubectl create namespace devenv --dry-run=client -o yaml | kubectl apply -f -
                    kubectl create secret generic vault-ssh-ca --namespace=devenv --from-literal=vault-ssh-ca.pub="$SSH_CA_KEY" --dry-run=client -o yaml | kubectl apply -f -
                    echo "✅ SSH CA configured"
                    # Note: devenv pod restart moved to after VSO config to avoid double restart
                fi

                # Export Vault CA
                "$K8S_DIR/platform/vault/scripts/export-vault-ca.sh" vault devenv 2>/dev/null || true
                echo "✅ Vault initialized and configured successfully"
            else
                echo "❌ Vault initialization output is not valid JSON"
                echo "   Output: $INIT_OUTPUT"
            fi
        else
            # Try to load keys from saved file
            VAULT_KEYS_FILE="$K8S_DIR/platform/vault/scripts/vault-keys.txt"
            if [[ -f "$VAULT_KEYS_FILE" ]]; then
                ROOT_TOKEN=$(grep "Root Token:" "$VAULT_KEYS_FILE" 2>/dev/null | awk '{print $3}' || echo "")
                UNSEAL_KEY=$(grep "Unseal Key:" "$VAULT_KEYS_FILE" 2>/dev/null | awk '{print $3}' || echo "")
                if [[ -z "$UNSEAL_KEY" ]] || [[ -z "$ROOT_TOKEN" ]]; then
                    echo "⚠️  vault-keys.txt exists but keys could not be parsed"
                fi
            else
                echo "⚠️  vault-keys.txt not found at $VAULT_KEYS_FILE"
                echo "   Vault may have been initialized elsewhere"
                ROOT_TOKEN=""
                UNSEAL_KEY=""
            fi

            if [[ "$SEALED" == "true" ]]; then
                echo "🔒 Vault is sealed - attempting to unseal..."
                if [[ -n "$UNSEAL_KEY" ]]; then
                    kubectl exec -n vault vault-0 -- vault operator unseal "$UNSEAL_KEY" >/dev/null 2>&1
                    echo "✅ Vault unsealed"
                else
                    echo "⚠️  Cannot unseal Vault - no unseal key found"
                    echo "   Run: ./platform/vault/scripts/unseal-vault.sh"
                fi
            else
                echo "✅ Vault is already unsealed"
            fi
        fi
    fi
fi

echo ""
echo "=========================================="
echo "  Step 3: Deploy Boundary"
echo "=========================================="
echo ""

if [[ "$SKIP_BOUNDARY" != "true" ]]; then
    # Boundary namespace already created in parallel step above
    if ! kubectl get secret boundary-db-secrets -n boundary &>/dev/null; then
    ROOT_KEY=$(openssl rand -hex 16)
    WORKER_KEY=$(openssl rand -hex 16)
    RECOVERY_KEY=$(openssl rand -hex 16)
    # Use hex for password to avoid special characters breaking HCL/URL parsing
    POSTGRES_PASSWORD=$(openssl rand -hex 16)

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

    # Create Enterprise license secret
    if [[ -f "$LICENSE_FILE" ]]; then
        echo ""
        echo "🔑 Creating Boundary Enterprise license secret..."
        kubectl create secret generic boundary-license \
            --namespace=boundary \
            --from-file=license="$LICENSE_FILE" \
            --dry-run=client -o yaml | kubectl apply -f -
        echo "✅ Boundary Enterprise license secret created"
    fi
fi

    # Create configmaps with embedded keys (proper multi-line HCL format)
    # These need to be created/updated on every run
    ROOT_KEY=$(kubectl get secret boundary-kms-keys -n boundary -o jsonpath='{.data.BOUNDARY_ROOT_KEY}' | base64 -d)
    WORKER_KEY=$(kubectl get secret boundary-kms-keys -n boundary -o jsonpath='{.data.BOUNDARY_WORKER_AUTH_KEY}' | base64 -d)
    RECOVERY_KEY=$(kubectl get secret boundary-kms-keys -n boundary -o jsonpath='{.data.BOUNDARY_RECOVERY_KEY}' | base64 -d)
    POSTGRES_USER=$(kubectl get secret boundary-db-secrets -n boundary -o jsonpath='{.data.POSTGRES_USER}' | base64 -d)
    POSTGRES_PASSWORD=$(kubectl get secret boundary-db-secrets -n boundary -o jsonpath='{.data.POSTGRES_PASSWORD}' | base64 -d)
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
      description = "Boundary controller running in Kubernetes"
      public_cluster_addr = "boundary-controller-cluster.boundary.svc.cluster.local:9201"
      database {
        url = "postgresql://${POSTGRES_USER}:${POSTGRES_PASSWORD}@boundary-postgres.boundary.svc.cluster.local:5432/boundary?sslmode=disable"
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
      key = "${ROOT_KEY}"
      key_id = "global_root"
    }

    kms "aead" {
      purpose = "worker-auth"
      aead_type = "aes-gcm"
      key = "${WORKER_KEY}"
      key_id = "global_worker-auth"
    }

    kms "aead" {
      purpose = "recovery"
      aead_type = "aes-gcm"
      key = "${RECOVERY_KEY}"
      key_id = "global_recovery"
    }
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
      initial_upstreams = ["boundary-controller-cluster.boundary.svc.cluster.local:9201"]
      public_addr = "boundary-worker.boundary.svc.cluster.local:9202"
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
      key = "${WORKER_KEY}"
      key_id = "global_worker-auth"
    }
EOF

# Deploy Boundary components
kubectl apply -f "$K8S_DIR/platform/boundary/manifests/01-namespace.yaml"

# Apply TLS secrets and postgres in parallel (secrets required by controller/worker manifests)
echo "Creating TLS secrets and PostgreSQL..."
{
    kubectl apply -f "$K8S_DIR/platform/boundary/manifests/09-tls-secret.yaml" &
    kubectl apply -f "$K8S_DIR/platform/boundary/manifests/11-worker-tls-secret.yaml" &
    kubectl apply -f "$K8S_DIR/platform/boundary/manifests/04-postgres.yaml" &
    wait
}

echo "⏳ Waiting for PostgreSQL..."
kubectl rollout status statefulset/boundary-postgres -n boundary --timeout=90s

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
      database {
        url = "postgresql://${POSTGRES_USER}:${POSTGRES_PASSWORD}@boundary-postgres.boundary.svc.cluster.local:5432/boundary?sslmode=disable"
      }
    }

    kms "aead" {
      purpose = "root"
      aead_type = "aes-gcm"
      key = "${ROOT_KEY}"
      key_id = "global_root"
    }

    kms "aead" {
      purpose = "worker-auth"
      aead_type = "aes-gcm"
      key = "${WORKER_KEY}"
      key_id = "global_worker-auth"
    }

    kms "aead" {
      purpose = "recovery"
      aead_type = "aes-gcm"
      key = "${RECOVERY_KEY}"
      key_id = "global_recovery"
    }
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
        image: hashicorp/boundary:0.20.1
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
    if ! kubectl wait --for=condition=complete job/boundary-db-init -n boundary --timeout=30s; then
        echo "⚠️  Boundary database init job timed out or failed"
        echo "   Check job status: kubectl get job boundary-db-init -n boundary"
        echo "   Check logs: kubectl logs job/boundary-db-init -n boundary"
        echo "   Continuing, but Boundary may not work correctly..."
    else
        # Extract and save admin credentials
        echo "Extracting admin credentials..."
        INIT_OUTPUT=$(kubectl logs job/boundary-db-init -n boundary 2>/dev/null || echo "")

        AUTH_METHOD_ID=$(echo "$INIT_OUTPUT" | grep -E "Auth Method ID:" | head -1 | awk -F': ' '{print $2}' | tr -d ' ')
        LOGIN_NAME=$(echo "$INIT_OUTPUT" | grep -E "Login Name:" | head -1 | awk -F': ' '{print $2}' | tr -d ' ')
        PASSWORD=$(echo "$INIT_OUTPUT" | grep -E "Password:" | head -1 | awk -F': ' '{print $2}' | tr -d ' ')

        if [[ -n "$AUTH_METHOD_ID" ]] && [[ -n "$PASSWORD" ]]; then
            mkdir -p "$K8S_DIR/platform/boundary/scripts"
            cat > "$K8S_DIR/platform/boundary/scripts/boundary-credentials.txt" << EOF
==========================================
  Boundary Admin Credentials
==========================================

Auth Method ID: $AUTH_METHOD_ID
Login Name:     ${LOGIN_NAME:-admin}
Password:       $PASSWORD

==========================================
EOF
            chmod 600 "$K8S_DIR/platform/boundary/scripts/boundary-credentials.txt"
            echo "✅ Credentials saved to platform/boundary/scripts/boundary-credentials.txt"
        else
            echo "⚠️  Could not extract credentials from init job logs"
        fi
    fi
fi

    # Get ingress-nginx ClusterIP for hostAliases (required for OIDC)
    echo "Detecting ingress-nginx ClusterIP for OIDC..."
    INGRESS_NGINX_IP=$(kubectl get svc -n ingress-nginx ingress-nginx-controller -o jsonpath='{.spec.clusterIP}' 2>/dev/null || echo "")
    if [[ -z "$INGRESS_NGINX_IP" ]]; then
        INGRESS_NGINX_IP=$(kubectl get svc -n ingress-nginx nginx-ingress-controller -o jsonpath='{.spec.clusterIP}' 2>/dev/null || echo "127.0.0.1")
    fi
    echo "  Using ingress IP: $INGRESS_NGINX_IP"

    # Apply controller, worker, and service in parallel for speed
    echo "Applying Boundary controller, worker, and services..."
    {
        sed "s/\${INGRESS_NGINX_IP}/${INGRESS_NGINX_IP}/g" "$K8S_DIR/platform/boundary/manifests/05-controller.yaml" | kubectl apply -f - &
        kubectl apply -f "$K8S_DIR/platform/boundary/manifests/06-worker.yaml" &
        kubectl apply -f "$K8S_DIR/platform/boundary/manifests/07-service.yaml" &
        wait
    }

    # Apply ingress resources in parallel
    echo "Applying Boundary ingress resources..."
    {
        kubectl apply -f "$K8S_DIR/platform/boundary/manifests/10-ingress.yaml" 2>/dev/null || echo "  ⚠️  Ingress not applied" &
        kubectl apply -f "$K8S_DIR/platform/boundary/manifests/12-worker-ingress.yaml" 2>/dev/null || echo "  ⚠️  Worker ingress not applied" &
        wait
    }

    echo "✅ Boundary deployed"
else
    echo "⏭️  Skipping Boundary deployment (SKIP_BOUNDARY=true)"
fi

echo ""
echo "=========================================="
echo "  Step 4: Deploy Vault Secrets Operator"
echo "=========================================="
echo ""

if [[ "$SKIP_VSO" != "true" ]]; then
    # Helm repos already set up in parallel step
    kubectl apply -f "$K8S_DIR/platform/vault-secrets-operator/manifests/01-namespace.yaml"

    helm upgrade --install vault-secrets-operator hashicorp/vault-secrets-operator \
        --namespace vault-secrets-operator-system \
        --set defaultVaultConnection.enabled=false \
        --set defaultAuthMethod.enabled=false \
        --wait --timeout 2m

    # Apply VSO custom resources in parallel
    {
        kubectl apply -f "$K8S_DIR/platform/vault-secrets-operator/manifests/02-vaultconnection.yaml" &
        kubectl apply -f "$K8S_DIR/platform/vault-secrets-operator/manifests/03-vaultauth.yaml" &
        wait
    }

    # Configure Vault for VSO - first ensure Vault is unsealed
    if [[ -n "$ROOT_TOKEN" ]]; then
        # Re-check if Vault needs unsealing (may have been sealed during pod restart)
        VAULT_STATUS=$(get_vault_status 3 3)  # Quick check: 3 attempts, 3 seconds apart
        # Note: Cannot use '.sealed // true' because jq's // operator treats false as falsy
    SEALED=$(echo "$VAULT_STATUS" | jq -r 'if .sealed == null then true else .sealed end')
        if [[ "$SEALED" == "true" ]]; then
            UNSEAL_KEY=$(grep "Unseal Key:" "$K8S_DIR/platform/vault/scripts/vault-keys.txt" 2>/dev/null | awk '{print $3}' || echo "")
            if [[ -n "$UNSEAL_KEY" ]]; then
                echo "🔒 Vault sealed - unsealing for VSO configuration..."
                kubectl exec -n vault vault-0 -- vault operator unseal "$UNSEAL_KEY" >/dev/null 2>&1
            fi
        fi

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
            vault write auth/kubernetes/role/devenv-secrets bound_service_account_names='*' bound_service_account_namespaces=devenv,vault-secrets-operator-system policies=devenv-secrets ttl=1h
        " 2>/dev/null

        # Store initial credentials in Vault KV (placeholder values)
        # These should be updated with real values using configure-secrets.sh
        echo "Storing initial credentials in Vault KV..."
        kubectl exec -n vault vault-0 -- sh -c "
            export VAULT_TOKEN='$ROOT_TOKEN'
            vault kv put secret/devenv/credentials \
                github_token=placeholder-update-me \
                langfuse_host= \
                langfuse_public_key= \
                langfuse_secret_key=
        " 2>/dev/null
        echo "⚠️  Update credentials with: ./platform/vault/scripts/configure-secrets.sh"
    fi

    # Apply example secret sync
    kubectl apply -f "$K8S_DIR/platform/vault-secrets-operator/manifests/04-vaultstaticsecret-example.yaml"

    # Wait for VSO to sync the secret (poll instead of sleep)
    echo "⏳ Waiting for VSO to sync secrets..."
    for i in {1..30}; do
        if kubectl get secret devenv-vault-secrets -n devenv &>/dev/null; then
            break
        fi
        sleep 1
    done

    # Restart devenv pod to pick up the newly synced secrets (SSH CA + VSO secrets)
    # This single restart replaces the earlier SSH CA restart to avoid double restart
    if kubectl get pod -l app=claude-code-sandbox -n devenv &>/dev/null; then
        echo "🔄 Restarting devenv sandbox to pick up SSH CA and VSO-synced secrets..."
        kubectl delete pod -n devenv -l app=claude-code-sandbox --wait=false 2>/dev/null || true
    fi

    echo "✅ Vault Secrets Operator deployed"
else
    echo "⏭️  Skipping Vault Secrets Operator deployment (SKIP_VSO=true)"
fi

echo ""
echo "=========================================="
echo "  Waiting for all pods..."
echo "=========================================="
# Removed redundant sleep - pods already confirmed rolling out

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
echo "1. Access Claude Code Sandbox via code-server (Browser IDE):"
echo "   kubectl port-forward -n devenv svc/claude-code-sandbox 13337:13337"
echo "   Open: http://localhost:13337"
echo ""
echo "2. Access via kubectl exec:"
echo "   kubectl exec -it -n devenv \$(kubectl get pod -n devenv -l app=claude-code-sandbox -o jsonpath='{.items[0].metadata.name}') -- /bin/bash"
echo ""
echo "3. Access via SSH (VSCode Remote SSH):"
echo "   a. Configure SSH CA: ./platform/vault/scripts/configure-ssh-engine.sh"
echo "   b. Get signed cert: vault write -field=signed_key ssh/sign/devenv-access public_key=@~/.ssh/id_rsa.pub > ~/.ssh/id_rsa-cert.pub"
echo "   c. Port forward: kubectl port-forward -n devenv svc/claude-code-sandbox 2222:22"
echo "   d. Connect via VSCode Remote SSH to 'localhost:2222' as user 'node'"
echo ""
echo "4. Port-forward to Vault UI:"
echo "   kubectl port-forward -n vault vault-0 8200:8200"
echo "   Open: http://localhost:8200"
echo ""
echo "5. Configure secrets (GITHUB_TOKEN, Langfuse):"
echo "   ./platform/vault/scripts/configure-secrets.sh"
echo ""
echo "6. Configure TFE dynamic tokens:"
echo "   ./platform/vault/scripts/configure-tfe-engine.sh"
echo ""
echo "7. View synced secrets:"
echo "   kubectl get secret devenv-vault-secrets -n devenv -o yaml"
echo ""
echo "8. Run healthcheck:"
echo "   ./scripts/healthcheck.sh"
echo ""

# ==========================================
# Step 5: Deploy Keycloak (Optional)
# ==========================================

if [[ "$DEPLOY_KEYCLOAK" == "true" ]]; then
    echo ""
    echo "=========================================="
    echo "  Step 5: Deploy Keycloak"
    echo "=========================================="
    echo ""

    # Create shared OIDC client secret BEFORE Keycloak deployment
    # This ensures both Keycloak realm-init and Boundary use the SAME secret
    # Fixes: "Invalid client or Invalid client credentials" OIDC callback error
    echo "Creating shared OIDC client secret..."
    kubectl create namespace keycloak --dry-run=client -o yaml | kubectl apply -f -
    if ! kubectl get secret boundary-oidc-client-secret -n keycloak &>/dev/null; then
        OIDC_CLIENT_SECRET=$(openssl rand -base64 32 | tr -d '=/+' | head -c 32)
        kubectl create secret generic boundary-oidc-client-secret \
            --namespace=keycloak \
            --from-literal=client-secret="$OIDC_CLIENT_SECRET" \
            --dry-run=client -o yaml | kubectl apply -f -
        echo "✅ Created shared OIDC client secret (boundary-oidc-client-secret)"
    else
        echo "✅ Shared OIDC client secret already exists"
    fi

    if [[ -f "$K8S_DIR/platform/keycloak/scripts/deploy-keycloak.sh" ]]; then
        "$K8S_DIR/platform/keycloak/scripts/deploy-keycloak.sh"

        # Wait for Keycloak to be ready
        echo "⏳ Waiting for Keycloak to be ready..."
        if ! kubectl rollout status deployment/keycloak -n keycloak --timeout=180s; then
            echo "⚠️  Keycloak rollout timed out or failed"
            echo "   Check status: kubectl get pods -n keycloak"
            echo "   Continuing, but Keycloak may not be fully ready..."
        fi

        # Configure realm and demo users
        if [[ -f "$K8S_DIR/platform/keycloak/scripts/configure-realm.sh" ]]; then
            echo ""
            echo "Configuring Keycloak realm and demo users..."
            # Keycloak already confirmed ready via rollout status - no sleep needed
            "$K8S_DIR/platform/keycloak/scripts/configure-realm.sh" --in-cluster || echo "⚠️  Keycloak realm configuration failed (may need manual setup)"
        fi

        # Create keycloak-http service for port 80 -> 8080 mapping
        # This is needed because Keycloak advertises issuer without port, but listens on 8080
        echo "Creating keycloak-http service (port 80 -> 8080)..."
        cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Service
metadata:
  name: keycloak-http
  namespace: keycloak
spec:
  selector:
    app: keycloak
  ports:
    - name: http
      port: 80
      targetPort: 8080
  type: ClusterIP
EOF

        # Update Boundary controller hostAliases if Boundary is deployed
        # IMPORTANT: For OIDC to work, keycloak.local must point to the ingress controller
        # (which handles TLS termination) so Boundary can validate the HTTPS issuer
        if kubectl get deployment boundary-controller -n boundary &>/dev/null; then
            echo "Updating Boundary controller hostAliases for Keycloak/Boundary connectivity..."

            # Use ingress controller IP for keycloak.local (required for HTTPS OIDC validation)
            INGRESS_IP=$(kubectl get svc ingress-nginx-controller -n ingress-nginx -o jsonpath='{.spec.clusterIP}' 2>/dev/null)
            if [[ -z "$INGRESS_IP" ]]; then
                echo "⚠️  Ingress controller not found, falling back to keycloak-http service"
                INGRESS_IP=$(kubectl get svc keycloak-http -n keycloak -o jsonpath='{.spec.clusterIP}')
            fi
            BOUNDARY_API_IP=$(kubectl get svc boundary-controller-api -n boundary -o jsonpath='{.spec.clusterIP}')

            kubectl patch deployment boundary-controller -n boundary --type='json' -p="[
              {
                \"op\": \"replace\",
                \"path\": \"/spec/template/spec/hostAliases\",
                \"value\": [
                  {
                    \"ip\": \"$INGRESS_IP\",
                    \"hostnames\": [\"keycloak.local\"]
                  },
                  {
                    \"ip\": \"$BOUNDARY_API_IP\",
                    \"hostnames\": [\"boundary.local\"]
                  }
                ]
              }
            ]"
            kubectl rollout status deployment/boundary-controller -n boundary --timeout=60s 2>/dev/null || true
        fi

        echo "✅ Keycloak deployed"
    else
        echo "⚠️  Keycloak deployment script not found, skipping"
    fi
else
    echo ""
    echo "Skipping Keycloak deployment (DEPLOY_KEYCLOAK=false)"
fi

# ==========================================
# Step 6: Configure Boundary Targets & OIDC
# ==========================================

# Track configuration failures for final summary
BOUNDARY_TARGETS_FAILED=""
BOUNDARY_OIDC_FAILED=""

if [[ "$CONFIGURE_BOUNDARY_TARGETS" == "true" ]] && [[ "$DEPLOY_BOUNDARY" == "true" ]]; then
    echo ""
    echo "=========================================="
    echo "  Step 6: Configure Boundary Targets"
    echo "=========================================="
    echo ""

    # Wait for Boundary to be fully ready
    echo "⏳ Waiting for Boundary controller..."
    if ! kubectl rollout status deployment/boundary-controller -n boundary --timeout=120s; then
        echo "⚠️  Boundary controller rollout timed out or failed"
        echo "   Check status: kubectl get pods -n boundary"
        echo "   Continuing, but Boundary configuration may fail..."
    fi

    # Wait for Boundary API to be ready (rollout status doesn't guarantee API readiness)
    echo "⏳ Waiting for Boundary API to be ready..."
    BOUNDARY_READY=false
    for i in {1..30}; do
        if kubectl exec -n boundary deployment/boundary-controller -c boundary-controller -- \
            boundary auth-methods list -scope-id=global -format=json >/dev/null 2>&1; then
            BOUNDARY_READY=true
            break
        fi
        echo "   Attempt $i/30: Boundary API not ready yet..."
        sleep 2
    done

    if [[ "$BOUNDARY_READY" != "true" ]]; then
        echo "⚠️  Boundary API did not become ready in time"
        echo "   Configuration may fail, but will attempt anyway..."
    else
        echo "✅ Boundary API is ready"
    fi

    if [[ -f "$K8S_DIR/platform/boundary/scripts/configure-targets.sh" ]]; then
        echo "Running configure-targets.sh..."
        CONFIG_OUTPUT_FILE=$(mktemp)
        TARGETS_MAX_RETRIES=3
        TARGETS_RETRY_DELAY=10
        TARGETS_SUCCESS=false

        for attempt in $(seq 1 $TARGETS_MAX_RETRIES); do
            if [[ $attempt -gt 1 ]]; then
                echo ""
                echo "⏳ Retry attempt $attempt/$TARGETS_MAX_RETRIES (waiting ${TARGETS_RETRY_DELAY}s)..."
                sleep $TARGETS_RETRY_DELAY
            fi

            if "$K8S_DIR/platform/boundary/scripts/configure-targets.sh" boundary devenv 2>&1 | tee "$CONFIG_OUTPUT_FILE"; then
                TARGETS_SUCCESS=true
                break
            fi

            if [[ $attempt -lt $TARGETS_MAX_RETRIES ]]; then
                echo "⚠️  Attempt $attempt failed, will retry..."
            fi
        done

        if [[ "$TARGETS_SUCCESS" != "true" ]]; then
            echo ""
            echo "❌ BOUNDARY TARGETS CONFIGURATION FAILED (after $TARGETS_MAX_RETRIES attempts)"
            echo "   Error output saved. Last 20 lines:"
            echo "   ----------------------------------------"
            tail -20 "$CONFIG_OUTPUT_FILE" | sed 's/^/   /'
            echo "   ----------------------------------------"
            echo ""
            echo "   To retry manually, run:"
            echo "   $K8S_DIR/platform/boundary/scripts/configure-targets.sh boundary devenv"
            BOUNDARY_TARGETS_FAILED="true"
        fi
        rm -f "$CONFIG_OUTPUT_FILE"
    fi

    # Configure OIDC if Keycloak is deployed AND targets configuration succeeded
    # OIDC requires the DevOps organization that configure-targets.sh creates
    if [[ "$DEPLOY_KEYCLOAK" == "true" ]] && [[ -z "$BOUNDARY_TARGETS_FAILED" ]]; then
        KEYCLOAK_STATUS=$(kubectl get pod -l app=keycloak -n keycloak -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "NotFound")
        if [[ "$KEYCLOAK_STATUS" == "Running" ]]; then
            echo ""
            echo "Configuring Boundary OIDC with Keycloak..."
            if [[ -f "$K8S_DIR/platform/boundary/scripts/configure-oidc-auth.sh" ]]; then
                OIDC_OUTPUT_FILE=$(mktemp)
                if ! "$K8S_DIR/platform/boundary/scripts/configure-oidc-auth.sh" 2>&1 | tee "$OIDC_OUTPUT_FILE"; then
                    echo ""
                    echo "❌ OIDC CONFIGURATION FAILED"
                    echo "   Error output saved. Last 20 lines:"
                    echo "   ----------------------------------------"
                    tail -20 "$OIDC_OUTPUT_FILE" | sed 's/^/   /'
                    echo "   ----------------------------------------"
                    echo ""
                    echo "   This may require Boundary targets to be configured first."
                    echo "   To retry manually, run:"
                    echo "   $K8S_DIR/platform/boundary/scripts/configure-oidc-auth.sh"
                    BOUNDARY_OIDC_FAILED="true"
                fi
                rm -f "$OIDC_OUTPUT_FILE"
            fi
        fi
    elif [[ "$DEPLOY_KEYCLOAK" == "true" ]] && [[ -n "$BOUNDARY_TARGETS_FAILED" ]]; then
        echo ""
        echo "⏭️  Skipping OIDC configuration (requires DevOps organization from configure-targets.sh)"
        BOUNDARY_OIDC_FAILED="skipped"
    fi

    # Report configuration status
    if [[ -n "$BOUNDARY_TARGETS_FAILED" ]] || [[ -n "$BOUNDARY_OIDC_FAILED" ]]; then
        echo ""
        echo "⚠️  Boundary configuration completed with errors"
        [[ -n "$BOUNDARY_TARGETS_FAILED" ]] && echo "   - Targets configuration: FAILED"
        [[ "$BOUNDARY_OIDC_FAILED" == "skipped" ]] && echo "   - OIDC configuration: SKIPPED (depends on targets)"
        [[ "$BOUNDARY_OIDC_FAILED" == "true" ]] && echo "   - OIDC configuration: FAILED"
    else
        echo "✅ Boundary configuration complete"
    fi
else
    echo ""
    echo "Skipping Boundary targets configuration"
fi

# Determine overall deployment status
DEPLOYMENT_HAD_ERRORS=""
if [[ -n "$BOUNDARY_TARGETS_FAILED" ]] || [[ -n "$BOUNDARY_OIDC_FAILED" ]]; then
    DEPLOYMENT_HAD_ERRORS="true"
fi

echo ""
if [[ -n "$DEPLOYMENT_HAD_ERRORS" ]]; then
    echo "=========================================="
    echo "  ⚠️  PLATFORM DEPLOYMENT COMPLETED WITH ERRORS"
    echo "=========================================="
else
    echo "=========================================="
    echo "  ✅ FULL PLATFORM DEPLOYMENT COMPLETE"
    echo "=========================================="
fi
echo ""
echo "Components deployed:"
echo "  ✅ Agent Sandbox (devenv)"
echo "  ✅ Vault"
echo "  ✅ Boundary"
echo "  ✅ Vault Secrets Operator"
if [[ "$DEPLOY_KEYCLOAK" == "true" ]]; then
echo "  ✅ Keycloak"
fi

# Show configuration status
if [[ "$CONFIGURE_BOUNDARY_TARGETS" == "true" ]]; then
    if [[ -n "$BOUNDARY_TARGETS_FAILED" ]]; then
        echo "  ❌ Boundary Targets (FAILED - run configure-targets.sh manually)"
    else
        echo "  ✅ Boundary Targets"
    fi
    if [[ "$DEPLOY_KEYCLOAK" == "true" ]]; then
        if [[ "$BOUNDARY_OIDC_FAILED" == "skipped" ]]; then
            echo "  ⏭️  Boundary OIDC (SKIPPED - run configure-targets.sh first, then configure-oidc-auth.sh)"
        elif [[ "$BOUNDARY_OIDC_FAILED" == "true" ]]; then
            echo "  ❌ Boundary OIDC (FAILED - run configure-oidc-auth.sh manually)"
        else
            echo "  ✅ Boundary OIDC"
        fi
    fi
fi
echo ""

# Run all verification tests
echo ""
echo "=========================================="
echo "  Running Platform Verification Tests"
echo "=========================================="
echo ""

# Run the comprehensive test suite
if [[ -f "$SCRIPT_DIR/tests/run-all-tests.sh" ]]; then
    "$SCRIPT_DIR/tests/run-all-tests.sh" || true
else
    # Fallback to individual tests if run-all-tests.sh not found
    echo "Running individual tests..."
    "$SCRIPT_DIR/tests/healthcheck.sh" || true
    "$SCRIPT_DIR/tests/test-secrets.sh" || true
    "$SCRIPT_DIR/tests/test-boundary.sh" || true
    [[ "$DEPLOY_KEYCLOAK" == "true" ]] && "$SCRIPT_DIR/tests/test-keycloak.sh" || true
    [[ "$CONFIGURE_BOUNDARY_TARGETS" == "true" ]] && "$SCRIPT_DIR/tests/test-oidc-auth.sh" || true
    # CRITICAL: Validate OIDC client secret consistency between Keycloak and Boundary
    # This test catches the "Invalid client or Invalid client credentials" error
    [[ "$DEPLOY_KEYCLOAK" == "true" ]] && [[ -f "$SCRIPT_DIR/tests/test-oidc-client-secret.sh" ]] && "$SCRIPT_DIR/tests/test-oidc-client-secret.sh" || true
fi

echo ""
if [[ -n "$DEPLOYMENT_HAD_ERRORS" ]]; then
    echo "=========================================="
    echo "  ⚠️  Deployment Complete with Errors"
    echo "=========================================="
    echo ""
    echo "Components deployed but some configuration failed."
    echo ""
    echo "Failed configurations:"
    [[ -n "$BOUNDARY_TARGETS_FAILED" ]] && echo "  - Boundary Targets: Run ./platform/boundary/scripts/configure-targets.sh boundary devenv"
    [[ "$BOUNDARY_OIDC_FAILED" == "skipped" ]] && echo "  - Boundary OIDC: Run configure-targets.sh first, then ./platform/boundary/scripts/configure-oidc-auth.sh"
    [[ "$BOUNDARY_OIDC_FAILED" == "true" ]] && echo "  - Boundary OIDC: Run ./platform/boundary/scripts/configure-oidc-auth.sh"
    echo ""
    echo "Check the test results above for any issues."
else
    echo "=========================================="
    echo "  🎉 Deployment Complete!"
    echo "=========================================="
    echo ""
    echo "All components deployed and verified."
    echo "Check the test results above for any issues."
fi
echo ""
