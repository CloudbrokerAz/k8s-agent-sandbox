# Boundary Configuration Fixes Log

This document tracks the working configuration for Boundary SSH proxy.

## Working Solution: Port-Forward + Vault SSH CA

**Status: VERIFIED WORKING** (2025-12-15)

### Architecture

```
Client → kubectl port-forward → Boundary Worker → Sandbox sshd
                                     ↓
                              Vault SSH CA
                              (certificate auth)
```

### Configuration Summary

| Component | Setting | Value |
|-----------|---------|-------|
| Boundary Worker | `public_addr` | `localhost:9202` |
| Boundary Worker | `tls_disable` | `true` (proxy listener) |
| Sandbox sshd | Port | `22` |
| Sandbox sshd | `TrustedUserCAKeys` | `/vault-ssh-ca/vault-ssh-ca.pub` (mount path) |
| Sandbox sshd | `AuthorizedPrincipalsFile` | `none` |
| Vault SSH | Role | `devenv-access` |
| Vault SSH | Principal | `node` |

### Usage

```bash
# 1. Start port-forward for Boundary worker
kubectl port-forward -n boundary svc/boundary-worker 9202:9202 &

# 2. Generate and sign SSH key
ssh-keygen -t ed25519 -f /tmp/ssh-key -N ""
vault write -field=signed_key ssh/sign/devenv-access \
  public_key=@/tmp/ssh-key.pub \
  valid_principals=node > /tmp/ssh-key-cert.pub

# 3. Connect via Boundary
export BOUNDARY_ADDR=https://boundary.local
export BOUNDARY_TLS_INSECURE=true
boundary connect -target-id=ttcp_w20V4jZhpw -exec ssh -- \
  -i /tmp/ssh-key \
  -o CertificateFile=/tmp/ssh-key-cert.pub \
  -o StrictHostKeyChecking=no \
  -l node -p '{{boundary.port}}' '{{boundary.ip}}' 'echo SSH_SUCCESS'
```

### Key Files

| File | Purpose |
|------|---------|
| `k8s/platform/boundary/manifests/03-configmap.yaml` | Boundary worker config |
| `k8s/agent-sandbox/vscode-claude/scripts/setup-ssh-ca.sh` | Sandbox SSH CA setup |
| `k8s/platform/vault/scripts/vault-ssh-ca.pub` | Vault SSH CA public key |

### Why Port-Forward Instead of Ingress

Boundary worker uses dynamic SNI-based TLS where session IDs (e.g., `s_rdT4sLtwrW`) are passed as SNI values. nginx-ingress cannot handle this because it expects SNI to match host rules. Port-forward provides a simple, reliable solution for dev/Kind environments.

## Credential Brokering (Community Edition)

**Status: WORKING** (2025-12-15)

For external users who cannot directly access Vault, credential brokering provides pre-signed SSH credentials.

### Architecture

```
User → OIDC Auth → Boundary → Authorize Session → Get Brokered Credentials
                                     ↓
                              Vault KV Secret
                              (pre-signed SSH key + cert)
                                     ↓
                              User → SSH with credentials → Sandbox
```

### Configuration

The `configure-credential-brokering.sh` script:
1. Generates an ED25519 SSH key pair
2. Signs the key with Vault SSH CA
3. Stores both in Vault KV at `secret/boundary/ssh-credentials`
4. Creates a vault-generic credential library
5. Attaches as brokered-credential-source to SSH targets

### Usage

```bash
# 1. Authenticate via OIDC
export BOUNDARY_ADDR=https://boundary.local
export BOUNDARY_TLS_INSECURE=true
boundary authenticate oidc -auth-method-id=amoidc_IwjPNziUka

# 2. Connect with brokered credentials
# Credentials are automatically retrieved and used
boundary connect -target-id=ttcp_i8JZfSe0Vd -exec ssh -- \
  -l node -p '{{boundary.port}}' '{{boundary.ip}}'

# Or get credentials explicitly
boundary targets authorize-session -id=ttcp_i8JZfSe0Vd -format=json | \
  jq '.item.credentials[0].secret.decoded.data'
```

### Security Note

This uses a shared pre-signed SSH key (valid for 24h). For per-user certificates:
- Use Enterprise credential injection, or
- Have users sign their own keys via vault.local

### Key Files

| File | Purpose |
|------|---------|
| `configure-credential-brokering.sh` | Sets up brokered credentials |
| `secret/boundary/ssh-credentials` | Vault KV path for SSH credentials |
| `clvlt_*` | Vault-generic credential library ID |
