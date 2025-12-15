#!/bin/bash
set -euo pipefail

# Master deployment script for the complete K8s platform (OPTIMIZED)
# Deploys: DevEnv, Boundary, Vault, Vault Secrets Operator, and Keycloak
#
# KEY OPTIMIZATIONS vs deploy-all.sh:
#   - Keycloak and Boundary deploy in parallel (no inter-dependency)
#   - VSO and Keycloak realm config run in parallel
#   - Status checks run in parallel
#   - Consolidated Vault configuration into single exec call
#   - Boundary manifests applied in larger parallel batches
#   - Eliminated redundant waits
#
# USAGE:
#   ./deploy-all-optimized.sh             # Full deployment
#   RESUME=auto ./deploy-all-optimized.sh # Resume partial deployment
#
# ENVIRONMENT VARIABLES:
#   RESUME=auto|false     - Auto-detect and skip already-running components
#   PARALLEL=true|false   - Run independent deployments concurrently (default: true)
#   SKIP_DEVENV=true      - Skip Agent Sandbox deployment
#   SKIP_VAULT=true       - Skip Vault deployment
#   SKIP_BOUNDARY=true    - Skip Boundary deployment
#   SKIP_VSO=true         - Skip Vault Secrets Operator deployment
#   BUILD_IMAGE=false     - Skip Docker image build
#   DEBUG=true            - Enable verbose output

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
K8S_DIR="$(dirname "$SCRIPT_DIR")"

# Source configuration
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
BUILD_IMAGE="${BUILD_IMAGE:-true}"
DOCKER_REGISTRY="${DOCKER_REGISTRY:-}"
IMAGE_NAME="${IMAGE_NAME:-agent-sandbox}"
IMAGE_TAG="${IMAGE_TAG:-latest}"
DEBUG="${DEBUG:-false}"

[[ "$DEBUG" == "true" ]] && set -x

PARALLEL="${PARALLEL:-true}"
RESUME="${RESUME:-false}"
SKIP_DEVENV="${SKIP_DEVENV:-false}"
SKIP_VAULT="${SKIP_VAULT:-false}"
SKIP_BOUNDARY="${SKIP_BOUNDARY:-false}"
SKIP_VSO="${SKIP_VSO:-false}"

# Export for child functions
export ROOT_TOKEN=""
export UNSEAL_KEY=""

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
echo "  Complete Platform Deployment (OPTIMIZED)"
echo "=========================================="
echo ""
echo "Parallel mode: $PARALLEL"
echo ""

if [[ "$RESUME" == "auto" ]] || [[ -n "${EXISTING:-}" ]]; then
    echo "Detecting existing deployments..."
    auto_detect_resume
    echo ""
fi

# Enhanced parallel execution with proper error tracking
run_parallel() {
    if [[ "$PARALLEL" == "true" ]]; then
        "$@" &
    else
        "$@"
    fi
}

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
get_vault_status() {
    local max_attempts="${1:-5}"
    local sleep_interval="${2:-5}"
    local attempt=1
    local vault_output=""

    while [[ $attempt -le $max_attempts ]]; do
        vault_output=$(kubectl exec -n vault vault-0 -- vault status -format=json 2>/dev/null) || true
        if echo "$vault_output" | jq -e . >/dev/null 2>&1; then
            echo "$vault_output"
            return 0
        fi
        if [[ $attempt -lt $max_attempts ]]; then
            sleep "$sleep_interval"
        fi
        ((attempt++))
    done
    echo '{"initialized":false,"sealed":true}'
    return 1
}

# ==========================================
# Phase 1: Prerequisites (Parallel)
# ==========================================
echo "=========================================="
echo "  Phase 1: Prerequisites Check"
echo "=========================================="
echo ""

if [[ -f "$SCRIPT_DIR/check-prereqs.sh" ]]; then
    if ! "$SCRIPT_DIR/check-prereqs.sh"; then
        echo "❌ Prerequisites check failed"
        exit 1
    fi
