# Boundary-Keycloak OIDC Integration Fixes

**Date**: 2025-12-13
**Summary**: Comprehensive fixes for OIDC integration issues between Boundary and Keycloak

---

## Overview

This changelog documents fixes applied to resolve inconsistencies and misconfigurations in the Boundary-Keycloak OIDC integration. All changes ensure proper authentication flow for users accessing Boundary via external ingress.

---

## Critical Fixes

### 1. Dynamic Ingress IP Resolution

**Problem**: Hardcoded ingress-nginx ClusterIP (`10.96.197.168`) in controller hostAliases would break if the ingress service was redeployed.

**Files Changed**:
- `manifests/05-controller.yaml`
- `scripts/deploy-boundary.sh`

**Solution**:
- Controller manifest now uses placeholder: `${INGRESS_NGINX_IP:-127.0.0.1}`
- `deploy-boundary.sh` dynamically fetches ingress ClusterIP at deployment time
- Uses `envsubst` or `sed` to substitute the IP before applying the manifest

**Before**:
```yaml
hostAliases:
  - ip: "10.96.197.168"  # Hardcoded - breaks on redeployment
```

**After**:
```yaml
hostAliases:
  - ip: "${INGRESS_NGINX_IP:-127.0.0.1}"  # Dynamically substituted
```

---

### 2. Managed Group Filter Syntax Standardization

**Problem**: Inconsistent filter syntax between scripts caused OIDC group mappings to fail.

**Files Changed**:
- `scripts/configure-oidc-auth.sh` (already correct)
- `k8s/platform/keycloak/scripts/boundary-oidc-setup.sh`
- `k8s/platform/keycloak/BOUNDARY_INTEGRATION.md`

**Incorrect Syntax** (was in some files):
```bash
-filter '"admins" in "/resource/groups"'  # WRONG for OIDC
```

**Correct Syntax** (now standardized everywhere):
```bash
-filter '"/token/groups" contains "admins"'  # Correct for OIDC token claims
```

**Why**: OIDC tokens include groups in the `/token/groups` claim path, not `/resource/groups` which is for LDAP-style resources.

---

### 3. Keycloak Client Redirect URIs

**Problem**: Realm-init only created one redirect URI, preventing authentication via port-forward.

**File Changed**: `k8s/platform/keycloak/manifests/06-realm-init.yaml`

**Before**:
```json
"redirectUris": ["$BOUNDARY_URL/v1/auth-methods/oidc:authenticate:callback"]
```

**After**:
```json
"redirectUris": [
    "$BOUNDARY_URL/v1/auth-methods/oidc:authenticate:callback",
    "http://127.0.0.1:9200/v1/auth-methods/oidc:authenticate:callback",
    "http://localhost:9200/v1/auth-methods/oidc:authenticate:callback"
]
```

---

## High Severity Fixes

### 4. Invalid `groups` Claims Scope Removed

**Problem**: Requesting `groups` as a claims scope would fail because Keycloak doesn't have a standard `groups` scope - groups are included via a mapper.

**File Changed**: `scripts/configure-oidc-auth.sh`

**Before**:
```bash
-claims-scopes="profile" \
-claims-scopes="email" \
-claims-scopes="groups"  # Invalid - not a standard scope
```

**After**:
```bash
-claims-scopes="profile" \
-claims-scopes="email"
# Note: groups are included via Keycloak's groups mapper, not a scope
```

Also fixed in client creation:
```json
"defaultClientScopes": ["openid", "profile", "email"]  # Removed "groups"
```

---

### 5. Deprecated Duplicate OIDC Script

**Problem**: Two OIDC setup scripts with different logic and inconsistencies.

**File Changed**: `k8s/platform/keycloak/scripts/boundary-oidc-setup.sh`

**Solution**: Added deprecation warning pointing to the authoritative script:
- **Deprecated**: `k8s/platform/keycloak/scripts/boundary-oidc-setup.sh`
- **Use Instead**: `k8s/platform/boundary/scripts/configure-oidc-auth.sh`

The deprecated script now displays a warning and 5-second delay before continuing.

---

## Medium Severity Fixes

### 6. Port-Forward Cleanup with Trap

**Problem**: Port-forward processes could be orphaned if the function exited early due to errors.

**File Changed**: `scripts/configure-oidc-auth.sh`

