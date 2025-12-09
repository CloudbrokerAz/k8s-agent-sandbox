# Agent Sandbox Platform - Kubernetes Deployment

This directory contains the complete platform for deploying AI agent development environments to Kubernetes, including secrets management, secure access, and secret synchronization.

## Directory Structure

```
k8s/
├── agent-sandbox/           # Core development environments
│   ├── manifests/          # DevEnv Kubernetes manifests
│   └── scripts/            # DevEnv deployment scripts
├── platform/               # Supporting infrastructure
│   ├── boundary/           # HashiCorp Boundary (secure access)
│   ├── vault/              # HashiCorp Vault (secrets management)
│   └── vault-secrets-operator/  # VSO (secret synchronization)
├── scripts/                # Master deployment scripts
│   ├── deploy-all.sh       # Deploy complete platform
│   ├── teardown-all.sh     # Remove complete platform
│   └── setup-kind.sh       # Create local Kind cluster
└── docs/                   # Documentation
    ├── README.md           # This file
    ├── GETTING_STARTED.md  # Quick start guide
    └── ARCHITECTURE.md     # Platform architecture
```

## Architecture

- **Agent Sandbox**: Multi-user isolated development environments (StatefulSet pods)
  - Custom devcontainer with pre-installed tools (Terraform, AWS CLI, Claude Code, etc.)
  - SSH access for VSCode Remote Development
  - Persistent workspaces across restarts
- **HashiCorp Vault**: Centralized secrets management with KV, SSH, and TFE engines
- **HashiCorp Boundary**: Identity-based secure access to agent pods
- **Vault Secrets Operator**: Automatic sync of secrets from Vault to Kubernetes
- **Network isolation**: Controlled access via NetworkPolicies

## Prerequisites

1. **Kubernetes cluster** (Kind, K8s, OpenShift, etc.)
2. **kubectl** installed and configured
3. **Helm 3.x** installed (for VSO deployment)
4. **Docker** installed (for building images)

### Validate Prerequisites

Run the prerequisite check script before deployment:

```bash
cd k8s/scripts
./check-prereqs.sh
```

This validates:
- kubectl installation and cluster connectivity
- Helm installation
- Docker availability
- Required CLI tools (jq, openssl)

### Configuration

All platform settings are defined in `scripts/platform.env.example`. To customize:

```bash
# Copy to .env for local overrides
cp scripts/platform.env.example scripts/.env

# Edit configuration
vi scripts/.env
```

Key configuration options:
- `DEVENV_REPLICAS` - Number of agent sandbox pods
- `DEPLOY_BOUNDARY` - Enable/disable Boundary deployment
- `DEPLOY_VAULT` - Enable/disable Vault deployment
- `DEPLOY_VSO` - Enable/disable VSO deployment
- `DEBUG` - Enable verbose output

## Quick Start

### Option 1: Full Platform Deployment (Recommended)

Deploy the complete platform including Vault, Boundary, and VSO:

```bash
cd k8s/scripts

# Create a local Kind cluster (if needed)
./setup-kind.sh

# Deploy all components
./deploy-all.sh
```

This will deploy:
1. **Agent Sandbox** - Multi-user development environments
2. **Vault** - Secrets management (auto-initialized)
3. **Boundary** - Secure access management
4. **VSO** - Automatic secret synchronization
5. **Keycloak** - Identity provider (optional)

#### Deployment Features

The deploy script supports advanced options:

```bash
# Resume a partial deployment (skips already-deployed components)
RESUME=auto ./deploy-all.sh

# Run deployments in parallel (faster but more resource-intensive)
PARALLEL=true ./deploy-all.sh

# Skip specific components
SKIP_VAULT=true SKIP_BOUNDARY=true ./deploy-all.sh

# Combined options
RESUME=auto PARALLEL=true ./deploy-all.sh
```

### Option 2: Agent Sandbox Only

Deploy just the development environments:

```bash
cd k8s/agent-sandbox/scripts

# Create secrets
./create-secrets.sh

# Deploy
./deploy.sh
```

### Access Your Environment

```bash
# Check pod status
kubectl get pods -n devenv

# Access the dev environment
kubectl exec -it -n devenv devenv-0 -- /bin/bash

# View logs
kubectl logs -n devenv devenv-0 -f
```

### Configure Additional Services

```bash
# Configure SSH secrets engine
./platform/vault/scripts/configure-ssh-engine.sh

# Configure TFE secrets engine (for Terraform Cloud)
./platform/vault/scripts/configure-tfe-engine.sh
```