fi

# Check for Kubernetes cluster
if ! kubectl cluster-info &> /dev/null; then
    echo "⚠️  No Kubernetes cluster available"
    if command -v docker &> /dev/null && docker info &> /dev/null; then
        if [[ -f "$SCRIPT_DIR/setup-kind.sh" ]]; then
            "$SCRIPT_DIR/setup-kind.sh" "${KIND_CLUSTER_NAME:-sandbox}"
        fi
    else
        echo "❌ Cannot create cluster - Docker not available"
        exit 1
    fi
fi

# Install ingress + setup helm repos in parallel
install_ingress() {
    if ! kubectl get namespace ingress-nginx &>/dev/null; then
        echo "[Ingress] Installing nginx ingress controller..."
        kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml
        kubectl wait --namespace ingress-nginx \
            --for=condition=ready pod \
            --selector=app.kubernetes.io/component=controller \
            --timeout=60s 2>/dev/null || true
        echo "[Ingress] ✅ Installed"
    else
        echo "[Ingress] ✅ Already installed"
    fi
}

setup_helm_repos() {
    echo "[Helm] Setting up repositories..."
    helm repo add hashicorp https://helm.releases.hashicorp.com 2>/dev/null || true
    helm repo update >/dev/null 2>&1
    echo "[Helm] ✅ Ready"
}

run_parallel install_ingress
run_parallel setup_helm_repos
wait_parallel

# Check Boundary license
if [[ "${SKIP_BOUNDARY:-false}" != "true" ]]; then
    LICENSE_FILE="$SCRIPT_DIR/license/boundary.hclic"
    if [[ ! -f "$LICENSE_FILE" ]] || [[ ! -s "$LICENSE_FILE" ]]; then
        echo "❌ Boundary license not found: $LICENSE_FILE"
        exit 1
    fi
    echo "✅ Boundary license found"
fi

echo "✅ Prerequisites met"
echo ""

# ==========================================
# Phase 2: Deploy Base Components (Parallel)
# Agent Sandbox, Vault manifests, Boundary namespace
# ==========================================
echo "=========================================="
echo "  Phase 2: Deploy Base Components (Parallel)"
echo "=========================================="
echo ""

deploy_agent_sandbox() {
    if [[ "$SKIP_DEVENV" != "true" ]]; then
        AGENT_SANDBOX_DIR="$K8S_DIR/agent-sandbox"
        if [[ -f "$AGENT_SANDBOX_DIR/deploy.sh" ]]; then
            echo "[AgentSandbox] Deploying..."
            NAMESPACE="$DEVENV_NAMESPACE" "$AGENT_SANDBOX_DIR/deploy.sh"
        else
            kubectl create namespace devenv --dry-run=client -o yaml | kubectl apply -f -
            kubectl get secret devenv-vault-secrets -n devenv &>/dev/null || \
                kubectl create secret generic devenv-vault-secrets --namespace=devenv \
                    --from-literal=GITHUB_TOKEN=placeholder --dry-run=client -o yaml | kubectl apply -f -
            [[ -d "$AGENT_SANDBOX_DIR/base" ]] && kubectl apply -k "$AGENT_SANDBOX_DIR/base"
        fi
        echo "[AgentSandbox] ✅ Deployed"
    else
        echo "[AgentSandbox] ⏭️  Skipped"
    fi
}

deploy_vault_manifests() {
    if [[ "$SKIP_VAULT" != "true" ]]; then
        echo "[Vault] Deploying manifests..."
        kubectl apply -f "$K8S_DIR/platform/vault/manifests/01-namespace.yaml"
        # Apply all vault manifests in parallel
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
        echo "[Vault] ⏭️  Skipped"
    fi
}

