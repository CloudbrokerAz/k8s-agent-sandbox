# Platform Access Guide

This guide explains how to access platform services (Vault, Boundary, etc.) from your Mac when they're running in a KIND cluster.

## Architecture

```
┌─────────────────────────────────────────────────┐
│  Mac (localhost)                                │
│  - /etc/hosts: *.hashicorp.lab → 127.0.0.1      │
│  - Browser/curl → https://*.hashicorp.lab:443   │
└────────────────┬────────────────────────────────┘
                 │
                 ▼
┌─────────────────────────────────────────────────┐
│  KIND Cluster                                   │
│  - Host ports: 80→80, 443→443                   │
│  - NGINX Ingress Controller (TLS termination)   │
│    ├─ vault.hashicorp.lab → vault:8200         │
│    ├─ boundary.hashicorp.lab → boundary:9200    │
│    └─ keycloak.hashicorp.lab → keycloak:8080    │
└─────────────────────────────────────────────────┘
                 │
                 ▼
┌─────────────────────────────────────────────────┐
│  Services                                       │
│  - vault:8200 (ClusterIP)                       │
│  - boundary-controller-api:9200 (ClusterIP)     │
│  - keycloak:8080 (ClusterIP)                    │
│  - code-server:13337 (ClusterIP)                │
└─────────────────────────────────────────────────┘
```

## Quick Start

### One-Command Setup

```bash
cd k8s/scripts
./setup-platform-access.sh
```

This script will:
1. Validate prerequisites
2. Install NGINX Ingress Controller
3. Apply ingress resources for all services
4. Prompt to update /etc/hosts
5. Test connectivity

### Access Vault (Quick)

```bash
# Setup access
cd k8s/platform/vault/scripts
./access-vault.sh setup

# Open Vault UI
./access-vault.sh open

# Get root token
./access-vault.sh token

# Check status
./access-vault.sh status
```

## Manual Setup

If you prefer step-by-step setup:

### 1. Install NGINX Ingress Controller

```bash
cd k8s/scripts
./setup-ingress.sh
```

This installs the NGINX Ingress Controller optimized for KIND clusters.

### 2. Apply Ingress Resources

```bash
# Vault (includes TLS secret)
kubectl apply -f k8s/platform/vault/manifests/08-tls-secret.yaml
kubectl apply -f k8s/platform/vault/manifests/07-ingress.yaml

# Boundary (includes TLS secret)
kubectl apply -f k8s/platform/boundary/manifests/09-tls-secret.yaml
kubectl apply -f k8s/platform/boundary/manifests/10-ingress.yaml

# Keycloak (includes TLS secret)
kubectl apply -f k8s/platform/keycloak/manifests/07-tls-secret.yaml
kubectl apply -f k8s/platform/keycloak/manifests/08-ingress.yaml
```

### 3. Update /etc/hosts

```bash
# Check current entries
./scripts/update-hosts.sh check

# Add entries
sudo ./scripts/update-hosts.sh add

# Remove entries
sudo ./scripts/update-hosts.sh remove
```

This adds entries like:
```
127.0.0.1    vault.hashicorp.lab
127.0.0.1    boundary.hashicorp.lab
127.0.0.1    boundary-worker.hashicorp.lab
127.0.0.1    code-server.hashicorp.lab
127.0.0.1    keycloak.hashicorp.lab
```

### 4. Test Connectivity

```bash
cd k8s/scripts
./test-platform-access.sh

# Or with auto-fix
AUTO_FIX=true ./test-platform-access.sh

# Verbose mode
VERBOSE=true ./test-platform-access.sh
```

## Accessing Services

### Vault

```bash
# UI (HTTPS with self-signed cert)
open https://vault.hashicorp.lab

# API (use -k to skip cert verification for self-signed)
curl -k https://vault.hashicorp.lab/v1/sys/health

# Seal status
curl -k https://vault.hashicorp.lab/v1/sys/seal-status | jq

# Get token
grep "Root Token" k8s/platform/vault/scripts/vault-keys.txt
```

### Boundary

```bash
# UI (HTTPS with self-signed cert)
open https://boundary.hashicorp.lab

# CLI
export BOUNDARY_ADDR=https://boundary.hashicorp.lab
boundary authenticate
```

### Keycloak

```bash
# Admin Console (HTTPS with self-signed cert)
open https://keycloak.hashicorp.lab

# Default credentials: admin / admin123!@#
```

### Code Server

```bash
# UI (once ingress is created)
open http://code-server.hashicorp.lab
```

## Troubleshooting

### Validate Prerequisites

```bash
cd k8s/scripts
./validate-access-prereqs.sh
```

This checks:
- kubectl installation
- curl availability
- Kubernetes cluster connectivity
- NGINX Ingress Controller status
- /etc/hosts entries
- Ingress resources

### Common Issues

#### 1. "Connection refused" or "Could not resolve host"

**Problem**: DNS not configured

**Solution**:
```bash
# Check /etc/hosts
./scripts/update-hosts.sh check

# Add entries
sudo ./scripts/update-hosts.sh add
```

