# Keycloak Module

## Overview

Keycloak is deployed as the Identity Provider (IdP) for OIDC authentication with HashiCorp Boundary.

## Key Scripts

- `scripts/deploy-keycloak.sh` - Deploys Keycloak with PostgreSQL
- `scripts/configure-realm.sh` - Configures the `agent-sandbox` realm, Boundary client, groups, and demo users

## Critical Configuration Details

### HTTPS Issuer URL (KC_HOSTNAME_URL)

**CRITICAL**: Keycloak must be configured with `KC_HOSTNAME_URL=https://keycloak.hashicorp.lab` (NOT `KC_HOSTNAME`) when running behind an ingress with TLS termination.

This ensures Keycloak advertises HTTPS URLs in its OIDC discovery document:
- Authorization endpoint: `https://keycloak.hashicorp.lab/realms/agent-sandbox/protocol/openid-connect/auth`
- Token endpoint: `https://keycloak.hashicorp.lab/realms/agent-sandbox/protocol/openid-connect/token`
- Issuer: `https://keycloak.hashicorp.lab/realms/agent-sandbox`

**Common Issue**: Using `KC_HOSTNAME=keycloak.hashicorp.lab` (without `_URL`) causes Keycloak to advertise `http://` URLs, which breaks browser-based OIDC flows where users access via `https://boundary.hashicorp.lab`.

**Important**: Do NOT set both `KC_HOSTNAME` and `KC_HOSTNAME_URL` - Keycloak will fail to start with error: `You can not set both 'hostname' and 'hostname-url' options`.

The manifest `manifests/04-deployment.yaml` has this configured correctly.

### Redirect URIs

The Boundary OIDC client must have multiple redirect URIs configured for different access methods:

| Access Method | Redirect URI |
|--------------|--------------|
| Internal (cluster) | `http://boundary-controller-api.boundary.svc.cluster.local:9200/v1/auth-methods/oidc:authenticate:callback` |
| External (ingress) | `https://boundary.hashicorp.lab/v1/auth-methods/oidc:authenticate:callback` |
| Port-forward | `http://127.0.0.1:9200/v1/auth-methods/oidc:authenticate:callback` |

**Common Issue**: If only the internal URI is configured, users accessing via `https://boundary.hashicorp.lab` will get `Invalid parameter: redirect_uri` error.

### Groups Client Scope

For Boundary OIDC managed groups to work, Keycloak must have:

1. A `groups` **client scope** (not just user groups)
2. A protocol mapper within that scope using `oidc-group-membership-mapper`
3. The `groups` scope assigned to the `boundary` client as an optional scope

**Common Issue**: Without the groups scope, Boundary OIDC will fail with `Invalid scopes: openid email groups profile`.

The `configure-realm.sh` script creates this automatically (step 6).

### Port Mapping (keycloak-http Service)

Keycloak advertises its OIDC issuer URL without a port (e.g., `http://keycloak.hashicorp.lab/realms/agent-sandbox`), but the Keycloak pod listens on port 8080.

The `deploy-all.sh` script creates a `keycloak-http` service that maps port 80 to 8080:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: keycloak-http
  namespace: keycloak
spec:
  selector:
    app: keycloak
  ports:
    - port: 80
      targetPort: 8080
```

**Common Issue**: Without this service, OIDC token exchange fails with connection timeout to `keycloak.hashicorp.lab:80`.

### Client Secret Synchronization

The Boundary OIDC auth method must use the **same client secret** that Keycloak has configured. The `configure-oidc-auth.sh` script auto-fetches the secret from Keycloak's admin API.

**Common Issue**: If the client secret doesn't match, you'll get `Invalid client or Invalid client credentials` during OIDC callback.

## Admin Credentials

- Username: `admin`
- Password: Retrieved from `keycloak-admin` secret or defaults to `admin123!@#`

**Note**: The Keycloak admin token expires in 60 seconds. Scripts must get fresh tokens before each batch of API calls.

## Demo Users

Created by `configure-realm.sh`:

| User | Email | Password | Group |
|------|-------|----------|-------|
| admin | admin@example.com | Admin123!@# | admins |
| developer | developer@example.com | Dev123!@# | developers |
| readonly | readonly@example.com | Read123!@# | readonly |

## Troubleshooting

### OIDC Authentication Errors

1. **`Invalid parameter: redirect_uri`**
   - Check that all redirect URIs are configured in Keycloak client
   - Verify `webOrigins` includes the access URL

2. **`Invalid scopes: ... groups`**
   - Ensure the `groups` client scope exists
   - Verify it has the `oidc-group-membership-mapper` protocol mapper
   - Confirm it's assigned to the `boundary` client

3. **`Invalid client credentials`**
   - Re-run `configure-oidc-auth.sh` to sync the client secret
   - Or manually update Boundary's auth method with the correct secret

4. **Connection timeout to keycloak.hashicorp.lab**
   - Ensure `keycloak-http` service exists
   - Verify Boundary controller has correct `hostAliases`

### Checking Keycloak Admin API

```bash
# Get admin token (URL-encode special characters in password)
TOKEN=$(curl -s -X POST 'https://keycloak.hashicorp.lab/realms/master/protocol/openid-connect/token' \
  -H 'Content-Type: application/x-www-form-urlencoded' \
  -d 'username=admin' \
  -d 'password=admin123%21%40%23' \
  -d 'grant_type=password' \
  -d 'client_id=admin-cli' \
  --insecure | jq -r '.access_token')

# List client scopes
curl -s 'https://keycloak.hashicorp.lab/admin/realms/agent-sandbox/client-scopes' \
  -H "Authorization: Bearer $TOKEN" --insecure | jq '.[].name'

# Get boundary client config
curl -s 'https://keycloak.hashicorp.lab/admin/realms/agent-sandbox/clients?clientId=boundary' \
  -H "Authorization: Bearer $TOKEN" --insecure | jq '.[0] | {redirectUris, webOrigins}'
```
