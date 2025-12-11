# Architecture Overview

## System Architecture

```
┌──────────────────────────────────────────────────────────────────────────────────┐
│                              Kubernetes Cluster                                   │
│                                                                                  │
│  ┌────────────────────────────────────────────────────────────────────────────┐ │
│  │                         Nginx Ingress Controller                            │ │
│  │                         (ingress-nginx namespace)                           │ │
│  │                                                                            │ │
│  │  vault.local ────────► :8200    boundary.local ────────► :9200            │ │
│  │  keycloak.local ─────► :8080    boundary-worker.local ──► :9202           │ │
│  │                                                                            │ │
│  └────────────────────────────────────────────────────────────────────────────┘ │
│                                                                                  │
│  ┌────────────────────────────────────────────────────────────────────────────┐ │
│  │                         Platform Services                                   │ │
│  │                                                                            │ │
│  │  ┌─────────────┐   ┌─────────────┐   ┌─────────────┐   ┌─────────────┐   │ │
│  │  │   Vault     │   │  Boundary   │   │  Keycloak   │   │    VSO      │   │ │
│  │  │  (vault)    │   │ (boundary)  │   │ (keycloak)  │   │   (vso)     │   │ │
│  │  │             │   │             │   │             │   │             │   │ │
│  │  │ ┌─────────┐ │   │ ┌─────────┐ │   │ ┌─────────┐ │   │ ┌─────────┐ │   │ │
│  │  │ │ Secrets │ │   │ │Controller│ │   │ │  OIDC   │ │   │ │  Sync   │ │   │ │
│  │  │ │  - KV   │ │   │ │  :9200  │ │   │ │Provider │ │   │ │ Secrets │ │   │ │
│  │  │ │  - SSH  │ │   │ │  :9201  │ │   │ │  :8080  │ │   │ │ to K8s  │ │   │ │
│  │  │ │  - TFE  │ │   │ ├─────────┤ │   │ └─────────┘ │   │ └─────────┘ │   │ │
│  │  │ └─────────┘ │   │ │ Worker  │ │   │             │   │             │   │ │
│  │  │   :8200    │   │ │  :9202  │ │   │ PostgreSQL  │   │  Helm Chart │   │ │
│  │  └──────┬──────┘   │ └─────────┘ │   └──────┬──────┘   └──────┬──────┘   │ │
│  │         │          └──────┬──────┘          │                 │          │ │
│  └─────────┼─────────────────┼─────────────────┼─────────────────┼──────────┘ │
│            │                 │                 │                 │            │
│            ▼                 ▼                 ▼                 ▼            │
│  ┌────────────────────────────────────────────────────────────────────────┐  │
│  │                        Namespace: devenv                               │  │
│  │                                                                        │  │
│  │   ┌─────────────┐   ┌─────────────┐   ┌─────────────┐                │  │
│  │   │  devenv-0   │   │  devenv-1   │   │  devenv-N   │                │  │
│  │   │             │   │             │   │             │                │  │
│  │   │ Claude Code │   │ Claude Code │   │ Claude Code │                │  │
│  │   │ Terraform   │   │ Terraform   │   │ Terraform   │                │  │
│  │   │ Bun + Tools │   │ Bun + Tools │   │ Bun + Tools │                │  │
│  │   │             │   │             │   │             │                │  │
│  │   │ PVCs:       │   │ PVCs:       │   │ PVCs:       │                │  │
│  │   │ - workspace │   │ - workspace │   │ - workspace │                │  │
│  │   │ - history   │   │ - history   │   │ - history   │                │  │
│  │   │ - config    │   │ - config    │   │ - config    │                │  │
│  │   └─────────────┘   └─────────────┘   └─────────────┘                │  │
│  │                                                                        │  │
│  │   Secrets (auto-synced from Vault via VSO):                           │  │
│  │   ┌──────────────────────────────────────────────────┐               │  │
│  │   │ devenv-vault-secrets: GITHUB_TOKEN, LANGFUSE_*   │               │  │
│  │   │ tfe-dynamic-token: TFE_TOKEN (auto-renewed)      │               │  │
│  │   └──────────────────────────────────────────────────┘               │  │
│  └────────────────────────────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────────────────────────────┘
```

## User Authentication Flow

