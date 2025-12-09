# Agent Sandbox - Multi-User Development Environment

The Agent Sandbox provides isolated development environments for AI agents and developers running on Kubernetes. Each environment is a stateful pod with persistent storage, pre-configured tooling, and access to shared platform services.

## Overview

```
agent-sandbox/
├── manifests/           # Kubernetes manifests
│   ├── 01-namespace.yaml
│   ├── 02-secrets.yaml (template)
│   ├── 03-storageclass.yaml
│   ├── 04-pvc-template.yaml
│   ├── 05-statefulset.yaml
│   ├── 06-service.yaml
│   ├── 07-networkpolicy.yaml
│   └── sandbox-override.yaml
└── scripts/
    ├── deploy.sh
    ├── create-secrets.sh
    ├── scale.sh
    ├── teardown.sh
    └── build-and-push.sh
```

## Features

- **Isolated Environments**: Each pod runs independently with its own filesystem
- **Persistent Storage**: Work survives pod restarts via PersistentVolumeClaims
- **Pre-configured Tools**: Git, Terraform, AWS CLI, kubectl, and development tools
- **Auto-installed Tools**: Claude Code, Bun, and ccstatusline installed at startup
- **Secret Injection**: Credentials synced from Vault via VSO
- **Network Isolation**: Controlled ingress/egress via NetworkPolicies
- **SSH Access**: Optional SSH access via Boundary

## Pre-installed Tools

Each devenv pod comes with:

| Tool | Description |
|------|-------------|
| **Claude Code** | AI-powered coding assistant CLI |
| **Terraform** | Infrastructure as code tool |
| **AWS CLI** | AWS command-line interface |
| **Bun** | Fast JavaScript runtime and package manager |
| **ccstatusline** | Claude Code status line customization |
| **Git** | Version control |
| **kubectl** | Kubernetes CLI |

## Quick Start

### Deploy (Standalone)

```bash
cd /workspace/k8s/agent-sandbox/scripts

# Create namespace and secrets
./create-secrets.sh

# Deploy the StatefulSet
./deploy.sh
```

### Deploy (Full Platform)

Use the master deployment script to deploy with all platform services:

```bash
cd /workspace/k8s/scripts
./deploy-all.sh
```

### Access Your Environment

```bash
# Get shell access
kubectl exec -it -n devenv devenv-0 -- /bin/bash

# View logs
kubectl logs -n devenv devenv-0 -f
```

## Scaling

Scale the number of development environments:

```bash
# Scale to 3 replicas
./scripts/scale.sh 3

# Check status
kubectl get pods -n devenv
```

## Configuration

### Environment Variables

The following secrets are injected into each pod:

| Variable | Description |
|----------|-------------|
| `GITHUB_TOKEN` | GitHub personal access token |
| `TFE_TOKEN` | Terraform Cloud/Enterprise token |
| `AWS_ACCESS_KEY_ID` | AWS access key |
| `AWS_SECRET_ACCESS_KEY` | AWS secret key |

### Resource Limits

Default resource allocation per pod:

```yaml
resources:
  requests:
    memory: "2Gi"
    cpu: "500m"
  limits:
    memory: "4Gi"
    cpu: "2000m"
```

### Security Context

The devenv pods run with a relaxed security context for development convenience:

```yaml
securityContext:
  runAsUser: 0      # Root user for full permissions
  runAsGroup: 0
  fsGroup: 0
```

For production deployments, consider tightening permissions.

### Storage

Each pod gets 10Gi of persistent storage (configurable via PVC template).

## Integration with Platform Services

### Vault Secrets Operator

Secrets are automatically synced from Vault:

```bash
# View synced secrets
kubectl get secret devenv-vault-secrets -n devenv -o yaml

# Check sync status
kubectl get vaultstaticsecret -n devenv
```

### Boundary Access

SSH access to agent sandbox pods via Boundary:

```bash
# Connect via Boundary CLI
boundary connect ssh -target-name=devenv-ssh
```

## Cleanup

```bash
# Remove agent sandbox only
./scripts/teardown.sh

# Remove entire platform
cd /workspace/k8s/scripts
./teardown-all.sh
```

## Troubleshooting

### Pod Not Starting

```bash
# Check pod events
kubectl describe pod -n devenv devenv-0

# Check PVC binding
kubectl get pvc -n devenv
```

### Secrets Not Available

```bash
# Verify secret exists
kubectl get secret devenv-secrets -n devenv

# Check VSO sync status
kubectl describe vaultstaticsecret -n devenv
```

## Related Documentation

- [Platform Architecture](../ARCHITECTURE.md)
- [Getting Started Guide](../GETTING_STARTED.md)
- [Vault Integration](../platform/vault/README.md)
- [Boundary Access](../platform/boundary/README.md)
