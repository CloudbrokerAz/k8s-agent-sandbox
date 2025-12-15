# Boundary OIDC Integration with Keycloak

Complete guide for integrating Keycloak with HashiCorp Boundary for OIDC authentication.

## Prerequisites

1. Keycloak deployed and configured (see QUICKSTART.md)
2. Boundary cluster running
3. Boundary admin access
4. Port-forwarding active for both services

## Architecture

```
┌──────────────┐         OIDC Flow        ┌──────────────┐
│              │◄──────────────────────────│              │
│   Boundary   │                           │   Keycloak   │
│              │──────────────────────────►│              │
└──────────────┘   Authentication         └──────────────┘
                   Authorization

User Login Flow:
1. User → Boundary → Redirect to Keycloak
2. User authenticates with Keycloak
3. Keycloak → ID Token → Boundary
4. Boundary validates token and creates session
```

## Configuration Steps

### 1. Set Environment Variables

```bash
# Boundary configuration
export BOUNDARY_ADDR=https://boundary.hashicorp.lab
export BOUNDARY_ADMIN_USER=admin
export BOUNDARY_ADMIN_PASSWORD=password

# Keycloak configuration (from configure-realm.sh output)
export KEYCLOAK_URL=https://keycloak.hashicorp.lab
export KEYCLOAK_REALM=agent-sandbox
export KEYCLOAK_CLIENT_ID=boundary
export KEYCLOAK_CLIENT_SECRET=boundary-client-secret-change-me
```

### 2. Authenticate to Boundary as Admin

```bash
# Authenticate with initial admin credentials
boundary authenticate password \
  -auth-method-id ampw_<your-initial-auth-method-id> \
  -login-name $BOUNDARY_ADMIN_USER \
  -password env://BOUNDARY_ADMIN_PASSWORD
```

### 3. Create OIDC Auth Method

```bash
# Get your global scope or org scope ID
SCOPE_ID=$(boundary scopes list -format json | jq -r '.items[] | select(.type=="global") | .id')

# Create the OIDC auth method
boundary auth-methods create oidc \
  -scope-id $SCOPE_ID \
  -name "keycloak-oidc" \
  -description "Keycloak OIDC authentication for Agent Sandbox Platform" \
  -issuer "https://keycloak.hashicorp.lab/realms/${KEYCLOAK_REALM}" \
  -client-id "${KEYCLOAK_CLIENT_ID}" \
  -client-secret env://KEYCLOAK_CLIENT_SECRET \
  -signing-algorithm "RS256" \
  -api-url-prefix "https://boundary.hashicorp.lab" \
  -max-age 0 \
  -format json | tee oidc-auth-method.json

# Save the auth method ID
export AUTH_METHOD_ID=$(cat oidc-auth-method.json | jq -r '.item.id')
echo "OIDC Auth Method ID: $AUTH_METHOD_ID"
```

### 4. Configure OIDC Claims and Scopes

```bash
# Add standard OIDC scopes
boundary auth-methods update oidc \
  -id $AUTH_METHOD_ID \
  -allowed-audience "${KEYCLOAK_CLIENT_ID}" \
  -claims-scopes "openid" \
  -claims-scopes "profile" \
  -claims-scopes "email"

# Configure account claim keys
boundary auth-methods update oidc \
  -id $AUTH_METHOD_ID \
  -account-claim-maps "oid=sub" \
  -account-claim-maps "email=email"
```

### 5. Create Managed Groups (Map Keycloak Groups)

```bash
# Create managed group for Keycloak 'admins' group
# Note: Use "/token/groups" for OIDC token claims, NOT "/resource/groups"
boundary managed-groups create oidc \
  -auth-method-id $AUTH_METHOD_ID \
  -name "keycloak-admins" \
  -description "Keycloak administrators" \
  -filter '"/token/groups" contains "admins"' \
  -format json | tee managed-group-admins.json

export ADMIN_GROUP_ID=$(cat managed-group-admins.json | jq -r '.item.id')

# Create managed group for Keycloak 'developers' group
boundary managed-groups create oidc \
  -auth-method-id $AUTH_METHOD_ID \
  -name "keycloak-developers" \
  -description "Keycloak developers" \
  -filter '"/token/groups" contains "developers"' \
  -format json | tee managed-group-developers.json

export DEV_GROUP_ID=$(cat managed-group-developers.json | jq -r '.item.id')

# Create managed group for Keycloak 'readonly' group
boundary managed-groups create oidc \
  -auth-method-id $AUTH_METHOD_ID \
  -name "keycloak-readonly" \
  -description "Keycloak read-only users" \
  -filter '"/token/groups" contains "readonly"' \
  -format json | tee managed-group-readonly.json

export READONLY_GROUP_ID=$(cat managed-group-readonly.json | jq -r '.item.id')
```

