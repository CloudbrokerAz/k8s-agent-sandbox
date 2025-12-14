# Agent Sandbox Platform - Kubernetes Deployment

Kubernetes-based development platform for AI agents with integrated secrets management, secure access, and identity management.

## Directory Structure

```
k8s/
├── agent-sandbox/               # AI agent development environments
│   ├── vscode-claude/          # Claude Code sandbox configuration
│   │   ├── base/               # Kubernetes manifests
│   │   ├── devcontainer.json   # Dev container configuration
│   │   └── entrypoint.sh       # Container startup script
│   ├── vscode-gemini/          # Gemini sandbox configuration
│   │   ├── base/               # Kubernetes manifests
│   │   ├── devcontainer.json   # Dev container configuration
│   │   └── entrypoint.sh       # Container startup script
│   ├── deploy.sh               # Deployment script
│   ├── teardown.sh             # Cleanup script
│   └── cached-manifest.yaml    # Cached Agent-Sandbox CRD
├── platform/                    # Supporting infrastructure
│   ├── boundary/               # HashiCorp Boundary (secure access)
│   ├── vault/                  # HashiCorp Vault (secrets)
│   ├── keycloak/               # Keycloak (identity provider)
│   └── vault-secrets-operator/ # VSO (secret sync)
└── scripts/                     # Deployment automation
    ├── deploy-all.sh           # Master deployment script
    ├── teardown-all.sh         # Master cleanup script
    ├── setup-kind.sh           # Create Kind cluster
    └── platform.env.example    # Configuration template
```

## Architecture

### Agent Sandboxes

Two AI agent development environments:

- **Claude Code Sandbox** - AI-powered development with Claude Code
  - Browser-based IDE (code-server)
  - SSH access for VSCode Remote Development
  - Pre-installed: Terraform, AWS CLI, kubectl, etc.

- **Gemini Sandbox** - AI agent development environment
  - Google Gemini CLI for AI-assisted development
  - Similar tooling and features as Claude Code sandbox
  - Isolated workspace

### Platform Services

- **HashiCorp Vault** - Secrets management
  - SSH CA for certificate-based authentication
  - Dynamic Terraform Cloud/Enterprise tokens
  - KV secrets (GitHub tokens, Langfuse credentials, etc.)

- **HashiCorp Boundary** - Zero-trust network access
  - SSH targets for each sandbox
  - OIDC integration with Keycloak
  - Vault-signed SSH certificates

- **Keycloak** - Identity provider
  - `agent-sandbox` realm
  - Demo users (admin, developer, readonly)
  - OIDC client for Boundary

- **Vault Secrets Operator** - Kubernetes integration
  - Auto-sync Vault secrets to Kubernetes secrets
  - Dynamic secret rotation

## Quick Start

### Prerequisites

1. **Docker** - For Kind cluster
2. **kubectl** - Kubernetes CLI
3. **Boundary License** - Enterprise license at `k8s/scripts/license/boundary.hclic`

Add to `/etc/hosts`:
```
127.0.0.1 vault.local boundary.local keycloak.local
```

### Deploy Complete Platform

```bash
cd k8s/scripts
./deploy-all.sh
```

This deploys:
1. Agent-Sandbox CRD + controller
2. Claude Code sandbox
3. Gemini sandbox
4. Vault (auto-initialized)
5. Boundary + PostgreSQL
6. Keycloak + PostgreSQL
7. Vault Secrets Operator
8. Boundary targets + OIDC configuration

### Access Sandboxes

#### Browser IDE (Claude Code)

```bash
kubectl port-forward -n devenv svc/claude-code-sandbox 13337:13337
# Open http://localhost:13337
```

#### SSH Access (VSCode Remote)

```bash
# 1. Port-forward Boundary worker
kubectl port-forward -n boundary svc/boundary-worker 9202:9202 &

# 2. Get Vault-signed SSH certificate
vault write -field=signed_key ssh/sign/devenv-access \
  public_key=@~/.ssh/id_rsa.pub \
  valid_principals=node > ~/.ssh/id_rsa-cert.pub

# 3. Get target ID from credentials file
cat k8s/platform/boundary/scripts/boundary-credentials.txt

# 4. Connect
export BOUNDARY_ADDR=https://boundary.local
export BOUNDARY_TLS_INSECURE=true
boundary connect -target-id=<TARGET_ID> -exec ssh -- \
  -i ~/.ssh/id_rsa \
  -o CertificateFile=~/.ssh/id_rsa-cert.pub \
  -l node -p '{{boundary.port}}' '{{boundary.ip}}'
```

## Configuration

### Environment Variables

Copy and customize:

```bash
cp k8s/scripts/platform.env.example k8s/scripts/.env
```

Key variables:

