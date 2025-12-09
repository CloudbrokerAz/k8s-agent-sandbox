# Claude Code Sandbox

Kubernetes-native sandbox environment for Claude Code, following the [kubernetes-sigs/agent-sandbox](https://github.com/kubernetes-sigs/agent-sandbox) pattern.

## Overview

This deployment uses:
- **Sandbox CRD** from kubernetes-sigs/agent-sandbox for lifecycle management
- **envbuilder** to build the devcontainer at runtime
- **ConfigMap-based devcontainer.json** (no external git clone required)
- **code-server** for browser-based VS Code access
- **SSH** for native VS Code Remote SSH access
- **srlynch1/terraform-ai-tools** base image (Claude Code installed via postCreateCommand)

## Quick Start

```bash
# Deploy (installs CRD if needed)
./deploy.sh

# Access via code-server
kubectl port-forward -n devenv svc/claude-code-sandbox 13337:13337
# Open http://localhost:13337

# Access via shell
kubectl exec -it -n devenv $(kubectl get pod -n devenv -l app=claude-code-sandbox -o jsonpath='{.items[0].metadata.name}') -- /bin/bash

# Teardown
./teardown.sh
```

## Structure

```
k8s/agent-sandbox/
├── base/                              # Base Kustomize manifests
│   ├── kustomization.yaml
│   ├── devcontainer-configmap.yaml    # ConfigMap with devcontainer.json + entrypoint.sh
│   ├── claude-code-sandbox.yaml       # Sandbox CRD
│   └── service.yaml
├── overlays/                          # Optional runtime overlays
│   ├── gvisor/                        # gVisor sandbox isolation
│   └── kata/                          # Kata VM isolation
├── devcontainer.json                  # DevContainer configuration (reference)
├── deploy.sh                          # End-to-end deployment script
├── teardown.sh                        # Cleanup script
├── PLAN.md                            # Implementation checklist
└── README.md                          # This file
```

## Deployment Options

### Base (default)
```bash
./deploy.sh
# or
kubectl apply -k base/
```

### With gVisor isolation
```bash
OVERLAY=gvisor ./deploy.sh
# or
kubectl apply -k overlays/gvisor/
```

### With Kata Containers isolation
```bash
OVERLAY=kata ./deploy.sh
# or
kubectl apply -k overlays/kata/
```

## Pre-installed Tools

Each sandbox comes with:

| Tool | Description |
|------|-------------|
| **Claude Code** | AI-powered coding assistant CLI |
| **code-server** | Browser-based VS Code |
| **Node.js LTS** | JavaScript runtime |
| **Docker** | Container runtime (via dind) |
| **SSH** | Remote access via SSH |

## Environment Variables

The sandbox is configured with these environment variables:

| Variable | Description |
|----------|-------------|
| `GITHUB_TOKEN` | GitHub authentication (from secret) |
| `TFE_TOKEN` | Terraform Cloud token (from secret) |
| `LANGFUSE_*` | Observability tokens (from secret) |
| `VAULT_ADDR` | Vault server address |
| `CLAUDE_CONFIG_DIR` | Claude Code config path |

## Secrets

Create the required secret before deployment:

```bash
kubectl create namespace devenv
kubectl create secret generic devenv-vault-secrets -n devenv \
  --from-literal=GITHUB_TOKEN=$GITHUB_TOKEN \
  --from-literal=TFE_TOKEN=$TFE_TOKEN \
  --from-literal=LANGFUSE_HOST=$LANGFUSE_HOST \
  --from-literal=LANGFUSE_PUBLIC_KEY=$LANGFUSE_PUBLIC_KEY \
  --from-literal=LANGFUSE_SECRET_KEY=$LANGFUSE_SECRET_KEY
```

Or use Vault Secrets Operator (VSO) to sync from Vault.

## Persistent Storage

The sandbox uses these PVCs:
- `workspaces-pvc` (20Gi) - Workspace and repo data
- `claude-config-pvc` (1Gi) - Claude Code configuration
- `bash-history-pvc` (1Gi) - Shell history

## Access Methods

1. **code-server (Browser IDE)**
   ```bash
   kubectl port-forward -n devenv svc/claude-code-sandbox 13337:13337
   ```
   Open http://localhost:13337

2. **kubectl exec**
   ```bash
   kubectl exec -it -n devenv claude-code-sandbox-0 -- /bin/bash
   ```

3. **SSH via Boundary** (if configured)
   ```bash
   boundary connect ssh -target-id=<target> -- -l node
   ```

## Troubleshooting

### Check sandbox status
```bash
kubectl get sandbox -n devenv
kubectl get pods -n devenv
```

### View logs
```bash
kubectl logs -f -n devenv -l app=claude-code-sandbox
```

### Envbuilder taking too long
First-time builds can take 5-10 minutes. Check logs for progress:
```bash
kubectl logs -f -n devenv claude-code-sandbox-0
```

### CRD not found
```bash
kubectl apply -f https://github.com/kubernetes-sigs/agent-sandbox/releases/download/v0.1.0/manifest.yaml
```

## Integration with Platform Services

### Vault Secrets Operator
Secrets are automatically synced from Vault when VSO is configured.

### Boundary Access
SSH access to sandbox pods via Boundary for secure remote access.

## References

- [kubernetes-sigs/agent-sandbox](https://github.com/kubernetes-sigs/agent-sandbox)
- [coder/envbuilder](https://github.com/coder/envbuilder)
- [DevContainers specification](https://containers.dev/)