### 6. Assign Roles to Managed Groups

```bash
# Get the org scope (adjust as needed)
ORG_SCOPE_ID=$(boundary scopes list -format json | jq -r '.items[] | select(.type=="org") | .id' | head -1)

# Create or get admin role
boundary roles create \
  -scope-id $ORG_SCOPE_ID \
  -name "keycloak-admin-role" \
  -description "Administrator role for Keycloak admins" \
  -grant-scope-id $ORG_SCOPE_ID \
  -principal-id $ADMIN_GROUP_ID \
  -grant-string "id=*;type=*;actions=*"

# Create or get developer role
boundary roles create \
  -scope-id $ORG_SCOPE_ID \
  -name "keycloak-developer-role" \
  -description "Developer role for Keycloak developers" \
  -grant-scope-id $ORG_SCOPE_ID \
  -principal-id $DEV_GROUP_ID \
  -grant-string "id=*;type=target;actions=read,authorize-session" \
  -grant-string "id=*;type=session;actions=read,cancel,list"

# Create or get readonly role
boundary roles create \
  -scope-id $ORG_SCOPE_ID \
  -name "keycloak-readonly-role" \
  -description "Read-only role for Keycloak users" \
  -grant-scope-id $ORG_SCOPE_ID \
  -principal-id $READONLY_GROUP_ID \
  -grant-string "id=*;type=*;actions=read,list"
```

## Testing Authentication

### Test 1: Authenticate as Admin User

```bash
# Authenticate with admin@example.com
boundary authenticate oidc \
  -auth-method-id $AUTH_METHOD_ID

# This will:
# 1. Open browser to Keycloak login
# 2. Enter: admin@example.com / Admin123!@#
# 3. Redirect back to Boundary with token
# 4. Display authentication token

# Verify you're authenticated
boundary accounts list -auth-method-id $AUTH_METHOD_ID
```

### Test 2: Authenticate as Developer User

```bash
# Clear current token
unset BOUNDARY_TOKEN

# Authenticate with developer@example.com
boundary authenticate oidc \
  -auth-method-id $AUTH_METHOD_ID

# Login with: developer@example.com / Dev123!@#
```

### Test 3: Verify Managed Group Membership

```bash
# List managed group members
boundary managed-groups read -id $ADMIN_GROUP_ID
boundary managed-groups read -id $DEV_GROUP_ID
boundary managed-groups read -id $READONLY_GROUP_ID
```

## Keycloak User Attributes for Boundary

### Standard Claims Mapping

| Keycloak Claim | Boundary Account Field | Description |
|----------------|----------------------|-------------|
| sub | Account ID | Unique user identifier |
| email | Email | User email address |
| name | Full Name | User's full name |
| preferred_username | Username | Preferred username |
| groups | Managed Groups | Group memberships |

### Custom Attributes (Optional)

Add custom attributes in Keycloak:

1. Go to Keycloak Admin Console
2. Select `agent-sandbox` realm
3. Go to **Clients** → **boundary**
4. Click **Client Scopes** tab
5. Add mappers for custom claims

Example custom mapper:
```
Mapper Type: User Attribute
User Attribute: department
Token Claim Name: department
Claim JSON Type: String
Add to ID token: ON
Add to access token: ON
Add to userinfo: ON
```

## Advanced Configuration

### Enable MFA in Keycloak

```bash
# In Keycloak Admin Console:
# 1. Realm Settings → Security Defenses
# 2. Click "OTP Policy" tab
# 3. Configure OTP settings
# 4. Authentication → Required Actions
# 5. Enable "Configure OTP"
```

### Session Management

```bash
# Update session timeouts in Boundary
boundary auth-methods update oidc \
  -id $AUTH_METHOD_ID \
  -max-age 3600  # 1 hour

# Keycloak token lifespan (in Keycloak Admin):
# Realm Settings → Tokens → Access Token Lifespan
```