```
┌──────────┐
│   User   │
└────┬─────┘
     │
     │ 1. boundary authenticate oidc
     ▼
┌─────────────────┐     2. Redirect to Keycloak     ┌─────────────────┐
│    Boundary     │ ──────────────────────────────► │    Keycloak     │
│   Controller    │                                 │  (agent-sandbox │
│    :9200        │                                 │     realm)      │
└────────┬────────┘                                 └────────┬────────┘
         │                                                   │
         │                     3. User logs in               │
         │                     (admin@example.com)           │
         │                                                   │
         │ ◄─────────────────────────────────────────────────┘
         │    4. ID Token + Groups (admins/developers/readonly)
         │
         │ 5. Create session, return auth token
         ▼
┌─────────────────┐
│  Authenticated  │
│     Session     │
└────────┬────────┘
         │
         │ 6. boundary connect ssh -target-id=<devenv>
         ▼
┌─────────────────┐     7. Proxy connection     ┌─────────────────┐
│    Boundary     │ ──────────────────────────► │   DevEnv Pod    │
│     Worker      │                             │   (devenv-0)    │
│    :9202        │                             │     :22 SSH     │
└─────────────────┘                             └─────────────────┘
```

## Secrets Flow (Vault + VSO)

```
┌───────────────────────────────────────────────────────────────────────┐
│                         Secrets Flow                                   │
│                                                                       │
│  ┌─────────────┐                      ┌─────────────────────────────┐│
│  │   Admin     │  vault kv put        │         Vault               ││
│  │   User      │ ────────────────────►│                             ││
│  └─────────────┘  secret/devenv/creds │  ┌───────────────────────┐  ││
│                                        │  │ secret/devenv/        │  ││
│                                        │  │   - GITHUB_TOKEN      │  ││
│                                        │  │   - LANGFUSE_*        │  ││
│                                        │  └───────────────────────┘  ││
│                                        │                             ││
│                                        │  ┌───────────────────────┐  ││
│                                        │  │ terraform/tfe/creds   │  ││
│                                        │  │   - Dynamic TFE Token │  ││
│                                        │  └───────────────────────┘  ││
│                                        └──────────────┬──────────────┘│
│                                                       │               │
│                   Kubernetes Auth                     │               │
│                   (ServiceAccount)                    │               │
│                                                       ▼               │
│  ┌─────────────────────────────────────────────────────────────────┐ │
│  │                    VSO Controller                                │ │
│  │                                                                  │ │
│  │   VaultStaticSecret ──► Poll every 30s ──► K8s Secret          │ │
│  │   VaultDynamicSecret ──► Auto-renew ──► K8s Secret             │ │
│  └─────────────────────────────────────────────────────────────────┘ │
│                                        │                              │
│                                        ▼                              │
│  ┌─────────────────────────────────────────────────────────────────┐ │
│  │                    devenv namespace                              │ │
│  │                                                                  │ │
│  │   ┌─────────────────────┐    ┌─────────────────────┐           │ │
│  │   │ devenv-vault-secrets│    │  tfe-dynamic-token  │           │ │
│  │   │   (K8s Secret)      │    │    (K8s Secret)     │           │ │
│  │   └──────────┬──────────┘    └──────────┬──────────┘           │ │
│  │              │                          │                       │ │
│  │              ▼                          ▼                       │ │
│  │   ┌───────────────────────────────────────────────────────────┐│ │
│  │   │              DevEnv Pod (devenv-0)                        ││ │
│  │   │                                                           ││ │
│  │   │   env:                                                    ││ │
│  │   │     GITHUB_TOKEN: (from devenv-vault-secrets)             ││ │
│  │   │     TFE_TOKEN: (from tfe-dynamic-token)                   ││ │
│  │   │     TF_TOKEN_app_terraform_io: (from tfe-dynamic-token)   ││ │
│  │   │     LANGFUSE_*: (from devenv-vault-secrets)               ││ │
│  │   └───────────────────────────────────────────────────────────┘│ │
│  └─────────────────────────────────────────────────────────────────┘ │
└───────────────────────────────────────────────────────────────────────┘
```

## Network Flow

