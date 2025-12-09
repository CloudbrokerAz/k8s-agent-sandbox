# Platform Fixes and Improvements

This document describes fixes applied to the Agent Sandbox Platform scripts.

## Issues Fixed

### 1. Healthcheck Configuration Path Issue

**Issue**: The healthcheck script was trying to source configuration from the wrong path.

**Location**: `k8s/scripts/tests/healthcheck.sh:11-14`

**Fix**: Updated configuration sourcing to look in the parent directory:
```bash
# Before
if [[ -f "$SCRIPT_DIR/.env" ]]; then
    source "$SCRIPT_DIR/.env"
elif [[ -f "$SCRIPT_DIR/platform.env.example" ]]; then
    source "$SCRIPT_DIR/platform.env.example"
fi

# After
if [[ -f "$SCRIPT_DIR/../.env" ]]; then
    source "$SCRIPT_DIR/../.env"
elif [[ -f "$SCRIPT_DIR/../platform.env.example" ]]; then
    source "$SCRIPT_DIR/../platform.env.example"
fi
```

### 2. Vault Auto-Unseal Missing

**Issue**: Vault becomes sealed after pod restarts and requires manual unsealing.

**Impact**: Healthcheck shows "FAIL: Vault is sealed" after any pod restart.

**Fix**: Created `k8s/platform/vault/scripts/unseal-vault.sh` to automate unsealing.

**Usage**:
```bash
# Unseal Vault manually
./k8s/platform/vault/scripts/unseal-vault.sh

# Or use the quick-fix script
./k8s/scripts/quick-fix.sh
```

**Features**:
- Automatically detects unseal threshold (1 or 3 keys)
- Reads keys from vault-keys.txt
- Validates Vault status before and after unsealing
- Provides clear error messages

### 3. Missing vault-keys.txt Error Handling

**Issue**: Healthcheck script crashes if `vault-keys.txt` doesn't exist.

**Location**: `k8s/scripts/tests/healthcheck.sh:168`

**Fix**: Added file existence check before reading:
```bash
# Before
VAULT_TOKEN=$(grep "Root Token:" "$K8S_DIR/platform/vault/scripts/vault-keys.txt" 2>/dev/null | awk '{print $3}' || echo "")

# After
VAULT_KEYS_FILE="$K8S_DIR/platform/vault/scripts/vault-keys.txt"
if [[ -f "$VAULT_KEYS_FILE" ]]; then
    VAULT_TOKEN=$(grep "Root Token:" "$VAULT_KEYS_FILE" 2>/dev/null | awk '{print $3}' || echo "")
else
    VAULT_TOKEN=""
    check_warn "Vault keys file not found (Vault not initialized)"
fi
```

### 4. Improved Error Messages

**Issue**: Healthcheck errors didn't provide actionable fix instructions.

**Fix**: Updated error messages to include remediation commands:

```bash
# Before
check_fail "Vault is sealed"

# After
check_fail "Vault is sealed (run: ./platform/vault/scripts/unseal-vault.sh)"
```

## New Scripts Created

### unseal-vault.sh

**Location**: `k8s/platform/vault/scripts/unseal-vault.sh`

**Purpose**: Automatically unseal Vault using stored keys

**Usage**:
```bash
# Unseal Vault in default namespace (vault)
./unseal-vault.sh

# Unseal Vault in custom namespace
./unseal-vault.sh my-vault-namespace
```

**Features**:
- Waits for Vault pod to be ready
- Checks if Vault is already unsealed (idempotent)
- Supports both threshold=1 and threshold=3 configurations
- Clear progress messages
- Error handling for missing keys file

### quick-fix.sh

**Location**: `k8s/scripts/quick-fix.sh`

**Purpose**: One-command fix for common platform issues

**Usage**:
```bash
./scripts/quick-fix.sh
```

**Features**:
- Unseals Vault if sealed
- Checks secrets configuration
- Verifies SSH engine setup
- Provides actionable next steps
- Safe to run multiple times

## Common Issues and Solutions

### Issue: Vault is sealed

**Symptom**: Healthcheck shows `FAIL: Vault is sealed`

