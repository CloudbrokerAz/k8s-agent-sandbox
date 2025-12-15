# Boundary-Keycloak OIDC Integration Plan

## Executive Summary

This document outlines the plan to achieve successful OIDC authentication between HashiCorp Boundary and Keycloak. The integration allows users to authenticate to Boundary using Keycloak credentials with role-based access control via group membership.

## Documentation References

### Official HashiCorp Documentation
- [Boundary Auth Methods - OIDC](https://developer.hashicorp.com/boundary/docs/concepts/domain-model/auth-methods)
- [Boundary OIDC with Auth0](https://developer.hashicorp.com/boundary/tutorials/identity-management/oidc-auth0) (patterns apply to Keycloak)
- [Vault OIDC with Keycloak](https://developer.hashicorp.com/vault/docs/auth/jwt/oidc-providers/keycloak)

### HashiCorp Community Discussions
- [Boundary Keycloak OIDC](https://discuss.hashicorp.com/t/boundary-keycloak-oidc/23374) - max-age configuration
- [Desktop Client and Keycloak](https://discuss.hashicorp.com/t/impossible-to-connect-with-desktop-client-and-keycloak/63372) - HTTPS requirements

### Keycloak Documentation
- [Client Authentication Methods](https://wjw465150.gitbooks.io/keycloak-documentation/content/securing_apps/topics/oidc/java/client-authentication.html)
- Token endpoint supports: `client_secret_basic`, `client_secret_post`, `client_secret_jwt`, `private_key_jwt`

## Current Issue

**Error**: `invalid_client_credentials` during OAuth2 token exchange

**Root Cause Analysis**: The client secret synchronization between Keycloak and Boundary is failing due to:
1. **Hardcoded vs Dynamic Secret Mismatch**: Keycloak's `configure-realm.sh` sets a hardcoded secret (`boundary-client-secret-change-me`), but Boundary's `configure-oidc-auth.sh` fetches the current secret from Keycloak API
2. **Secret Regeneration**: When secrets are regenerated in Keycloak, Boundary's stored HMAC doesn't match
3. **Shell Escaping Issues**: Using `env://` syntax for passing secrets through kubectl exec causes shell escaping problems (fixed to use `file://` syntax)
4. **Potential Client Auth Method Mismatch**: Boundary (using go-oidc library) may use `client_secret_basic` (HTTP Basic Auth), while testing with wget uses `client_secret_post` (form parameters)

## Critical Diagnostic Finding

**Observation**: Manual wget tests from the Boundary pod succeed, but Boundary's actual OIDC flow fails.

| Test | Result | Keycloak Log |
|------|--------|--------------|
| Manual wget with POST body | `invalid_code` (success - proves creds work) | `client_auth_method="client-secret"` |
| Manual wget with Basic Auth | `invalid_code` (success) | `client_auth_method="client-secret"` |
| Boundary OIDC library | `invalid_client_credentials` | **No `client_auth_method` field** |

**Interpretation**: The absence of `client_auth_method` in Keycloak's logs for Boundary's requests suggests that **Boundary is not transmitting the client credentials at all**, or is transmitting them in a way Keycloak cannot recognize.

### Possible Causes

1. **Secret Retrieval Failure**: Boundary may be failing to decrypt/retrieve the stored secret from its database (it stores `client_secret_hmac`, not plaintext)
2. **Empty Secret Being Sent**: The secret may be corrupted or empty when Boundary attempts to use it
3. **URL/Port Mismatch**: Boundary's internal token endpoint URL may differ from what we tested manually
4. **TLS/Certificate Issues**: If Boundary is using HTTPS internally when we tested with HTTP
5. **go-oidc Library Behavior**: The go-oidc library may have specific requirements for secret handling

## Recommended Solution: Delete and Recreate OIDC Auth Method

Given the diagnostic finding (credentials not being sent), the most reliable fix is to **delete and recreate the OIDC auth method from scratch**:

```bash
# 1. Delete existing OIDC auth method
boundary auth-methods delete -id=amoidc_ZuxikrSxy4

# 2. Regenerate Keycloak client secret
curl -X POST "http://localhost:18080/admin/realms/agent-sandbox/clients/${CLIENT_UUID}/client-secret" \
  -H "Authorization: Bearer $KC_TOKEN"

# 3. Recreate OIDC auth method with fresh secret
boundary auth-methods create oidc \
  -name='keycloak' \
  -scope-id='o_Q27rf0A0wa' \
  -issuer='http://keycloak.hashicorp.lab/realms/agent-sandbox' \
  -client-id='boundary' \
  -client-secret='file:///tmp/client_secret.txt' \
  -signing-algorithm=RS256 \
  -api-url-prefix='https://boundary.hashicorp.lab' \
  -claims-scopes='profile' \
  -claims-scopes='email' \
  -claims-scopes='groups'

# 4. Activate the auth method
boundary auth-methods change-state oidc -id=<new_id> -state=active-public

# 5. Recreate managed groups with new auth method ID
```

**Why This Is Necessary**:
- Boundary stores an encrypted representation of the secret, not the plaintext
- If the encryption context or KMS keys are misaligned, updates may appear to succeed but the stored secret is unusable
- A fresh creation ensures the secret is properly encrypted with current keys

## Current Configuration (After Fix - 2025-12-12)

| Component | ID/Value |
|-----------|----------|
| OIDC Auth Method | `amoidc_IB7qfa5BPS` |
| Organization | `o_Q27rf0A0wa` (DevOps) |
| Project | `p_8R6bKLKbhT` (Agent-Sandbox) |
| Issuer | `http://keycloak.hashicorp.lab/realms/agent-sandbox` |
| api_url_prefix | `https://boundary.hashicorp.lab` |
| Client ID | `boundary` |
| Client Secret HMAC | `2wggp0oNWVB3bi5BbMepFqjv8t1ugxjWBCxwA2axzHs` |
| State | `active-public` |

**Managed Groups**:
| Name | ID | Filter |
|------|-----|--------|
| keycloak-admins | `mgoidc_jcxqeiLD6A` | `"/token/groups" contains "admins"` |
| keycloak-developers | `mgoidc_4JquhrRKbl` | `"/token/groups" contains "developers"` |
| keycloak-readonly | `mgoidc_pgCxIPOj74` | `"/token/groups" contains "readonly"` |

**Verification Tests Passed**:
- ✅ Manual introspection test: `{"active":false}` (credentials work)
- ✅ Token endpoint test: `invalid_code` with `client_auth_method="client-secret"` (credentials authenticated)

## Key Technical Details from Documentation

### Boundary OIDC Behavior
From HashiCorp documentation:
- **Boundary operates as a confidential OIDC client** - requires client secret
- **`client_secret_hmac`** - Boundary stores an HMAC of the secret, not the plaintext (allows verification without storing in plain text)
- **Secret Storage**: Boundary uses its database KMS key to encrypt the client secret before storing; the HMAC is a separate verification hash
- **`api_url_prefix`** - Critical: determines callback URL generation for external access
- **`issuer`** - Must match exactly what Keycloak advertises in OIDC discovery

### Keycloak Client Authentication Methods
From Keycloak documentation:
- **`client_secret_basic`**: Credentials sent in `Authorization: Basic BASE64(client_id:client_secret)` header
- **`client_secret_post`**: Credentials sent as `client_id` and `client_secret` form parameters in POST body
- **Default**: Keycloak accepts both methods unless explicitly restricted

### Critical Insight: External Ingress Access
When users access via external ingress (https://boundary.hashicorp.lab):
1. **Browser redirects to Keycloak** via external URL (https://keycloak.hashicorp.lab)
2. **Keycloak redirects back to Boundary** via callback URL (https://boundary.hashicorp.lab/v1/auth-methods/oidc:authenticate:callback)
3. **Boundary makes server-side token exchange** to Keycloak via internal URL (http://keycloak.hashicorp.lab)

**Important**: The `api_url_prefix` MUST match the external URL users access (https://boundary.hashicorp.lab), but the `issuer` should use the internal URL that Boundary can reach (http://keycloak.hashicorp.lab/realms/agent-sandbox)

## Architecture Overview

### Network Topology with External Ingress

```
┌──────────────────────────────────────────────────────────────────────────────────┐
│                              EXTERNAL (User's Browser)                            │
│                                                                                   │
│  ┌─────────────┐                                                                  │
│  │   Browser   │ ─────────────────────────────────────────────────────────┐      │
│  └──────┬──────┘                                                           │      │
│         │                                                                  │      │
│    1. HTTPS ──► https://boundary.hashicorp.lab (Initial access)            │      │
│    2. HTTPS ──► https://keycloak.hashicorp.lab/realms/agent-sandbox/auth (Redirect)│      │
│    5. HTTPS ──► https://boundary.hashicorp.lab/v1/.../callback (After KC login)    │      │
│                                                                            │      │
└────────┼───────────────────────────────────────────────────────────────────┼──────┘
         │                                                                   │
         ▼                                                                   ▼
┌────────────────────────────────────────────────────────────────────────────────────┐
│                           KUBERNETES CLUSTER (Internal)                             │
│                                                                                     │
│  ┌─────────────────────┐                    ┌─────────────────────────┐            │
│  │   Boundary Ingress  │                    │   Keycloak Ingress      │            │
│  │ (boundary.hashicorp.lab:443)│            │ (keycloak.hashicorp.lab:443)    │            │
│  └──────────┬──────────┘                    └───────────┬─────────────┘            │
│             │                                           │                          │
│             ▼                                           ▼                          │
│  ┌──────────────────────────┐            ┌─────────────────────────────────┐      │
│  │   Boundary Controller    │◄──────────►│         Keycloak                │      │
│  │   (boundary namespace)   │   HTTP     │     (keycloak namespace)        │      │
│  │                          │ Internal   │                                  │      │
│  │ - OIDC Auth Method       │  :8080     │ - agent-sandbox realm           │      │
│  │ - api_url_prefix:        │            │ - boundary client               │      │
│  │   https://boundary.hashicorp.lab │   Step 6:  │ - clientAuthenticatorType:      │      │
│  │ - issuer:                │  Token     │   client-secret                 │      │
│  │   http://keycloak.hashicorp.lab  │  Exchange  │ - groups scope & mapper         │      │
│  │   /realms/agent-sandbox  │            │                                  │      │
│  └──────────────────────────┘            └─────────────────────────────────┘      │
│             │                                                                      │
│             │ hostAliases:                                                         │
│             │   keycloak.hashicorp.lab -> keycloak.keycloak.svc:8080               │
│             │                                                                      │
│  ┌──────────▼──────────────┐                                                       │
│  │   Boundary Worker       │                                                       │
│  └─────────────────────────┘                                                       │
│                                                                                     │
└─────────────────────────────────────────────────────────────────────────────────────┘
```

### URL Configuration Summary

| Component | External URL (Browser) | Internal URL (Pod-to-Pod) |
|-----------|------------------------|---------------------------|
| Boundary API | https://boundary.hashicorp.lab | http://127.0.0.1:9200 |
| Keycloak | https://keycloak.hashicorp.lab | http://keycloak.hashicorp.lab:8080 |
| OIDC Discovery | https://keycloak.hashicorp.lab/realms/agent-sandbox/.well-known/openid-configuration | http://keycloak.hashicorp.lab/realms/agent-sandbox/.well-known/openid-configuration |
| Callback URL | https://boundary.hashicorp.lab/v1/auth-methods/oidc:authenticate:callback | N/A (browser redirect) |

**Critical Configuration Points**:
1. `api_url_prefix` = `https://boundary.hashicorp.lab` (external - for browser redirects)
2. `issuer` = `http://keycloak.hashicorp.lab/realms/agent-sandbox` (internal - for token exchange)
3. Keycloak must advertise the issuer that Boundary will use internally
4. Boundary needs `hostAliases` to resolve `keycloak.hashicorp.lab` to the internal service

## OIDC Authentication Flow

```
1. User visits https://boundary.hashicorp.lab
   │
2. User clicks "Sign in with Keycloak"
   │
3. Boundary redirects to Keycloak:
   │  GET https://keycloak.hashicorp.lab/realms/agent-sandbox/protocol/openid-connect/auth
   │      ?client_id=boundary
   │      &redirect_uri=https://boundary.hashicorp.lab/v1/auth-methods/oidc:authenticate:callback
   │      &response_type=code
   │      &scope=openid+profile+email+groups
   │
4. User authenticates with Keycloak credentials
   │
5. Keycloak redirects back to Boundary with authorization code:
   │  GET https://boundary.hashicorp.lab/v1/auth-methods/oidc:authenticate:callback
   │      ?code=<authorization_code>
   │      &state=<state>
   │
6. Boundary exchanges code for tokens: ◄─── THIS IS WHERE IT FAILS
   │  POST http://keycloak.hashicorp.lab/realms/agent-sandbox/protocol/openid-connect/token
   │      client_id=boundary
   │      client_secret=<MUST MATCH KEYCLOAK>
   │      grant_type=authorization_code
   │      code=<authorization_code>
   │
7. Keycloak returns ID token with claims including groups
   │
8. Boundary validates token, creates account, assigns managed groups
   │
9. User is authenticated with role-based permissions
```

## Implementation Plan

### Phase 0: Nuclear Option - Delete and Recreate (Recommended)

If manual tests pass but Boundary's OIDC flow fails, execute this phase first:

#### Task 0.1: Backup Current Configuration
```bash
# Save current auth method details
OIDC_ID="amoidc_ZuxikrSxy4"
boundary auth-methods read -id=$OIDC_ID -format=json > /tmp/oidc_backup.json

# Save managed groups
boundary managed-groups list -auth-method-id=$OIDC_ID -format=json > /tmp/managed_groups_backup.json

# Note: Roles will reference the old managed group IDs, we'll need to update them
```

#### Task 0.2: Delete Existing OIDC Auth Method
```bash
# This will also delete associated managed groups
boundary auth-methods delete -id=$OIDC_ID
```

#### Task 0.3: Regenerate Keycloak Client Secret
```bash
# Port-forward to Keycloak
kubectl port-forward -n keycloak svc/keycloak 18080:8080 &
PF_PID=$!
sleep 2

# Get admin token
KC_TOKEN=$(curl -s -X POST "http://localhost:18080/realms/master/protocol/openid-connect/token" \
  -d "username=admin&password=admin123!@#&grant_type=password&client_id=admin-cli" | jq -r '.access_token')

# Get client UUID
CLIENT_UUID=$(curl -s -H "Authorization: Bearer $KC_TOKEN" \
  "http://localhost:18080/admin/realms/agent-sandbox/clients?clientId=boundary" | jq -r '.[0].id')

# Regenerate secret
curl -s -X POST "http://localhost:18080/admin/realms/agent-sandbox/clients/${CLIENT_UUID}/client-secret" \
  -H "Authorization: Bearer $KC_TOKEN"

# Get new secret
NEW_SECRET=$(curl -s -H "Authorization: Bearer $KC_TOKEN" \
  "http://localhost:18080/admin/realms/agent-sandbox/clients/${CLIENT_UUID}/client-secret" | jq -r '.value')

echo "New Secret: $NEW_SECRET"
kill $PF_PID
```

#### Task 0.4: Create Fresh OIDC Auth Method
```bash
# Write secret to file (avoid shell escaping)
echo -n "$NEW_SECRET" > /tmp/client_secret.txt
kubectl cp /tmp/client_secret.txt boundary/$CONTROLLER_POD:/tmp/client_secret.txt -c boundary-controller
rm /tmp/client_secret.txt

# Create auth method
kubectl exec -n boundary $CONTROLLER_POD -c boundary-controller -- /bin/ash -c "
  export BOUNDARY_ADDR=http://127.0.0.1:9200
  export BOUNDARY_TOKEN='$AUTH_TOKEN'
  boundary auth-methods create oidc \
    -name='keycloak' \
    -description='Keycloak OIDC Authentication' \
    -scope-id='o_Q27rf0A0wa' \
    -issuer='http://keycloak.hashicorp.lab/realms/agent-sandbox' \
    -client-id='boundary' \
    -client-secret='file:///tmp/client_secret.txt' \
    -signing-algorithm=RS256 \
    -api-url-prefix='https://boundary.hashicorp.lab' \
    -format=json
  rm -f /tmp/client_secret.txt
"
```

#### Task 0.5: Configure and Activate
```bash
# Get new auth method ID
NEW_OIDC_ID=$(boundary auth-methods list -scope-id=o_Q27rf0A0wa -format=json | jq -r '.items[] | select(.type=="oidc") | .id')

# Add claims scopes
boundary auth-methods update oidc -id=$NEW_OIDC_ID \
  -claims-scopes="profile" -claims-scopes="email" -claims-scopes="groups"

# Activate
boundary auth-methods change-state oidc -id=$NEW_OIDC_ID -state=active-public
```

#### Task 0.6: Recreate Managed Groups and Update Roles
Run the configure-oidc-auth.sh script to recreate managed groups, then update existing roles to use the new managed group IDs.

### Phase 1: Prerequisites Verification

#### Task 1.1: Verify Keycloak Deployment
```bash
# Check Keycloak is running
kubectl get pods -n keycloak -l app=keycloak

# Verify keycloak-http service exists (port 80 -> 8080)
kubectl get svc -n keycloak keycloak-http

# Test OIDC discovery endpoint
curl -sk https://keycloak.hashicorp.lab/realms/agent-sandbox/.well-known/openid-configuration | jq '.issuer'
```

**Expected**: Keycloak running, service exists, issuer is `https://keycloak.hashicorp.lab/realms/agent-sandbox`

#### Task 1.2: Verify Boundary Deployment
```bash
# Check Boundary controller is running
kubectl get pods -n boundary -l app=boundary-controller

# Verify ingress is working
curl -sk https://boundary.hashicorp.lab/v1/auth-methods -H "Content-Type: application/json"

# Verify hostAliases for keycloak.hashicorp.lab resolution
kubectl get deployment boundary-controller -n boundary -o jsonpath='{.spec.template.spec.hostAliases}'
```

**Expected**: Controller running, API responds, hostAliases configured for keycloak.hashicorp.lab

### Phase 2: Keycloak Configuration

#### Task 2.1: Verify/Create agent-sandbox Realm
```bash
# Via Keycloak Admin API
curl -sk -X GET "https://keycloak.hashicorp.lab/admin/realms/agent-sandbox" \
  -H "Authorization: Bearer $KC_TOKEN" | jq '.realm'
```

If not exists, run: `./k8s/platform/keycloak/scripts/configure-realm.sh`

#### Task 2.2: Verify Boundary Client Configuration

**Required Client Settings**:
| Setting | Value | Purpose |
|---------|-------|---------|
| clientId | `boundary` | Identifies Boundary to Keycloak |
| protocol | openid-connect | OIDC protocol |
| publicClient | false | Confidential client (uses secret) |
| standardFlowEnabled | true | Authorization code flow |
| directAccessGrantsEnabled | false | Security: disable direct password grant |
| serviceAccountsEnabled | false | Not needed for user auth |

**Required Redirect URIs**:
- `https://boundary.hashicorp.lab/v1/auth-methods/oidc:authenticate:callback`
- `http://127.0.0.1:9200/v1/auth-methods/oidc:authenticate:callback`
- `http://boundary-controller-api.boundary.svc.cluster.local:9200/v1/auth-methods/oidc:authenticate:callback`

#### Task 2.3: Verify Groups Scope and Mapper

**Critical**: Without this, Boundary cannot see group memberships!

```bash
# Check groups scope exists
curl -sk "https://keycloak.hashicorp.lab/admin/realms/agent-sandbox/client-scopes" \
  -H "Authorization: Bearer $KC_TOKEN" | jq '.[] | select(.name=="groups")'

# Check mapper configuration
curl -sk "https://keycloak.hashicorp.lab/admin/realms/agent-sandbox/client-scopes/$(SCOPE_ID)/protocol-mappers/models" \
  -H "Authorization: Bearer $KC_TOKEN" | jq '.'
```

**Required Mapper Settings**:
- Type: `oidc-group-membership-mapper`
- Claim name: `groups`
- Full path: `false`
- Add to ID token: `true`
- Add to access token: `true`
- Add to userinfo: `true`

#### Task 2.4: Verify/Create User Groups and Demo Users

**Groups** (in agent-sandbox realm):
- `admins` → Full Boundary access
- `developers` → Connect to targets
- `readonly` → View only

**Demo Users**:
| Username | Password | Group |
|----------|----------|-------|
| admin | Admin123!@# | admins |
| developer | Dev123!@# | developers |
| readonly | Read123!@# | readonly |

### Phase 3: Secret Synchronization (Critical)

#### Task 3.1: Retrieve Current Keycloak Client Secret

```bash
#!/bin/bash
# get_keycloak_secret.sh

# Port-forward to Keycloak
kubectl port-forward -n keycloak svc/keycloak 18080:8080 &
PF_PID=$!
sleep 3

# Get admin credentials
KC_ADMIN=$(kubectl get secret keycloak-admin -n keycloak -o jsonpath='{.data.KEYCLOAK_ADMIN}' | base64 -d)
KC_PASS=$(kubectl get secret keycloak-admin -n keycloak -o jsonpath='{.data.KEYCLOAK_ADMIN_PASSWORD}' | base64 -d)

# Get admin token
KC_TOKEN=$(curl -s -X POST "http://localhost:18080/realms/master/protocol/openid-connect/token" \
  -d "username=${KC_ADMIN}&password=${KC_PASS}&grant_type=password&client_id=admin-cli" \
  | jq -r '.access_token')

# Get boundary client UUID
CLIENT_UUID=$(curl -s -H "Authorization: Bearer $KC_TOKEN" \
  "http://localhost:18080/admin/realms/agent-sandbox/clients?clientId=boundary" \
  | jq -r '.[0].id')

# Get client secret
CLIENT_SECRET=$(curl -s -H "Authorization: Bearer $KC_TOKEN" \
  "http://localhost:18080/admin/realms/agent-sandbox/clients/${CLIENT_UUID}/client-secret" \
  | jq -r '.value')

echo "Client Secret: $CLIENT_SECRET"

kill $PF_PID
```

#### Task 3.2: Update Boundary OIDC Auth Method with Correct Secret

```bash
#!/bin/bash
# sync_boundary_secret.sh

BOUNDARY_NS="boundary"
OIDC_AUTH_METHOD_ID="amoidc_ZuxikrSxy4"  # Get from Boundary

# Get Boundary admin password
ADMIN_PASS=$(grep "Password:" ./k8s/platform/boundary/scripts/boundary-credentials.txt | awk '{print $2}')

# Get controller pod
CONTROLLER_POD=$(kubectl get pod -l app=boundary-controller -n $BOUNDARY_NS -o jsonpath='{.items[0].metadata.name}')

# Write secret to temp file (avoids shell escaping issues)
echo -n "$CLIENT_SECRET" > /tmp/client_secret.txt
kubectl cp /tmp/client_secret.txt "$BOUNDARY_NS/$CONTROLLER_POD:/tmp/client_secret.txt" -c boundary-controller
rm /tmp/client_secret.txt

# Update auth method
kubectl exec -n $BOUNDARY_NS $CONTROLLER_POD -c boundary-controller -- /bin/ash -c "
  export BOUNDARY_ADDR=http://127.0.0.1:9200
  export BOUNDARY_PASSWORD='$ADMIN_PASS'
  boundary authenticate password -login-name=admin -password=env://BOUNDARY_PASSWORD
  boundary auth-methods update oidc -id=$OIDC_AUTH_METHOD_ID -client-secret='file:///tmp/client_secret.txt'
  rm /tmp/client_secret.txt
"
```

### Phase 4: Boundary OIDC Configuration

#### Task 4.1: Verify/Create OIDC Auth Method

**Required Settings**:
| Setting | Value |
|---------|-------|
| name | keycloak |
| scope_id | DevOps org ID |
| issuer | `http://keycloak.hashicorp.lab/realms/agent-sandbox` |
| client_id | boundary |
| client_secret | (from Keycloak) |
| signing_algorithm | RS256 |
| api_url_prefix | `https://boundary.hashicorp.lab` |
| claims_scopes | profile, email, groups |
| state | active-public |

**Note**: The issuer MUST be HTTP (not HTTPS) because Boundary accesses Keycloak internally via the HTTP service.

#### Task 4.2: Verify/Create Managed Groups

| Group Name | Filter | Purpose |
|------------|--------|---------|
| keycloak-admins | `"/token/groups" contains "admins"` | Full access |
| keycloak-developers | `"/token/groups" contains "developers"` | Connect access |
| keycloak-readonly | `"/token/groups" contains "readonly"` | List access |

#### Task 4.3: Verify/Create Roles with Grants

**Admin Role** (keycloak-admins):
- Grant: `ids=*;type=*;actions=*`

**Developer Role** (keycloak-developers):
- Grant: `ids=*;type=target;actions=read,authorize-session`

**Readonly Role** (keycloak-readonly):
- Grant: `ids=*;type=*;actions=read,list`

### Phase 5: Testing

#### Task 5.1: Test Client Credentials Directly

```bash
# Test from Boundary pod
kubectl exec -n boundary $CONTROLLER_POD -c boundary-controller -- /bin/ash -c "
  # Test introspection endpoint (should return {active:false} for fake token, NOT invalid_client_credentials)
  wget -q -O - --post-data='client_id=boundary&client_secret=$CLIENT_SECRET&token=fake' \
    'http://keycloak.hashicorp.lab/realms/agent-sandbox/protocol/openid-connect/token/introspect'
"
```

**Expected**: `{"active":false}` (proves credentials work)
**Failure**: `{"error":"invalid_client_credentials"}` (secret mismatch)

#### Task 5.2: Test Token Endpoint

```bash
# Test token endpoint with fake code (should fail with invalid_code, NOT invalid_client_credentials)
kubectl exec -n boundary $CONTROLLER_POD -c boundary-controller -- /bin/ash -c "
  wget -q -O - --post-data='client_id=boundary&client_secret=$CLIENT_SECRET&grant_type=authorization_code&code=fake&redirect_uri=https://boundary.hashicorp.lab/v1/auth-methods/oidc:authenticate:callback' \
    'http://keycloak.hashicorp.lab/realms/agent-sandbox/protocol/openid-connect/token'
"
```

**Expected**: `{"error":"invalid_code"}` with `client_auth_method="client-secret"` in logs
**Failure**: `{"error":"invalid_client_credentials"}`

#### Task 5.3: End-to-End OIDC Login Test

```bash
# Monitor Keycloak logs
kubectl logs -f -n keycloak deployment/keycloak &

# Attempt OIDC login
open https://boundary.hashicorp.lab
# Click "Sign in with Keycloak"
# Login as: developer / Dev123!@#
```

**Expected**: Successful login, user assigned to keycloak-developers group
**Verify**: Check Boundary accounts for OIDC-created account

#### Task 5.4: Verify Group Membership and Permissions

```bash
# After successful OIDC login, check session permissions
boundary sessions list -scope-id=<project_id>
boundary targets list -scope-id=<project_id>
```

### Phase 6: Script Updates

#### Task 6.1: Fix configure-oidc-auth.sh

Update to use `file://` syntax instead of `env://` for client secret passing (prevents shell escaping issues).

**Location**: `k8s/platform/boundary/scripts/configure-oidc-auth.sh`

**Changes**:
- Lines 280-290: Use kubectl cp and file:// for secret passing
- Lines 370-410: Same changes for create section

#### Task 6.2: Fix configure-realm.sh

Option A: Remove hardcoded secret, let Keycloak auto-generate
Option B: Store generated secret in Kubernetes secret for synchronization

**Recommendation**: Option A - Let Keycloak generate the secret and have Boundary's script fetch it dynamically.

#### Task 6.3: Create Unified Sync Script

Create a new script `sync-oidc-secrets.sh` that:
1. Retrieves current secret from Keycloak
2. Updates Boundary auth method
3. Verifies synchronization
4. Runs test cases

### Phase 7: Validation Checklist

| # | Check | Command | Expected |
|---|-------|---------|----------|
| 1 | Keycloak realm exists | `curl .../admin/realms/agent-sandbox` | 200 OK |
| 2 | Boundary client exists | `curl .../clients?clientId=boundary` | Client object |
| 3 | Groups scope configured | `curl .../client-scopes` | groups scope with mapper |
| 4 | Demo users exist | `curl .../users` | 3 users |
| 5 | Boundary OIDC auth method | `boundary auth-methods list` | keycloak method |
| 6 | Auth method state | Check attributes.state | active-public |
| 7 | Managed groups exist | `boundary managed-groups list` | 3 groups |
| 8 | Roles with grants | `boundary roles list` | 3 roles |
| 9 | Client credentials test | Introspection call | active:false |
| 10 | Token endpoint test | Token call with fake code | invalid_code (not invalid_client_credentials) |
| 11 | End-to-end login | Browser OIDC flow | Successful authentication |

## Troubleshooting Guide

### Error: `invalid_client_credentials`

**Cause**: Client secret mismatch OR secret not being transmitted

**Diagnostic Steps**:

1. **Check Keycloak Logs for `client_auth_method` field**:
   ```bash
   kubectl logs -n keycloak deployment/keycloak --tail=50 | grep -E "CODE_TO_TOKEN|client_auth"
   ```
   - If you see `client_auth_method="client-secret"` → Credentials were sent (secret mismatch)
   - If you see NO `client_auth_method` field → Credentials not being transmitted (encryption/storage issue)

2. **Manual Test from Boundary Pod**:
   ```bash
   # Get current secret from Keycloak
   SECRET="<get_from_keycloak_api>"

   # Test from Boundary pod
   kubectl exec -n boundary <pod> -c boundary-controller -- wget -q -O - \
     --post-data="client_id=boundary&client_secret=$SECRET&token=fake" \
     'http://keycloak.hashicorp.lab/realms/agent-sandbox/protocol/openid-connect/token/introspect'
   ```
   - If returns `{"active":false}` → Manual test passes (proves network + credentials work)
   - If returns error → Network or credential issue

3. **Compare Manual vs Boundary Library**:
   - If manual test passes but Boundary fails → **Delete and recreate OIDC auth method**
   - If manual test also fails → Debug network/secret synchronization

**Fix Options**:

**Option A: Update Secret (if `client_auth_method` is present in logs)**:
```bash
# Get current Keycloak secret using Phase 3 Task 3.1
# Update Boundary using Phase 3 Task 3.2
# Restart controller
kubectl rollout restart deployment/boundary-controller -n boundary
```

**Option B: Delete and Recreate (if `client_auth_method` is absent)**:
```bash
# See "Recommended Solution" section above
# This fixes encryption context issues
```

### Error: `invalid_redirect_uri`

**Cause**: Redirect URI not registered in Keycloak client

**Fix**: Add missing redirect URI to Keycloak client configuration

### Error: `Invalid scopes: groups`

**Cause**: Groups scope not configured in Keycloak or not assigned to client

**Fix**:
1. Create groups client scope with oidc-group-membership-mapper
2. Assign scope to boundary client as optional scope

### Error: Connection timeout to keycloak.hashicorp.lab

**Cause**: Boundary cannot reach Keycloak internally

**Fix**:
1. Verify keycloak-http service exists (port 80 -> 8080)
2. Verify hostAliases in Boundary controller deployment
3. Test connectivity from Boundary pod

### Error: `issuer did not match`

**Cause**: Issuer URL mismatch between Boundary config and Keycloak's advertised issuer

**Fix**: Ensure Boundary uses `http://keycloak.hashicorp.lab/realms/agent-sandbox` (HTTP, not HTTPS)

## Files Modified in This Plan

| File | Changes |
|------|---------|
| `k8s/platform/boundary/scripts/configure-oidc-auth.sh` | Use file:// syntax for secrets |
| `k8s/platform/keycloak/scripts/configure-realm.sh` | Remove hardcoded secret |
| `k8s/platform/boundary/AGENTS.md` | Update troubleshooting guide |
| `k8s/platform/keycloak/AGENTS.md` | Add OIDC configuration notes |

## Success Criteria

1. **Credential Test Passes**: Token introspection returns `{"active":false}` (not invalid_client_credentials)
2. **Token Exchange Works**: Token endpoint returns `invalid_code` for fake codes (proves client auth works)
3. **End-to-End Login Succeeds**: User can login via OIDC and access Boundary
4. **Group Membership Works**: Users are assigned to correct managed groups based on Keycloak groups
5. **RBAC Enforced**: Users have correct permissions based on group membership

## Execution Order

### Recommended Path (if manual tests pass but Boundary fails):

```
Phase 0: Nuclear Option - Delete and Recreate (20 min) ← START HERE
    ├── Task 0.1: Backup current config
    ├── Task 0.2: Delete existing OIDC auth method
    ├── Task 0.3: Regenerate Keycloak client secret
    ├── Task 0.4: Create fresh OIDC auth method
    ├── Task 0.5: Configure and activate
    └── Task 0.6: Recreate managed groups

Phase 5: Testing (10 min)
    ├── Task 5.1: Test credentials (should now pass)
    ├── Task 5.2: Test token endpoint
    ├── Task 5.3: E2E login test
    └── Task 5.4: Verify permissions

Phase 6: Script Updates (30 min)
    ├── Task 6.1: Fix configure-oidc-auth.sh (done)
    ├── Task 6.2: Fix configure-realm.sh (remove hardcoded secrets)
    └── Task 6.3: Create sync script
```

### Alternative Path (for fresh deployments):

```
Phase 1: Prerequisites Verification (15 min)
    ├── Task 1.1: Verify Keycloak
    └── Task 1.2: Verify Boundary

Phase 2: Keycloak Configuration (30 min)
    ├── Task 2.1: Verify realm
    ├── Task 2.2: Verify client
    ├── Task 2.3: Verify groups scope
    └── Task 2.4: Verify users

Phase 3: Secret Synchronization (15 min)
    ├── Task 3.1: Get Keycloak secret
    └── Task 3.2: Update Boundary

Phase 4: Boundary Configuration (20 min)
    ├── Task 4.1: Verify OIDC auth method
    ├── Task 4.2: Verify managed groups
    └── Task 4.3: Verify roles

Phase 5: Testing (20 min)
    ├── Task 5.1: Test credentials
    ├── Task 5.2: Test token endpoint
    ├── Task 5.3: E2E login test
    └── Task 5.4: Verify permissions

Phase 6: Script Updates (30 min)
    ├── Task 6.1: Fix configure-oidc-auth.sh
    ├── Task 6.2: Fix configure-realm.sh
    └── Task 6.3: Create sync script

Phase 7: Validation (15 min)
    └── Run validation checklist
```

## Quick Verification Commands

After implementing fixes, run these commands to verify:

```bash
# 1. Check OIDC auth method exists and is active
kubectl exec -n boundary $CONTROLLER_POD -c boundary-controller -- boundary auth-methods list -scope-id=o_Q27rf0A0wa -format=json | jq '.items[] | select(.type=="oidc") | {id:.id, state:.attributes.state}'

# 2. Manual credential test (should return {"active":false})
SECRET="<current_keycloak_secret>"
kubectl exec -n boundary $CONTROLLER_POD -c boundary-controller -- wget -q -O - \
  --post-data="client_id=boundary&client_secret=$SECRET&token=fake" \
  'http://keycloak.hashicorp.lab/realms/agent-sandbox/protocol/openid-connect/token/introspect'

# 3. Monitor Keycloak logs during test
kubectl logs -f -n keycloak deployment/keycloak --tail=5 | grep -E "CODE_TO_TOKEN|client_auth"

# 4. Browser test
open https://boundary.hashicorp.lab  # Click "Sign in with Keycloak"
```

**Total Estimated Effort**: ~1 hour (recommended path) or ~2.5 hours (full path)
