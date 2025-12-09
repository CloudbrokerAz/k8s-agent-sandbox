# Quick Reference Guide

## Essential Commands

### Build and Deploy

```bash
# One-time setup
./k8s/scripts/build-and-push.sh <dockerhub-username>
# Edit k8s/manifests/05-statefulset.yaml with your image name
./k8s/scripts/create-secrets.sh
./k8s/scripts/deploy.sh

# Or using Kustomize
kubectl apply -k k8s/manifests/
```

### Access

```bash
# Shell into pod
kubectl exec -it -n devenv devenv-0 -- /bin/zsh

# View logs
kubectl logs -n devenv devenv-0 -f

# Port forward
kubectl port-forward -n devenv devenv-0 8080:8080
```

### Scaling

```bash
# Scale up
./k8s/scripts/scale.sh 5

# Scale down
./k8s/scripts/scale.sh 1

# Scale to zero (pause)
./k8s/scripts/scale.sh 0
```

### Monitoring

```bash
# Get pod status
kubectl get pods -n devenv

# Get PVC status
kubectl get pvc -n devenv

# Get events
kubectl get events -n devenv --sort-by='.lastTimestamp'

# Resource usage
kubectl top pods -n devenv
```

### Troubleshooting

```bash
# Describe pod
kubectl describe pod devenv-0 -n devenv

# Check logs
kubectl logs -n devenv devenv-0 --tail=100

# Check secrets
kubectl get secret devenv-secrets -n devenv -o yaml

# Restart pod
kubectl delete pod devenv-0 -n devenv
```

### Data Management

```bash
# Backup workspace
kubectl exec -n devenv devenv-0 -- tar czf /tmp/backup.tar.gz /workspace
kubectl cp devenv/devenv-0:/tmp/backup.tar.gz ./backup.tar.gz

# Restore workspace
kubectl cp ./backup.tar.gz devenv/devenv-0:/tmp/backup.tar.gz
kubectl exec -n devenv devenv-0 -- tar xzf /tmp/backup.tar.gz -C /
```

### Cleanup

```bash
# Full teardown
./k8s/scripts/teardown.sh

# Delete specific resources
kubectl delete statefulset devenv -n devenv
kubectl delete pvc --all -n devenv
kubectl delete secret devenv-secrets -n devenv
```

## File Locations

```
k8s/
├── Dockerfile.production       # Production-ready Docker image
├── .dockerignore               # Build exclusions
├── README.md                   # Full documentation
├── GETTING_STARTED.md          # Step-by-step guide
├── ARCHITECTURE.md             # System design
├── QUICK_REFERENCE.md          # This file
├── manifests/
│   ├── 01-namespace.yaml       # Namespace: devenv
│   ├── 02-secrets.yaml         # Secret template
│   ├── 03-storageclass.yaml    # Storage provisioner
│   ├── 04-pvc-template.yaml    # PVC template
│   ├── 05-statefulset.yaml     # Main workload
│   ├── 06-service.yaml         # Network access
│   ├── 07-networkpolicy.yaml   # Network isolation
│   └── kustomization.yaml      # Kustomize config
└── scripts/
    ├── build-and-push.sh       # Build Docker image
    ├── create-secrets.sh       # Create K8s secrets
    ├── deploy.sh               # Deploy to cluster
    ├── scale.sh                # Scale replicas
    └── teardown.sh             # Remove everything
```

## Environment Variables (in Pod)

```bash
# GitHub
GITHUB_TOKEN

# Terraform Cloud
TFE_TOKEN
TF_TOKEN_app_terraform_io

# AWS
AWS_ACCESS_KEY_ID
AWS_SECRET_ACCESS_KEY
AWS_SESSION_TOKEN (optional)

# Langfuse (optional)
LANGFUSE_HOST
LANGFUSE_PUBLIC_KEY
LANGFUSE_SECRET_KEY

# System
CLAUDE_CONFIG_DIR=/home/node/.claude
NODE_OPTIONS=--max-old-space-size=4096
```

## Persistent Volumes (per pod)

