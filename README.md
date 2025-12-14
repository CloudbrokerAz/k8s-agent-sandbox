# K8s Agent Sandbox Platform

A complete Kubernetes-based development platform for AI agents with enterprise-grade security, secrets management, and secure access controls.

## Overview

This platform provides isolated development environments for AI agents (Claude Code, Google Gemini) with integrated:
- **HashiCorp Vault** - Centralized secrets management with dynamic credentials
- **HashiCorp Boundary** - Zero-trust network access with SSH certificate-based authentication
- **Keycloak** - Identity provider with OIDC/SSO support
- **Vault Secrets Operator** - Kubernetes-native secret synchronization

## Quick Start

### Prerequisites

1. **Docker** - For running Kind (Kubernetes in Docker)
2. **kubectl** - Kubernetes CLI (auto-installed if missing)
3. **Boundary Enterprise License** - Place at `k8s/scripts/license/boundary.hclic`

4. Add to `/etc/hosts`:
   ```
   127.0.0.1 vault.local boundary.local keycloak.local
   ```

### Deploy Everything

```bash
cd k8s/scripts
./deploy-all.sh
```

This will:
1. Create a Kind cluster (if not exists)
2. Deploy Claude Code Agent Sandbox
3. Deploy Gemini Agent Sandbox
4. Deploy Vault + initialize and unseal
5. Deploy Boundary + PostgreSQL
6. Deploy Vault Secrets Operator
7. Deploy Keycloak (optional)
8. Configure Boundary targets and OIDC

### Access the Sandboxes

#### Claude Code Sandbox (Browser IDE)
```bash
kubectl port-forward -n devenv svc/claude-code-sandbox 13337:13337
# Open http://localhost:13337
```

#### SSH Access (VSCode Remote SSH)
```bash
# 1. Port-forward Boundary worker
kubectl port-forward -n boundary svc/boundary-worker 9202:9202 &

# 2. Get Vault-signed SSH certificate
vault write -field=signed_key ssh/sign/devenv-access \
  public_key=@~/.ssh/id_rsa.pub \
  valid_principals=node > ~/.ssh/id_rsa-cert.pub

# 3. Connect via Boundary
export BOUNDARY_ADDR=https://boundary.local
export BOUNDARY_TLS_INSECURE=true
boundary connect -target-id=<TARGET_ID> -exec ssh -- \
  -i ~/.ssh/id_rsa \
  -o CertificateFile=~/.ssh/id_rsa-cert.pub \
  -l node -p '{{boundary.port}}' '{{boundary.ip}}'
```

### Teardown

```bash
cd k8s/scripts
./teardown-all.sh
```

## Architecture

```
┌─────────────────────────────────────────────┐
│         Kind Cluster (sandbox)              │
├─────────────────────────────────────────────┤
│                                             │
│  ┌──────────────────────────────────────┐  │
│  │   DevEnv Namespace                   │  │
│  │  ┌────────────┐  ┌────────────────┐  │  │
│  │  │ Claude Code│  │ Gemini Sandbox │  │  │
│  │  │  Sandbox   │  │  (Google AI)   │  │  │
│  │  └────────────┘  └────────────────┘  │  │
│  └──────────────────────────────────────┘  │
│                                             │
│  ┌──────────────────────────────────────┐  │
│  │   Vault (secrets management)         │  │
│  │   - SSH CA for certificate auth      │  │
│  │   - Dynamic TFE tokens               │  │
│  │   - KV secrets (GitHub, Langfuse)    │  │
│  └──────────────────────────────────────┘  │
│                                             │
│  ┌──────────────────────────────────────┐  │
│  │   Boundary (secure access)           │  │
│  │   - SSH targets for sandboxes        │  │
│  │   - OIDC with Keycloak               │  │
│  │   - Certificate-based auth           │  │
│  └──────────────────────────────────────┘  │
│                                             │
│  ┌──────────────────────────────────────┐  │
│  │   Keycloak (identity provider)       │  │
│  │   - agent-sandbox realm              │  │
│  │   - Demo users (admin, developer)    │  │
│  └──────────────────────────────────────┘  │
│                                             │
│  ┌──────────────────────────────────────┐  │
│  │   Vault Secrets Operator             │  │
│  │   - Auto-sync secrets to K8s         │  │
│  └──────────────────────────────────────┘  │
└─────────────────────────────────────────────┘
```

## Configuration

### Environment Variables

Copy and customize the environment file:
```bash
cp k8s/scripts/platform.env.example k8s/scripts/.env
```

Key variables:
- `BASE_IMAGE` - Base image for sandboxes (default: srlynch1/terraform-ai-tools:latest)
- `SKIP_CLAUDE_CODE` - Skip Claude Code sandbox deployment
- `SKIP_GEMINI` - Skip Gemini sandbox deployment
- `SKIP_VAULT` - Skip Vault deployment
- `SKIP_BOUNDARY` - Skip Boundary deployment
- `DEPLOY_KEYCLOAK` - Deploy Keycloak IDP

### Selective Deployment

```bash
# Deploy only Vault and Boundary
SKIP_CLAUDE_CODE=true SKIP_GEMINI=true ./deploy-all.sh

# Skip Keycloak
DEPLOY_KEYCLOAK=false ./deploy-all.sh
```

## Documentation

- **[k8s/README.md](k8s/README.md)** - Kubernetes platform details
- **[k8s/agent-sandbox/README.md](k8s/agent-sandbox/README.md)** - Agent sandbox architecture
- **[k8s/platform/boundary/README.md](k8s/platform/boundary/README.md)** - Boundary configuration
- **[k8s/platform/keycloak/README.md](k8s/platform/keycloak/README.md)** - Keycloak setup
- **[k8s/platform/vault-secrets-operator/README.md](k8s/platform/vault-secrets-operator/README.md)** - VSO configuration

## Testing

Run the comprehensive test suite:
```bash
cd k8s/scripts/tests
./run-all-tests.sh
```

Individual tests:
```bash
./healthcheck.sh           # Platform health check
./test-secrets.sh          # Vault secrets sync
./test-boundary.sh         # Boundary connectivity
./test-keycloak.sh         # Keycloak realm
./test-oidc-auth.sh        # OIDC authentication
```

## Troubleshooting

### Vault Sealed
```bash
# Unseal Vault
kubectl exec -n vault vault-0 -- vault operator unseal <UNSEAL_KEY>
```

### Boundary Targets Not Configured
```bash
# Manually configure targets
k8s/platform/boundary/scripts/configure-targets.sh boundary devenv
```

### View Credentials
- Vault: `k8s/platform/vault/scripts/vault-keys.txt`
- Boundary: `k8s/platform/boundary/scripts/boundary-credentials.txt`

## License

See LICENSE file for details.
