# Keycloak Identity Provider for Boundary

This directory contains Kubernetes manifests and scripts to deploy Keycloak as an Identity Provider (IDP) for HashiCorp Boundary OIDC authentication in the Agent Sandbox Platform.

## Overview

Keycloak provides:
- **OIDC/OAuth2 authentication** for Boundary
- **User and group management** with demo accounts
- **PostgreSQL persistence** for production-ready deployment
- **Development mode** configuration for easy testing

## Architecture

```
┌─────────────────────────────────────────┐
│         Keycloak Namespace              │
│                                         │
│  ┌──────────────┐     ┌──────────────┐ │
│  │   Keycloak   │────▶│  PostgreSQL  │ │
│  │  (Port 8080) │     │  (Port 5432) │ │
│  └──────────────┘     └──────────────┘ │
│         │                     │         │
│    ClusterIP                 PVC        │
│    Service                  (5Gi)       │
└─────────────────────────────────────────┘
         │
         ▼
    Boundary OIDC
  Auth Method Integration
```

## Quick Start

### 1. Deploy Keycloak

```bash
# Deploy Keycloak with PostgreSQL
./scripts/deploy-keycloak.sh

# Expected output:
# - Namespace: keycloak
# - PostgreSQL pod running
# - Keycloak pod running
# - Services created
```

### 2. Access Keycloak Admin Console

```bash
# Port-forward to access Keycloak
kubectl port-forward -n keycloak svc/keycloak 8080:8080

# Open browser to: http://localhost:8080
# Login with:
#   Username: admin
#   Password: admin123!@#
```

### 3. Configure Agent Sandbox Realm

```bash
# Run realm configuration script
# (Ensure port-forward is active first)
./scripts/configure-realm.sh

# This creates:
# - Realm: agent-sandbox
# - OIDC Client: boundary
# - Demo users and groups
```

## Demo User Credentials

After running `configure-realm.sh`, the following demo users are available:

| Email | Password | Group | Description |
|-------|----------|-------|-------------|
| admin@example.com | Admin123!@# | admins | Full administrative access |
| developer@example.com | Dev123!@# | developers | Developer access |
| readonly@example.com | Read123!@# | readonly | Read-only access |

## OIDC Configuration for Boundary

Use these values when configuring Boundary OIDC auth method:

```bash
# OIDC Issuer
https://keycloak.hashicorp.lab/realms/agent-sandbox

# Client Credentials
Client ID: boundary
Client Secret: boundary-client-secret-change-me

# OIDC Endpoints
Authorization: https://keycloak.hashicorp.lab/realms/agent-sandbox/protocol/openid-connect/auth
Token: https://keycloak.hashicorp.lab/realms/agent-sandbox/protocol/openid-connect/token
UserInfo: https://keycloak.hashicorp.lab/realms/agent-sandbox/protocol/openid-connect/userinfo
JWKS: https://keycloak.hashicorp.lab/realms/agent-sandbox/protocol/openid-connect/certs
```

## Boundary OIDC Integration

### Step 1: Create OIDC Auth Method in Boundary

```bash
# Set Boundary address
export BOUNDARY_ADDR=http://localhost:9200

# Authenticate as admin
boundary authenticate password \
  -auth-method-id ampw_1234567890 \
  -login-name admin

# Create OIDC auth method
boundary auth-methods create oidc \
  -name "Keycloak SSO" \
  -description "Keycloak OIDC authentication" \
  -issuer "https://keycloak.hashicorp.lab/realms/agent-sandbox" \
  -client-id "boundary" \
  -client-secret "boundary-client-secret-change-me" \
  -signing-algorithm "RS256" \
  -api-url-prefix "https://boundary.hashicorp.lab" \
  -max-age 0
```

### Step 2: Configure Managed Groups (Optional)

Map Keycloak groups to Boundary managed groups:

```bash
# Get auth method ID from previous command
AUTH_METHOD_ID="<your-auth-method-id>"

# Create managed group for admins
boundary managed-groups create oidc \
  -auth-method-id $AUTH_METHOD_ID \
  -name "keycloak-admins" \
  -filter '"admins" in "/groups"'

# Create managed group for developers
boundary managed-groups create oidc \
  -auth-method-id $AUTH_METHOD_ID \
  -name "keycloak-developers" \
  -filter '"developers" in "/groups"'
```

### Step 3: Test Authentication

```bash
# Authenticate with OIDC
boundary authenticate oidc \
  -auth-method-id $AUTH_METHOD_ID

# This will open a browser for Keycloak login
# Login with one of the demo users
```

## File Structure

```
keycloak/
├── manifests/
│   ├── 01-namespace.yaml          # Keycloak namespace
│   ├── 02-secrets.yaml            # Admin & DB credentials
│   ├── 03-postgres.yaml           # PostgreSQL deployment + PVC
│   ├── 04-deployment.yaml         # Keycloak deployment
│   └── 05-service.yaml            # ClusterIP services
├── scripts/
│   ├── deploy-keycloak.sh         # Deploy all resources
│   ├── configure-realm.sh         # Configure realm & users
│   └── teardown-keycloak.sh       # Remove all resources
└── README.md                      # This file
```

## Configuration Details

### Keycloak Settings