```
/workspace          → workspace-devenv-N     (10Gi)
/commandhistory     → bash-history-devenv-N  (1Gi)
/home/node/.claude  → claude-config-devenv-N (1Gi)
```

## Network Access Patterns

### Internal (within cluster)

```bash
# Pod to pod (same namespace)
ping devenv-1.devenv.devenv.svc.cluster.local

# Service access
curl http://devenv.devenv.svc.cluster.local:8080
```

### External (from local machine)

```bash
# Option 1: kubectl exec
kubectl exec -it -n devenv devenv-0 -- /bin/zsh

# Option 2: Port forward
kubectl port-forward -n devenv devenv-0 8080:8080

# Option 3: LoadBalancer (cloud only)
# Edit 06-service.yaml: type: LoadBalancer
kubectl get svc -n devenv  # Get external IP

# Option 4: Ingress
# Create ingress resource for HTTP/HTTPS access
```

## Common Issues and Solutions

| Issue | Check | Solution |
|-------|-------|----------|
| ImagePullBackOff | Image name | Verify in 05-statefulset.yaml |
| Pending PVC | StorageClass | `kubectl get sc` |
| CrashLoopBackOff | Logs | `kubectl logs devenv-0 -n devenv` |
| Secret not found | Secret exists | `kubectl get secret -n devenv` |
| Pod not ready | Readiness probe | Wait 2-5 minutes |
| Out of resources | Node capacity | `kubectl top nodes` |

## Resource Limits

Default per pod:
- **CPU**: 500m request → 2000m limit
- **Memory**: 2Gi request → 4Gi limit
- **Storage**: 12Gi total

## Security Checklist

- [ ] Secrets created (not committed to git)
- [ ] Image scanned for vulnerabilities
- [ ] NetworkPolicy applied
- [ ] Non-root user (UID 1000)
- [ ] Capabilities dropped (no privileged)
- [ ] RBAC configured (if applicable)
- [ ] TLS enabled (for ingress)
- [ ] Backup strategy in place

## Performance Tuning

### For Development (kind)

```yaml
# Reduce resources
resources:
  requests:
    memory: "1Gi"
    cpu: "250m"
  limits:
    memory: "2Gi"
    cpu: "1000m"
```

### For Production (cloud)

```yaml
# Increase resources
resources:
  requests:
    memory: "4Gi"
    cpu: "1000m"
  limits:
    memory: "8Gi"
    cpu: "4000m"
```

## Monitoring Queries (if Prometheus installed)

```promql
# CPU usage
sum(rate(container_cpu_usage_seconds_total{namespace="devenv"}[5m])) by (pod)

# Memory usage
sum(container_memory_usage_bytes{namespace="devenv"}) by (pod)

# Disk usage
sum(kubelet_volume_stats_used_bytes{namespace="devenv"}) by (persistentvolumeclaim)
```

## Useful Aliases

Add to your shell config:

```bash
# kubectl shortcuts
alias k='kubectl'
alias kdev='kubectl -n devenv'
alias kexec='kubectl exec -it -n devenv devenv-0 -- /bin/zsh'
alias klogs='kubectl logs -n devenv devenv-0 -f'
alias kpods='kubectl get pods -n devenv'
alias kpvcs='kubectl get pvc -n devenv'

# Quick access
alias devenv='kubectl exec -it -n devenv devenv-0 -- /bin/zsh'
```

## Next Steps After Deployment

1. **Test everything**: SSH, git, terraform, aws, gh
2. **Clone your repos**: `git clone` in `/workspace`
3. **Set up workflow**: Install additional tools as needed
4. **Create backups**: Schedule regular PVC snapshots
5. **Monitor usage**: Set up alerts for resource limits
6. **Scale as needed**: Add more replicas for more users
7. **Document for team**: Share access patterns and workflows

## Support Resources

- Full docs: `k8s/README.md`
- Getting started: `k8s/GETTING_STARTED.md`
- Architecture: `k8s/ARCHITECTURE.md`
- Kubernetes docs: https://kubernetes.io/docs/
- kind docs: https://kind.sigs.k8s.io/
