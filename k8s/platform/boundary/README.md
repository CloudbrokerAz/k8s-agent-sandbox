# HashiCorp Boundary on Kubernetes

Deploy HashiCorp Boundary Enterprise to provide secure access to your agent sandbox pods with credential injection.

**Current Version:** 0.20.1-ent (Enterprise)

## Overview

Boundary provides identity-based access management for dynamic infrastructure. This deployment integrates with the agent sandboxes to provide:

- **Secure SSH access** to sandbox pods via Boundary proxy
- **Credential injection** - Vault SSH certificates automatically injected (Enterprise)
- **OIDC authentication** via Keycloak
- **Identity-based access control**
- **No VPN required** - just authenticate and connect

## Architecture

```
┌────────────────────────────────────────────────────────────────────────────┐
│                           Kubernetes Cluster                                │
│                                                                            │
│  ┌────────────────────────────────────────────────────────────────────┐   │
│  │                    Nginx Ingress Controller                         │   │
│  │                    (ingress-nginx namespace)                        │   │
│  │                                                                     │   │
│  │  boundary.local ────────► Controller API :9200 (TLS termination)   │   │
│  │  boundary-worker.local ──► Worker Proxy :9202 (TLS termination)    │   │
│  │  keycloak.local ─────────► Keycloak :8080 (OIDC Provider)          │   │
│  └────────────────────────────────────────────────────────────────────┘   │
│                                                                            │
│  ┌────────────────────────────────────────────────────────────────────┐   │
│  │                      boundary namespace                             │   │
│  │                                                                     │   │
│  │  ┌──────────┐    ┌─────────────────┐    ┌─────────────────┐       │   │
│  │  │PostgreSQL│◄───│   Controller    │◄───│     Worker      │       │   │
│  │  │   :5432  │    │  :9200 (API)    │    │  :9202 (Proxy)  │       │   │
│  │  └──────────┘    │  :9201 (Cluster)│    │  :9203 (Health) │       │   │
│  │                  │  :9203 (Health) │    └────────┬────────┘       │   │
│  │                  └────────┬────────┘             │                 │   │
│  └───────────────────────────┼─────────────────────┼─────────────────┘   │
│                              │                      │                     │
│  ┌───────────────────────────┼─────────────────────┼─────────────────┐   │
│  │                    vault namespace              │                  │   │
│  │                           │                     │                  │   │
│  │    ┌──────────────────────▼─────────────────┐   │                  │   │
│  │    │  Vault (SSH CA)                        │   │                  │   │
│  │    │  - SSH secrets engine                  │   │                  │   │
│  │    │  - Certificate signing (devenv-access) │   │                  │   │
│  │    └────────────────────────────────────────┘   │                  │   │
│  └─────────────────────────────────────────────────┼─────────────────┘   │
│                                                     │                     │
│  ┌─────────────────────────────────────────────────┼─────────────────┐   │
│  │                      devenv namespace           │                  │   │
│  │                                                 ▼                  │   │
│  │              ┌────────────────────────────────────┐               │   │
│  │              │    claude-code-sandbox             │               │   │
│  │              │    (SSH :22 - trusts Vault CA)     │               │   │
│  │              └────────────────────────────────────┘               │   │
│  └────────────────────────────────────────────────────────────────────┘   │
└────────────────────────────────────────────────────────────────────────────┘
         ▲
         │ boundary connect ssh -target-id=tssh_xxx
         │ (certificate automatically injected)
         │
    ┌────┴────┐
    │  User   │
    └─────────┘
```

### Credential Injection Flow

```
┌──────────┐     1. Authenticate      ┌────────────────┐     2. OIDC      ┌──────────────┐
│   User   │ ────────────────────────►│    Boundary    │ ◄───────────────►│   Keycloak   │
│          │                          │   Controller   │                  │              │
└──────────┘                          └────────────────┘                  └──────────────┘
     │                                        │
     │  3. Connect to SSH Target              │
     │                                        │ 4. Request SSH Cert
     ▼                                        ▼
┌──────────┐                          ┌────────────────┐
│ Boundary │                          │     Vault      │
│  Worker  │ ◄────────────────────────│   (SSH CA)     │
└──────────┘  5. Inject Certificate   └────────────────┘
     │
     │  6. SSH with Signed Certificate
     ▼
┌──────────────────┐
│  DevEnv Pod      │
│  (trusts CA)     │
└──────────────────┘
```

## Ingress Access

Boundary is accessible via Nginx Ingress with TLS:

| Service | URL | Description |
|---------|-----|-------------|
| Controller API | https://boundary.local | Main API endpoint for clients |
| Worker Proxy | https://boundary-worker.local | Session proxy endpoint |

Add to `/etc/hosts`:
```
127.0.0.1 boundary.local boundary-worker.local
```

## Prerequisites