**Solution**: Added proper trap-based cleanup:
```bash
cleanup_port_forward() {
    if [[ -n "$PF_PID" ]]; then
        kill $PF_PID 2>/dev/null || true
        wait $PF_PID 2>/dev/null || true
    fi
}
trap cleanup_port_forward EXIT
```

All early returns now properly clean up the port-forward and reset the trap.

---

## Configuration Alignment Summary

| Component | External URL | Internal Service | Status |
|-----------|--------------|------------------|--------|
| Boundary API | `https://boundary.local` | `boundary-controller-api:9200` | Aligned |
| Boundary Worker | `https://boundary-worker.local:443` | `boundary-worker:9202` | Aligned |
| Keycloak | `https://keycloak.local` | `keycloak:8080` | Aligned |
| OIDC Issuer | `https://keycloak.local/realms/agent-sandbox` | N/A | Aligned |
| Callback URLs | Multiple (ingress + localhost) | N/A | Fixed |
| Group Filters | `/token/groups` | N/A | Standardized |

---

## Verification Steps

After applying these fixes, verify the OIDC integration:

### 1. Check Ingress IP Detection
```bash
# Should show the actual ingress ClusterIP during deployment
./deploy-boundary.sh
# Look for: "✅ Ingress ClusterIP: 10.x.x.x"
```

### 2. Verify Keycloak Client Redirect URIs
```bash
kubectl port-forward -n keycloak svc/keycloak 8080:8080 &
curl -s http://localhost:8080/admin/realms/agent-sandbox/clients?clientId=boundary \
  -H "Authorization: Bearer $(get-admin-token)" | jq '.[0].redirectUris'
# Should show 3 redirect URIs including localhost variants
```

### 3. Test OIDC Authentication
```bash
# Via port-forward
kubectl port-forward -n boundary svc/boundary-controller-api 9200:9200 &
export BOUNDARY_ADDR=http://127.0.0.1:9200
boundary authenticate oidc -auth-method-id=amoidc_xxx

# Via ingress
export BOUNDARY_ADDR=https://boundary.local
export BOUNDARY_TLS_INSECURE=true
boundary authenticate oidc -auth-method-id=amoidc_xxx
```

### 4. Verify Group Mappings
```bash
# After OIDC login, check managed groups
boundary managed-groups list -auth-method-id=amoidc_xxx
# Users should be assigned to their Keycloak groups
```

---

## Files Modified

| File | Change Type |
|------|-------------|
| `manifests/05-controller.yaml` | Modified hostAliases to use placeholder |
| `scripts/deploy-boundary.sh` | Added dynamic ingress IP detection |
| `scripts/configure-oidc-auth.sh` | Fixed claims scopes, added trap cleanup |
| `k8s/platform/keycloak/manifests/06-realm-init.yaml` | Added localhost redirect URIs |
| `k8s/platform/keycloak/scripts/boundary-oidc-setup.sh` | Added deprecation notice, fixed filters |
| `k8s/platform/keycloak/BOUNDARY_INTEGRATION.md` | Fixed filter syntax documentation |

---

## Additional Fixes (Review 2)

### 7. License Secret Made Optional for Community Edition

**Problem**: Controller deployment failed when Enterprise license secret didn't exist.

**File Changed**: `manifests/05-controller.yaml`

**Fix**: Added `optional: true` to license secret reference:
```yaml
- name: BOUNDARY_LICENSE
  valueFrom:
    secretKeyRef:
      name: boundary-license
      key: license
      optional: true  # Added - allows Community Edition to work
```

---

### 8. DB Init Image Version Matching

**Problem**: Database initialization used Community image while controller used Enterprise, potentially causing version mismatches.

**File Changed**: `scripts/deploy-boundary.sh`

**Fix**: Dynamically select image based on license availability:
```bash
if [[ "$ENTERPRISE_MODE" == "true" ]]; then
    BOUNDARY_INIT_IMAGE="hashicorp/boundary-enterprise:0.20.1-ent"
else
    BOUNDARY_INIT_IMAGE="hashicorp/boundary:0.20.1"
fi
```

---

### 9. Groups Mapper Auto-Creation

**Problem**: When `configure-oidc-auth.sh` created the Keycloak client, groups claims weren't included in OIDC tokens because the mapper was missing.

**File Changed**: `scripts/configure-oidc-auth.sh`

