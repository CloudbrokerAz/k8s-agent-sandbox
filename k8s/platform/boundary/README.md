# HashiCorp Boundary on Kubernetes

Deploy HashiCorp Boundary to provide secure access to your devenv pods.

## Overview

Boundary provides identity-based access management for dynamic infrastructure. This deployment integrates with the devenv StatefulSet to provide:

- **Secure SSH access** to devenv pods via Boundary proxy
- **Session recording** and audit logs
- **Identity-based access control**
- **No VPN required** - just authenticate and connect

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    Kubernetes Cluster                        │
│                                                              │
│  ┌─────────────────────────────────────────────────────┐    │
│  │                 boundary namespace                   │    │
│  │                                                      │    │
│  │  ┌──────────┐    ┌────────────┐    ┌───────────┐   │    │
│  │  │PostgreSQL│◄───│ Controller │◄───│  Worker   │   │    │
│  │  │   :5432  │    │:9200,:9201 │    │   :9202   │   │    │
│  │  └──────────┘    └────────────┘    └─────┬─────┘   │    │
│  │                                          │          │    │
│  └──────────────────────────────────────────┼──────────┘    │
│                                             │               │
│  ┌──────────────────────────────────────────┼──────────┐    │
│  │                 devenv namespace         │          │    │
│  │                                          ▼          │    │
│  │              ┌────────────────────────────┐         │    │
│  │              │   devenv-0, devenv-1, ...  │         │    │
│  │              │         SSH :22            │         │    │
│  │              └────────────────────────────┘         │    │
│  └──────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
         ▲
         │ boundary connect ssh
         │
    ┌────┴────┐
    │  User   │
    └─────────┘
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

The Boundary worker uses `initial_upstreams` to connect to the controller:

```hcl
worker {
  name = "kubernetes-worker"
  initial_upstreams = ["boundary-controller-cluster.boundary.svc.cluster.local:9201"]
  public_addr = "boundary-worker.boundary.svc.cluster.local:9202"
}
```

Note: Older Boundary versions used `controllers` instead of `initial_upstreams`.

## Directory Structure

```
boundary/
├── manifests/
│   ├── 01-namespace.yaml       # Boundary namespace
│   ├── 02-secrets.yaml         # Secret templates (don't apply directly)
│   ├── 03-configmap.yaml       # Boundary HCL configurations
│   ├── 04-postgres.yaml        # PostgreSQL StatefulSet
│   ├── 05-controller.yaml      # Boundary controller deployment
│   ├── 06-worker.yaml          # Boundary worker deployment
│   ├── 07-service.yaml         # Services (API, cluster, proxy)
│   ├── 08-networkpolicy.yaml   # Network isolation
│   └── kustomization.yaml      # Kustomize config
├── scripts/
│   ├── create-boundary-secrets.sh  # Generate and create secrets
│   ├── deploy-boundary.sh          # Deploy all components
│   ├── init-boundary.sh            # Setup guide
│   └── teardown-boundary.sh        # Remove deployment
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

## Connecting to DevEnv

After setup, connect to devenv pods via Boundary:

```bash
# Set Boundary address
export BOUNDARY_ADDR=http://127.0.0.1:9200

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
# User experience (Enterprise)
boundary connect ssh -target-id=devenv-ssh
# → Seamless passwordless connection

# User experience (Community)
# → Credentials brokered, manual configuration required
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

## Additional Resources

- [Boundary Documentation](https://developer.hashicorp.com/boundary/docs)
- [Boundary Tutorials](https://developer.hashicorp.com/boundary/tutorials)
- [Boundary CLI Reference](https://developer.hashicorp.com/boundary/docs/commands)
