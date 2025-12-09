# Keycloak Quick Start Guide

Fast setup guide for deploying Keycloak with Boundary integration.

## Prerequisites

- Kubernetes cluster running (Docker Desktop, minikube, etc.)
- kubectl configured
- curl and jq installed (for configuration script)

## 3-Step Deployment

### Step 1: Deploy Keycloak (2-3 minutes)

```bash
cd /workspace/k8s/platform/keycloak
./scripts/deploy-keycloak.sh
```

Wait for pods to be ready:
```bash
kubectl get pods -n keycloak -w
```

### Step 2: Configure Realm (1 minute)

In a new terminal, port-forward:
```bash
kubectl port-forward -n keycloak svc/keycloak 8080:8080
```

In original terminal, configure realm:
```bash
./scripts/configure-realm.sh
```

### Step 3: Test Access

Open browser: http://localhost:8080

Login with:
- Username: `admin`
- Password: `admin123!@#`

Navigate to: **agent-sandbox** realm

## Demo Users

Test authentication with:

```
Email: admin@example.com
Password: Admin123!@#
Group: admins

Email: developer@example.com
Password: Dev123!@#
Group: developers

Email: readonly@example.com
Password: Read123!@#
Group: readonly
```

## Boundary Integration

### Get OIDC Configuration

```bash
# Client ID
boundary

# Client Secret
boundary-client-secret-change-me

# Issuer URL (from within cluster)
http://keycloak.keycloak.svc.cluster.local:8080/realms/agent-sandbox

# Issuer URL (from localhost)
http://localhost:8080/realms/agent-sandbox
```

### Create OIDC Auth Method

```bash
boundary auth-methods create oidc \
  -name "Keycloak SSO" \
  -issuer "http://keycloak.keycloak.svc.cluster.local:8080/realms/agent-sandbox" \
  -client-id "boundary" \
  -client-secret "boundary-client-secret-change-me" \
  -api-url-prefix "http://localhost:9200"
```

## Verify Installation

```bash
# Check all pods running
kubectl get pods -n keycloak

# Check services
kubectl get svc -n keycloak

# Test Keycloak API
curl http://localhost:8080/realms/agent-sandbox/.well-known/openid-configuration
```

## Common Commands

```bash
# View Keycloak logs
kubectl logs -n keycloak -l app=keycloak -f

# View PostgreSQL logs
kubectl logs -n keycloak -l app=keycloak-postgres -f

# Restart Keycloak
kubectl rollout restart deployment/keycloak -n keycloak

# Access Keycloak pod
kubectl exec -it -n keycloak <keycloak-pod> -- bash

# Clean up everything
./scripts/teardown-keycloak.sh
```

## Troubleshooting

**Pod not starting?**
```bash
kubectl describe pod -n keycloak -l app=keycloak
kubectl logs -n keycloak -l app=keycloak --tail=50
```

**Can't access UI?**
```bash
# Verify port-forward
kubectl port-forward -n keycloak svc/keycloak 8080:8080

# Test locally
curl http://localhost:8080/health
```

**Configuration script fails?**
```bash
# Ensure port-forward is active
# Check Keycloak is ready
kubectl get pods -n keycloak

# Verify admin password
kubectl get secret -n keycloak keycloak-admin -o jsonpath='{.data.KEYCLOAK_ADMIN_PASSWORD}' | base64 -d
```

## Next Steps

1. Customize realm settings in Keycloak admin console
2. Add more users and groups
3. Configure Boundary OIDC auth method
4. Test user authentication flow
5. See full README.md for production hardening

## Production Checklist

Before production use:

- [ ] Change admin password
- [ ] Generate secure client secret
- [ ] Enable HTTPS/TLS
- [ ] Configure persistent storage backups
- [ ] Set up monitoring and alerts
- [ ] Review and apply security policies
- [ ] Configure network policies
- [ ] Set resource limits appropriately
- [ ] Enable audit logging
- [ ] Test disaster recovery procedures

---

For detailed documentation, see [README.md](./README.md)
