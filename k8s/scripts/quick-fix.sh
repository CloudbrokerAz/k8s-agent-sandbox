#!/bin/bash
set -euo pipefail

# Quick fix script for common platform issues
# Run this after deployment or when healthcheck shows failures

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
K8S_DIR="$(dirname "$SCRIPT_DIR")"

echo "=========================================="
echo "  Platform Quick Fix"
echo "=========================================="
echo ""
echo "This script will attempt to fix common issues:"
echo "  1. Unseal Vault if sealed"
echo "  2. Verify secrets are configured"
echo "  3. Check SSH engine configuration"
echo ""

# Source configuration
if [[ -f "$SCRIPT_DIR/.env" ]]; then
    source "$SCRIPT_DIR/.env"
elif [[ -f "$SCRIPT_DIR/platform.env.example" ]]; then
    source "$SCRIPT_DIR/platform.env.example"
fi

VAULT_NAMESPACE="${VAULT_NAMESPACE:-vault}"
DEVENV_NAMESPACE="${DEVENV_NAMESPACE:-devenv}"

# ==========================================
# 1. Check and Unseal Vault
# ==========================================
echo "=========================================="
echo "  1. Vault Status"
echo "=========================================="
echo ""

if ! kubectl get pod vault-0 -n "$VAULT_NAMESPACE" &>/dev/null; then
    echo "⚠️  Vault pod not found - skipping"
else
    VAULT_STATUS=$(kubectl exec -n "$VAULT_NAMESPACE" vault-0 -- vault status -format=json 2>/dev/null || echo '{"sealed":true}')
    SEALED=$(echo "$VAULT_STATUS" | jq -r '.sealed')

    if [[ "$SEALED" == "true" ]]; then
        echo "🔒 Vault is sealed, attempting to unseal..."
        if [[ -f "$K8S_DIR/platform/vault/scripts/unseal-vault.sh" ]]; then
            "$K8S_DIR/platform/vault/scripts/unseal-vault.sh" "$VAULT_NAMESPACE"
        else
            echo "❌ unseal-vault.sh not found"
            echo ""
            echo "Manual unseal required:"
            echo "  kubectl exec -n vault vault-0 -- vault operator unseal <unseal-key>"
        fi
    else
        echo "✅ Vault is unsealed"
    fi
fi

echo ""

# ==========================================
# 2. Check Secrets Configuration
# ==========================================
echo "=========================================="
echo "  2. Secrets Configuration"
echo "=========================================="
echo ""

if kubectl get secret devenv-vault-secrets -n "$DEVENV_NAMESPACE" &>/dev/null; then
    GITHUB_TOKEN=$(kubectl get secret devenv-vault-secrets -n "$DEVENV_NAMESPACE" -o jsonpath='{.data.GITHUB_TOKEN}' 2>/dev/null | base64 -d || echo "")

    if [[ -z "$GITHUB_TOKEN" ]] || [[ "$GITHUB_TOKEN" == "placeholder-update-me" ]] || [[ "$GITHUB_TOKEN" == "placeholder" ]]; then
        echo "⚠️  GITHUB_TOKEN not configured"
        echo ""
        echo "Configure secrets with:"
        echo "  ./platform/vault/scripts/configure-secrets.sh"
    else
        echo "✅ GITHUB_TOKEN configured"
    fi
else
    echo "⚠️  devenv-vault-secrets not found"
    echo ""
    echo "This secret should be created by VSO from Vault KV."
    echo "Check VSO status:"
    echo "  kubectl get vaultstaticsecret -n devenv"
    echo "  kubectl logs -n vault-secrets-operator-system -l app.kubernetes.io/name=vault-secrets-operator"
fi

echo ""

# ==========================================
# 3. Check SSH Engine
# ==========================================
echo "=========================================="
echo "  3. SSH Secrets Engine"
echo "=========================================="
echo ""

if kubectl get secret vault-ssh-ca -n "$DEVENV_NAMESPACE" &>/dev/null; then
    echo "✅ SSH CA certificate configured"
else
    echo "⚠️  SSH CA certificate not found"
    echo ""
    echo "Configure SSH engine with:"
    echo "  ./platform/vault/scripts/configure-ssh-engine.sh"
fi

echo ""

# ==========================================
# 4. Summary
# ==========================================
echo "=========================================="
echo "  Quick Fix Complete"
echo "=========================================="
echo ""
echo "Run healthcheck to verify:"
echo "  ./scripts/tests/healthcheck.sh"
echo ""