```
┌──────────────────────────────────────────────────────────────────────┐
│                         Network Topology                              │
│                                                                      │
│  External                                                            │
│  ────────                                                            │
│                                                                      │
│  ┌──────────┐                                                        │
│  │  User    │                                                        │
│  │ Workstation                                                       │
│  └────┬─────┘                                                        │
│       │                                                              │
│       │ kubectl port-forward / boundary connect                      │
│       ▼                                                              │
│  ═══════════════════════════════════════════════════════════════════│
│                         Cluster Network                              │
│  ═══════════════════════════════════════════════════════════════════│
│       │                                                              │
│       ├───────────────────┬───────────────────┬──────────────────┐  │
│       ▼                   ▼                   ▼                  ▼  │
│  ┌─────────┐        ┌─────────┐        ┌─────────┐        ┌─────────┐
│  │ Vault   │        │Boundary │        │Keycloak │        │ DevEnv  │
│  │ :8200   │        │ :9200   │        │  :8080  │        │ :22     │
│  │         │        │ :9201   │        │         │        │         │
│  │         │        │ :9202   │        │         │        │         │
│  └────┬────┘        └────┬────┘        └────┬────┘        └────┬────┘
│       │                  │                  │                  │    │
│       │                  │                  │                  │    │
│  Internal Service Discovery (*.svc.cluster.local)                   │
│  ─────────────────────────────────────────────────────────────────  │
│       │                  │                  │                  │    │
│       │                  │                  │                  │    │
│       │    ┌─────────────┴─────────────┐    │                  │    │
│       │    │     OIDC Authentication   │    │                  │    │
│       │    │  boundary ◄──────────────►│    │                  │    │
│       │    │           keycloak.keycloak.svc:8080               │    │
│       │    └───────────────────────────┘                       │    │
│       │                                                        │    │
│       │    ┌─────────────────────────────────────────────────┐│    │
│       │    │              Session Proxy                       ││    │
│       │    │  boundary-worker ──────────────────────► devenv  ││    │
│       │    │  :9202                                    :22    ││    │
│       │    └─────────────────────────────────────────────────┘│    │
│       │                                                        │    │
│       │    ┌─────────────────────────────────────────────────┐│    │
│       │    │              Secret Sync (VSO)                   ││    │
│       │    │  VSO ◄──────────────────────────────────► Vault  ││    │
│       │    │      vault.vault.svc:8200                        ││    │
│       │    └─────────────────────────────────────────────────┘│    │
│       │                                                        │    │
│       ▼                                                        │    │
│  ┌──────────────────────────────────────────────────────────┐  │    │
│  │                    Egress (Internet)                      │  │    │
│  │   DevEnv pods can reach:                                  │  │    │
│  │   - github.com (git operations)                           │  │    │
│  │   - app.terraform.io (TFC/TFE)                            │  │    │
│  │   - registry.terraform.io (providers)                     │  │    │
│  │   - api.anthropic.com (Claude)                            │  │    │
│  │   - *.amazonaws.com (AWS APIs)                            │  │    │
│  └──────────────────────────────────────────────────────────┘  │    │
└──────────────────────────────────────────────────────────────────────┘
```

## Component Breakdown

### StatefulSet

**Purpose**: Manages stateful pods with stable identities and persistent storage

**Features**:
- Ordered deployment and scaling
- Stable network identity (devenv-0, devenv-1, etc.)
- Persistent volume claims per pod
- Graceful shutdown and updates

**Why StatefulSet over Deployment?**
- Predictable pod names (easier user assignment)
- Stable storage binding (data persists across restarts)
- Ordered operations (safer for database-like workloads)

### Persistent Storage

Each pod gets **3 persistent volumes**:

1. **workspace** (10Gi): User's code, projects, and files
2. **bash-history** (1Gi): Command history for zsh/bash
3. **claude-config** (1Gi): Claude Code configuration and state

**Storage Flow**:
```
Pod Restart → PVC Remains → Same Data Mounted → User Continues Work
Pod Delete → PVC Remains → New Pod → Same Data Mounted
```

### Secrets Management

**Secrets injected as environment variables**:
```
Secret (K8s) → Environment Variable (Pod) → Application
```

**Lifecycle**:
1. Created once via `create-secrets.sh`
2. Mounted to all pods in namespace
3. Rotated by updating secret + rolling restart
4. Deleted only when namespace is destroyed