**Solution**:
```bash
# Option 1: Use quick-fix
./scripts/quick-fix.sh

# Option 2: Unseal directly
./platform/vault/scripts/unseal-vault.sh
```

### Issue: GITHUB_TOKEN not set

**Symptom**: Healthcheck shows `WARN: GITHUB_TOKEN not set`

**Solution**:
```bash
# Configure secrets in Vault
./platform/vault/scripts/configure-secrets.sh
```

### Issue: SSH CA not configured

**Symptom**: Healthcheck shows `WARN: Vault SSH CA secret not found`

**Solution**:
```bash
# Configure SSH secrets engine
./platform/vault/scripts/configure-ssh-engine.sh
```

### Issue: TFE_TOKEN not set

**Symptom**: Healthcheck shows `WARN: TFE_TOKEN not set`

**Solution**:
```bash
# Option 1: Configure static token in Vault
./platform/vault/scripts/configure-secrets.sh

# Option 2: Configure dynamic Terraform tokens
./platform/vault/scripts/configure-tfe-engine.sh
```

## Testing

After applying fixes, run the healthcheck:

```bash
cd k8s/scripts/tests
./healthcheck.sh
```

Expected results after fixes:
- ✅ Vault unsealed and ready (after running unseal-vault.sh)
- ⚠️ Configuration warnings (expected until secrets are configured)
- ❌ No critical failures

## Deployment Workflow

Recommended workflow after deployment:

```bash
# 1. Deploy the platform
./deploy-all.sh

# 2. Fix common issues
./scripts/quick-fix.sh

# 3. Configure secrets
./platform/vault/scripts/configure-secrets.sh

# 4. Configure SSH (optional, for VS Code Remote)
./platform/vault/scripts/configure-ssh-engine.sh

# 5. Run healthcheck
./scripts/tests/healthcheck.sh
```

## Automation Considerations

### Vault Auto-Unseal on Pod Start

For production, consider implementing auto-unseal via:

**Option 1: Init Container**
Add an init container to the Vault StatefulSet that unseals on pod start:

```yaml
initContainers:
- name: unseal
  image: bitnami/kubectl:latest
  command: ["/scripts/unseal-vault.sh"]
  volumeMounts:
  - name: unseal-script
    mountPath: /scripts
  - name: vault-keys
    mountPath: /keys
```

**Option 2: CronJob**
Create a CronJob that checks and unseals Vault every 5 minutes:

```yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: vault-unseal-monitor
spec:
  schedule: "*/5 * * * *"
  jobTemplate:
    spec:
      template:
        spec:
          restartPolicy: OnFailure
          containers:
          - name: unseal
            image: bitnami/kubectl:latest
            command: ["/scripts/unseal-vault.sh"]
```

**Option 3: Vault Auto-Unseal (Cloud KMS)**
Use cloud provider KMS for automatic unsealing (recommended for production):

- AWS KMS
- Azure Key Vault
- Google Cloud KMS

See: https://developer.hashicorp.com/vault/docs/concepts/seal

## Known Limitations

1. **Manual Unseal Required**: Vault still requires manual unsealing after pod restarts unless auto-unseal automation is implemented.

2. **Secrets Configuration**: Initial secrets (GITHUB_TOKEN, TFE_TOKEN) must be configured manually via `configure-secrets.sh`.

3. **SSH Engine**: SSH CA must be configured separately via `configure-ssh-engine.sh`.

## Future Improvements

1. **Auto-Unseal Init Container**: Add init container to automatically unseal Vault on pod start
2. **Secrets Validation**: Add validation for required secrets during deployment
3. **Health Monitor**: Create a monitoring DaemonSet that continuously checks platform health
4. **Automated Remediation**: Implement self-healing for common issues
5. **Cloud KMS Integration**: Support cloud provider KMS for production auto-unseal

## References

- [Vault Seal/Unseal Documentation](https://developer.hashicorp.com/vault/docs/concepts/seal)
- [Kubernetes Init Containers](https://kubernetes.io/docs/concepts/workloads/pods/init-containers/)
- [Vault Auto-Unseal](https://developer.hashicorp.com/vault/tutorials/auto-unseal)
