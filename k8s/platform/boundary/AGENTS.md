# Boundary Module

## Overview

HashiCorp Boundary provides secure access to infrastructure targets (SSH, databases, etc.) with identity-based authorization.

## Key Scripts

- `scripts/deploy-boundary.sh` - Deploys Boundary controller and workers
- `scripts/configure-oidc-auth.sh` - Configures OIDC authentication with Keycloak
- `scripts/create-boundary-secrets.sh` - Creates TLS secrets

## OIDC Integration with Keycloak

### Prerequisites

1. Keycloak must be deployed and running
2. `keycloak-http` service must exist (port 80 -> 8080 mapping)
3. Boundary controller must have `hostAliases` for `keycloak.local`

### Configuration Flow

1. `configure-oidc-auth.sh` auto-fetches the client secret from Keycloak
2. Creates OIDC auth method in the DevOps org scope
3. Sets `api-url-prefix` to `https://boundary.local` for callback URL generation
4. Activates the auth method to `active-public` state
5. Creates managed groups that map to Keycloak groups

### Key Configuration Parameters

| Parameter | Value | Purpose |
|-----------|-------|---------|
| issuer | `http://keycloak.local/realms/agent-sandbox` | OIDC discovery URL |
| client_id | `boundary` | Keycloak client ID |
| api_url_prefix | `https://boundary.local` | Determines callback URL |
| signing_algorithm | RS256 | JWT signature verification |
| claims_scopes | profile, email, groups | Requested OIDC scopes |

### Managed Groups

| Keycloak Group | Boundary Managed Group | Access Level |
|----------------|----------------------|--------------|
| admins | keycloak-admins | Full access |
| developers | keycloak-developers | Connect access |
| readonly | keycloak-readonly | List access |

## Critical Configuration Details

### hostAliases Configuration

The Boundary controller pod needs `hostAliases` to resolve both Keycloak and itself:

```yaml
hostAliases:
  - ip: "<keycloak-http ClusterIP>"
    hostnames: ["keycloak.local"]
  - ip: "<boundary-controller-api ClusterIP>"
    hostnames: ["boundary.local"]
```

**Common Issue**: Without correct hostAliases, OIDC discovery/token exchange fails with connection errors.

### Recovery Key for Admin Operations

Many Boundary admin operations require the recovery key. It's stored in the controller config:

```bash
kubectl exec -n boundary deployment/boundary-controller -c boundary-controller -- \
  cat /boundary/config/controller.hcl | grep -A5 recovery
```

### Auth Method States

- `inactive` - Cannot be used for authentication
- `active-private` - Can authenticate but not discoverable
- `active-public` - Fully active and discoverable

The `configure-oidc-auth.sh` script sets the auth method to `active-public`.

## Admin Credentials

Stored in `scripts/boundary-credentials.txt`:

- Auth Method ID: `ampw_iEqKXUrh2Q` (password auth)
- Login: `admin`
- Password: Generated during initialization

## Troubleshooting

### OIDC Errors

1. **`Invalid client credentials`**
   - Client secret mismatch between Boundary and Keycloak
   - Re-run `configure-oidc-auth.sh` to sync

2. **`issuer did not match`**
   - Issuer URL in Boundary doesn't match Keycloak's advertised URL
   - Must use `http://keycloak.local/realms/agent-sandbox` (what Keycloak advertises)

3. **`unable to exchange auth code`**
   - Usually a client secret mismatch
   - Update the auth method with correct secret from Keycloak

4. **Connection timeout during callback**
   - Boundary can't reach Keycloak
   - Check hostAliases and keycloak-http service

### Updating OIDC Client Secret

```bash
kubectl exec -n boundary deployment/boundary-controller -c boundary-controller -- /bin/ash -c '
export BOUNDARY_ADDR=http://127.0.0.1:9200
export KEYCLOAK_CLIENT_SECRET="<new-secret>"
cat > /tmp/recovery.hcl << EOF
kms "aead" {
  purpose = "recovery"
  aead_type = "aes-gcm"
  key = "<recovery-key>"
  key_id = "global_recovery"
}
EOF
boundary auth-methods update oidc \
    -id=<auth-method-id> \
    -client-secret=env://KEYCLOAK_CLIENT_SECRET \
    -recovery-config=/tmp/recovery.hcl
'
```

### Checking Auth Method Configuration

```bash
export BOUNDARY_ADDR=https://boundary.local
export BOUNDARY_TLS_INSECURE=true
boundary auth-methods list -scope-id=global -recursive -format=json | jq '.items[] | select(.type=="oidc")'
```

## SSH Target Access

After OIDC authentication, users can connect to targets based on their group membership:

```bash
export BOUNDARY_ADDR=https://boundary.local
export BOUNDARY_TLS_INSECURE=true

# Authenticate via OIDC
boundary authenticate oidc -auth-method-id=<oidc-auth-method-id>

# Connect to target
boundary connect ssh -target-id=<target-id>
```