### Callback URL Configuration

If Boundary is behind a proxy or load balancer:

```bash
# Update Keycloak redirect URIs
# In Keycloak Admin Console:
# Clients → boundary → Settings
# Add to Valid Redirect URIs:
# - https://boundary.hashicorp.lab/v1/auth-methods/oidc:authenticate:callback
# - http://localhost:9200/v1/auth-methods/oidc:authenticate:callback
```

## Troubleshooting

### Issue: "Invalid redirect URI"

**Solution:**
```bash
# Check Keycloak client redirect URIs
curl -H "Authorization: Bearer $ACCESS_TOKEN" \
  ${KEYCLOAK_URL}/admin/realms/${KEYCLOAK_REALM}/clients?clientId=boundary

# Update redirect URIs via configure-realm.sh or Keycloak Admin Console
```

### Issue: "Invalid issuer"

**Solution:**
```bash
# Verify issuer URL matches exactly
boundary auth-methods read -id $AUTH_METHOD_ID

# Should match Keycloak issuer (check for http vs https, trailing slash)
curl ${KEYCLOAK_URL}/realms/${KEYCLOAK_REALM}/.well-known/openid-configuration | jq -r '.issuer'
```

### Issue: "Groups not mapping correctly"

**Solution:**
```bash
# Update managed group filter - use "/token/groups" for OIDC claims
boundary managed-groups update oidc \
  -id $ADMIN_GROUP_ID \
  -filter '"/token/groups" contains "admins"'

# Verify user groups in Keycloak token
# Decode JWT token at https://jwt.io
# The groups claim should show: ["admins", "developers", ...]
```

### Issue: "Cannot connect to Keycloak from Boundary"

**Solution:**
```bash
# If Boundary is in Kubernetes, use ingress
# Update issuer to use external URL:
boundary auth-methods update oidc \
  -id $AUTH_METHOD_ID \
  -issuer "https://keycloak.hashicorp.lab/realms/agent-sandbox"

# Verify connectivity from Boundary pod
kubectl exec -n boundary <boundary-pod> -- curl -k https://keycloak.hashicorp.lab/health
```

## Security Best Practices

### 1. Use HTTPS in Production

```bash
# Enable TLS in Keycloak
# Update issuer to use https://
boundary auth-methods update oidc \
  -id $AUTH_METHOD_ID \
  -issuer "https://keycloak.hashicorp.lab/realms/agent-sandbox"
```

### 2. Rotate Client Secrets

```bash
# Generate new secret in Keycloak Admin Console
# Update Boundary auth method
boundary auth-methods update oidc \
  -id $AUTH_METHOD_ID \
  -client-secret "new-secure-secret"
```

### 3. Enable Audit Logging

```bash
# Keycloak events
# Realm Settings → Events → Event Listeners
# Enable: login, login_error, logout, register, etc.

# Boundary audit events are automatic
# Check logs: boundary events list
```

### 4. Implement Network Policies

Apply Kubernetes NetworkPolicy to restrict Keycloak access:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: keycloak-ingress
  namespace: keycloak
spec:
  podSelector:
    matchLabels:
      app: keycloak
  policyTypes:
  - Ingress
  ingress:
  - from:
    - namespaceSelector:
        matchLabels:
          name: boundary
    ports:
    - protocol: TCP
      port: 8080
```

## Complete Example Script

See `/workspace/k8s/platform/keycloak/scripts/boundary-oidc-setup.sh` for a complete automation script.

## References

- [Boundary OIDC Auth Methods](https://developer.hashicorp.com/boundary/docs/concepts/domain-model/auth-methods#oidc-auth-method-attributes)
- [Keycloak OIDC Clients](https://www.keycloak.org/docs/latest/server_admin/#_oidc_clients)
- [OpenID Connect Flows](https://openid.net/specs/openid-connect-core-1_0.html)

## Next Steps

1. Test authentication with all demo users
2. Add real users and groups in Keycloak
3. Configure custom claims and attributes
4. Set up MFA for sensitive accounts
5. Implement session management policies
6. Enable audit logging and monitoring
7. Plan for disaster recovery and backups

---

For issues, check Keycloak logs:
```bash
kubectl logs -n keycloak -l app=keycloak -f
```