### Networking

**Internal (Pod-to-Pod)**:
```
devenv-0.devenv.devenv.svc.cluster.local
│        │      │       │
│        │      │       └─ Cluster domain
│        │      └─ Namespace
│        └─ Service name
└─ Pod name
```

**External (User Access)**:
```
User → kubectl exec → API Server → kubelet → Pod Shell
User → Port Forward → API Server → Pod Port
User → Ingress → Nginx Ingress Controller → Service → Pod

Ingress URLs (with /etc/hosts entries):
  - https://vault.local → Vault API (:8200)
  - https://boundary.local → Boundary Controller API (:9200)
  - https://boundary-worker.local → Boundary Worker Proxy (:9202)
  - https://keycloak.local → Keycloak (:8080)
```

### Security Layers

1. **Namespace Isolation**: All resources in dedicated `devenv` namespace
2. **NetworkPolicy**: Restricts traffic to/from pods
3. **RBAC**: (Optional) Limit service account permissions
4. **SecurityContext**: Relaxed for development (runs as root), can be tightened for production
5. **Secrets**: Encrypted at rest (K8s default), synced via VSO from Vault
6. **Identity-Based Access**: Boundary + Keycloak OIDC for user authentication
7. **Session Recording**: Boundary provides audit logs for all connections

## VSCode Remote SSH via Boundary

```
┌────────────────────────────────────────────────────────────────────────────────┐
│                     VSCode Remote SSH Flow via Boundary                         │
│                                                                                │
│  ┌──────────────────────┐                                                      │
│  │   Developer Machine   │                                                      │
│  │                      │                                                      │
│  │  ┌────────────────┐  │                                                      │
│  │  │  VSCode IDE    │  │                                                      │
│  │  │  + Remote SSH  │  │                                                      │
│  │  │   Extension    │  │                                                      │
│  │  └───────┬────────┘  │                                                      │
│  │          │           │                                                      │
│  │          │ SSH to localhost:2222                                            │
│  │          ▼           │                                                      │
│  │  ┌────────────────┐  │                                                      │
│  │  │ Boundary       │  │  1. User authenticates via OIDC (Keycloak)          │
│  │  │ Desktop Client │  │  2. Receives session token                          │
│  │  │ (or CLI)       │  │  3. Opens local proxy on localhost:2222             │
│  │  └───────┬────────┘  │                                                      │
│  └──────────┼───────────┘                                                      │
│             │                                                                  │
│             │ Secure tunnel (TLS)                                              │
│             ▼                                                                  │
│  ┌──────────────────────────────────────────────────────────────────────────┐ │
│  │                         Kubernetes Cluster                                │ │
│  │                                                                          │ │
│  │  ┌───────────────────────────────────────────────────────────────────┐  │ │
│  │  │                      boundary namespace                            │  │ │
│  │  │                                                                    │  │ │
│  │  │  ┌──────────────────┐          ┌──────────────────┐               │  │ │
│  │  │  │ Boundary         │          │ Boundary         │               │  │ │
│  │  │  │ Controller       │◄────────►│ Worker           │               │  │ │
│  │  │  │                  │  cluster │                  │               │  │ │
│  │  │  │ - Auth (OIDC)    │  comms   │ - Session proxy  │               │  │ │
│  │  │  │ - Session mgmt   │  :9201   │ - Target connect │               │  │ │
│  │  │  │ - Audit logs     │          │                  │               │  │ │
│  │  │  │   :9200          │          │   :9202          │               │  │ │
│  │  │  └────────┬─────────┘          └────────┬─────────┘               │  │ │
│  │  │           │                             │                          │  │ │
│  │  │           │  4. Validate session        │ 5. Proxy SSH traffic    │  │ │
│  │  │           ▼                             ▼                          │  │ │
│  │  │  ┌──────────────────┐                                              │  │ │
│  │  │  │ Keycloak         │                                              │  │ │
│  │  │  │ (OIDC Provider)  │                                              │  │ │
│  │  │  │   :8080          │                                              │  │ │
│  │  │  └──────────────────┘                                              │  │ │
│  │  └───────────────────────────────────────────────────────────────────┘  │ │
│  │                                    │                                     │ │
│  │                                    │ SSH connection                      │ │
│  │                                    ▼                                     │ │
│  │  ┌───────────────────────────────────────────────────────────────────┐  │ │
│  │  │                       devenv namespace                             │  │ │
│  │  │                                                                    │  │ │
│  │  │  ┌──────────────────────────────────────────────────────────┐    │  │ │
│  │  │  │                    DevEnv Pod (devenv-0)                  │    │  │ │
│  │  │  │                                                           │    │  │ │
│  │  │  │   6. SSH Server accepts connection                        │    │  │ │
│  │  │  │      (authenticated via Vault SSH CA or keys)             │    │  │ │
│  │  │  │                                                           │    │  │ │
│  │  │  │   7. VSCode Remote SSH Extension installs                 │    │  │ │
│  │  │  │      vscode-server in /home/node/.vscode-server           │    │  │ │
│  │  │  │                                                           │    │  │ │
│  │  │  │   8. Developer has full IDE access to:                    │    │  │ │
│  │  │  │      /workspace (persistent - PVC)                        │    │  │ │
│  │  │  │                                                           │    │  │ │
│  │  │  │   Installed Tools:                                        │    │  │ │
│  │  │  │   - Claude Code (AI assistant)                            │    │  │ │
│  │  │  │   - Terraform                                             │    │  │ │
│  │  │  │   - AWS CLI                                               │    │  │ │
│  │  │  │   - Bun                                                   │    │  │ │
│  │  │  │   - Git, Go, Python, Node.js                              │    │  │ │
│  │  │  └──────────────────────────────────────────────────────────┘    │  │ │
│  │  └───────────────────────────────────────────────────────────────────┘  │ │
│  └──────────────────────────────────────────────────────────────────────────┘ │
└────────────────────────────────────────────────────────────────────────────────┘

Connection Steps:
1. boundary authenticate oidc -auth-method-id=<keycloak-oidc>
   → Opens browser for Keycloak login
   → Returns session token

2. boundary connect ssh -target-id=<devenv-target> -listen-port=2222
   → Opens local proxy on localhost:2222
   → Traffic is proxied through Boundary worker to devenv pod

3. VSCode Remote SSH connects to localhost:2222
   → SSH session is established through Boundary tunnel
   → VSCode installs/runs vscode-server in the pod
   → Full IDE experience with terminal, extensions, debugging
```

