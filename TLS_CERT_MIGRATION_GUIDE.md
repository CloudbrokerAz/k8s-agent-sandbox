# TLS Certificate Migration Guide: .local to hashicorp.lab

This guide provides instructions for migrating TLS certificates from the `.local` domain to the `hashicorp.lab` domain for all services.

## Quick Start

There are two options to generate and update the certificates:

### Option 1: Using the Bash Script (Recommended)

```bash
chmod +x k8s/scripts/generate-tls-certs-hashicorp-lab.sh
k8s/scripts/generate-tls-certs-hashicorp-lab.sh
```

### Option 2: Using the Python Script

```bash
python3 k8s/scripts/generate-tls-certs-hashicorp-lab.py
```

## Manual Generation

If you prefer to generate the certificates manually, follow these steps:

### 1. Generate Boundary Certificate

```bash
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout /tmp/boundary.key -out /tmp/boundary.crt \
  -subj "/CN=boundary.hashicorp.lab" \
  -addext "subjectAltName=DNS:boundary.hashicorp.lab,DNS:localhost,IP:127.0.0.1"

# Encode the certificate and key
base64 -i /tmp/boundary.crt -o /tmp/boundary_crt.b64
base64 -i /tmp/boundary.key -o /tmp/boundary_key.b64
```

### 2. Generate Boundary Worker Certificate

```bash
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout /tmp/boundary-worker.key -out /tmp/boundary-worker.crt \
  -subj "/CN=boundary-worker.hashicorp.lab" \
  -addext "subjectAltName=DNS:boundary-worker.hashicorp.lab,DNS:localhost,IP:127.0.0.1"

# Encode the certificate and key
base64 -i /tmp/boundary-worker.crt -o /tmp/boundary-worker_crt.b64
base64 -i /tmp/boundary-worker.key -o /tmp/boundary-worker_key.b64
```

### 3. Generate Keycloak Certificate

```bash
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout /tmp/keycloak.key -out /tmp/keycloak.crt \
  -subj "/CN=keycloak.hashicorp.lab" \
  -addext "subjectAltName=DNS:keycloak.hashicorp.lab,DNS:localhost,IP:127.0.0.1"

# Encode the certificate and key
base64 -i /tmp/keycloak.crt -o /tmp/keycloak_crt.b64
base64 -i /tmp/keycloak.key -o /tmp/keycloak_key.b64
```

### 4. Generate Vault Certificate

```bash
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout /tmp/vault.key -out /tmp/vault.crt \
  -subj "/CN=vault.hashicorp.lab" \
  -addext "subjectAltName=DNS:vault.hashicorp.lab,DNS:localhost,IP:127.0.0.1"

# Encode the certificate and key
base64 -i /tmp/vault.crt -o /tmp/vault_crt.b64
base64 -i /tmp/vault.key -o /tmp/vault_key.b64
```

## Files to Update

The following files need to be updated with the new base64-encoded certificate values:

1. **k8s/platform/boundary/manifests/09-tls-secret.yaml** - for boundary.hashicorp.lab
2. **k8s/platform/boundary/manifests/11-worker-tls-secret.yaml** - for boundary-worker.hashicorp.lab
3. **k8s/platform/keycloak/manifests/07-tls-secret.yaml** - for keycloak.hashicorp.lab
4. **k8s/platform/vault/manifests/08-tls-secret.yaml** - for vault.hashicorp.lab

## Certificate Details

### Boundary (boundary.hashicorp.lab)

- **File**: `k8s/platform/boundary/manifests/09-tls-secret.yaml`
- **Namespace**: boundary
- **Secret Name**: boundary-tls
- **Subject**: CN=boundary.hashicorp.lab
- **SANs**:
  - DNS:boundary.hashicorp.lab
  - DNS:localhost
  - IP:127.0.0.1
- **Validity**: 365 days
- **Key Type**: RSA 2048-bit

### Boundary Worker (boundary-worker.hashicorp.lab)

- **File**: `k8s/platform/boundary/manifests/11-worker-tls-secret.yaml`
- **Namespace**: boundary
- **Secret Name**: boundary-worker-tls
- **Subject**: CN=boundary-worker.hashicorp.lab
- **SANs**:
  - DNS:boundary-worker.hashicorp.lab
  - DNS:localhost
  - IP:127.0.0.1
- **Validity**: 365 days
- **Key Type**: RSA 2048-bit

### Keycloak (keycloak.hashicorp.lab)

- **File**: `k8s/platform/keycloak/manifests/07-tls-secret.yaml`
- **Namespace**: keycloak
- **Secret Name**: keycloak-tls
- **Subject**: CN=keycloak.hashicorp.lab
- **SANs**:
  - DNS:keycloak.hashicorp.lab
  - DNS:localhost
  - IP:127.0.0.1
- **Validity**: 365 days
- **Key Type**: RSA 2048-bit

### Vault (vault.hashicorp.lab)

- **File**: `k8s/platform/vault/manifests/08-tls-secret.yaml`
- **Namespace**: vault
- **Secret Name**: vault-tls
- **Subject**: CN=vault.hashicorp.lab
- **SANs**:
  - DNS:vault.hashicorp.lab
  - DNS:localhost
  - IP:127.0.0.1
- **Validity**: 365 days
- **Key Type**: RSA 2048-bit

## Verification

After generation, verify the certificates:

```bash
# Check certificate details
openssl x509 -in /tmp/boundary.crt -text -noout
openssl x509 -in /tmp/boundary-worker.crt -text -noout
openssl x509 -in /tmp/keycloak.crt -text -noout
openssl x509 -in /tmp/vault.crt -text -noout

# Verify SANs are present
openssl x509 -in /tmp/boundary.crt -text -noout | grep -A 1 "Subject Alternative Name"
```

## Applying the Changes

1. Run the script to generate certificates and update YAML files:
   ```bash
   python3 k8s/scripts/generate-tls-certs-hashicorp-lab.py
   ```

2. Verify the updated files:
   ```bash
   git diff k8s/platform/*/manifests/*-tls-secret.yaml
   ```

3. Commit the changes:
   ```bash
   git add k8s/platform/*/manifests/*-tls-secret.yaml
   git commit -m "Update TLS certificates for hashicorp.lab domain migration"
   ```

4. Apply to Kubernetes:
   ```bash
   # Replace the secrets in your cluster
   kubectl apply -f k8s/platform/boundary/manifests/09-tls-secret.yaml
   kubectl apply -f k8s/platform/boundary/manifests/11-worker-tls-secret.yaml
   kubectl apply -f k8s/platform/keycloak/manifests/07-tls-secret.yaml
   kubectl apply -f k8s/platform/vault/manifests/08-tls-secret.yaml

   # Or recreate them
   kubectl delete secret boundary-tls -n boundary
   kubectl delete secret boundary-worker-tls -n boundary
   kubectl delete secret keycloak-tls -n keycloak
   kubectl delete secret vault-tls -n vault

   kubectl apply -f k8s/platform/boundary/manifests/09-tls-secret.yaml
   kubectl apply -f k8s/platform/boundary/manifests/11-worker-tls-secret.yaml
   kubectl apply -f k8s/platform/keycloak/manifests/07-tls-secret.yaml
   kubectl apply -f k8s/platform/vault/manifests/08-tls-secret.yaml
   ```

## Important Notes

- These are **self-signed certificates** and should only be used for development/testing
- The certificates are valid for **365 days**
- The certificates include **Subject Alternative Names (SANs)** which are required for proper TLS validation
- Ensure your application configurations are updated to use the new `hashicorp.lab` domain
- After updating secrets, pods may need to be restarted to pick up the new certificates
