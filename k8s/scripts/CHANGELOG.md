# Scripts Changelog

## 2025-12-09 - Bug Fixes and Improvements

### Fixed

1. **Configuration Path Issues in Test Scripts**
   - Fixed `healthcheck.sh` and `test-secrets.sh` to source configuration from correct parent directory
   - Changed `$SCRIPT_DIR/platform.env.example` to `$SCRIPT_DIR/../platform.env.example`
   - **Impact**: Test scripts can now properly load configuration
   - **Files**: `k8s/scripts/tests/healthcheck.sh`, `k8s/scripts/tests/test-secrets.sh`

2. **Vault Keys File Error Handling**
   - Added file existence check before reading `vault-keys.txt`
   - Prevents script crashes when Vault is not yet initialized
   - Provides helpful warning message
   - **Files**: `k8s/scripts/tests/healthcheck.sh`

3. **Improved Error Messages**
   - Updated Vault sealed error to include remediation command
   - Changed from `Vault is sealed` to `Vault is sealed (run: ./platform/vault/scripts/unseal-vault.sh)`
   - **Impact**: Users get actionable next steps from healthcheck failures

### Added

1. **Vault Unseal Script** (`k8s/platform/vault/scripts/unseal-vault.sh`)
   - Automated Vault unsealing using stored keys
   - Supports both threshold=1 and threshold=3 configurations
   - Idempotent (safe to run multiple times)
   - Clear progress and error messages
   - **Usage**: `./platform/vault/scripts/unseal-vault.sh [namespace]`

2. **Quick Fix Script** (`k8s/scripts/quick-fix.sh`)
   - One-command fix for common platform issues
   - Unseals Vault if sealed
   - Checks secrets configuration
   - Verifies SSH engine setup
   - **Usage**: `./scripts/quick-fix.sh`

3. **Fixes Documentation** (`k8s/scripts/FIXES.md`)
   - Comprehensive documentation of all fixes
   - Common issues and solutions
   - Testing instructions
   - Future automation recommendations

## Testing

Run the healthcheck to verify fixes:

```bash
cd k8s/scripts/tests
./healthcheck.sh
```

Expected improvements:
- ✅ Configuration loads correctly
- ✅ No crashes from missing vault-keys.txt
- ✅ Clear error messages with fix instructions
- ⚠️ Vault unsealed (after running unseal-vault.sh)

## Upgrade Instructions

No breaking changes. All fixes are backward compatible.

To apply fixes:

```bash
# 1. Pull latest code
git pull

# 2. If Vault is sealed, unseal it
./k8s/platform/vault/scripts/unseal-vault.sh

# 3. Run quick-fix for other common issues
./k8s/scripts/quick-fix.sh

# 4. Verify with healthcheck
./k8s/scripts/tests/healthcheck.sh
```

## Files Changed

- ✏️ Modified: `k8s/scripts/tests/healthcheck.sh`
- ✏️ Modified: `k8s/scripts/tests/test-secrets.sh`
- ➕ Added: `k8s/platform/vault/scripts/unseal-vault.sh`
- ➕ Added: `k8s/scripts/quick-fix.sh`
- ➕ Added: `k8s/scripts/FIXES.md`
- ➕ Added: `k8s/scripts/CHANGELOG.md`

## Contributors

- Claude Code (AI Assistant)
- Based on user testing and healthcheck output feedback