deploy_boundary_namespace() {
    if [[ "$SKIP_BOUNDARY" != "true" ]]; then
        echo "[Boundary] Creating namespace and secrets..."
        kubectl create namespace boundary --dry-run=client -o yaml | kubectl apply -f -

        if ! kubectl get secret boundary-db-secrets -n boundary &>/dev/null; then
            ROOT_KEY=$(openssl rand -hex 16)
            WORKER_KEY=$(openssl rand -hex 16)
            RECOVERY_KEY=$(openssl rand -hex 16)
            POSTGRES_PASSWORD=$(openssl rand -hex 16)

            {
                kubectl create secret generic boundary-db-secrets --namespace=boundary \
                    --from-literal=POSTGRES_USER=boundary \
                    --from-literal=POSTGRES_PASSWORD="$POSTGRES_PASSWORD" \
                    --dry-run=client -o yaml | kubectl apply -f - &
                kubectl create secret generic boundary-kms-keys --namespace=boundary \
                    --from-literal=BOUNDARY_ROOT_KEY="$ROOT_KEY" \
                    --from-literal=BOUNDARY_WORKER_AUTH_KEY="$WORKER_KEY" \
                    --from-literal=BOUNDARY_RECOVERY_KEY="$RECOVERY_KEY" \
                    --dry-run=client -o yaml | kubectl apply -f - &
                wait
            }

            LICENSE_FILE="$SCRIPT_DIR/license/boundary.hclic"
            [[ -f "$LICENSE_FILE" ]] && kubectl create secret generic boundary-license \
                --namespace=boundary --from-file=license="$LICENSE_FILE" \
                --dry-run=client -o yaml | kubectl apply -f -
        fi
        echo "[Boundary] ✅ Namespace and secrets ready"
    else
        echo "[Boundary] ⏭️  Skipped"
    fi
}

run_parallel deploy_agent_sandbox
run_parallel deploy_vault_manifests
run_parallel deploy_boundary_namespace
wait_parallel

echo "✅ Base components deployed"
echo ""

# ==========================================
# Phase 3: Initialize Vault (Sequential - required for VSO)
# ==========================================
if [[ "$SKIP_VAULT" != "true" ]]; then
    echo "=========================================="
    echo "  Phase 3: Initialize Vault"
    echo "=========================================="
    echo ""

    echo "⏳ Waiting for Vault pod..."
    kubectl rollout status statefulset/vault -n vault --timeout=120s

    VAULT_STATUS=$(get_vault_status 3 2)
    INITIALIZED=$(echo "$VAULT_STATUS" | jq -r '.initialized // false')
    SEALED=$(echo "$VAULT_STATUS" | jq -r 'if .sealed == null then true else .sealed end')

    if [[ "$INITIALIZED" == "false" ]]; then
        echo "Initializing Vault..."
        INIT_OUTPUT=$(kubectl exec -n vault vault-0 -- vault operator init -key-shares=1 -key-threshold=1 -format=json 2>&1)

        if echo "$INIT_OUTPUT" | jq -e . >/dev/null 2>&1; then
            UNSEAL_KEY=$(echo "$INIT_OUTPUT" | jq -r '.unseal_keys_b64[0]')
            ROOT_TOKEN=$(echo "$INIT_OUTPUT" | jq -r '.root_token')
            export ROOT_TOKEN UNSEAL_KEY

            kubectl exec -n vault vault-0 -- vault operator unseal "$UNSEAL_KEY"

            mkdir -p "$K8S_DIR/platform/vault/scripts"
            cat > "$K8S_DIR/platform/vault/scripts/vault-keys.txt" << EOF
==========================================
  VAULT KEYS - SAVE SECURELY!