```bash
# Namespace configuration
DEVENV_NAMESPACE="devenv"              # Sandboxes namespace
VAULT_NAMESPACE="vault"                # Vault namespace
BOUNDARY_NAMESPACE="boundary"          # Boundary namespace

# Image configuration
BASE_IMAGE="srlynch1/terraform-ai-tools:latest"

# Deployment control
SKIP_CLAUDE_CODE="false"               # Skip Claude Code sandbox
SKIP_GEMINI="false"                    # Skip Gemini sandbox
SKIP_VAULT="false"                     # Skip Vault
SKIP_BOUNDARY="false"                  # Skip Boundary
DEPLOY_KEYCLOAK="true"                 # Deploy Keycloak
```

### Selective Deployment

```bash
# Deploy only Vault and Boundary
SKIP_CLAUDE_CODE=true SKIP_GEMINI=true ./deploy-all.sh

# Skip Keycloak
DEPLOY_KEYCLOAK=false ./deploy-all.sh

# Resume partial deployment
RESUME=auto ./deploy-all.sh
```

## Advanced Features

### Parallel Deployment

Enable parallel execution for faster deployment:

```bash
PARALLEL=true ./deploy-all.sh
```

Components deploy concurrently:
- Base image loading
- Claude Code sandbox
- Gemini sandbox
- Vault
- Boundary
- Helm repository setup

### Resume Mode

Auto-detect and skip already-running components:

```bash
RESUME=auto ./deploy-all.sh
```

Detects:
- Running Vault StatefulSet
- Running Boundary controller
- Deployed sandboxes
- Running VSO

## Testing

### Health Check

```bash
cd k8s/scripts/tests
./healthcheck.sh
```

Checks:
- Vault status and unsealing
- Boundary controller and worker
- Agent sandbox pods
- Keycloak realm configuration
- OIDC integration
- VSO deployment

### Individual Tests

```bash
cd k8s/scripts/tests

./test-secrets.sh          # Vault secrets sync via VSO
./test-boundary.sh         # Boundary connectivity
./test-keycloak.sh         # Keycloak realm
./test-oidc-auth.sh        # OIDC authentication
./test-oidc-browser.sh     # Browser-based OIDC flow
```

## Troubleshooting

### View Credentials

```bash
# Vault root token and unseal keys
cat k8s/platform/vault/scripts/vault-keys.txt

# Boundary admin credentials
cat k8s/platform/boundary/scripts/boundary-credentials.txt

# Keycloak admin credentials
kubectl get secret keycloak-admin -n keycloak -o jsonpath='{.data.KEYCLOAK_ADMIN_PASSWORD}' | base64 -d
```

### Vault Sealed

```bash
# Get unseal key from vault-keys.txt
kubectl exec -n vault vault-0 -- vault operator unseal <UNSEAL_KEY>
```

### Boundary Targets Not Found

```bash
# Manually configure targets
k8s/platform/boundary/scripts/configure-targets.sh
```

### Pod Issues

```bash
# Check sandbox status
kubectl get pods -n devenv
kubectl describe pod -n devenv claude-code-sandbox-<ID>
kubectl logs -n devenv claude-code-sandbox-<ID> -f

# Check Vault
kubectl get pods -n vault
kubectl logs -n vault vault-0

# Check Boundary
kubectl get pods -n boundary
kubectl logs -n boundary -l app=boundary-controller
```

## Cleanup

### Complete Teardown

```bash
cd k8s/scripts
./teardown-all.sh
```

Removes:
- All sandboxes
- Vault
- Boundary
- Keycloak
- VSO
- Agent-Sandbox CRD and controller

### Selective Cleanup

```bash
# Teardown only Claude Code sandbox
cd k8s/agent-sandbox
./teardown.sh

# Delete specific namespace
kubectl delete namespace devenv
```

## Security Considerations

1. **Secrets Management**
   - Never commit secrets to git
   - Runtime credentials stored in `k8s/platform/*/scripts/` (gitignored)
   - Use Vault for centralized secret management

2. **Network Security**
   - NetworkPolicies enforce isolation
   - Boundary provides zero-trust access
   - No direct SSH exposure

3. **Authentication**
   - Vault-signed SSH certificates (short-lived)
   - Boundary OIDC with Keycloak
   - No static passwords for sandbox access

4. **Image Security**
   - Base image: `srlynch1/terraform-ai-tools:latest`
   - Scan images for vulnerabilities
   - Use specific version tags in production

## Next Steps

1. **Customize sandboxes** - Modify devcontainer.json for your tools
2. **Add users** - Configure Keycloak realm with your user directory
3. **Integrate CI/CD** - Automate secret provisioning
4. **Setup monitoring** - Add Prometheus/Grafana
5. **Production hardening** - Review security contexts and policies

## References

- [Agent-Sandbox Project](https://github.com/kubernetes-sigs/agent-sandbox)
- [HashiCorp Vault](https://www.vaultproject.io/)
- [HashiCorp Boundary](https://www.boundaryproject.io/)
- [Keycloak](https://www.keycloak.org/)
- [Dev Containers](https://containers.dev/)
