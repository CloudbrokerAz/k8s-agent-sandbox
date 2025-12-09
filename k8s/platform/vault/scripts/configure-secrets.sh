#!/bin/bash
set -euo pipefail

# Configure secrets in Vault KV for devenv pods
# These secrets are synced to Kubernetes via Vault Secrets Operator
#
# Usage:
#   Interactive:  ./configure-secrets.sh
#   From env:     ./configure-secrets.sh --from-env
#   Non-interactive: GITHUB_TOKEN=xxx ./configure-secrets.sh --from-env

VAULT_NAMESPACE="${1:-vault}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
K8S_DIR="$(dirname "$(dirname "$(dirname "$SCRIPT_DIR")")")"
FROM_ENV="${2:-}"

# Source configuration if available
if [[ -f "$K8S_DIR/scripts/.env" ]]; then
    source "$K8S_DIR/scripts/.env"
elif [[ -f "$K8S_DIR/scripts/platform.env.example" ]]; then
    # Only source example if running non-interactively
    if [[ "$FROM_ENV" == "--from-env" ]]; then
        source "$K8S_DIR/scripts/platform.env.example"
    fi
fi

echo "=========================================="
echo "  Vault Secrets Configuration"
echo "=========================================="
echo ""
echo "This script configures secrets in Vault KV that are synced"
echo "to the devenv pods via Vault Secrets Operator."
echo ""

# Get root token
if [[ -z "${VAULT_TOKEN:-}" ]]; then
    if [[ -f "$SCRIPT_DIR/vault-keys.txt" ]]; then
        VAULT_TOKEN=$(grep "Root Token:" "$SCRIPT_DIR/vault-keys.txt" | awk '{print $3}')
        echo "✅ Found Vault token"
    else
        echo "Enter Vault root token:"
        read -rs VAULT_TOKEN
    fi
fi

# Check Vault status
SEALED=$(kubectl exec -n "$VAULT_NAMESPACE" vault-0 -- vault status -format=json 2>/dev/null | jq -r '.sealed' || echo "true")
if [[ "$SEALED" == "true" ]]; then
    echo "❌ Vault is sealed"
    exit 1
fi

echo ""
echo "Current secrets in Vault:"
kubectl exec -n "$VAULT_NAMESPACE" vault-0 -- sh -c "
    export VAULT_TOKEN='$VAULT_TOKEN'
    vault kv get -format=json secret/devenv/credentials 2>/dev/null | jq -r '.data.data | keys[]' || echo '(none)'
"

# Check if running from environment variables
if [[ "$FROM_ENV" == "--from-env" ]]; then
    echo "Running in non-interactive mode (--from-env)"
    echo ""
    if [[ -n "${GITHUB_TOKEN:-}" ]]; then
        echo "✅ GITHUB_TOKEN found in environment"
    else
        echo "⚠️  GITHUB_TOKEN not set in environment"
    fi
    if [[ -n "${LANGFUSE_HOST:-}" ]]; then
        echo "✅ Langfuse configuration found in environment"
    fi
else
    echo ""
    echo "=========================================="
    echo "  Configure GitHub Token"
    echo "=========================================="
    echo ""
    echo "The GitHub token is used for:"
    echo "  - GitHub CLI (gh) authentication"
    echo "  - Claude Code GitHub MCP integration"
    echo "  - Git operations with private repositories"
    echo ""
    echo "Get a token from: https://github.com/settings/tokens"
    echo "Required scopes: repo, read:org, workflow"
    echo ""

    # Use existing env var or prompt
    if [[ -n "${GITHUB_TOKEN:-}" ]]; then
        echo "GitHub token found in environment. Press Enter to use it, or enter a new one:"
        read -p "> " -rs NEW_TOKEN
        if [[ -n "$NEW_TOKEN" ]]; then
            GITHUB_TOKEN="$NEW_TOKEN"
        fi
    else
        read -p "Enter GitHub Personal Access Token (or press Enter to skip): " -rs GITHUB_TOKEN
    fi
    echo ""

    echo ""
    echo "=========================================="
    echo "  Configure Langfuse (Optional)"
    echo "=========================================="
    echo ""
    echo "Langfuse is used for LLM observability and tracing."
    echo "Leave blank to skip Langfuse configuration."
    echo ""

    if [[ -z "${LANGFUSE_HOST:-}" ]]; then
        read -p "Langfuse Host URL (e.g., https://cloud.langfuse.com): " LANGFUSE_HOST
    else
        echo "Using LANGFUSE_HOST from environment: $LANGFUSE_HOST"
    fi
    if [[ -z "${LANGFUSE_PUBLIC_KEY:-}" ]]; then
        read -p "Langfuse Public Key: " LANGFUSE_PUBLIC_KEY
    else
        echo "Using LANGFUSE_PUBLIC_KEY from environment"
    fi
    if [[ -z "${LANGFUSE_SECRET_KEY:-}" ]]; then
        read -p "Langfuse Secret Key: " -rs LANGFUSE_SECRET_KEY
        echo ""
    else
        echo "Using LANGFUSE_SECRET_KEY from environment"
    fi
fi

echo ""
echo "Updating Vault secrets..."

# Build the vault kv put command with non-empty values
CMD="vault kv put secret/devenv/credentials"

if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    CMD="$CMD github_token='$GITHUB_TOKEN'"
else
    # Preserve existing value if not updating
    EXISTING=$(kubectl exec -n "$VAULT_NAMESPACE" vault-0 -- sh -c "
        export VAULT_TOKEN='$VAULT_TOKEN'
        vault kv get -field=github_token secret/devenv/credentials 2>/dev/null || echo ''
    ")
    CMD="$CMD github_token='$EXISTING'"
fi

CMD="$CMD langfuse_host='${LANGFUSE_HOST:-}'"
CMD="$CMD langfuse_public_key='${LANGFUSE_PUBLIC_KEY:-}'"
CMD="$CMD langfuse_secret_key='${LANGFUSE_SECRET_KEY:-}'"

kubectl exec -n "$VAULT_NAMESPACE" vault-0 -- sh -c "
    export VAULT_TOKEN='$VAULT_TOKEN'
    $CMD
"

echo ""
echo "=========================================="
echo "  ✅ Secrets Configured"
echo "=========================================="
echo ""
echo "Secrets stored at: secret/devenv/credentials"
echo ""
echo "The Vault Secrets Operator will sync these to the"
echo "'devenv-vault-secrets' Kubernetes secret in the devenv namespace."
echo ""
echo "To verify sync:"
echo "  kubectl get secret devenv-vault-secrets -n devenv -o yaml"
echo ""
echo "To trigger immediate sync:"
echo "  kubectl delete secret devenv-vault-secrets -n devenv"
echo "  # VSO will recreate it within 30 seconds"
echo ""