==========================================
Unseal Key: $UNSEAL_KEY
Root Token: $ROOT_TOKEN
==========================================
EOF
            chmod 600 "$K8S_DIR/platform/vault/scripts/vault-keys.txt"
            echo "✅ Vault initialized"
        else
            echo "❌ Vault initialization failed"
        fi
    else
        echo "✅ Vault already initialized"
        VAULT_KEYS_FILE="$K8S_DIR/platform/vault/scripts/vault-keys.txt"
        if [[ -f "$VAULT_KEYS_FILE" ]]; then
            UNSEAL_KEY=$(grep "Unseal Key:" "$VAULT_KEYS_FILE" 2>/dev/null | awk '{print $3}' || echo "")
            ROOT_TOKEN=$(grep "Root Token:" "$VAULT_KEYS_FILE" 2>/dev/null | awk '{print $3}' || echo "")
            export ROOT_TOKEN UNSEAL_KEY
        fi

        if [[ "$SEALED" == "true" ]] && [[ -n "$UNSEAL_KEY" ]]; then
            echo "🔒 Unsealing Vault..."
            kubectl exec -n vault vault-0 -- vault operator unseal "$UNSEAL_KEY"
        fi
    fi

    # Configure Vault in a SINGLE exec call (consolidated for efficiency)
    if [[ -n "$ROOT_TOKEN" ]]; then
        echo "Configuring Vault (consolidated)..."
        K8S_HOST="https://kubernetes.default.svc"
        K8S_CA_CERT=$(kubectl config view --raw --minify --flatten -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' 2>/dev/null | base64 -d 2>/dev/null) || true

        kubectl exec -n vault vault-0 -- sh -c "
            export VAULT_TOKEN='$ROOT_TOKEN'

            # Enable auth and secrets engines (all in one call)
            vault auth enable kubernetes 2>/dev/null || true
            vault secrets enable -path=secret kv-v2 2>/dev/null || true
            vault secrets enable -path=ssh ssh 2>/dev/null || true
            vault secrets enable -path=terraform terraform 2>/dev/null || true

            # Configure Kubernetes auth
            vault write auth/kubernetes/config kubernetes_host='$K8S_HOST' kubernetes_ca_cert='$K8S_CA_CERT' disable_local_ca_jwt=false

            # Configure SSH CA
            vault write ssh/config/ca generate_signing_key=true 2>/dev/null || true
            vault write ssh/roles/devenv-access key_type=ca ttl=1h max_ttl=24h allow_user_certificates=true allowed_users='node,root' default_user=node 2>/dev/null || true
        " 2>/dev/null

        # Export SSH CA and create secrets
        SSH_CA_KEY=$(kubectl exec -n vault vault-0 -- sh -c "export VAULT_TOKEN='$ROOT_TOKEN'; vault read -field=public_key ssh/config/ca 2>/dev/null" || echo "")
        if [[ -n "$SSH_CA_KEY" ]]; then
            echo "$SSH_CA_KEY" > "$K8S_DIR/platform/vault/scripts/vault-ssh-ca.pub"
            kubectl create namespace devenv --dry-run=client -o yaml | kubectl apply -f -
            kubectl create secret generic vault-ssh-ca --namespace=devenv \
                --from-literal=vault-ssh-ca.pub="$SSH_CA_KEY" --dry-run=client -o yaml | kubectl apply -f -
        fi

        "$K8S_DIR/platform/vault/scripts/export-vault-ca.sh" vault devenv 2>/dev/null || true
        echo "✅ Vault configured"
    fi
else
    # Load existing Vault credentials if skipping deployment
    VAULT_KEYS_FILE="$K8S_DIR/platform/vault/scripts/vault-keys.txt"
    if [[ -f "$VAULT_KEYS_FILE" ]]; then
        UNSEAL_KEY=$(grep "Unseal Key:" "$VAULT_KEYS_FILE" 2>/dev/null | awk '{print $3}' || echo "")
        ROOT_TOKEN=$(grep "Root Token:" "$VAULT_KEYS_FILE" 2>/dev/null | awk '{print $3}' || echo "")
        export ROOT_TOKEN UNSEAL_KEY
    fi
fi

# ==========================================
# Phase 4: Deploy Boundary & Keycloak (PARALLEL)
# These have NO dependencies on each other!
# ==========================================
echo ""
echo "=========================================="
echo "  Phase 4: Deploy Boundary & Keycloak (PARALLEL)"
echo "=========================================="
echo ""

# Function: Deploy Boundary (postgres, controller, worker)
deploy_boundary_full() {
    if [[ "$SKIP_BOUNDARY" != "true" ]]; then
        echo "[Boundary] Starting full deployment..."

        # Get secrets for config generation
        ROOT_KEY=$(kubectl get secret boundary-kms-keys -n boundary -o jsonpath='{.data.BOUNDARY_ROOT_KEY}' | base64 -d)
        WORKER_KEY=$(kubectl get secret boundary-kms-keys -n boundary -o jsonpath='{.data.BOUNDARY_WORKER_AUTH_KEY}' | base64 -d)
        RECOVERY_KEY=$(kubectl get secret boundary-kms-keys -n boundary -o jsonpath='{.data.BOUNDARY_RECOVERY_KEY}' | base64 -d)
        POSTGRES_USER=$(kubectl get secret boundary-db-secrets -n boundary -o jsonpath='{.data.POSTGRES_USER}' | base64 -d)
        POSTGRES_PASSWORD=$(kubectl get secret boundary-db-secrets -n boundary -o jsonpath='{.data.POSTGRES_PASSWORD}' | base64 -d)

        # Create configmaps
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
      database { url = "postgresql://${POSTGRES_USER}:${POSTGRES_PASSWORD}@boundary-postgres.boundary.svc.cluster.local:5432/boundary?sslmode=disable" }
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
      initial_upstreams = ["boundary-controller-cluster.boundary.svc.cluster.local:9201"]
      public_addr = "boundary-worker.boundary.svc.cluster.local:9202"
    }
    listener "tcp" { address = "0.0.0.0:9202"; purpose = "proxy"; tls_disable = true }
    listener "tcp" { address = "0.0.0.0:9203"; purpose = "ops"; tls_disable = true }
    kms "aead" { purpose = "worker-auth"; aead_type = "aes-gcm"; key = "${WORKER_KEY}"; key_id = "global_worker-auth" }
EOF

        # Apply TLS and postgres in parallel
        {
            kubectl apply -f "$K8S_DIR/platform/boundary/manifests/09-tls-secret.yaml" &
            kubectl apply -f "$K8S_DIR/platform/boundary/manifests/11-worker-tls-secret.yaml" &
            kubectl apply -f "$K8S_DIR/platform/boundary/manifests/04-postgres.yaml" &
            wait
        }

        echo "[Boundary] ⏳ Waiting for PostgreSQL..."
        kubectl rollout status statefulset/boundary-postgres -n boundary --timeout=90s

        # Initialize database if needed
        if ! kubectl get job boundary-db-init -n boundary &>/dev/null; then
            echo "[Boundary] Initializing database..."
            cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: boundary-init-config
  namespace: boundary
data:
  init.hcl: |
    disable_mlock = true
    controller { name = "init"; database { url = "postgresql://${POSTGRES_USER}:${POSTGRES_PASSWORD}@boundary-postgres.boundary.svc.cluster.local:5432/boundary?sslmode=disable" } }
    kms "aead" { purpose = "root"; aead_type = "aes-gcm"; key = "${ROOT_KEY}"; key_id = "global_root" }
    kms "aead" { purpose = "worker-auth"; aead_type = "aes-gcm"; key = "${WORKER_KEY}"; key_id = "global_worker-auth" }
    kms "aead" { purpose = "recovery"; aead_type = "aes-gcm"; key = "${RECOVERY_KEY}"; key_id = "global_recovery" }
---
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
            kubectl wait --for=condition=complete job/boundary-db-init -n boundary --timeout=30s || true

            # Extract credentials
            INIT_OUTPUT=$(kubectl logs job/boundary-db-init -n boundary 2>/dev/null || echo "")
            AUTH_METHOD_ID=$(echo "$INIT_OUTPUT" | grep -E "Auth Method ID:" | head -1 | awk -F': ' '{print $2}' | tr -d ' ')
            PASSWORD=$(echo "$INIT_OUTPUT" | grep -E "Password:" | head -1 | awk -F': ' '{print $2}' | tr -d ' ')
            if [[ -n "$AUTH_METHOD_ID" ]] && [[ -n "$PASSWORD" ]]; then
                mkdir -p "$K8S_DIR/platform/boundary/scripts"
                cat > "$K8S_DIR/platform/boundary/scripts/boundary-credentials.txt" << EOF
==========================================
  Boundary Admin Credentials
==========================================
Auth Method ID: $AUTH_METHOD_ID
Login Name:     admin
Password:       $PASSWORD
==========================================
EOF
                chmod 600 "$K8S_DIR/platform/boundary/scripts/boundary-credentials.txt"
            fi
        fi

        # Get ingress IP for hostAliases
        INGRESS_NGINX_IP=$(kubectl get svc -n ingress-nginx ingress-nginx-controller -o jsonpath='{.spec.clusterIP}' 2>/dev/null || echo "127.0.0.1")

        # Deploy controller, worker, services, and ingress ALL in parallel
        echo "[Boundary] Deploying controller, worker, and services..."
        {
            sed "s/\${INGRESS_NGINX_IP}/${INGRESS_NGINX_IP}/g" "$K8S_DIR/platform/boundary/manifests/05-controller.yaml" | kubectl apply -f - &
            kubectl apply -f "$K8S_DIR/platform/boundary/manifests/06-worker.yaml" &
            kubectl apply -f "$K8S_DIR/platform/boundary/manifests/07-service.yaml" &
            kubectl apply -f "$K8S_DIR/platform/boundary/manifests/10-ingress.yaml" 2>/dev/null &
            kubectl apply -f "$K8S_DIR/platform/boundary/manifests/12-worker-ingress.yaml" 2>/dev/null &
            wait
        }

        echo "[Boundary] ✅ Deployed"
    else
        echo "[Boundary] ⏭️  Skipped"
    fi
}