**Fix**: Added groups mapper creation after client creation:
```bash
curl -s -X POST ".../clients/${CLIENT_ID}/protocol-mappers/models" \
    -d '{
        "name": "groups",
        "protocolMapper": "oidc-group-membership-mapper",
        "config": {
            "claim.name": "groups",
            "id.token.claim": "true",
            "access.token.claim": "true"
        }
    }'
```

---

### 10. Port-Forward Health Check

**Problem**: Fixed 2-second wait after port-forward start was insufficient on slow systems.

**File Changed**: `scripts/configure-oidc-auth.sh`

**Fix**: Replaced static sleep with active health check polling:
```bash
while ! curl -s "http://localhost:${PORT}/health/ready" >/dev/null 2>&1; do
    WAIT_COUNT=$((WAIT_COUNT + 1))
    if [[ $WAIT_COUNT -ge 20 ]]; then
        echo "Timeout waiting for Keycloak port-forward"
        return 1
    fi
    sleep 0.5
done
```

---

### 11. Config File Redirect URIs Corrected

**Problem**: Config file output showed incorrect internal service URL for redirect URIs.

**File Changed**: `scripts/configure-oidc-auth.sh`

**Fix**: Updated to show correct redirect URIs including ingress URL:
```
Valid Redirect URIs:
  * https://boundary.local/v1/auth-methods/oidc:authenticate:callback (via ingress)
  * http://127.0.0.1:9200/v1/auth-methods/oidc:authenticate:callback (port-forward)
  * http://localhost:9200/v1/auth-methods/oidc:authenticate:callback (port-forward)
```

---

### 12. Fixed Keycloak Realm-Init Job Image Missing jq

**Problem**: The realm-init job used `curlimages/curl:latest` which doesn't include `jq`, causing the initialization script to fail.

**File Changed**: `k8s/platform/keycloak/manifests/06-realm-init.yaml`

**Fix**: Changed to Alpine image with curl and jq installed:
```yaml
image: alpine:3.19
command: ["/bin/sh", "-c", "apk add --no-cache curl jq && /bin/sh /scripts/init-realm.sh"]
```

---

### 13. Fixed Demo User Passwords with Special Characters

**Problem**: Passwords with special characters (`!@#`) were not being set correctly due to shell escaping issues in the realm-init script.

**File Changed**: `k8s/platform/keycloak/manifests/06-realm-init.yaml`

**Fix**: Changed to simpler passwords without special characters:
| User | Old Password | New Password |
|------|--------------|--------------|
| admin | `Admin123!@#` | `Admin123` |
| developer | `Dev123!@#` | `Developer123` |
| readonly | `Read123!@#` | `Readonly123` |

---

### 14. Fixed deploy-all.sh Missing Ingress IP Substitution

**Problem**: `deploy-all.sh` applied the controller manifest directly without substituting the `${INGRESS_NGINX_IP}` placeholder, causing Kubernetes validation errors.

**File Changed**: `k8s/scripts/deploy-all.sh`

**Fix**: Added ingress IP detection and sed substitution before applying the manifest:
```bash
# Get ingress-nginx ClusterIP for hostAliases (required for OIDC)
INGRESS_NGINX_IP=$(kubectl get svc -n ingress-nginx ingress-nginx-controller -o jsonpath='{.spec.clusterIP}' 2>/dev/null || echo "")
if [[ -z "$INGRESS_NGINX_IP" ]]; then
    INGRESS_NGINX_IP=$(kubectl get svc -n ingress-nginx nginx-ingress-controller -o jsonpath='{.spec.clusterIP}' 2>/dev/null || echo "127.0.0.1")
fi

# Substitute ingress IP in controller manifest before applying
sed "s/\${INGRESS_NGINX_IP}/${INGRESS_NGINX_IP}/g" "$K8S_DIR/platform/boundary/manifests/05-controller.yaml" | kubectl apply -f -
```

---

## Complete Configuration Alignment (Final)

| Component | External URL | Backend | TLS | Status |
|-----------|--------------|---------|-----|--------|
| Boundary API | `https://boundary.local` | `controller:9200` | Ingress terminates | ✅ |
| Boundary Worker | `https://boundary-worker.local:443` | `worker:9202` | Passthrough to worker | ✅ |
| Keycloak | `https://keycloak.local` | `keycloak:8080` | Ingress terminates | ✅ |
| OIDC Issuer | `https://keycloak.local/realms/agent-sandbox` | N/A | N/A | ✅ |
| KC_HOSTNAME_URL | `https://keycloak.local` | N/A | Advertises HTTPS | ✅ |
| Callback URLs | 3 variants (ingress + localhost) | N/A | N/A | ✅ |
| Groups Mapper | Auto-created | N/A | N/A | ✅ |
| Managed Groups | `/token/groups` filter | N/A | N/A | ✅ |