## Multi-User Setup

### Scaling for Multiple Users

Each replica in the StatefulSet is an isolated dev environment:

```bash
# Scale to 3 users
./k8s/agent-sandbox/scripts/scale.sh 3

# Access specific user environments
kubectl exec -it -n devenv devenv-0 -- /bin/bash  # User 1
kubectl exec -it -n devenv devenv-1 -- /bin/bash  # User 2
kubectl exec -it -n devenv devenv-2 -- /bin/bash  # User 3
```

### Per-User Configuration

Each pod gets:
- **Unique persistent volumes**: `workspace-devenv-{0,1,2,...}`
- **Stable network identity**: `devenv-{0,1,2,...}.devenv.devenv.svc.cluster.local`
- **Isolated workspace**: No cross-contamination between users

## Cluster-Specific Configuration

### For kind (Docker Desktop)

The default configuration works out of the box. Uses `standard` StorageClass.

```bash
# Verify storage class
kubectl get storageclass

# Should see 'standard' or 'hostpath'
```

### For Standard Kubernetes

Update `k8s/agent-sandbox/manifests/05-statefulset.yaml` to use your cluster's StorageClass:

```yaml
storageClassName: your-storage-class  # e.g., gp2, ebs, nfs, etc.
```

### For OpenShift

1. **Remove or update StorageClass** in manifests:
   ```bash
   # OpenShift typically auto-provisions storage
   # Comment out storageClassName in 05-statefulset.yaml
   ```

2. **SecurityContextConstraints** may need adjustment:
   ```bash
   # Allow the service account to run with specific user ID
   oc adm policy add-scc-to-user anyuid -z default -n devenv
   ```

3. **NetworkPolicy** enforcement:
   OpenShift enforces NetworkPolicies by default. Review `07-networkpolicy.yaml`.

## Advanced Configuration

### Custom Storage Sizes

Edit `k8s/agent-sandbox/manifests/05-statefulset.yaml`:

```yaml
volumeClaimTemplates:
- metadata:
    name: workspace
  spec:
    resources:
      requests:
        storage: 20Gi  # Increase from default 10Gi
```

### Resource Limits

Adjust CPU/memory in `05-statefulset.yaml`:

```yaml
resources:
  requests:
    memory: "4Gi"   # Increase from 2Gi
    cpu: "1000m"    # Increase from 500m
  limits:
    memory: "8Gi"   # Increase from 4Gi
    cpu: "4000m"    # Increase from 2000m
```

### External Access

#### Option 1: Port Forwarding (Development)

```bash
kubectl port-forward -n devenv devenv-0 8080:8080
# Access at http://localhost:8080
```

#### Option 2: LoadBalancer (Cloud)

Edit `k8s/agent-sandbox/manifests/06-service.yaml`:

```yaml
spec:
  type: LoadBalancer  # Change from ClusterIP
```

#### Option 3: Ingress (Production)

Create an Ingress resource (example for nginx-ingress):

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: devenv-ingress
  namespace: devenv
spec:
  rules:
  - host: devenv.example.com
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: devenv
            port:
              number: 8080
```

## Secrets Management

### Using External Secret Managers

Instead of `create-secrets.sh`, integrate with:

- **HashiCorp Vault**: Use [Vault Secrets Operator](https://github.com/hashicorp/vault-secrets-operator)
- **AWS Secrets Manager**: Use [External Secrets Operator](https://external-secrets.io/)
- **Azure Key Vault**: Use [Secrets Store CSI Driver](https://secrets-store-csi-driver.sigs.k8s.io/)

### Rotating Secrets

```bash
# Update secrets
kubectl create secret generic devenv-secrets \
  --from-literal=GITHUB_TOKEN="new-token" \
  -n devenv \
  --dry-run=client -o yaml | kubectl apply -f -

# Restart pods to pick up new secrets
kubectl rollout restart statefulset/devenv -n devenv
```

## Troubleshooting

### Pods Not Starting

```bash
# Check pod status
kubectl describe pod devenv-0 -n devenv

# Common issues:
# - Image pull errors: Verify Docker Hub credentials
# - PVC pending: Check StorageClass availability
# - Secret missing: Run create-secrets.sh
```

### Storage Issues

```bash
# Check PVCs
kubectl get pvc -n devenv

# Check PVs
kubectl get pv

# Force delete stuck PVC (CAUTION: data loss)
kubectl patch pvc workspace-devenv-0 -n devenv -p '{"metadata":{"finalizers":null}}'
```

### Network Issues

```bash
# Test DNS resolution
kubectl exec -it -n devenv devenv-0 -- nslookup google.com