# Function: Deploy Keycloak
deploy_keycloak_full() {
    if [[ "$DEPLOY_KEYCLOAK" == "true" ]]; then
        echo "[Keycloak] Starting deployment..."

        kubectl create namespace keycloak --dry-run=client -o yaml | kubectl apply -f -

        # Create shared OIDC secret BEFORE deployment
        if ! kubectl get secret boundary-oidc-client-secret -n keycloak &>/dev/null; then
            OIDC_CLIENT_SECRET=$(openssl rand -base64 32 | tr -d '=/+' | head -c 32)
            kubectl create secret generic boundary-oidc-client-secret \
                --namespace=keycloak \
                --from-literal=client-secret="$OIDC_CLIENT_SECRET" \
                --dry-run=client -o yaml | kubectl apply -f -
            echo "[Keycloak] ✅ Created shared OIDC client secret"
        fi

        if [[ -f "$K8S_DIR/platform/keycloak/scripts/deploy-keycloak.sh" ]]; then
            "$K8S_DIR/platform/keycloak/scripts/deploy-keycloak.sh"

            echo "[Keycloak] ⏳ Waiting for Keycloak to be ready..."
            kubectl rollout status deployment/keycloak -n keycloak --timeout=180s || true

            # Configure realm
            if [[ -f "$K8S_DIR/platform/keycloak/scripts/configure-realm.sh" ]]; then
                echo "[Keycloak] Configuring realm..."
                "$K8S_DIR/platform/keycloak/scripts/configure-realm.sh" --in-cluster || echo "[Keycloak] ⚠️  Realm config failed"
            fi

            # Create keycloak-http service
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
            echo "[Keycloak] ✅ Deployed"
        else
            echo "[Keycloak] ⚠️  Deployment script not found"
        fi
    else
        echo "[Keycloak] ⏭️  Skipped"
    fi
}

