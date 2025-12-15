# Boundary External Client Connectivity

This document explains how external clients (Boundary CLI on your laptop) connect to Boundary in the Kubernetes cluster.

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                          External Client (Laptop)                            │
│                                                                              │
│  /etc/hosts: 127.0.0.1 boundary.hashicorp.lab boundary-worker.hashicorp.lab │
│  BOUNDARY_ADDR=https://boundary.hashicorp.lab                               │
│  BOUNDARY_TLS_INSECURE=true                                                  │
└──────────────────────────┬──────────────────────────┬────────────────────────┘
                           │                          │
                    (1) API/Auth               (4) SSH Session Proxy
                  HTTPS to boundary.hashicorp.lab   HTTPS to boundary-worker.hashicorp.lab
                           │                          │
                           ▼                          ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                     NGINX Ingress Controller (localhost:443)                 │
│                                                                              │
│  ┌──────────────────────────────────┐   ┌──────────────────────────────────┐│
│  │  Controller Ingress              │   │  Worker Ingress                  ││
│  │  Host: boundary.hashicorp.lab    │   │  Host: boundary-worker.hashicorp.lab ││
│  │  TLS: Termination at Ingress     │   │  TLS: SSL Passthrough            ││
│  │  Backend: HTTP to :9200          │   │  Backend: TLS to :9202           ││
│  └──────────────┬───────────────────┘   └───────────────┬──────────────────┘│
└─────────────────┼───────────────────────────────────────┼────────────────────┘
                  │                                       │
         HTTP (TLS terminated)                  TLS passthrough (encrypted)
                  │                                       │
                  ▼                                       ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                            boundary namespace                                │
│                                                                              │
│  ┌──────────────────────────────────┐   ┌──────────────────────────────────┐│
│  │  Boundary Controller             │   │  Boundary Worker                 ││
│  │  - API Listener: 9200 (HTTP)     │◄──┤  - Proxy Listener: 9202 (TLS)    ││
│  │  - Cluster Listener: 9201        │   │  - public_addr: boundary-worker  ││
│  │  - OIDC Auth via Keycloak        │   │    .hashicorp.lab:443            ││
│  │  - Returns worker address        │   │  - Multiplexed protocol          ││
│  └──────────────────────────────────┘   └────────────┬─────────────────────┘│
└──────────────────────────────────────────────────────┼───────────────────────┘
                                                       │
                                                  (5) SSH to target
                                                       │
                                                       ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                              devenv namespace                                │
│  ┌──────────────────────────────────────────────────────────────────────┐   │
│  │  claude-code-sandbox Pod (SSH :22, trusts Vault CA)                  │   │
│  └──────────────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────────────┘
```

## Connection Flow

### Step 1: Client Authenticates (via boundary.hashicorp.lab)

```bash
export BOUNDARY_ADDR=https://boundary.hashicorp.lab
export BOUNDARY_TLS_INSECURE=true
boundary authenticate oidc -auth-method-id <auth-method-id>
```

**Flow:** Client → `boundary.hashicorp.lab` → NGINX (TLS termination) → Controller API → Keycloak OIDC → Token returned

### Step 2: Client Requests SSH Session

```bash
boundary connect ssh -target-id tssh_xxxxxxxxxx
```

**Flow:** Client → Controller API → Authorization check → Returns worker address: `boundary-worker.hashicorp.lab:443`

### Step 3: Client Connects to Worker (via boundary-worker.hashicorp.lab)

**Flow:**
- Client resolves `boundary-worker.hashicorp.lab` → `127.0.0.1` (via /etc/hosts)
- Client initiates TLS to `boundary-worker.hashicorp.lab:443`
- NGINX forwards encrypted stream (SSL passthrough - no termination)
- Worker terminates TLS using its certificate
- Boundary's multiplexed protocol runs over TLS

### Step 4: Worker Establishes SSH Connection

**Flow:** Worker → Vault (get SSH certificate) → Target pod SSH :22

### Step 5: SSH Session Active

Client ↔ Worker (TLS tunnel) ↔ Target (SSH with Vault cert)

## TLS Configuration

### Controller Ingress (TLS Termination)

```yaml
annotations:
  nginx.ingress.kubernetes.io/backend-protocol: "HTTP"
  nginx.ingress.kubernetes.io/ssl-redirect: "true"