---

## Additional Fixes (Review 3)

### 15. Shared OIDC Client Secret via Kubernetes Secret

**Problem**: OIDC callback failing with "Invalid client or Invalid client credentials" because the client secret in Boundary didn't match Keycloak's auto-generated secret.

**Root Cause**:
- Keycloak's realm-init job created the client without specifying a secret → Keycloak auto-generated one
- Boundary's configure-oidc-auth.sh fetched the secret later, but if the sync failed, secrets wouldn't match
- No validation existed to catch this mismatch before users encountered it

**Files Changed**:
- `k8s/scripts/deploy-all.sh`
- `k8s/platform/keycloak/manifests/06-realm-init.yaml`
- `k8s/platform/boundary/scripts/configure-oidc-auth.sh`
- `k8s/scripts/tests/test-oidc-client-secret.sh` (new)

**Solution**:
1. **Create shared secret before Keycloak deployment** (`deploy-all.sh`):
   ```bash
   OIDC_CLIENT_SECRET=$(openssl rand -base64 32 | tr -d '=/+' | head -c 32)
   kubectl create secret generic boundary-oidc-client-secret \
       --namespace=keycloak \
       --from-literal=client-secret="$OIDC_CLIENT_SECRET"
   ```

2. **Realm-init uses shared secret** (`06-realm-init.yaml`):
   ```yaml
   - name: KEYCLOAK_CLIENT_SECRET
     valueFrom:
       secretKeyRef:
         name: boundary-oidc-client-secret
         key: client-secret
         optional: true
   ```

3. **configure-oidc-auth.sh reads shared secret first**:
   ```bash
   KEYCLOAK_CLIENT_SECRET=$(kubectl get secret boundary-oidc-client-secret \
       -n "$KEYCLOAK_NAMESPACE" -o jsonpath='{.data.client-secret}' | base64 -d)
   ```

4. **Validation test** (`test-oidc-client-secret.sh`):
   - Fetches client secret from Keycloak
   - Validates Boundary OIDC auth method exists
   - Ensures shared Kubernetes secret exists and matches
   - Runs as part of deployment verification

---

### 16. OIDC Client Secret Consistency Test

**Problem**: No automated validation to catch client secret mismatches before users encountered OIDC failures.

**File Created**: `k8s/scripts/tests/test-oidc-client-secret.sh`

**Test Coverage**:
1. Verifies Keycloak and Boundary pods are running
2. Fetches client secret from Keycloak via admin API
3. Verifies Boundary OIDC auth method exists
4. Validates client_id matches between systems
5. Creates/validates shared Kubernetes secret
6. Provides clear remediation steps if issues found

**Integration**: Added to `deploy-all.sh` verification tests:
```bash
[[ "$DEPLOY_KEYCLOAK" == "true" ]] && "$SCRIPT_DIR/tests/test-oidc-client-secret.sh" || true
```

---

## Complete Configuration Alignment (Final v2)

| Component | External URL | Backend | TLS | Status |
|-----------|--------------|---------|-----|--------|
| Boundary API | `https://boundary.local` | `controller:9200` | Ingress terminates | ✅ |
| Boundary Worker | `https://boundary-worker.local:443` | `worker:9202` | Passthrough to worker | ✅ |
| Keycloak | `https://keycloak.local` | `keycloak:8080` | Ingress terminates | ✅ |
| OIDC Issuer | `https://keycloak.local/realms/agent-sandbox` | N/A | N/A | ✅ |
| KC_HOSTNAME_URL | `https://keycloak.local` | N/A | Advertises HTTPS | ✅ |
| Callback URLs | 3 variants (ingress + localhost) | N/A | N/A | ✅ |
| Groups Mapper | Auto-created | N/A | N/A | ✅ |
| Managed Groups | `/token/groups` filter | N/A | N/A | ✅ |
| **Client Secret** | **Shared via K8s secret** | N/A | N/A | ✅ |

---

## Additional Fixes (Review 4 - Browser Testing)

### 17. Update Boundary OIDC Auth Method with Correct Client Secret

**Problem**: OIDC callback failing with "Invalid client or Invalid client credentials" even after shared secret was created. The Boundary OIDC auth method stored an old/different client secret in its database.