# Test internet connectivity
kubectl exec -it -n devenv devenv-0 -- curl -I https://github.com

# Check NetworkPolicy
kubectl describe networkpolicy -n devenv
```

### Resource Constraints

```bash
# Check pod resource usage
kubectl top pods -n devenv

# Check node capacity
kubectl describe nodes | grep -A 5 "Allocated resources"
```

## Monitoring and Observability

### Basic Monitoring

```bash
# Watch pod status
kubectl get pods -n devenv -w

# Stream logs
kubectl logs -n devenv devenv-0 -f

# Get events
kubectl get events -n devenv --sort-by='.lastTimestamp'
```

### Metrics (if Prometheus is installed)

```bash
# Pod metrics
kubectl top pods -n devenv

# Container metrics
kubectl top pods -n devenv --containers
```

## Backup and Disaster Recovery

### Backup Workspace Data

```bash
# Create a backup of a user's workspace
kubectl exec -n devenv devenv-0 -- tar czf /tmp/backup.tar.gz /workspace
kubectl cp devenv/devenv-0:/tmp/backup.tar.gz ./backup-user0-$(date +%Y%m%d).tar.gz
```

### Restore Workspace Data

```bash
# Restore from backup
kubectl cp ./backup-user0-20250101.tar.gz devenv/devenv-0:/tmp/backup.tar.gz
kubectl exec -n devenv devenv-0 -- tar xzf /tmp/backup.tar.gz -C /
```

## Cleanup

### Remove Everything

```bash
cd k8s/scripts

# Remove complete platform (Vault, Boundary, VSO, DevEnv)
./teardown-all.sh

# Remove only agent sandbox
./agent-sandbox/scripts/teardown.sh
```

### Remove Specific Components

```bash
# Delete StatefulSet only (keeps data)
kubectl delete statefulset devenv -n devenv

# Delete PVCs (CAUTION: data loss)
kubectl delete pvc -n devenv --all

# Delete secrets
kubectl delete secret devenv-secrets -n devenv
```

## Security Considerations

1. **Secrets**: Never commit secrets to git. Use `.gitignore` for any files containing secrets.

2. **RBAC**: Consider creating service accounts with limited permissions:
   ```yaml
   apiVersion: v1
   kind: ServiceAccount
   metadata:
     name: devenv-sa
     namespace: devenv
   ```

3. **Network Isolation**: The default NetworkPolicy provides basic isolation. Review for your security requirements.

4. **Image Scanning**: Scan your Docker image for vulnerabilities:
   ```bash
   docker scan your-username/terraform-devenv:latest
   ```

5. **Pod Security**: The DevEnv StatefulSet uses a relaxed security context (runs as root) for development convenience. For production deployments, consider tightening the security context in `agent-sandbox/manifests/05-statefulset.yaml`.

## Cost Optimization

### For Cloud Clusters

1. **Right-size resources**: Adjust requests/limits based on actual usage
2. **Scale to zero**: When not in use: `./scale.sh 0`
3. **Use node autoscaling**: Configure cluster autoscaler
4. **Storage class**: Use cheaper storage tiers for non-critical data

### For kind/Local

1. **Limit replicas**: Don't over-provision locally
2. **Resource limits**: Prevent OOM on your machine
3. **Cleanup**: Use `./teardown.sh` when done

## Next Steps

1. **Add SSH access**: Configure SSH server in the container for remote access
2. **Implement authentication**: Add OAuth/OIDC for user management
3. **Setup ingress**: Expose via ingress controller for web access
4. **Add monitoring**: Integrate Prometheus/Grafana for observability
5. **Automate provisioning**: Use Terraform or Helm for deployment automation
6. **User namespaces**: Isolate users in separate namespaces for stronger security

## References

- [Kubernetes StatefulSets](https://kubernetes.io/docs/concepts/workloads/controllers/statefulset/)
- [Kubernetes Secrets](https://kubernetes.io/docs/concepts/configuration/secret/)
- [kind Documentation](https://kind.sigs.k8s.io/)
- [Agent Sandbox Project](https://github.com/kubernetes-sigs/agent-sandbox)
- [DevContainer Spec](https://containers.dev/)

## Support

For issues or questions:
- Review pod logs: `kubectl logs -n devenv devenv-0`
- Check events: `kubectl get events -n devenv`
- Describe resources: `kubectl describe pod devenv-0 -n devenv`
