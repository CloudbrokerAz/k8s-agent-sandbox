# Boundary OIDC Fixes Log

This document tracks fixes applied to resolve OIDC authentication issues between Boundary and Keycloak.

## Problem Summary

Users accessing Boundary via `https://boundary.local` were getting OIDC errors during the OAuth2 callback phase.

## Root Causes and Fixes

### 1. Keycloak Hostname Configuration (KC_HOSTNAME_URL)

**Problem**: Keycloak was configured with `KC_HOSTNAME=keycloak.local` which caused it to advertise HTTP URLs in the OIDC discovery document, but users access via HTTPS ingress.

**Error**:
```
oidc: issuer did not match the issuer returned by provider, expected "http://keycloak.local/realms/agent-sandbox" got "https://keycloak.local/realms/agent-sandbox"
```

**Fix**: Use `KC_HOSTNAME_URL=https://keycloak.local` instead of `KC_HOSTNAME=keycloak.local`

**Important**: Do NOT set both `KC_HOSTNAME` and `KC_HOSTNAME_URL` - Keycloak will fail to start.

**File**: `k8s/platform/keycloak/manifests/04-deployment.yaml`
```yaml
- name: KC_HOSTNAME_URL
  value: "https://keycloak.local"
- name: KC_HOSTNAME_ADMIN_URL
  value: "https://keycloak.local"
```

### 2. Boundary OIDC Issuer Must Be HTTPS

**Problem**: Boundary's OIDC auth method was configured with `http://` issuer but Keycloak now advertises `https://`.

**Fix**: Update the OIDC auth method issuer to `https://keycloak.local/realms/agent-sandbox`

**File**: `k8s/platform/boundary/scripts/configure-oidc-auth.sh`
```bash
OIDC_ISSUER="https://keycloak.local/realms/agent-sandbox"
```

### 3. Boundary Controller Network Access to HTTPS Keycloak

**Problem**: Boundary controller needs to validate the OIDC provider by fetching the discovery document. It must reach `https://keycloak.local:443`.

**Fix**: Update Boundary controller `hostAliases` to point `keycloak.local` to the ingress controller service IP (which handles TLS termination).

**File**: `k8s/scripts/deploy-all.sh` - Update hostAliases section
```bash
INGRESS_IP=$(kubectl get svc ingress-nginx-controller -n ingress-nginx -o jsonpath='{.spec.clusterIP}')
# Then use $INGRESS_IP for keycloak.local hostAlias
```

### 4. TLS Certificate Must Have SANs

**Problem**: The self-signed TLS certificate used Common Name (CN) only, which causes Go's TLS library to fail validation.

**Error**:
```
x509: certificate relies on legacy Common Name field, use SANs instead
```

**Fix**: Regenerate certificate with Subject Alternative Names (SAN):
```bash
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout keycloak-tls.key \
  -out keycloak-tls.crt \
  -subj "/CN=keycloak.local" \
  -addext "subjectAltName=DNS:keycloak.local,DNS:keycloak.keycloak.svc.cluster.local"
```

### 5. Boundary Must Trust the Self-Signed CA

**Problem**: Self-signed certificate is not trusted by default.

**Error**:
```
x509: certificate signed by unknown authority
```

**Fix**: Add the CA certificate to the Boundary OIDC auth method:
```bash
boundary auth-methods update oidc \
  -id='amoidc_xxx' \
  -issuer='https://keycloak.local/realms/agent-sandbox' \
  -idp-ca-cert="$(cat keycloak-tls.crt)"
```

### 6. Client Secret Synchronization

**Problem**: Client secret mismatch between Keycloak and Boundary causes `invalid_client_credentials` error.

**Fix**: The `configure-oidc-auth.sh` script auto-fetches the client secret from Keycloak's admin API and configures it in Boundary.

## Verification Commands

```bash
# Check Keycloak OIDC discovery (should show HTTPS URLs)
curl -sk 'https://keycloak.local/realms/agent-sandbox/.well-known/openid-configuration' | jq '{issuer}'

# Check Boundary OIDC config
boundary auth-methods read -id=<auth-method-id> -format=json | jq '.item.attributes | {issuer, state}'

# Test from Boundary controller pod
kubectl exec -n boundary <controller-pod> -c boundary-controller -- \
  wget --no-check-certificate -O - 'https://keycloak.local/realms/agent-sandbox/.well-known/openid-configuration'
```

## Related Files

- `k8s/platform/keycloak/manifests/04-deployment.yaml` - Keycloak deployment with KC_HOSTNAME_URL
- `k8s/platform/keycloak/AGENTS.md` - Keycloak configuration documentation
- `k8s/platform/boundary/scripts/configure-oidc-auth.sh` - OIDC setup script
- `k8s/scripts/deploy-all.sh` - Main deployment script