**Root Cause**:
- Boundary stores the client_secret_hmac (hash) of the configured secret
- Even if K8s secret matched Keycloak, Boundary's internal database had a different secret
- The `configure-oidc-auth.sh` script wasn't updating existing auth methods with the current secret

**Boundary Logs Showing the Issue**:
```
oidc.Callback: unable to complete exchange with oidc provider:
  Provider.Exchange: unable to exchange auth code with provider:
    oauth2: "unauthorized_client" "Invalid client or Invalid client credentials"
```

**Files Changed**:
- `k8s/platform/boundary/scripts/configure-oidc-auth.sh`

**Fix**: Always update the auth method with the current client secret from K8s:
```bash
# Get current version and update with correct secret
CURRENT_VERSION=$(boundary auth-methods read -id=$AUTH_METHOD_ID ... | jq -r '.item.version')
boundary auth-methods update oidc \
    -id=$AUTH_METHOD_ID \
    -client-secret="$CLIENT_SECRET" \
    -version=$CURRENT_VERSION
```

---

### 18. Set OIDC Auth Method as Primary for Auto User Creation

**Problem**: OIDC login failing with "user not found for account ... and auth method is not primary for the scope so refusing to auto-create user".

**Root Cause**:
- Boundary requires auth method to be "primary" for a scope to auto-create users on first login
- OIDC auth method was created but not set as primary for the DevOps scope
- Users had to be manually pre-created before they could login via OIDC

**Boundary Error**:
```
iam.(Repository).LookupUserWithLogin: user not found for account acctoidc_xxx and
auth method is not primary for the scope so refusing to auto-create user
```

**Files Changed**:
- `k8s/platform/boundary/scripts/configure-oidc-auth.sh`

**Fix**: Set OIDC auth method as primary for the scope after creation:
```bash
# After creating OIDC auth method, set it as primary for auto-user creation
boundary scopes update -id=$SCOPE_ID \
    -primary-auth-method-id=$OIDC_AUTH_METHOD_ID
```

---

### 19. Playwright Browser Test for OIDC Flow

**Problem**: No automated end-to-end test that validates the actual browser-based OIDC flow.

**File Created**: `k8s/scripts/tests/test-oidc-browser.py`

**Test Coverage**:
1. Navigate to Boundary UI
2. Select DevOps scope
3. Click OIDC/Keycloak auth method
4. Handle popup window redirect to Keycloak
5. Fill credentials and submit
6. Verify successful authentication
7. Capture screenshots at each step for debugging

**Dependencies**: Requires Python virtual environment with Playwright:
```bash
python3 -m venv .venv
.venv/bin/pip install playwright
.venv/bin/python -m playwright install chromium
.venv/bin/python k8s/scripts/tests/test-oidc-browser.py
```

---

## Complete Configuration Alignment (Final v3)

| Component | External URL | Backend | TLS | Status |
|-----------|--------------|---------|-----|--------|
| Boundary API | `https://boundary.local` | `controller:9200` | Ingress terminates | ✅ |
| Boundary Worker | `https://boundary-worker.local:443` | `worker:9202` | Passthrough to worker | ✅ |
| Keycloak | `https://keycloak.local` | `keycloak:8080` | Ingress terminates | ✅ |
| OIDC Issuer | `https://keycloak.local/realms/agent-sandbox` | N/A | N/A | ✅ |
| KC_HOSTNAME_URL | `https://keycloak.local` | N/A | Advertises HTTPS | ✅ |
| Callback URLs | 3 variants (ingress + localhost) | N/A | N/A | ✅ |
| Groups Mapper | Auto-created | N/A | N/A | ✅ |
| Managed Groups | `/token/groups` filter | N/A | N/A | ✅ |
| Client Secret | Shared via K8s secret | N/A | N/A | ✅ |
| **Auth Method** | **Updated with current secret** | N/A | N/A | ✅ |
| **Primary Auth** | **OIDC set as primary** | N/A | N/A | ✅ |

---

## Related Documentation

- [Boundary OIDC Auth Methods](https://developer.hashicorp.com/boundary/docs/concepts/domain-model/auth-methods#oidc-auth-method-attributes)
- [Keycloak OIDC Clients](https://www.keycloak.org/docs/latest/server_admin/#_oidc_clients)
- [Boundary Managed Groups](https://developer.hashicorp.com/boundary/docs/concepts/domain-model/managed-groups)