```

- NGINX terminates TLS using `boundary-tls` secret
- Backend is HTTP (controller has `tls_disable = true`)

### Worker Ingress (SSL Passthrough)

```yaml
annotations:
  nginx.ingress.kubernetes.io/ssl-passthrough: "true"
  nginx.ingress.kubernetes.io/ssl-redirect: "true"
```

- NGINX does NOT terminate TLS
- Forwards encrypted stream directly to worker
- Worker terminates TLS with its own certificate
- **Required** because Boundary uses a multiplexed protocol that needs end-to-end TLS

### Certificates with SANs

Both certificates must have Subject Alternative Names (SANs) to avoid:
```
x509: certificate relies on legacy Common Name field, use SANs instead
```

**Controller cert SANs:** `DNS:boundary.hashicorp.lab,DNS:localhost,IP:127.0.0.1`
**Worker cert SANs:** `DNS:boundary-worker.hashicorp.lab,DNS:localhost,IP:127.0.0.1`

Regenerate with:
```bash
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout boundary.key -out boundary.crt \
  -subj "/CN=boundary.hashicorp.lab" \
  -addext "subjectAltName=DNS:boundary.hashicorp.lab,DNS:localhost,IP:127.0.0.1"
```

## Client Setup

### 1. Configure /etc/hosts

```bash
sudo sh -c 'echo "127.0.0.1 boundary.hashicorp.lab boundary-worker.hashicorp.lab" >> /etc/hosts'
```

### 2. Set Environment

```bash
export BOUNDARY_ADDR=https://boundary.hashicorp.lab
export BOUNDARY_TLS_INSECURE=true  # For self-signed certs
```

Or use CA certificate:
```bash
export BOUNDARY_CACERT=/path/to/boundary-ca-bundle.crt
unset BOUNDARY_TLS_INSECURE
```

### 3. Run Setup Script

```bash
cd k8s/platform/boundary/scripts
./setup-client.sh
source ./boundary-env.sh
```

### 4. Authenticate

```bash
# OIDC (Keycloak)
boundary authenticate oidc -auth-method-id amoidc_xxxxxxxxxx

# Or password
boundary authenticate password -auth-method-id ampw_xxxxxxxxxx -login-name admin
```

### 5. Connect

```bash
# List targets
boundary targets list -recursive -scope-id global

# SSH (Enterprise with credential injection)
boundary connect ssh -target-id tssh_xxxxxxxxxx

# SSH (Community)
boundary connect ssh -target-id ttcp_xxxxxxxxxx -- -l node
```

## Troubleshooting

### Cannot resolve boundary.hashicorp.lab

```bash
grep boundary /etc/hosts
# Add if missing: 127.0.0.1 boundary.hashicorp.lab boundary-worker.hashicorp.lab
```

### TLS certificate verification failed

```bash
export BOUNDARY_TLS_INSECURE=true
```

### SSL passthrough not working

```bash
# Check ingress controller has --enable-ssl-passthrough
kubectl get deployment -n ingress-nginx ingress-nginx-controller -o yaml | grep ssl-passthrough

# Check annotation on worker ingress
kubectl get ingress boundary-worker -n boundary -o yaml | grep ssl-passthrough
```

### Session fails to connect to worker

```bash
# Check worker is healthy
kubectl get pods -n boundary -l app=boundary-worker
kubectl logs -n boundary -l app=boundary-worker

# Verify worker public_addr matches ingress
# Should be: boundary-worker.hashicorp.lab:443
```

## Environment Variables

| Variable | Description | Example |
|----------|-------------|---------|
| `BOUNDARY_ADDR` | Controller API URL | `https://boundary.hashicorp.lab` |
| `BOUNDARY_TLS_INSECURE` | Skip TLS verify | `true` |
| `BOUNDARY_CACERT` | CA cert path | `/path/to/ca.crt` |
| `BOUNDARY_TOKEN` | Auth token | Set by authenticate |
