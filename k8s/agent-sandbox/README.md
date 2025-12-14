# Agent Sandboxes

Kubernetes-native development environments for AI agents, following the [kubernetes-sigs/agent-sandbox](https://github.com/kubernetes-sigs/agent-sandbox) pattern.

## Overview

Two isolated sandbox environments:

- **Claude Code Sandbox** (`vscode-claude/`) - AI-powered development with Claude Code
- **Gemini Sandbox** (`vscode-gemini/`) - Google AI agent development with Gemini CLI

Both use:
- **Sandbox CRD** from kubernetes-sigs/agent-sandbox for lifecycle management
- **envbuilder** to build devcontainer at runtime
- **code-server** for browser-based VS Code access
- **SSH** for VSCode Remote SSH access
- **srlynch1/terraform-ai-tools** base image

## Directory Structure

```
k8s/agent-sandbox/
├── vscode-claude/                 # Claude Code sandbox
│   ├── base/                      # Kubernetes manifests
│   │   ├── kustomization.yaml
│   │   ├── claude-code-sandbox.yaml
│   │   └── service.yaml
│   ├── devcontainer.json          # Dev container configuration
│   ├── entrypoint.sh              # Container startup script
│   └── scripts/
│       └── setup-ssh-ca.sh        # Configure Vault SSH CA
├── vscode-gemini/                 # Gemini sandbox
│   ├── base/                      # Kubernetes manifests
│   │   ├── kustomization.yaml
│   │   ├── gemini-sandbox.yaml
│   │   └── service.yaml
│   ├── devcontainer.json          # Dev container configuration
│   ├── entrypoint.sh              # Container startup script
│   └── scripts/
│       └── setup-ssh-ca.sh        # Configure Vault SSH CA
├── overlays/                      # Optional runtime overlays
│   ├── gvisor/                    # gVisor sandbox isolation
│   └── kata/                      # Kata Containers isolation
├── deploy.sh                      # Deployment script (deploys Claude Code)
├── teardown.sh                    # Cleanup script
├── cached-manifest.yaml           # Cached Agent-Sandbox CRD
└── README.md                      # This file
```

## Quick Start

### Deploy via deploy-all.sh (Recommended)

```bash
cd k8s/scripts
./deploy-all.sh
```

This deploys both sandboxes plus the complete platform.

### Deploy Manually

```bash
# Deploy Claude Code sandbox only
cd k8s/agent-sandbox
./deploy.sh

# Deploy Gemini sandbox separately
kubectl apply -k vscode-gemini/base/
```

## Access

### Claude Code Sandbox

**Browser IDE:**
```bash
kubectl port-forward -n devenv svc/claude-code-sandbox 13337:13337
# Open http://localhost:13337
```

**Shell:**
```bash
POD=$(kubectl get pod -n devenv -l app=claude-code-sandbox -o jsonpath='{.items[0].metadata.name}')
kubectl exec -it -n devenv $POD -- /bin/bash
```

### Gemini Sandbox

**Browser IDE:**
```bash
kubectl port-forward -n devenv svc/gemini-sandbox-ssh 13338:13337
# Open http://localhost:13338
```

**Shell:**
```bash
POD=$(kubectl get pod -n devenv -l app=gemini-sandbox -o jsonpath='{.items[0].metadata.name}')
kubectl exec -it -n devenv $POD -- /bin/bash
```

### SSH Access (via Boundary)

See [Boundary README](../platform/boundary/README.md) for SSH setup via Vault-signed certificates.

## Pre-installed Tools

Both sandboxes include:

| Tool | Description |
|------|-------------|
| **code-server** | Browser-based VS Code |
| **Node.js LTS** | JavaScript runtime |
| **Terraform** | Infrastructure as Code |
| **AWS CLI** | AWS command line tools |
| **kubectl** | Kubernetes CLI |
| **SSH** | Remote access |

### Claude Code Sandbox
Additionally includes:
- **Claude Code** - AI-powered coding assistant

### Gemini Sandbox
Additionally includes:
- **@google/gemini-cli** - Google Gemini AI CLI

## Configuration

### Dev Container Configuration

Each sandbox has its own `devcontainer.json`:
- `vscode-claude/devcontainer.json` - Claude Code configuration
- `vscode-gemini/devcontainer.json` - Gemini configuration

Customize these files to add tools, extensions, or modify the environment.

### Environment Variables

Sandboxes receive secrets from `devenv-vault-secrets`:

| Variable | Description |
|----------|-------------|
| `GITHUB_TOKEN` | GitHub authentication |
| `TFE_TOKEN` | Terraform Cloud token |
| `LANGFUSE_*` | Observability credentials |
| `VAULT_ADDR` | Vault server address |

Secrets are synced from Vault via Vault Secrets Operator (VSO).

## Deployment Options

### Base (default)

```bash
./deploy.sh
```

### With gVisor Isolation

```bash
OVERLAY=gvisor ./deploy.sh
```

Requires gVisor runtime class in your cluster.

### With Kata Containers

```bash
OVERLAY=kata ./deploy.sh
```

Requires Kata Containers runtime class in your cluster.

## Persistent Storage

Each sandbox uses persistent volumes:

- **`workspaces-pvc`** (20Gi) - Workspace and repository data
- **`claude-config-pvc` / `gemini-config-pvc`** (1Gi) - Agent configuration
- **`bash-history-pvc`** (1Gi) - Shell history

Storage persists across pod restarts.

## Troubleshooting

### Check Status

```bash
# Check Sandbox CRDs
kubectl get sandbox -n devenv

# Check pods
kubectl get pods -n devenv

# Check services
kubectl get svc -n devenv
```

### View Logs

```bash
# Claude Code sandbox
kubectl logs -f -n devenv -l app=claude-code-sandbox

# Gemini sandbox
kubectl logs -f -n devenv -l app=gemini-sandbox
```

### Common Issues

**Pod stuck in Init state:**
```bash
# Check envbuilder is pulling/building the devcontainer
kubectl describe pod -n devenv <POD_NAME>
```

**Can't access code-server:**
```bash
# Verify port-forward
kubectl get svc -n devenv
kubectl port-forward -n devenv svc/claude-code-sandbox 13337:13337
```

**SSH access fails:**
```bash
# Check Boundary target configuration
cat ../platform/boundary/scripts/boundary-credentials.txt

# Verify Vault SSH CA is configured
kubectl exec -n vault vault-0 -- vault read ssh/config/ca
```

## Cleanup

### Remove Both Sandboxes

```bash
./teardown.sh
kubectl delete -k vscode-gemini/base/
```

### Remove Everything

```bash
cd k8s/scripts
./teardown-all.sh
```

## Security

### SSH Certificate Authentication

- No password-based SSH authentication
- Vault-signed certificates with short TTLs (24h default)
- Certificates contain user principal (`node`)
- Automatic CA public key configuration

### Network Isolation

- NetworkPolicies restrict traffic
- No direct external access (access via Boundary)
- Isolated from other namespaces

### Secrets Management

- Secrets stored in Vault
- Auto-synced to Kubernetes via VSO
- No secrets in container images or git

## Next Steps

1. **Customize tools** - Edit `devcontainer.json` for your stack
2. **Add VS Code extensions** - Update `devcontainer.json` extensions list
3. **Configure Boundary** - Setup SSH targets for remote access
4. **Integrate monitoring** - Add observability for sandbox usage

## References

- [Agent-Sandbox Project](https://github.com/kubernetes-sigs/agent-sandbox)
- [Dev Containers Specification](https://containers.dev/)
- [envbuilder Documentation](https://github.com/coder/envbuilder)
- [code-server Documentation](https://coder.com/docs/code-server)
