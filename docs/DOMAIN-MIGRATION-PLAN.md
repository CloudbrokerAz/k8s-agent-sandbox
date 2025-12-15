# Domain Migration Plan: `.local` to `hashicorp.lab`

## Overview

This document outlines all changes required to migrate from `.local` domains to `hashicorp.lab` domains.

### Reason for Migration

macOS treats `.local` domains specially due to mDNS (Bonjour) multicast DNS. This causes:
- **5-second DNS timeout** before falling back to `/etc/hosts`
- API response times of 5-7 seconds instead of <100ms
- Poor developer experience

The `hashicorp.lab` domain bypasses mDNS and resolves immediately from `/etc/hosts`.

### Domain Mapping

| Current Domain | New Domain |
|---------------|------------|
| `boundary.local` | `boundary.hashicorp.lab` |
| `boundary-worker.local` | `boundary-worker.hashicorp.lab` |
| `keycloak.local` | `keycloak.hashicorp.lab` |
| `vault.local` | `vault.hashicorp.lab` |

---

## Changes Required

### 1. TLS Certificates (High Priority)

New self-signed certificates must be generated with updated SANs.

| File | Domains to Update |
|------|-------------------|
| `k8s/platform/boundary/manifests/09-tls-secret.yaml` | `boundary.hashicorp.lab` |
| `k8s/platform/boundary/manifests/11-worker-tls-secret.yaml` | `boundary-worker.hashicorp.lab` |
| `k8s/platform/keycloak/manifests/07-tls-secret.yaml` | `keycloak.hashicorp.lab` |
| `k8s/platform/vault/manifests/08-tls-secret.yaml` | `vault.hashicorp.lab` |

**Action**: Regenerate all certificates with:
```bash
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout <service>.key -out <service>.crt \
  -subj "/CN=<service>.hashicorp.lab" \
  -addext "subjectAltName=DNS:<service>.hashicorp.lab,DNS:localhost,IP:127.0.0.1"
```

---

### 2. Ingress Resources

| File | Change |
|------|--------|
| `k8s/platform/boundary/manifests/10-ingress.yaml` | `host: boundary.local` → `boundary.hashicorp.lab` |
| `k8s/platform/boundary/manifests/12-worker-ingress.yaml` | `host: boundary-worker.local` → `boundary-worker.hashicorp.lab` |
| `k8s/platform/keycloak/manifests/08-ingress.yaml` | `host: keycloak.local` → `keycloak.hashicorp.lab` |
| `k8s/platform/vault/manifests/07-ingress.yaml` | `host: vault.local` → `vault.hashicorp.lab` |

---

### 3. Keycloak Configuration

| File | Changes |
|------|---------|
| `k8s/platform/keycloak/manifests/04-deployment.yaml` | `KC_HOSTNAME_URL` and `KC_ADMIN_URL` → `https://keycloak.hashicorp.lab` |
| `k8s/platform/keycloak/manifests/06-realm-init.yaml` | `BOUNDARY_URL` → `https://boundary.hashicorp.lab`, `KEYCLOAK_EXTERNAL_URL` → `https://keycloak.hashicorp.lab` |
| `k8s/platform/keycloak/scripts/configure-realm.sh` | `BOUNDARY_EXTERNAL_URL` default value |
| `k8s/platform/keycloak/scripts/deploy-keycloak.sh` | Output messages with URLs |

---

### 4. Boundary Configuration

| File | Changes |
|------|---------|
| `k8s/platform/boundary/manifests/03-configmap.yaml` | Any `keycloak.local` or `boundary.local` references |
| `k8s/platform/boundary/manifests/05-controller.yaml` | `hostAliases` for `keycloak.hashicorp.lab` |
| `k8s/platform/boundary/manifests/06-worker.yaml` | `public_addr` if set to `.local` domain |
| `k8s/platform/boundary/scripts/configure-oidc-auth.sh` | OIDC issuer and API prefix URLs |
| `k8s/platform/boundary/scripts/configure-targets.sh` | Any domain references |
| `k8s/platform/boundary/scripts/configure-credential-brokering.sh` | Any domain references |
| `k8s/platform/boundary/scripts/deploy-boundary.sh` | Output messages with URLs |
| `k8s/platform/boundary/scripts/boundary-env.sh` | `BOUNDARY_ADDR` default |
| `k8s/platform/boundary/scripts/setup-client.sh` | Client setup instructions |

---

### 5. Vault Configuration

| File | Changes |
|------|---------|
| `k8s/platform/vault/scripts/deploy-vault.sh` | Output messages with URLs |
| `k8s/platform/vault/scripts/export-vault-ca.sh` | Any domain references |

---

### 6. Deployment Scripts

| File | Changes |
|------|---------|
| `k8s/scripts/deploy-all.sh` | Any hardcoded `.local` domains |
| `k8s/scripts/deploy-all-optimized.sh` | Any hardcoded `.local` domains |

---

### 7. Test Scripts

