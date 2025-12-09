# Claude Code Sandbox Implementation Plan

## Overview
Create a Claude Code sandbox following the exact pattern from `kubernetes-sigs/agent-sandbox/examples/vscode-sandbox`, using envbuilder to build the devcontainer at runtime.

## Reference
- Repository: https://github.com/kubernetes-sigs/agent-sandbox
- Example: `examples/vscode-sandbox`
- Pattern: Sandbox CRD + envbuilder + devcontainer features

---

## Checklist

### Phase 0: Deploy Script (End-to-End)
- [x] 0.1 Create `deploy.sh` script that handles full deployment
- [x] 0.2 Script checks for agent-sandbox CRD, installs if missing
- [x] 0.3 Script waits for controller to be ready
- [x] 0.4 Script applies kustomize manifests
- [x] 0.5 Script waits for sandbox pod to be ready
- [x] 0.6 Script outputs access instructions

### Phase 1: Prerequisites
- [x] 1.1 Check latest agent-sandbox release version (v0.1.0)
- [x] 1.2 Install agent-sandbox CRD and controller (via deploy.sh)
- [x] 1.3 Verify Sandbox CRD is available (`kubectl get crd sandboxes.agents.x-k8s.io`)
- [x] 1.4 Verify controller is running

### Phase 2: Directory Structure
- [x] 2.1 Create base directory: `base/`
- [x] 2.2 Create overlays directory structure: `overlays/gvisor/`, `overlays/kata/`
- [x] 2.3 Create devcontainer.json for Claude Code
- [x] 2.4 Create entrypoint.sh script

### Phase 3: Base Manifests
- [x] 3.1 Create `base/claude-code-sandbox.yaml` (Sandbox CRD)
  - Container: `ghcr.io/coder/envbuilder`
  - ENVBUILDER_GIT_URL pointing to this repo
  - ENVBUILDER_DEVCONTAINER_DIR: `k8s/agent-sandbox`
  - ENVBUILDER_INIT_SCRIPT: `k8s/agent-sandbox/entrypoint.sh`
  - Volume mounts for /workspaces
  - Resource requests/limits
- [x] 3.2 Create `base/kustomization.yaml`
- [x] 3.3 Create `base/service.yaml`

### Phase 4: DevContainer Configuration
- [x] 4.1 Create devcontainer.json with:
  - Base image: `mcr.microsoft.com/devcontainers/base:ubuntu`
  - Feature: code-server (port 13337)
  - Feature: sshd (port 22)
  - Feature: docker-in-docker
  - Feature: node (lts)
  - postCreateCommand: Install Claude Code CLI
  - appPort mappings
- [x] 4.2 Create entrypoint.sh with:
  - Vault TLS CA trust configuration
  - Vault SSH CA configuration
  - Claude Code verification/installation
  - code-server startup
  - Keep-alive mechanism

### Phase 5: Optional Overlays
- [x] 5.1 Create `overlays/gvisor/kustomization.yaml` (adds runtimeClassName: gvisor)
- [x] 5.2 Create `overlays/kata/kustomization.yaml` (adds runtimeClassName: kata-qemu)

### Phase 6: Secret Integration
- [x] 6.1 Add GITHUB_TOKEN env var from secret
- [x] 6.2 Add TFE_TOKEN env var from secret
- [x] 6.3 Add LANGFUSE_* env vars from secret
- [x] 6.4 Add Vault CA volume mount
- [x] 6.5 Add Vault SSH CA volume mount

### Phase 7: Deployment & Testing
- [ ] 7.1 Deploy base sandbox: `./deploy.sh`
- [ ] 7.2 Verify sandbox resource created
- [ ] 7.3 Verify pod is running
- [ ] 7.4 Wait for envbuilder to complete (monitor logs)
- [ ] 7.5 Test code-server access via port-forward
- [ ] 7.6 Test Claude Code CLI availability
- [ ] 7.7 Test SSH access (if configured)

### Phase 8: Documentation
- [x] 8.1 Update README with deployment instructions
- [x] 8.2 Document access methods (kubectl exec, port-forward, SSH)
- [x] 8.3 Document optional hardening overlays
- [x] 8.4 Create teardown.sh script
- [x] 8.5 Update deploy-all.sh to use new pattern

---

## File Structure (Actual)

```
k8s/agent-sandbox/
├── PLAN.md                        # This file
├── README.md                      # Usage documentation
├── base/
│   ├── kustomization.yaml
│   ├── claude-code-sandbox.yaml   # Sandbox CRD manifest
│   └── service.yaml               # ClusterIP service
├── overlays/
│   ├── gvisor/
│   │   └── kustomization.yaml     # gVisor runtime overlay
│   └── kata/
│       └── kustomization.yaml     # Kata runtime overlay
├── devcontainer.json              # Claude Code devcontainer config
├── entrypoint.sh                  # Initialization script
├── deploy.sh                      # End-to-end deployment script
└── teardown.sh                    # Cleanup script
```

---

## Key Environment Variables

| Variable | Description | Source |
|----------|-------------|--------|
| ENVBUILDER_GIT_URL | Repository to clone | Static |
| ENVBUILDER_DEVCONTAINER_DIR | Path to devcontainer.json | Static |
| ENVBUILDER_INIT_SCRIPT | Post-build init script | Static |
| ENVBUILDER_IGNORE_PATHS | Paths to skip | Static |
| GITHUB_TOKEN | GitHub authentication | Secret |
| TFE_TOKEN | Terraform Cloud token | Secret |
| LANGFUSE_* | Observability tokens | Secret |
| VAULT_ADDR | Vault server address | Static |
| VAULT_CACERT | Vault CA cert path | Static |

---

## Access Methods

1. **code-server (Browser IDE)**:
   ```bash
   kubectl port-forward -n devenv svc/claude-code-sandbox 13337:13337
   # Open http://localhost:13337
   ```

2. **kubectl exec**:
   ```bash
   kubectl exec -it -n devenv $(kubectl get pod -n devenv -l app=claude-code-sandbox -o jsonpath='{.items[0].metadata.name}') -- /bin/bash
   ```

3. **SSH via Boundary**:
   ```bash
   boundary connect ssh -target-id=<target> -- -l node
   ```

---

## Deployment Commands

```bash
# Deploy (installs CRD if needed)
./deploy.sh

# Deploy with gVisor isolation
OVERLAY=gvisor ./deploy.sh

# Deploy with Kata isolation
OVERLAY=kata ./deploy.sh

# Teardown
./teardown.sh
```

---

## Notes

- Envbuilder takes 5-10 minutes on first run (builds devcontainer image)
- Subsequent restarts are faster (layers cached in /workspaces)
- Use startup probes with high failure threshold to accommodate build time
- The Sandbox CRD requires kubernetes-sigs/agent-sandbox controller (v0.1.0+)