# RUN BOUNDARY AND KEYCLOAK IN PARALLEL!
run_parallel deploy_boundary_full
run_parallel deploy_keycloak_full
wait_parallel

echo ""
echo "✅ Boundary & Keycloak deployed in parallel"
echo ""

# ==========================================
# Phase 5: Deploy VSO (can start now that Vault is ready)
# ==========================================
echo "=========================================="
echo "  Phase 5: Deploy Vault Secrets Operator"
echo "=========================================="
echo ""

if [[ "$SKIP_VSO" != "true" ]]; then
    echo "[VSO] Starting deployment..."
    kubectl apply -f "$K8S_DIR/platform/vault-secrets-operator/manifests/01-namespace.yaml"

    helm upgrade --install vault-secrets-operator hashicorp/vault-secrets-operator \
        --namespace vault-secrets-operator-system \
        --set defaultVaultConnection.enabled=false \
        --set defaultAuthMethod.enabled=false \
        --wait --timeout 2m

    # Apply VSO resources in parallel
    {
        kubectl apply -f "$K8S_DIR/platform/vault-secrets-operator/manifests/02-vaultconnection.yaml" &
        kubectl apply -f "$K8S_DIR/platform/vault-secrets-operator/manifests/03-vaultauth.yaml" &
        wait
    }

    # Configure Vault for VSO
    if [[ -n "$ROOT_TOKEN" ]]; then
        # Ensure Vault is unsealed
        VAULT_STATUS=$(get_vault_status 3 3)
        SEALED=$(echo "$VAULT_STATUS" | jq -r 'if .sealed == null then true else .sealed end')
        if [[ "$SEALED" == "true" ]] && [[ -n "$UNSEAL_KEY" ]]; then
            kubectl exec -n vault vault-0 -- vault operator unseal "$UNSEAL_KEY" >/dev/null 2>&1
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
            vault kv put secret/devenv/credentials github_token=placeholder-update-me langfuse_host= langfuse_public_key= langfuse_secret_key=
        " 2>/dev/null
        echo "⚠️  Update credentials with: ./platform/vault/scripts/configure-secrets.sh"
    fi

    kubectl apply -f "$K8S_DIR/platform/vault-secrets-operator/manifests/04-vaultstaticsecret-example.yaml"

    # Poll for secret sync
    echo "[VSO] ⏳ Waiting for secrets to sync..."
    for i in {1..30}; do
        kubectl get secret devenv-vault-secrets -n devenv &>/dev/null && break
        sleep 1
    done

    # Restart devenv pod
    if kubectl get pod -l app=claude-code-sandbox -n devenv &>/dev/null; then
        echo "🔄 Restarting devenv sandbox..."
        kubectl delete pod -n devenv -l app=claude-code-sandbox --wait=false 2>/dev/null || true
    fi

    echo "[VSO] ✅ Deployed"