| File | Changes |
|------|---------|
| `k8s/scripts/tests/test-boundary.sh` | Expected domain assertions |
| `k8s/scripts/tests/test-keycloak.sh` | Expected domain assertions |
| `k8s/scripts/tests/test-oidc-auth.sh` | URL defaults |
| `k8s/scripts/tests/test-oidc-flow.sh` | `KEYCLOAK_URL`, `BOUNDARY_URL` defaults |
| `k8s/scripts/tests/test-oidc-browser.sh` | `/etc/hosts` checks, URL defaults |
| `k8s/scripts/tests/test-oidc-browser.py` | `BOUNDARY_URL`, `KEYCLOAK_URL` defaults |
| `k8s/scripts/tests/test-ssh-oidc-browser.sh` | URL defaults, `/etc/hosts` checks |
| `k8s/scripts/tests/test-ssh-oidc-browser.py` | URL defaults |
| `k8s/scripts/test-vault-ssh-access.sh` | Output messages |
| `k8s/scripts/tests/healthcheck.sh` | Domain references |
| `k8s/platform/boundary/scripts/tests/test-targets.sh` | Domain references |
| `k8s/platform/boundary/scripts/tests/test-deployment.sh` | Domain references |

---

### 8. Kind Cluster Configuration

| File | Changes |
|------|---------|
| `k8s/scripts/kind-config.yaml` | Comments referencing `.local` domains |

---

### 9. Documentation

| File | Changes |
|------|---------|
| `README.md` | `/etc/hosts` instructions, `BOUNDARY_ADDR` examples |
| `k8s/README.md` | `/etc/hosts` instructions, all URL examples |
| `k8s/ARCHITECTURE.md` | Architecture diagrams |
| `k8s/QUICK_REFERENCE.md` | Quick reference URLs |
| `k8s/docs/PLATFORM-ACCESS.md` | All access instructions and `/etc/hosts` entries |
| `k8s/docs/architecture.mmd` | Mermaid diagram node names |
| `k8s/docs/architecture-simple.mmd` | Mermaid diagram node names |
| `k8s/docs/boundary-external-connectivity.md` | All domain references |
| `k8s/platform/boundary/README.md` | Boundary-specific docs |
| `k8s/platform/boundary/AGENTS.md` | OIDC configuration details |
| `k8s/platform/boundary/OIDC-SETUP.md` | OIDC setup guide |
| `k8s/platform/boundary/OIDC-FIXES.md` | Fix documentation |
| `k8s/platform/boundary/OIDC_FIXES_CHANGELOG.md` | Changelog |
| `k8s/platform/boundary/FIXES-LOG.md` | Fixes log |
| `k8s/platform/boundary/UPGRADE-0.20.1.md` | Upgrade guide |
| `k8s/platform/keycloak/README.md` | Keycloak docs |
| `k8s/platform/keycloak/QUICKSTART.md` | Quickstart guide |
| `k8s/platform/keycloak/AGENTS.md` | Keycloak AGENTS.md |
| `k8s/platform/keycloak/BOUNDARY_INTEGRATION.md` | Integration guide |
| `k8s/platform/vault-secrets-operator/README.md` | VSO docs |
| `boundary_keycloak_plan.md` | Design document |

---

### 10. Sandbox Manifests

| File | Changes |
|------|---------|
| `k8s/agent-sandbox/vscode-claude/base/claude-code-sandbox.yaml` | Any domain references |
| `k8s/agent-sandbox/vscode-gemini/base/gemini-sandbox.yaml` | Any domain references |

---

### 11. Other Files

| File | Changes |
|------|---------|
| `.gitignore` | Any `.local` patterns |
| `.claude/settings.local.json` | Any domain references |
| `k8s/Dockerfile.production` | Any domain references |
| `.devcontainer/base-image/Dockerfile` | Any domain references |
| `.devcontainer/base-image/library-scripts/terraform-tools.sh` | Any domain references |

---

## Implementation Order

1. **Phase 1: Generate New TLS Certificates**
   - Generate all 4 certificates with new SANs
   - Update secret manifests with new base64-encoded values

2. **Phase 2: Update Kubernetes Manifests**
   - Update all ingress resources
   - Update Keycloak deployment (KC_HOSTNAME_URL)
   - Update Boundary controller/worker configs
   - Update realm-init ConfigMap

3. **Phase 3: Update Scripts**
   - Update deployment scripts
   - Update configuration scripts
   - Update test scripts

4. **Phase 4: Update Documentation**
   - Update all README files
   - Update AGENTS.md files
   - Update architecture diagrams

5. **Phase 5: User Action Required**
   - Update `/etc/hosts`:
     ```
     127.0.0.1 vault.hashicorp.lab boundary.hashicorp.lab boundary-worker.hashicorp.lab keycloak.hashicorp.lab
     ```

6. **Phase 6: Redeploy and Test**
   - Full redeployment of all components
   - Run all test suites
   - Verify OIDC flow works end-to-end

---

## Verification Checklist

- [ ] All TLS certificates regenerated with new SANs
- [ ] All ingress hosts updated
- [ ] Keycloak KC_HOSTNAME_URL updated
- [ ] Boundary OIDC issuer updated
- [ ] Boundary api_url_prefix updated
- [ ] All test scripts pass
- [ ] OIDC browser flow works
- [ ] SSH via Boundary works
- [ ] API response time < 200ms (vs 5+ seconds before)

---

## Rollback Plan

If issues occur:
1. Revert to `main` branch
2. Restore `.local` entries in `/etc/hosts`
3. Redeploy from main branch

---

## Notes

- The `.local` TLD is reserved for mDNS by RFC 6762
- `.lab` is not a registered TLD and is safe for local use
- `hashicorp.lab` namespace clearly identifies this as a HashiCorp sandbox environment