- **Version**: 24.0.5 (latest stable)
- **Mode**: Development (`start-dev`)
- **Database**: PostgreSQL 16-alpine
- **Storage**: 5Gi PVC for PostgreSQL
- **Resources**:
  - Keycloak: 512Mi-1Gi memory, 500m-1000m CPU
  - PostgreSQL: 256Mi-512Mi memory, 250m-500m CPU

### Security Notes

**For Development/Testing:**
- Default admin password: `admin123!@#`
- Client secret: `boundary-client-secret-change-me`
- HTTP enabled (no TLS)
- Strict hostname checking disabled

**For Production:**
1. **Change all default passwords**
2. **Update client secret** to a secure random value
3. **Enable HTTPS/TLS** with valid certificates
4. **Use Kubernetes secrets** with proper RBAC
5. **Enable hostname strict checking**
6. **Configure network policies** for isolation
7. **Use production database** with backups
8. **Implement monitoring** and alerting

### Environment Variables

Keycloak configuration can be customized via environment variables:

```bash
# For configure-realm.sh
export KEYCLOAK_URL="http://localhost:8080"
export KEYCLOAK_ADMIN="admin"
export KEYCLOAK_ADMIN_PASSWORD="admin123!@#"
export BOUNDARY_URL="http://localhost:9200"

# Run configuration
./scripts/configure-realm.sh
```

## Troubleshooting

### Keycloak Pod Not Starting

```bash
# Check pod status
kubectl get pods -n keycloak

# View logs
kubectl logs -n keycloak -l app=keycloak --tail=100

# Common issues:
# - PostgreSQL not ready: Wait for DB to start first
# - Resource limits: Check node resources
# - Image pull: Verify network connectivity
```

### PostgreSQL Connection Issues

```bash
# Check PostgreSQL pod
kubectl get pods -n keycloak -l app=keycloak-postgres

# Test database connectivity
kubectl exec -n keycloak -it <postgres-pod> -- psql -U keycloak -d keycloak

# Verify secrets
kubectl get secret -n keycloak keycloak-db -o yaml
```

### Realm Configuration Fails

```bash
# Ensure port-forward is active
kubectl port-forward -n keycloak svc/keycloak 8080:8080

# Test Keycloak health
curl http://localhost:8080/health

# Verify admin credentials
kubectl get secret -n keycloak keycloak-admin -o jsonpath='{.data.KEYCLOAK_ADMIN_PASSWORD}' | base64 -d
```

### OIDC Authentication Issues

1. **Check redirect URIs**: Ensure Boundary callback URL is registered
2. **Verify issuer URL**: Must match exactly (http vs https)
3. **Check client secret**: Must match between Keycloak and Boundary
4. **Review token lifespan**: Default is 3600 seconds
5. **Check network connectivity**: Boundary must reach Keycloak

## Monitoring

### Health Checks

```bash
# Keycloak health endpoints
curl http://localhost:8080/health/live    # Liveness
curl http://localhost:8080/health/ready   # Readiness
curl http://localhost:8080/health/started # Startup

# PostgreSQL health
kubectl exec -n keycloak <postgres-pod> -- pg_isready -U keycloak
```

### Resource Usage

```bash
# Check resource consumption
kubectl top pods -n keycloak

# View events
kubectl get events -n keycloak --sort-by='.lastTimestamp'
```

## Backup and Restore

### Database Backup

```bash
# Backup PostgreSQL database
kubectl exec -n keycloak <postgres-pod> -- \
  pg_dump -U keycloak keycloak > keycloak-backup.sql

# Restore from backup
kubectl exec -i -n keycloak <postgres-pod> -- \
  psql -U keycloak keycloak < keycloak-backup.sql
```

### Realm Export

```bash
# Export realm configuration via API
curl -H "Authorization: Bearer $ACCESS_TOKEN" \
  http://localhost:8080/admin/realms/agent-sandbox \
  > agent-sandbox-realm.json
```

## Cleanup

### Remove All Resources

```bash
# Run teardown script
./scripts/teardown-keycloak.sh

# This will prompt for confirmation before:
# 1. Deleting deployments and services
# 2. Deleting PostgreSQL and PVC (data loss)
# 3. Deleting namespace
```

### Partial Cleanup

```bash
# Delete only Keycloak (keep database)
kubectl delete -f manifests/04-deployment.yaml
kubectl delete -f manifests/05-service.yaml

# Delete only database
kubectl delete -f manifests/03-postgres.yaml
```

## Next Steps

1. **Deploy Keycloak**: Run `./scripts/deploy-keycloak.sh`
2. **Configure Realm**: Run `./scripts/configure-realm.sh`
3. **Integrate Boundary**: Configure OIDC auth method in Boundary
4. **Test Authentication**: Login with demo users
5. **Customize**: Add more users, groups, and client scopes
6. **Production Hardening**: Implement security best practices

## References

- [Keycloak Documentation](https://www.keycloak.org/documentation)
- [Boundary OIDC Auth Method](https://developer.hashicorp.com/boundary/docs/concepts/domain-model/auth-methods#oidc-auth-method-attributes)
- [OpenID Connect Specification](https://openid.net/specs/openid-connect-core-1_0.html)
- [Kubernetes Secrets Management](https://kubernetes.io/docs/concepts/configuration/secret/)

## Support

For issues or questions:
1. Check troubleshooting section above
2. Review Keycloak logs: `kubectl logs -n keycloak -l app=keycloak`
3. Verify Boundary configuration
4. Consult Keycloak and Boundary documentation