else
    echo "[VSO] ⏭️  Skipped"
fi

# ==========================================
# Phase 6: Post-Deployment Configuration
# Update hostAliases, configure OIDC
# ==========================================
echo ""
echo "=========================================="
echo "  Phase 6: Post-Deployment Configuration"
echo "=========================================="
echo ""

# Update Boundary hostAliases for Keycloak connectivity
if [[ "$DEPLOY_KEYCLOAK" == "true" ]] && kubectl get deployment boundary-controller -n boundary &>/dev/null; then
    echo "Updating Boundary controller hostAliases..."
    INGRESS_IP=$(kubectl get svc ingress-nginx-controller -n ingress-nginx -o jsonpath='{.spec.clusterIP}' 2>/dev/null)
    if [[ -z "$INGRESS_IP" ]]; then
        INGRESS_IP=$(kubectl get svc keycloak-http -n keycloak -o jsonpath='{.spec.clusterIP}' 2>/dev/null || echo "127.0.0.1")
    fi
    BOUNDARY_API_IP=$(kubectl get svc boundary-controller-api -n boundary -o jsonpath='{.spec.clusterIP}' 2>/dev/null || echo "127.0.0.1")

    kubectl patch deployment boundary-controller -n boundary --type='json' -p="[
      {\"op\": \"replace\", \"path\": \"/spec/template/spec/hostAliases\", \"value\": [
        {\"ip\": \"$INGRESS_IP\", \"hostnames\": [\"keycloak.hashicorp.lab\"]},
        {\"ip\": \"$BOUNDARY_API_IP\", \"hostnames\": [\"boundary.hashicorp.lab\"]}
      ]}
    ]" 2>/dev/null || true
    kubectl rollout status deployment/boundary-controller -n boundary --timeout=60s 2>/dev/null || true
