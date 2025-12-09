# Getting Started with Agent Sandbox Platform

This guide walks you through deploying the complete Agent Sandbox Platform to a Kubernetes cluster step by step.

## Prerequisites Checklist

- [ ] Docker installed and running
- [ ] kubectl installed (`kubectl version --client`)
- [ ] Helm 3.x installed (`helm version`)
- [ ] Kubernetes cluster running (Kind, K8s, or OpenShift)
- [ ] kubectl configured to access your cluster (`kubectl cluster-info`)

## Step 1: Validate Prerequisites

Run the prerequisite check script:

```bash
cd k8s/scripts
./check-prereqs.sh
```

Expected output:
```
==========================================
  Agent Sandbox Platform Prerequisites
==========================================

Checking kubectl... OK (v1.28.0)
Checking cluster connectivity... OK (context: kind-sandbox)
Checking Helm... OK (v3.12.0)
Checking Docker... OK (24.0.6)
Checking jq... OK (jq-1.6)
Checking openssl... OK (3.0.2)

==========================================
  All prerequisites met
==========================================

Ready to deploy. Run:
  ./deploy-all.sh
```

## Step 2: Create a Local Cluster (Optional)

If you don't have a Kubernetes cluster, create one with Kind:

```bash
cd k8s/scripts
./setup-kind.sh
```

This creates a cluster named `sandbox` with proper port mappings.

## Step 3: Configure the Platform (Optional)

Customize the deployment by copying and editing the configuration:

```bash
# Copy default config
cp scripts/platform.env scripts/.env

# Edit configuration
vi scripts/.env
```

Key options:
- `DEVENV_REPLICAS` - Number of agent sandbox pods (default: 1)
- `DEPLOY_BOUNDARY` - Enable Boundary secure access (default: true)
- `DEPLOY_VAULT` - Enable Vault secrets management (default: true)
- `DEPLOY_VSO` - Enable Vault Secrets Operator (default: true)

## Step 4: Deploy the Platform

Deploy all components with a single command:

```bash
cd k8s/scripts
./deploy-all.sh
```

This deploys:
1. **Agent Sandbox** - Multi-user development environments
2. **Vault** - Secrets management (auto-initialized)
3. **Boundary** - Secure access management
4. **Vault Secrets Operator** - Automatic secret synchronization

Expected output includes:
```
==========================================
  DEPLOYMENT COMPLETE
==========================================

Status:
devenv        devenv-0                        1/1     Running
vault         vault-0                         1/1     Running
boundary      boundary-controller-...         1/1     Running
boundary      boundary-worker-...             1/1     Running
```

## Step 5: Verify Deployment

Check all pods are running:

```bash
# Check all platform pods
kubectl get pods -A | grep -E "(devenv|boundary|vault)"

# Check secrets are synced (if VSO deployed)
kubectl get secret devenv-vault-secrets -n devenv
```

## Step 6: Access Your Environment

### Shell Access

```bash
# Get shell access to the agent sandbox
kubectl exec -it -n devenv devenv-0 -- /bin/bash

# You're now inside the development environment!
```

### Vault UI

```bash
# Port-forward to Vault
kubectl port-forward -n vault vault-0 8200:8200

# Open http://localhost:8200
# Use token from: k8s/platform/vault/scripts/vault-keys.txt
```

## Step 7: Configure Additional Services (Optional)

### SSH Secrets Engine

Generate SSH certificates for secure access:

```bash
./platform/vault/scripts/configure-ssh-engine.sh
```

### Terraform Enterprise Integration

Connect to Terraform Cloud/Enterprise for dynamic tokens:

```bash
./platform/vault/scripts/configure-tfe-engine.sh
```

## Step 8: Scale for Multiple Users

Scale the agent sandbox for multiple users:

```bash
# Scale to 3 replicas
cd k8s/agent-sandbox/scripts
./scale.sh 3

# Access different user environments
kubectl exec -it -n devenv devenv-0 -- /bin/bash  # User 1
kubectl exec -it -n devenv devenv-1 -- /bin/bash  # User 2
kubectl exec -it -n devenv devenv-2 -- /bin/bash  # User 3
```

## Platform Architecture