#### 2. "404 Not Found"

**Problem**: Ingress resource not applied

**Solution**:
```bash
# Check ingresses
kubectl get ingress -A

# Apply Vault ingress
kubectl apply -f k8s/platform/vault/manifests/07-ingress.yaml
```

#### 3. "Service Unavailable" or "502 Bad Gateway"

**Problem**: Backend service not running

**Solution**:
```bash
# Check Vault pod
kubectl get pods -n vault

# Check Vault service
kubectl get svc -n vault

# Restart if needed
kubectl rollout restart statefulset/vault -n vault
```

#### 4. Ingress controller not installed

**Problem**: NGINX Ingress Controller missing

**Solution**:
```bash
./scripts/setup-ingress.sh
```

### Manual Diagnostics

```bash
# Check all ingresses
kubectl get ingress -A

# Check ingress controller
kubectl get pods -n ingress-nginx

# Check service endpoints
kubectl get endpoints -n vault

# Test from within cluster
kubectl run -it --rm debug --image=curlimages/curl --restart=Never -- \
  curl http://vault.vault.svc.cluster.local:8200/v1/sys/health
```

## Alternative Access Methods

If ingress doesn't work, you can use:

### Port Forwarding

```bash
# Vault
kubectl port-forward -n vault svc/vault 8200:8200
# Then access: http://localhost:8200

# Boundary
kubectl port-forward -n boundary svc/boundary-controller 9200:9200
```

### NodePort (Not Recommended for KIND)

```bash
# Modify service to NodePort type
kubectl patch svc vault -n vault -p '{"spec":{"type":"NodePort"}}'

# Get NodePort
kubectl get svc vault -n vault
```

## Scripts Reference

| Script | Purpose |
|--------|---------|
| `setup-ingress.sh` | Install NGINX Ingress Controller |
| `setup-platform-access.sh` | Complete access setup (all-in-one) |
| `validate-access-prereqs.sh` | Check prerequisites |
| `update-hosts.sh` | Manage /etc/hosts entries |
| `test-platform-access.sh` | Test connectivity with auto-fix |
| `vault/scripts/access-vault.sh` | Vault-specific helper |

## Environment Variables

```bash
# Auto-update /etc/hosts without prompting
AUTO_HOSTS=true ./setup-platform-access.sh

# Skip connectivity tests
SKIP_TESTS=true ./setup-platform-access.sh

# Auto-fix issues during testing
AUTO_FIX=true ./test-platform-access.sh

# Verbose test output
VERBOSE=true ./test-platform-access.sh
```

## Security Considerations

1. **Local Development Only**: This setup is for local KIND clusters only
2. **/etc/hosts requires sudo**: The update-hosts.sh script needs root access
3. **Self-Signed Certificates**: Services use HTTPS with self-signed certificates
   - Your browser will show a security warning (expected for local development)
   - Use `curl -k` or `--insecure` to skip certificate verification
4. **Root tokens**: Keep vault-keys.txt secure (already in .gitignore)

## Adding New Services

To expose a new service:

1. Generate self-signed TLS certificate:
```bash
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout myservice.key -out myservice.crt -subj "/CN=myservice.local"
```

2. Create TLS secret manifest (e.g., `platform/myservice/manifests/XX-tls-secret.yaml`):
```yaml
apiVersion: v1
kind: Secret
metadata:
  name: myservice-tls
  namespace: myservice
type: kubernetes.io/tls
data:
  tls.crt: <base64-encoded-cert>
  tls.key: <base64-encoded-key>
```

3. Create ingress manifest (e.g., `platform/myservice/manifests/XX-ingress.yaml`):
```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: myservice
  namespace: myservice
  annotations:
    nginx.ingress.kubernetes.io/backend-protocol: "HTTP"
    nginx.ingress.kubernetes.io/ssl-redirect: "true"
    nginx.ingress.kubernetes.io/force-ssl-redirect: "true"
spec:
  ingressClassName: nginx
  tls:
    - hosts:
        - myservice.local
      secretName: myservice-tls
  rules:
    - host: myservice.local
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: myservice
                port:
                  number: 8080
```

4. Add hostname to `scripts/update-hosts.sh`:
```bash
SERVICES=(
    "vault.hashicorp.lab"
    "boundary.hashicorp.lab"
    "boundary-worker.hashicorp.lab"
    "code-server.hashicorp.lab"
    "keycloak.hashicorp.lab"
    "myservice.hashicorp.lab"  # Add this
)
```

5. Apply and test:
```bash
kubectl apply -f platform/myservice/manifests/XX-tls-secret.yaml
kubectl apply -f platform/myservice/manifests/XX-ingress.yaml
sudo ./scripts/update-hosts.sh add
curl -k https://myservice.hashicorp.lab
```

## CI/CD Integration

For automated testing in CI/CD:

```bash
# Non-interactive setup
SKIP_TESTS=false ./setup-platform-access.sh

# Automated testing
AUTO_FIX=true ./test-platform-access.sh || {
    echo "Access tests failed"
    kubectl get ingress -A
    kubectl get pods -A
    exit 1
}
```
