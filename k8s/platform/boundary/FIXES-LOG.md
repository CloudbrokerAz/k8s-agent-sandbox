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
