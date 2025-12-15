# TLS Certificate Generation Summary

## Overview

Successfully generated four self-signed TLS certificates for the domain migration from `.local` to `hashicorp.lab` and updated all corresponding Kubernetes secret files.

## Date Generated

December 15, 2025 at 07:37:02 UTC

## Certificates Generated

### 1. Boundary Certificate
- **File Updated**: `k8s/platform/boundary/manifests/09-tls-secret.yaml`
- **Domain**: boundary.hashicorp.lab
- **Subject**: CN=boundary.hashicorp.lab
- **Subject Alternative Names (SANs)**:
  - DNS:boundary.hashicorp.lab
  - DNS:localhost
  - IP:127.0.0.1
- **Validity**: 365 days (until December 15, 2026)
- **Key Type**: RSA 2048-bit
- **Kubernetes Secret Name**: boundary-tls
- **Kubernetes Namespace**: boundary

### 2. Boundary Worker Certificate
- **File Updated**: `k8s/platform/boundary/manifests/11-worker-tls-secret.yaml`
- **Domain**: boundary-worker.hashicorp.lab
- **Subject**: CN=boundary-worker.hashicorp.lab
- **Subject Alternative Names (SANs)**:
  - DNS:boundary-worker.hashicorp.lab
  - DNS:localhost
  - IP:127.0.0.1
- **Validity**: 365 days (until December 15, 2026)
- **Key Type**: RSA 2048-bit
- **Kubernetes Secret Name**: boundary-worker-tls
- **Kubernetes Namespace**: boundary

### 3. Keycloak Certificate
- **File Updated**: `k8s/platform/keycloak/manifests/07-tls-secret.yaml`
- **Domain**: keycloak.hashicorp.lab
- **Subject**: CN=keycloak.hashicorp.lab
- **Subject Alternative Names (SANs)**:
  - DNS:keycloak.hashicorp.lab
  - DNS:localhost
  - IP:127.0.0.1
- **Validity**: 365 days (until December 15, 2026)
- **Key Type**: RSA 2048-bit
- **Kubernetes Secret Name**: keycloak-tls
- **Kubernetes Namespace**: keycloak

### 4. Vault Certificate
- **File Updated**: `k8s/platform/vault/manifests/08-tls-secret.yaml`
- **Domain**: vault.hashicorp.lab
- **Subject**: CN=vault.hashicorp.lab
- **Subject Alternative Names (SANs)**:
  - DNS:vault.hashicorp.lab
  - DNS:localhost
  - IP:127.0.0.1
- **Validity**: 365 days (until December 15, 2026)
- **Key Type**: RSA 2048-bit
- **Kubernetes Secret Name**: vault-tls
- **Kubernetes Namespace**: vault

## Generation Method

All certificates were generated using OpenSSL with the following command pattern:

```bash
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout <service>.key -out <service>.crt \
  -subj "/CN=<service>.hashicorp.lab" \
  -addext "subjectAltName=DNS:<service>.hashicorp.lab,DNS:localhost,IP:127.0.0.1"
```

## Files Updated

The following Kubernetes secret YAML files were updated with new base64-encoded certificate and key values:

1. `/k8s/platform/boundary/manifests/09-tls-secret.yaml`
2. `/k8s/platform/boundary/manifests/11-worker-tls-secret.yaml`
3. `/k8s/platform/keycloak/manifests/07-tls-secret.yaml`
4. `/k8s/platform/vault/manifests/08-tls-secret.yaml`

Each file now contains:
- Updated comments referencing the new `hashicorp.lab` domain
- New base64-encoded `tls.crt` (certificate) data
- New base64-encoded `tls.key` (private key) data
- Unchanged Kubernetes metadata (namespace, secret name, labels)

## Backup Files Created

Backup copies of the original files have been created with the following naming convention:
- `<filename>.bak-20251215_183702`

These backups are located in the same directory as the original files.

## Additional Files Generated

The following helper scripts and documentation files were created for reference:

1. **generate-certs.sh** - Automated bash script for generating all certificates and updating YAML files
2. **k8s/scripts/generate-tls-certs-hashicorp-lab.sh** - Alternative bash script for certificate generation
3. **k8s/scripts/generate-tls-certs-hashicorp-lab.py** - Python script for automated certificate generation and YAML updates
4. **TLS_CERT_MIGRATION_GUIDE.md** - Comprehensive guide for manual and automated certificate generation

## Next Steps

### 1. Review Changes
```bash
git diff k8s/platform/*/manifests/*-tls-secret.yaml
```

### 2. Commit Changes
```bash
git add k8s/platform/*/manifests/*-tls-secret.yaml
git commit -m "Update TLS certificates for hashicorp.lab domain migration

- Generate new self-signed certificates for boundary.hashicorp.lab
- Generate new self-signed certificates for boundary-worker.hashicorp.lab
- Generate new self-signed certificates for keycloak.hashicorp.lab
- Generate new self-signed certificates for vault.hashicorp.lab
- Include Subject Alternative Names (SANs) for TLS validation
- Certificates valid for 365 days (until Dec 15, 2026)"
```

### 3. Apply Updated Secrets to Kubernetes
```bash
# Apply the new secrets
kubectl apply -f k8s/platform/boundary/manifests/09-tls-secret.yaml
kubectl apply -f k8s/platform/boundary/manifests/11-worker-tls-secret.yaml
kubectl apply -f k8s/platform/keycloak/manifests/07-tls-secret.yaml
kubectl apply -f k8s/platform/vault/manifests/08-tls-secret.yaml

# Verify secrets were updated
kubectl get secret -n boundary boundary-tls -o yaml
kubectl get secret -n boundary boundary-worker-tls -o yaml
kubectl get secret -n keycloak keycloak-tls -o yaml
kubectl get secret -n vault vault-tls -o yaml
```

### 4. Restart Pods
After applying the new secrets, restart the pods in each namespace to pick up the new certificates:

```bash
# Boundary
kubectl rollout restart deployment/boundary-controller -n boundary
kubectl rollout restart deployment/boundary-worker -n boundary

# Keycloak
kubectl rollout restart deployment/keycloak -n keycloak

# Vault
kubectl rollout restart statefulset/vault -n vault
```

### 5. Verify TLS Configuration
Update any application configurations that reference the old `.local` domain to use the new `hashicorp.lab` domain.

### 6. Update DNS/Hosts
Ensure DNS or local hosts file entries point to the correct IP addresses for:
- boundary.hashicorp.lab
- boundary-worker.hashicorp.lab
- keycloak.hashicorp.lab
- vault.hashicorp.lab

## Important Notes

1. **Self-Signed Certificates**: These are self-signed certificates intended for development and testing environments. They are not signed by a Certificate Authority (CA).

2. **Browser Warnings**: When accessing these services via HTTPS in a web browser, you will receive security warnings about untrusted certificates. This is expected and normal for self-signed certificates.

3. **Certificate Validation**: Applications using these certificates should be configured to skip certificate validation in development environments, or add the certificates to their trusted CA store.

4. **Expiration**: These certificates expire on December 15, 2026. Plan to regenerate them before that date if the deployment is still in use.

5. **Subject Alternative Names (SANs)**: These certificates include SANs which are required for proper TLS validation by modern applications and Go's TLS library.

6. **Pod Restarts**: Pods may need to be restarted after updating the secrets for them to pick up the new certificates.

## Cleanup

Optional: Remove the backup files and helper scripts after verifying the changes:

```bash
rm -f k8s/platform/*/manifests/*-tls-secret.yaml.bak-*
rm -f generate-certs.sh
rm -f k8s/scripts/generate-tls-certs-hashicorp-lab.sh
rm -f k8s/scripts/generate-tls-certs-hashicorp-lab.py
```

## Related Documentation

- `TLS_CERT_MIGRATION_GUIDE.md` - Complete guide for certificate generation
- `k8s/platform/boundary/manifests/09-tls-secret.yaml` - Boundary TLS secret
- `k8s/platform/boundary/manifests/11-worker-tls-secret.yaml` - Boundary worker TLS secret
- `k8s/platform/keycloak/manifests/07-tls-secret.yaml` - Keycloak TLS secret
- `k8s/platform/vault/manifests/08-tls-secret.yaml` - Vault TLS secret
