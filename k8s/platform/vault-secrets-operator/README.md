# Vault Secrets Operator (VSO)

Deploy HashiCorp Vault Secrets Operator to automatically sync secrets from Vault to Kubernetes.

## Overview

VSO watches for custom resources (VaultStaticSecret, VaultDynamicSecret) and automatically syncs secrets from Vault to Kubernetes Secrets. When secrets change in Vault, they are automatically updated in Kubernetes.

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    Kubernetes Cluster                        │
│                                                              │
│  ┌─────────────────────────────────────────────────────┐    │
│  │        vault-secrets-operator-system namespace       │    │
│  │                                                      │    │
│  │  ┌────────────────────────────────────────────────┐ │    │
│  │  │      VSO Controller Manager                     │ │    │
│  │  │  - Watches VaultStaticSecret CRs               │ │    │
│  │  │  - Authenticates to Vault                       │ │    │
│  │  │  - Syncs secrets to K8s                        │ │    │
│  │  └────────────────────┬───────────────────────────┘ │    │
│  │                       │                              │    │
│  └───────────────────────┼──────────────────────────────┘    │
│                          │                                   │
│  ┌───────────────────────┼──────────────────────────────┐   │
│  │      vault namespace  │                              │   │
│  │                       ▼                              │   │
│  │              ┌─────────────────┐                     │   │
│  │              │  Vault Server   │                     │   │
│  │              │  KV Secrets     │                     │   │
│  │              │  SSH Certs      │                     │   │
│  │              └─────────────────┘                     │   │
│  └──────────────────────────────────────────────────────┘   │
│                          │                                   │
│  ┌───────────────────────┼──────────────────────────────┐   │
│  │      devenv namespace │                              │   │
│  │                       ▼                              │   │
│  │  VaultStaticSecret ──► K8s Secret (auto-synced)     │   │
│  │                                                      │   │
│  └──────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
```

## Prerequisites

- Kubernetes cluster with kubectl access
- Helm 3.x installed
- Vault deployed and initialized (`/workspace/k8s/vault/`)

## Quick Start

```bash
cd /workspace/k8s/vault-secrets-operator/scripts

# 1. Deploy VSO (installs via Helm)
./deploy-vso.sh

# 2. Configure Vault Kubernetes auth
./configure-vault-k8s-auth.sh

# 3. Secrets will auto-sync based on VaultStaticSecret CRs
```

## Directory Structure

```
vault-secrets-operator/
├── manifests/
│   ├── 01-namespace.yaml            # VSO namespace
│   ├── 02-vaultconnection.yaml      # Vault connection config
│   ├── 03-vaultauth.yaml            # Auth method configs
│   ├── 04-vaultstaticsecret-example.yaml  # Example secret sync
│   └── kustomization.yaml
├── scripts/
│   ├── deploy-vso.sh                # Deploy VSO via Helm
│   ├── configure-vault-k8s-auth.sh  # Setup Vault K8s auth
│   └── teardown-vso.sh              # Remove VSO
└── README.md
```

## Custom Resources

### VaultConnection
Defines how to connect to Vault:
```yaml
apiVersion: secrets.hashicorp.com/v1beta1
kind: VaultConnection
metadata:
  name: vault-connection
  namespace: devenv
spec:
  address: http://vault.vault.svc.cluster.local:8200
  skipTLSVerify: true
```

### VaultAuth
Configures authentication to Vault:
```yaml
apiVersion: secrets.hashicorp.com/v1beta1
kind: VaultAuth
metadata:
  name: devenv-vault-auth
  namespace: devenv
spec:
  vaultConnectionRef: vault-connection
  method: kubernetes
  mount: kubernetes
  kubernetes:
    role: devenv-secrets
    serviceAccount: default
```

### VaultStaticSecret
Syncs a secret from Vault to Kubernetes:
```yaml
apiVersion: secrets.hashicorp.com/v1beta1
kind: VaultStaticSecret
metadata:
  name: devenv-credentials
  namespace: devenv
spec:
  vaultAuthRef: devenv-vault-auth
  type: kv-v2
  mount: secret
  path: devenv/credentials
  destination:
    name: devenv-vault-secrets
    create: true
  refreshAfter: 30s
```

## Usage

### Create a secret in Vault
```bash
vault kv put secret/devenv/credentials \
    username=myuser \
    password=mypassword \
    api_key=my-api-key
```

### Apply VaultStaticSecret
```bash
kubectl apply -f manifests/04-vaultstaticsecret-example.yaml
```

### Verify sync
```bash
kubectl get secret devenv-vault-secrets -n devenv -o yaml
```

### Decode secret values
```bash
kubectl get secret devenv-vault-secrets -n devenv \
  -o jsonpath='{.data.username}' | base64 -d
```

## Troubleshooting

### Check VSO logs
```bash
kubectl logs -n vault-secrets-operator-system \
  -l app.kubernetes.io/name=vault-secrets-operator
```

### Check secret sync status
```bash
kubectl describe vaultstaticsecret <name> -n <namespace>
```

### Common issues

1. **Permission denied**: Check Vault policy and Kubernetes auth role
2. **VaultConnection not found**: Ensure VaultConnection is in same namespace as VaultAuth
3. **Secret not syncing**: Check VaultStaticSecret events for errors

## Cleanup

```bash
./scripts/teardown-vso.sh
```

## Additional Resources

- [VSO Documentation](https://developer.hashicorp.com/vault/docs/platform/k8s/vso)
- [VSO Tutorials](https://developer.hashicorp.com/vault/tutorials/kubernetes/vault-secrets-operator)
- [API Reference](https://developer.hashicorp.com/vault/docs/platform/k8s/vso/api-reference)