fi

# Configure Boundary targets
if [[ "$CONFIGURE_BOUNDARY_TARGETS" == "true" ]] && [[ "$DEPLOY_BOUNDARY" == "true" ]]; then
    echo "Configuring Boundary targets..."
    kubectl rollout status deployment/boundary-controller -n boundary --timeout=60s 2>/dev/null || true

    [[ -f "$K8S_DIR/platform/boundary/scripts/configure-targets.sh" ]] && \
        "$K8S_DIR/platform/boundary/scripts/configure-targets.sh" boundary devenv || true
fi

# Configure OIDC
if [[ "$DEPLOY_KEYCLOAK" == "true" ]] && [[ "$CONFIGURE_BOUNDARY_TARGETS" == "true" ]]; then
    KEYCLOAK_STATUS=$(kubectl get pod -l app=keycloak -n keycloak -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "NotFound")
    if [[ "$KEYCLOAK_STATUS" == "Running" ]]; then
        echo "Configuring Boundary OIDC..."
        [[ -f "$K8S_DIR/platform/boundary/scripts/configure-oidc-auth.sh" ]] && \
            "$K8S_DIR/platform/boundary/scripts/configure-oidc-auth.sh" || true
    fi
fi

echo "✅ Post-deployment configuration complete"

# ==========================================
# Status Summary (Parallel Queries)
# ==========================================
echo ""
echo "=========================================="
echo "  Deployment Status Summary"
echo "=========================================="
echo ""

echo "Pods:"
kubectl get pods -A 2>/dev/null | grep -E "(devenv|boundary|vault|keycloak)" || true

echo ""
echo "Services:"
{
    kubectl get svc -n devenv 2>/dev/null &
    kubectl get svc -n boundary 2>/dev/null &
    kubectl get svc -n vault 2>/dev/null &
    [[ "$DEPLOY_KEYCLOAK" == "true" ]] && kubectl get svc -n keycloak 2>/dev/null &
    wait
} || true

# ==========================================
# Run Tests
# ==========================================
echo ""
echo "=========================================="
echo "  Running Verification Tests"
echo "=========================================="
echo ""

if [[ -f "$SCRIPT_DIR/tests/run-all-tests.sh" ]]; then
    "$SCRIPT_DIR/tests/run-all-tests.sh" || true
fi

echo ""
echo "=========================================="
echo "  🎉 OPTIMIZED DEPLOYMENT COMPLETE"
echo "=========================================="
echo ""
echo "Components deployed:"
[[ "$SKIP_DEVENV" != "true" ]] && echo "  ✅ Agent Sandbox (devenv)"
[[ "$SKIP_VAULT" != "true" ]] && echo "  ✅ Vault"
[[ "$SKIP_BOUNDARY" != "true" ]] && echo "  ✅ Boundary"
[[ "$SKIP_VSO" != "true" ]] && echo "  ✅ Vault Secrets Operator"
[[ "$DEPLOY_KEYCLOAK" == "true" ]] && echo "  ✅ Keycloak"
echo ""
echo "Next steps:"
echo "  kubectl port-forward -n devenv svc/claude-code-sandbox 13337:13337"
echo "  Open: http://localhost:13337"
echo ""