```
                           Agent Sandbox Platform
┌──────────────────────────────────────────────────────────────────────────┐
│                                                                          │
│   ┌─────────────┐   ┌─────────────┐   ┌─────────────┐   ┌─────────────┐ │
│   │   Vault     │   │  Boundary   │   │  Keycloak   │   │    VSO      │ │
│   │  (secrets)  │   │  (access)   │   │   (OIDC)    │   │   (sync)    │ │
│   │   :8200     │   │   :9200     │   │   :8080     │   │             │ │
│   └──────┬──────┘   └──────┬──────┘   └──────┬──────┘   └──────┬──────┘ │
│          │                 │                 │                 │        │
│          │                 │    OIDC Auth    │                 │        │
│          │                 │◄───────────────►│                 │        │
│          │                 │                                   │        │
│          │                 │ SSH Proxy                         │        │
│          │                 ▼                                   │        │
│   ┌──────┴─────────────────────────────────────────────────────┴──────┐ │
│   │                        devenv namespace                           │ │
│   │                                                                   │ │
│   │   ┌─────────────┐   ┌─────────────┐   ┌─────────────┐           │ │
│   │   │  devenv-0   │   │  devenv-1   │   │  devenv-N   │           │ │
│   │   │             │   │             │   │             │           │ │
│   │   │ Claude Code │   │ Claude Code │   │ Claude Code │           │ │
│   │   │ Terraform   │   │ Terraform   │   │ Terraform   │           │ │
│   │   │ AWS CLI     │   │ AWS CLI     │   │ AWS CLI     │           │ │
│   │   │ Bun + Tools │   │ Bun + Tools │   │ Bun + Tools │           │ │
│   │   │             │   │             │   │             │           │ │
│   │   │ /workspace  │   │ /workspace  │   │ /workspace  │           │ │
│   │   │  (PVC)      │   │  (PVC)      │   │  (PVC)      │           │ │
│   │   └─────────────┘   └─────────────┘   └─────────────┘           │ │
│   │                                                                   │ │
│   │   Secrets (auto-synced from Vault):                              │ │
│   │   - GITHUB_TOKEN, TFE_TOKEN, LANGFUSE_*, AWS_*                   │ │
│   └───────────────────────────────────────────────────────────────────┘ │
└──────────────────────────────────────────────────────────────────────────┘

User Access Flow:
1. User → Boundary (OIDC auth via Keycloak)
2. Boundary Worker → DevEnv Pod (SSH proxy)
3. VSCode Remote SSH → Full IDE experience
```

## Common Tasks

### View Logs

```bash
# Agent sandbox logs
kubectl logs -n devenv devenv-0 -f

# Vault logs
kubectl logs -n vault vault-0 -f

# VSO controller logs
kubectl logs -n vault-secrets-operator-system -l app.kubernetes.io/name=vault-secrets-operator
```

### Restart Components

```bash
# Restart agent sandbox (data persists)
kubectl delete pod devenv-0 -n devenv

# Restart Vault (may require unseal)
kubectl delete pod vault-0 -n vault
```

### Port Forwarding

```bash
# Vault UI
kubectl port-forward -n vault vault-0 8200:8200

# Boundary API
kubectl port-forward -n boundary svc/boundary-api 9200:9200
```

### Copy Files

```bash
# Copy TO the pod
kubectl cp ./myfile.txt devenv/devenv-0:/workspace/myfile.txt

# Copy FROM the pod
kubectl cp devenv/devenv-0:/workspace/output.txt ./output.txt
```

## Persistent Storage

Data persists across pod restarts:

| Volume | Path | Purpose |
|--------|------|---------|
| workspace | /workspace | Code and projects |
| bash-history | /commandhistory | Shell history |
| claude-config | /home/node/.claude | Claude Code config |

```bash
# Check PVCs
kubectl get pvc -n devenv
```

## Troubleshooting

### Pod Not Starting

```bash
# Check pod events
kubectl describe pod devenv-0 -n devenv

# Check PVC binding
kubectl get pvc -n devenv
```

### Vault Sealed

```bash
# Check Vault status
kubectl exec -n vault vault-0 -- vault status

# Unseal if needed (get key from vault-keys.txt)
kubectl exec -n vault vault-0 -- vault operator unseal <UNSEAL_KEY>
```

### Secrets Not Syncing

```bash
# Check VaultStaticSecret status
kubectl describe vaultstaticsecret -n devenv

# Check VSO logs
kubectl logs -n vault-secrets-operator-system -l app.kubernetes.io/name=vault-secrets-operator
```

## Cleanup

### Remove Everything

```bash
cd k8s/scripts
./teardown-all.sh
```

This removes:
1. Vault Secrets Operator
2. Boundary (controller, worker, postgres)
3. Vault
4. Agent Sandbox

### Remove Kind Cluster

```bash
kind delete cluster --name sandbox
```

### Keep Data, Scale Down

```bash
# Scale to zero (keeps PVCs)
./agent-sandbox/scripts/scale.sh 0
```

## What You've Accomplished

- Deployed a complete secrets management platform (Vault)
- Set up secure access infrastructure (Boundary)
- Configured automatic secret synchronization (VSO)
- Created scalable, isolated development environments
- Enabled multi-user access with persistent storage

## Next Steps

1. **Configure SSH Engine**: Generate SSH certificates for secure access
2. **Integrate TFE**: Connect to Terraform Cloud for dynamic tokens
3. **Add Users**: Scale to multiple replicas for team access
4. **Set Up Ingress**: Expose services externally
5. **Add Monitoring**: Integrate Prometheus/Grafana

## Documentation

- [Platform README](README.md) - Full platform documentation
- [Agent Sandbox](agent-sandbox/README.md) - Development environment details
- [Architecture](ARCHITECTURE.md) - Platform architecture
- [Vault Integration](platform/vault/README.md) - Vault configuration
- [Boundary Access](platform/boundary/README.md) - Boundary setup
- [VSO Configuration](platform/vault-secrets-operator/README.md) - Secret sync

---

**Congratulations!** You now have a complete Agent Sandbox Platform running on Kubernetes!
