# K8s AI Agent Sandbox

Local Kubernetes sandbox with Vault, Boundary, and Keycloak for secure agent development.

## Quick Start

### Prerequisites

1. Add to `/etc/hosts`:
   ```
   127.0.0.1 vault.local boundary.local boundary-worker.local keycloak.local
   ```

2. Add Boundary Enterprise license:
   ```
   ./k8s/scripts/license/boundary.hclic
   ```

### Deploy
```bash
cd k8s/scripts
./setup-kind.sh && ./deploy-all.sh
```

### Teardown
```bash
cd k8s/scripts
./teardown-all.sh
```