- Kubernetes cluster with kubectl access
- Boundary CLI installed ([download](https://developer.hashicorp.com/boundary/downloads))
- devenv deployed (see `/workspace/k8s/GETTING_STARTED.md`)

## Quick Start

### Option 1: Full Platform Deployment (Recommended)

Boundary is deployed automatically as part of the full platform:

```bash
cd /workspace/k8s/scripts
./deploy-all.sh
```

### Option 2: Standalone Deployment

```bash
cd /workspace/k8s/platform/boundary/scripts

# 1. Create secrets (database credentials and KMS keys)
./create-boundary-secrets.sh

# 2. Deploy Boundary
./deploy-boundary.sh

# 3. Initialize configuration (interactive guide)
./init-boundary.sh
```

## Configuration Notes

### HCL Configuration Format

Boundary uses HCL (HashiCorp Configuration Language) for its configuration. The configuration must use **multi-line format** (not single-line with semicolons):

```hcl
# Correct format
listener "tcp" {
  address = "0.0.0.0:9200"
  purpose = "api"
  tls_disable = true
}

# Incorrect format (will cause parsing errors)
# listener "tcp" { address = "0.0.0.0:9200"; purpose = "api"; tls_disable = true }
```

### Worker Configuration

The Boundary worker uses `initial_upstreams` to connect to the controller (as of Boundary 0.15+):

```hcl
worker {
  name = "kubernetes-worker"
  initial_upstreams = ["boundary-controller-cluster.boundary.svc.cluster.local:9201"]
  public_addr = "boundary-worker.local:443"
}
```

**Note:** Boundary versions prior to 0.15 used `controllers` instead of `initial_upstreams`. This deployment uses version 0.20.1.

### OIDC Configuration

This deployment supports external OIDC URLs using the `-disable-discovered-config-validation` flag (available in Boundary 0.20+):

```bash
# OIDC configured with external Keycloak URL
boundary auth-methods create oidc \
  -issuer='https://keycloak.local/realms/agent-sandbox' \
  -disable-discovered-config-validation
```

This allows using publicly accessible OIDC issuer URLs while bypassing strict discovery validation requirements.

## Directory Structure

```
boundary/
├── manifests/
│   ├── 01-namespace.yaml          # Boundary namespace
│   ├── 02-secrets.yaml            # Secret templates (don't apply directly)
│   ├── 03-configmap.yaml          # Boundary HCL configurations
│   ├── 04-postgres.yaml           # PostgreSQL StatefulSet
│   ├── 05-controller.yaml         # Boundary Enterprise controller deployment
│   ├── 06-worker.yaml             # Boundary Enterprise worker deployment
│   ├── 07-service.yaml            # Services (API, cluster, proxy)
│   ├── 08-networkpolicy.yaml      # Network isolation
│   ├── 09-tls-secret.yaml         # Controller TLS certificate
│   ├── 10-ingress.yaml            # Controller ingress
│   ├── 11-worker-tls-secret.yaml  # Worker TLS certificate
│   ├── 12-worker-ingress.yaml     # Worker ingress
│   └── kustomization.yaml         # Kustomize config
├── scripts/
│   ├── create-boundary-secrets.sh     # Generate and create secrets
│   ├── deploy-boundary.sh             # Deploy all components
│   ├── init-boundary.sh               # Setup guide
│   ├── add-license.sh                 # Add enterprise license
│   ├── configure-targets.sh           # Configure scopes, hosts, targets
│   ├── configure-oidc-auth.sh         # Configure Keycloak OIDC
│   ├── configure-credential-injection.sh  # Setup Vault SSH credential injection
│   ├── teardown-boundary.sh           # Remove deployment
│   └── tests/                         # Test scripts
│       ├── test-deployment.sh         # Test pod health
│       ├── test-authentication.sh     # Test auth methods
│       ├── test-targets.sh            # Test target connectivity
│       └── run-all-tests.sh           # Run all tests
└── README.md
```

## Components

### Controller
- **API Listener** (9200): Client connections and UI
- **Cluster Listener** (9201): Worker communication
- **Ops Listener** (9203): Health checks

### Worker
- **Proxy Listener** (9202): Session proxy connections
- **Ops Listener** (9203): Health checks

### PostgreSQL
- Stores Boundary state (scopes, targets, sessions)
- 5Gi persistent volume
- Credentials in Kubernetes secret

## Connecting to Agent Sandboxes

After setup, connect to sandbox pods via Boundary:

### Via Ingress (Recommended)

```bash
# Set Boundary address (via ingress)
export BOUNDARY_ADDR=https://boundary.local

# Authenticate
boundary authenticate password -auth-method-id=<id> -login-name=admin

# Connect via SSH
boundary connect ssh -target-id=<target-id> -- -l node
```

### Via Port Forward

```bash
# Set Boundary address (via port-forward)
export BOUNDARY_ADDR=http://127.0.0.1:9200

# Port forward to controller
kubectl port-forward -n boundary svc/boundary-controller-api 9200:9200

# Authenticate
boundary authenticate password -auth-method-id=<id> -login-name=admin

# Connect via SSH
boundary connect ssh -target-id=<target-id> -- -l node
```

## Enterprise License

For credential injection (passwordless SSH via Vault certificates), Boundary Enterprise is required.

### Providing a License

Set the license when creating secrets:

```bash
# Option 1: License file
BOUNDARY_LICENSE_FILE=/path/to/license.hclic ./create-boundary-secrets.sh

# Option 2: License string (env var)
BOUNDARY_LICENSE="02MV4UU43BK5..." ./create-boundary-secrets.sh
```

### Community vs Enterprise Features

| Feature | Community | Enterprise |
|---------|-----------|------------|
| SSH Targets | ✅ | ✅ |
| Vault Credential Store | ✅ | ✅ |
| Credential Brokering | ✅ | ✅ |
| **Credential Injection** | ❌ | ✅ |
| Session Recording | ❌ | ✅ |
| Multi-hop Workers | ❌ | ✅ |

### Credential Injection

With Enterprise, Boundary injects Vault-signed SSH certificates directly into sessions:

```bash
# User experience (Enterprise with credential injection)
boundary connect ssh -target-id=tssh_bu1SpYV1Zi
# → Seamless passwordless connection - certificate automatically injected

# User experience (Community with credential brokering)
boundary connect ssh -target-id=ttcp_xxx -- -l node
# → Credentials brokered, manual key configuration required
```

### Configuring Credential Injection

After deploying Boundary Enterprise with a valid license:

```bash
# 1. Ensure Vault SSH CA is configured
./platform/vault/scripts/configure-ssh-engine.sh

# 2. Configure credential injection
./scripts/configure-credential-injection.sh
```

This script:
1. Creates a Vault policy (`boundary-ssh`) for SSH certificate signing
2. Creates an orphan, periodic Vault token for Boundary
3. Creates a Vault credential store in Boundary
4. Creates an SSH certificate credential library
5. Attaches the credential library to the SSH target

#### Manual Configuration (Reference)

```bash
# Create Vault credential store (requires proper token)
boundary credential-stores create vault \
  -scope-id=<project-id> \
  -vault-address="http://vault.vault.svc.cluster.local:8200" \
  -vault-token="<orphan-periodic-token>" \
  -name="Vault SSH Credential Store"

# Create SSH certificate credential library
boundary credential-libraries create vault-ssh-certificate \
  -credential-store-id=<store-id> \
  -vault-path="ssh/sign/devenv-access" \
  -username="node" \
  -name="SSH Certificate Library"

# Attach to SSH target with injection
boundary targets add-credential-sources \
  -id=<target-id> \
  -injected-application-credential-source=<library-id>
```

#### Vault Token Requirements

The token for Boundary's Vault credential store must be:
- **Orphan** - so it doesn't get revoked when parent tokens expire
- **Periodic** - so it can be renewed indefinitely
- **Has specific capabilities** - see `boundary-ssh` policy:

```hcl
path "ssh/sign/devenv-access" {
  capabilities = ["create", "update"]
}
path "auth/token/lookup-self" { capabilities = ["read"] }
path "auth/token/renew-self" { capabilities = ["update"] }
path "auth/token/revoke-self" { capabilities = ["update"] }
path "sys/leases/renew" { capabilities = ["update"] }
path "sys/leases/revoke" { capabilities = ["update"] }
path "sys/capabilities-self" { capabilities = ["update"] }
```

## Security

- **Non-root containers**: All pods run as non-root users
- **KMS encryption**: AEAD encryption for sensitive data
- **NetworkPolicy**: Traffic isolation between namespaces
- **No privilege escalation**: Containers cannot gain privileges

## Troubleshooting

### Check pod status
```bash
kubectl get pods -n boundary
```

### View controller logs
```bash
kubectl logs -n boundary -l app=boundary-controller
```

### View worker logs
```bash
kubectl logs -n boundary -l app=boundary-worker
```

### Check database
```bash
kubectl exec -it -n boundary boundary-postgres-0 -- psql -U boundary -d boundary -c '\dt'
```

### Restart components
```bash
kubectl rollout restart deployment/boundary-controller -n boundary
kubectl rollout restart deployment/boundary-worker -n boundary
```

## Cleanup

```bash
./scripts/teardown-boundary.sh
```

## Upgrade History

### 0.20.1-ent (2025-12-11)
- Upgraded from 0.17.2 to 0.20.1 Enterprise
- Switched to Enterprise image: `hashicorp/boundary-enterprise:0.20.1-ent`
- Added credential injection with Vault SSH CA integration
- Migrated worker configuration from `controllers` to `initial_upstreams`
- Enabled external OIDC URL support with `-disable-discovered-config-validation` flag
- Database schema migrated to 0.20.1
- Added `configure-credential-injection.sh` for automated Vault integration
- See [UPGRADE-0.20.1.md](UPGRADE-0.20.1.md) for detailed upgrade documentation

## Additional Resources

- [Boundary Documentation](https://developer.hashicorp.com/boundary/docs)
- [Boundary Tutorials](https://developer.hashicorp.com/boundary/tutorials)
- [Boundary CLI Reference](https://developer.hashicorp.com/boundary/docs/commands)