## Mermaid Diagrams

For interactive/rendered diagrams, see the `.mmd` files in the `docs/` directory:

- **[docs/architecture.mmd](docs/architecture.mmd)** - Complete platform architecture with all components
- **[docs/secrets-sync-flow.mmd](docs/secrets-sync-flow.mmd)** - VSO secrets synchronization flow
- **[docs/ssh-credential-flow.mmd](docs/ssh-credential-flow.mmd)** - SSH authentication via Boundary/Keycloak

These can be rendered using:
- VS Code Mermaid extension
- GitHub (automatically renders `.mmd` files)
- [Mermaid Live Editor](https://mermaid.live/)

## Data Flow

### User Workflow

```
┌──────────┐
│  User    │
└────┬─────┘
     │
     │ kubectl exec -it devenv-0 -- /bin/zsh
     ▼
┌────────────────┐
│  K8s API       │
│  Server        │
└────┬───────────┘
     │
     │ Authentication & Authorization
     ▼
┌────────────────┐
│  kubelet       │
│  (on node)     │
└────┬───────────┘
     │
     │ Execute shell in container
     ▼
┌────────────────┐
│  Pod: devenv-0 │
│                │
│  ┌──────────┐  │
│  │ /bin/zsh │  │
│  └──────────┘  │
│                │
│  Mounts:       │
│  /workspace    │ ← PVC: workspace-devenv-0
│  /commandhistory│ ← PVC: bash-history-devenv-0
│  /home/node/.claude│ ← PVC: claude-config-devenv-0
│                │
│  Env Vars:     │
│  GITHUB_TOKEN  │ ← Secret: devenv-secrets
│  TFE_TOKEN     │
│  AWS_*         │
└────────────────┘
```

### Code Execution Flow

```
User writes code in /workspace
         │
         ▼
Saved to PVC (persistent)
         │
         ▼
Git commit & push
         │
         ▼
GitHub (external)
         │
         ▼
Terraform init/plan/apply
         │
         ▼
HCP Terraform (external, authenticated via TFE_TOKEN)
         │
         ▼
AWS resources created (authenticated via AWS_* credentials)
```

## Scaling Patterns

### Horizontal Scaling (More Users)

```bash
./k8s/scripts/scale.sh 5
```

**Result**:
```
devenv-0 → User A → PVCs: workspace-0, history-0, config-0
devenv-1 → User B → PVCs: workspace-1, history-1, config-1
devenv-2 → User C → PVCs: workspace-2, history-2, config-2
devenv-3 → User D → PVCs: workspace-3, history-3, config-3
devenv-4 → User E → PVCs: workspace-4, history-4, config-4
```

### Vertical Scaling (More Resources per User)

Edit `05-statefulset.yaml`:
```yaml
resources:
  requests:
    memory: "4Gi"  # Increase from 2Gi
    cpu: "1000m"   # Increase from 500m
```

Apply: `kubectl apply -f k8s/manifests/05-statefulset.yaml`

## Cluster Compatibility Matrix

| Feature | kind | Standard K8s | OpenShift | Notes |
|---------|------|--------------|-----------|-------|
| StatefulSet | ✅ | ✅ | ✅ | Core K8s resource |
| PVC (hostpath) | ✅ | ⚠️ | ❌ | kind default, not for prod |
| PVC (dynamic) | ⚠️ | ✅ | ✅ | Requires StorageClass |
| NetworkPolicy | ⚠️ | ✅ | ✅ | Requires CNI support |
| Secrets | ✅ | ✅ | ✅ | Core K8s resource |
| SecurityContext | ✅ | ✅ | ⚠️ | OpenShift: SCC required |
| LoadBalancer | ❌ | ✅ | ✅ | kind: use port-forward |

Legend:
- ✅ Fully supported
- ⚠️ Requires configuration
- ❌ Not available

## Resource Requirements

### Per Pod

- **CPU**: 500m request, 2000m limit
- **Memory**: 2Gi request, 4Gi limit
- **Storage**: 12Gi total (10Gi + 1Gi + 1Gi)

### Cluster Minimums (3 users)

- **Nodes**: 1 (kind) or 2+ (production)
- **CPU**: 6 cores minimum (3 users × 2 cores)
- **Memory**: 12Gi minimum (3 users × 4Gi)
- **Storage**: 36Gi minimum (3 users × 12Gi)

### Cost Estimation (AWS EKS example)

For 10 users:
- **Compute**: 10 × t3.large (~$0.0832/hr) = ~$600/month
- **Storage**: 10 × 12Gi gp3 (~$0.08/GB/month) = ~$10/month
- **Total**: ~$610/month (excluding data transfer, control plane)

## High Availability Considerations

Current setup is **single-replica per user** (no HA). For production:

1. **Multi-zone PVCs**: Use storage that replicates across zones
2. **Pod Disruption Budgets**: Prevent simultaneous evictions
3. **Node Affinity**: Spread users across nodes
4. **Backup Strategy**: Regular PVC snapshots
5. **Monitoring**: Prometheus alerts for pod failures

## Future Enhancements

### Short Term
- [ ] Add SSH server for remote IDE access (VS Code Remote)
- [ ] Implement ingress for web-based terminal
- [ ] Add resource quotas per namespace
- [ ] Set up automated backups to S3

### Medium Term
- [ ] Multi-tenancy with separate namespaces per team
- [ ] OAuth/OIDC authentication
- [ ] Grafana dashboards for resource usage
- [ ] Automated user provisioning via API

### Long Term
- [ ] Integrate with agent-sandbox CRD for better isolation
- [ ] GPU support for AI/ML workloads
- [ ] Federation across multiple clusters
- [ ] Marketplace for pre-configured environments

## References

- [Kubernetes StatefulSet Best Practices](https://kubernetes.io/docs/tutorials/stateful-application/)
- [Storage Classes](https://kubernetes.io/docs/concepts/storage/storage-classes/)
- [Network Policies](https://kubernetes.io/docs/concepts/services-networking/network-policies/)
- [Pod Security Standards](https://kubernetes.io/docs/concepts/security/pod-security-standards/)
