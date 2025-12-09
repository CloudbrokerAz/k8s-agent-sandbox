# Architecture Overview

## System Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                         Kubernetes Cluster                          │
│                                                                     │
│  ┌───────────────────────────────────────────────────────────────┐ │
│  │                    Namespace: devenv                          │ │
│  │                                                               │ │
│  │  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐      │ │
│  │  │   devenv-0   │  │   devenv-1   │  │   devenv-2   │      │ │
│  │  │              │  │              │  │              │      │ │
│  │  │  ┌────────┐  │  │  ┌────────┐  │  │  ┌────────┐  │      │ │
│  │  │  │  Pod   │  │  │  │  Pod   │  │  │  │  Pod   │  │      │ │
│  │  │  │        │  │  │  │        │  │  │  │        │  │      │ │
│  │  │  │ Claude │  │  │  │ Claude │  │  │  │ Claude │  │      │ │
│  │  │  │  Code  │  │  │  │  Code  │  │  │  │  Code  │  │      │ │
│  │  │  │   +    │  │  │  │   +    │  │  │  │   +    │  │      │ │
│  │  │  │Terraform│ │  │  │Terraform│ │  │  │Terraform│ │      │ │
│  │  │  │   +    │  │  │  │   +    │  │  │  │   +    │  │      │ │
│  │  │  │  Tools │  │  │  │  Tools │  │  │  │  Tools │  │      │ │
│  │  │  └────┬───┘  │  │  └────┬───┘  │  │  └────┬───┘  │      │ │
│  │  │       │      │  │       │      │  │       │      │      │ │
│  │  │  ┌────▼───┐  │  │  ┌────▼───┐  │  │  ┌────▼───┐  │      │ │
│  │  │  │  PVCs  │  │  │  │  PVCs  │  │  │  │  PVCs  │  │      │ │
│  │  │  │ ├─────┤ │  │  │ ├─────┤ │  │  │ ├─────┤ │      │ │
│  │  │  │ │Workspace││  │  │Workspace││  │  │Workspace││      │ │
│  │  │  │ │ 10Gi │ │  │  │ 10Gi │ │  │  │ 10Gi │ │      │ │
│  │  │  │ ├─────┤ │  │  │ ├─────┤ │  │  │ ├─────┤ │      │ │
│  │  │  │ │History││ │  │ │History││ │  │ │History││      │ │
│  │  │  │ │ 1Gi  │ │  │  │ 1Gi  │ │  │  │ 1Gi  │ │      │ │
│  │  │  │ ├─────┤ │  │  │ ├─────┤ │  │  │ ├─────┤ │      │ │
│  │  │  │ │Config││ │  │ │Config││ │  │ │Config││      │ │
│  │  │  │ │ 1Gi  │ │  │  │ 1Gi  │ │  │  │ 1Gi  │ │      │ │
│  │  │  │ └─────┘ │  │  │ └─────┘ │  │  │ └─────┘ │      │ │
│  │  └──────────────┘  └──────────────┘  └──────────────┘      │ │
│  │                                                               │ │
│  │  ┌──────────────────────────────────────────────────┐       │ │
│  │  │          Service: devenv (ClusterIP)             │       │ │
│  │  │  Exposes: SSH (22), HTTP (8080)                  │       │ │
│  │  └──────────────────────────────────────────────────┘       │ │
│  │                                                               │ │
│  │  ┌──────────────────────────────────────────────────┐       │ │
│  │  │          Secret: devenv-secrets                  │       │ │
│  │  │  - GITHUB_TOKEN                                  │       │ │
│  │  │  - TFE_TOKEN                                     │       │ │
│  │  │  - AWS credentials                               │       │ │
│  │  └──────────────────────────────────────────────────┘       │ │
│  │                                                               │ │
│  │  ┌──────────────────────────────────────────────────┐       │ │
│  │  │       NetworkPolicy: devenv-isolation            │       │ │
│  │  │  Ingress: Allow from namespace                   │       │ │
│  │  │  Egress: Allow DNS + Internet                    │       │ │
│  │  └──────────────────────────────────────────────────┘       │ │
│  └───────────────────────────────────────────────────────────────┘ │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
                              │
                              ▼
                    ┌──────────────────┐
                    │  External Access │
                    │                  │
                    │  kubectl exec    │
                    │  port-forward    │
                    │  ingress         │
                    └──────────────────┘
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
User → Ingress → Load Balancer → Service → Pod
```

### Security Layers

1. **Namespace Isolation**: All resources in dedicated `devenv` namespace
2. **NetworkPolicy**: Restricts traffic to/from pods
3. **RBAC**: (Optional) Limit service account permissions
4. **SecurityContext**: Non-root user (UID 1000), dropped capabilities
5. **Secrets**: Encrypted at rest (K8s default)

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
