# Boundary OIDC Authentication with Keycloak

This guide explains how to configure Boundary to use Keycloak as an OIDC identity provider for authentication.

## Overview

The OIDC integration enables:
- Single Sign-On (SSO) authentication via Keycloak
- Role-based access control using Keycloak groups
- Centralized user management
- Support for multiple authentication methods (password and OIDC)

## Architecture

```
┌──────────────────────────────────────────────────────────────┐
│                    Kubernetes Cluster                         │
│                                                               │
│  ┌─────────────────┐              ┌─────────────────┐        │
│  │    Keycloak     │              │    Boundary     │        │
│  │  (keycloak ns)  │◄────OIDC────►│ (boundary ns)   │        │
│  │                 │              │                 │        │
│  │ - Realm: agent- │              │ - OIDC Auth     │        │
│  │   sandbox       │              │ - Managed Groups│        │
│  │ - Client: bound-│              │ - Roles         │        │
│  │   ary           │              │                 │        │
│  │ - Groups:       │              │                 │        │
│  │   * admins      │◄───maps to──►│ oidc-admins     │        │
│  │   * developers  │◄───maps to──►│ oidc-developers │        │
│  │   * readonly    │◄───maps to──►│ oidc-readonly   │        │
│  └─────────────────┘              └─────────────────┘        │
└──────────────────────────────────────────────────────────────┘
```

## Group Mappings

| Keycloak Group | Boundary Role    | Permissions                                      |
|----------------|------------------|--------------------------------------------------|
| admins         | oidc-admins      | Full access (all operations on all resources)    |
| developers     | oidc-developers  | Connect access (read + authorize-session)        |
| readonly       | oidc-readonly    | List access (read + list on all resources)       |

## Prerequisites

1. Keycloak deployed and running in the cluster
2. Boundary deployed and configured (run `configure-targets.sh` first)
3. Boundary CLI installed (optional, uses kubectl if not available)

## Quick Start

### Step 1: Configure OIDC Authentication

```bash
cd /workspace/k8s/platform/boundary/scripts

# Run the OIDC configuration script
./configure-oidc-auth.sh
```

The script will:
- Detect if Keycloak is running
- Create an OIDC auth method in Boundary
- Create managed groups for Keycloak group mappings
- Create roles with appropriate permissions
- Prompt for the Keycloak client secret

### Step 2: Configure Keycloak Client

In Keycloak, create a new client with these settings:

**Client Configuration:**
- **Realm:** `agent-sandbox`
- **Client ID:** `boundary`
- **Client Protocol:** `openid-connect`
- **Access Type:** `confidential`
- **Standard Flow Enabled:** `ON`
- **Direct Access Grants Enabled:** `OFF`

**Valid Redirect URIs:**
```
https://boundary.hashicorp.lab/v1/auth-methods/oidc:authenticate:callback
http://127.0.0.1:9200/v1/auth-methods/oidc:authenticate:callback
http://localhost:9200/v1/auth-methods/oidc:authenticate:callback
```

**Client Scopes:**
- Ensure the `groups` scope is included in token claims
- Add mappers for user attributes if needed

### Step 3: Create Groups and Users

In Keycloak, create the following groups:

1. **admins** - Full administrator access
2. **developers** - Developer access (can connect to targets)
3. **readonly** - Read-only access (can list resources)

Then create users and assign them to the appropriate groups.

### Step 4: Test the Configuration

```bash
# Run the test script to verify OIDC setup
./test-oidc-auth.sh
```

The test script validates:
- OIDC auth method exists and is configured correctly
- Managed groups are created with proper filters
- Roles are assigned correct permissions
- Keycloak is reachable from Boundary
- OIDC discovery endpoint is accessible

### Step 5: Authenticate with OIDC

```bash
# Set Boundary address (via ingress)
export BOUNDARY_ADDR=https://boundary.hashicorp.lab
export BOUNDARY_TLS_INSECURE=true

# Authenticate using OIDC (browser will open)
boundary authenticate oidc -auth-method-id=<auth-method-id>

# Find auth-method-id from the output of configure-oidc-auth.sh
# or from: cat /workspace/k8s/platform/boundary/scripts/boundary-oidc-config.txt
```

## Configuration Details

### OIDC Settings

- **Keycloak URL:** `https://keycloak.hashicorp.lab`
- **Realm:** `agent-sandbox`
- **Client ID:** `boundary`
- **Issuer:** `https://keycloak.hashicorp.lab/realms/agent-sandbox`
- **Signing Algorithm:** RS256

### Managed Group Filters

The managed groups use filters to map Keycloak groups to Boundary:

```hcl
# Admins group
"/token/groups" contains "admins"

# Developers group
"/token/groups" contains "developers"

# Readonly group
"/token/groups" contains "readonly"
```

### Role Grants

**oidc-admins:**
```
ids=*;type=*;actions=*
```

**oidc-developers:**
```
ids=*;type=target;actions=read,authorize-session
```

**oidc-readonly:**
```
ids=*;type=*;actions=read,list
```

## Files Created/Modified

### Created Files

1. **`/workspace/k8s/platform/boundary/scripts/configure-oidc-auth.sh`**
   - Main script to configure OIDC auth method
   - Creates managed groups and roles
   - Prompts for Keycloak client secret

2. **`/workspace/k8s/platform/boundary/scripts/test-oidc-auth.sh`**
   - Validates OIDC configuration
   - Tests connectivity to Keycloak
   - Verifies managed groups and roles

3. **`/workspace/k8s/platform/boundary/scripts/boundary-oidc-config.txt`** (generated)
   - Contains OIDC configuration details
   - Auth method ID
   - Managed group IDs
   - Usage instructions

### Modified Files

1. **`/workspace/k8s/platform/boundary/scripts/configure-targets.sh`**
   - Added detection of Keycloak
   - Provides hint to run configure-oidc-auth.sh if Keycloak is available

2. **`/workspace/k8s/scripts/healthcheck.sh`**
   - Added OIDC auth method verification
   - Checks managed groups are configured
   - Validates expected group count

## Troubleshooting

### OIDC Auth Method Not Created

**Problem:** `configure-oidc-auth.sh` fails to create OIDC auth method

**Solutions:**
1. Verify Boundary is running: `kubectl get pods -n boundary`
2. Check Keycloak is accessible: `kubectl get pods -n keycloak`
3. Ensure you have the Keycloak client secret
4. Verify the DevOps organization exists (run `configure-targets.sh` first)

### Authentication Fails

**Problem:** Browser authentication redirects fail or timeout

**Solutions:**
1. Verify port-forward is running: `kubectl port-forward -n boundary svc/boundary-controller-api 9200:9200`
2. Check redirect URIs in Keycloak client match exactly
3. Ensure Keycloak groups exist and users are assigned
4. Verify OIDC discovery endpoint is accessible: run `test-oidc-auth.sh`

### Groups Not Mapped

**Problem:** User authenticates but has no access to resources

**Solutions:**
1. Verify user is assigned to groups in Keycloak
2. Check groups claim is included in token (configure client scopes)
3. Verify managed group filters match Keycloak group names exactly
4. Check role principals include the managed groups: `boundary roles read -id=<role-id>`

### Connectivity Issues

**Problem:** Boundary cannot reach Keycloak

**Solutions:**
1. Verify Keycloak service exists: `kubectl get svc -n keycloak`
2. Test connectivity from Boundary pod:
   ```bash
   kubectl exec -n boundary <controller-pod> -- \
     curl http://keycloak.keycloak.svc.cluster.local:8080
   ```
3. Check network policies allow traffic between namespaces
4. Verify Keycloak realm exists and is active

## Advanced Configuration

### Using Custom Keycloak Namespace

```bash
./configure-oidc-auth.sh boundary custom-keycloak-ns
```

### Multiple OIDC Providers

Boundary supports multiple auth methods. To add a second OIDC provider:

1. Modify `configure-oidc-auth.sh` to use a different auth method name
2. Update the issuer and client ID
3. Create separate managed groups with different filters

### Custom Group Mappings

To add custom group mappings, edit the managed group filters:

```bash
boundary managed-groups create oidc \
  -name="custom-group" \
  -auth-method-id=<auth-method-id> \
  -filter='"/token/groups" contains "custom"'
```

## Security Considerations

1. **Client Secret Storage:** Store Keycloak client secret securely (consider using Vault)
2. **TLS/HTTPS:** In production, use HTTPS for all communication
3. **Token Validation:** Boundary validates tokens using Keycloak's public keys
4. **Group Claims:** Ensure groups claim is not manipulatable by users
5. **Session Timeout:** Configure appropriate session timeouts in Boundary
6. **Audit Logging:** Enable audit logging to track OIDC authentications

## Additional Resources

- [Boundary OIDC Documentation](https://developer.hashicorp.com/boundary/docs/configuration/identity-providers/oidc)
- [Keycloak OIDC Configuration](https://www.keycloak.org/docs/latest/server_admin/#_oidc)
- [Boundary Managed Groups](https://developer.hashicorp.com/boundary/docs/concepts/domain-model/managed-groups)
- [Boundary Roles and Permissions](https://developer.hashicorp.com/boundary/docs/concepts/security/permissions)
