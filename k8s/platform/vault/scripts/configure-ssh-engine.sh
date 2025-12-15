#!/bin/bash
set -euo pipefail

NAMESPACE="${1:-vault}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=========================================="
echo "  Vault SSH Engine Configuration"
echo "=========================================="
echo ""

# Get root token
if [[ -z "${VAULT_TOKEN:-}" ]]; then
    if [[ -f "$SCRIPT_DIR/vault-keys.txt" ]]; then
        VAULT_TOKEN=$(grep "Root Token:" "$SCRIPT_DIR/vault-keys.txt" | awk '{print $3}')
    else
        echo "Enter Vault root token:"
        read -rs VAULT_TOKEN
    fi
fi

echo "🔧 Enabling SSH secrets engine..."
kubectl exec -n "$NAMESPACE" vault-0 -- sh -c "
    export VAULT_TOKEN='$VAULT_TOKEN'
    vault secrets enable -path=ssh ssh 2>/dev/null || echo '  (already enabled)'
"

echo "🔧 Configuring SSH CA..."
kubectl exec -n "$NAMESPACE" vault-0 -- sh -c "
    export VAULT_TOKEN='$VAULT_TOKEN'
    vault write ssh/config/ca generate_signing_key=true 2>/dev/null || echo '  (CA already configured)'
"

echo "🔧 Creating devenv-access role..."
# Vault SSH role creation - default_extensions must be a map passed via JSON stdin
# Extensions include permit-port-forwarding for VS Code Remote SSH TCP forwarding
kubectl exec -n "$NAMESPACE" vault-0 -i -- sh -c "
    export VAULT_TOKEN='$VAULT_TOKEN'
    vault write ssh/roles/devenv-access -
" << 'ROLE_EOF'
{
  "key_type": "ca",
  "allowed_users": "node,root",
  "default_user": "node",
  "allow_user_certificates": true,
  "ttl": "1h",
  "max_ttl": "24h",
  "allowed_extensions": "permit-pty,permit-port-forwarding,permit-agent-forwarding,permit-X11-forwarding",
  "default_extensions": {
    "permit-pty": "",
    "permit-port-forwarding": "",
    "permit-agent-forwarding": "",
    "permit-X11-forwarding": ""
  }
}
ROLE_EOF
echo "  Role created with port-forwarding extensions"

echo ""
echo "📋 SSH CA Public Key:"
CA_KEY=$(kubectl exec -n "$NAMESPACE" vault-0 -- sh -c "
    export VAULT_TOKEN='$VAULT_TOKEN'
    vault read -field=public_key ssh/config/ca
")
echo "$CA_KEY"
echo "$CA_KEY" > "$SCRIPT_DIR/vault-ssh-ca.pub"

echo ""
echo "=========================================="
echo "  ✅ SSH Engine Configured"
echo "=========================================="
echo ""
echo "CA key saved to: $SCRIPT_DIR/vault-ssh-ca.pub"
echo ""

# Create Kubernetes secret with SSH CA public key for devenv pods
echo "Creating Kubernetes secret with SSH CA..."
kubectl create secret generic vault-ssh-ca \
    --namespace=devenv \
    --from-file=vault-ssh-ca.pub="$SCRIPT_DIR/vault-ssh-ca.pub" \
    --dry-run=client -o yaml | kubectl apply -f -
echo "✅ Secret 'vault-ssh-ca' created in devenv namespace"

# Restart all devenv sandbox pods to pick up the new SSH CA secret
echo "🔄 Restarting devenv sandboxes to pick up SSH CA secret..."
for sandbox in claude-code-sandbox gemini-sandbox; do
    if kubectl get pod -n devenv -l app=$sandbox &>/dev/null 2>&1; then
        kubectl delete pod -n devenv -l app=$sandbox --wait=false 2>/dev/null || true
        echo "   Restarted $sandbox"
    fi
done
echo "   Pods will restart automatically. Wait for them to be Ready before connecting."

echo ""
echo "To use with devenv:"
echo "  1. The SSH CA is automatically mounted to devenv pods"
echo "  2. Request a signed certificate:"
echo "     vault write -field=signed_key ssh/sign/devenv-access public_key=@~/.ssh/id_rsa.pub > ~/.ssh/id_rsa-cert.pub"
echo "  3. SSH with signed cert:"
echo "     ssh -i ~/.ssh/id_rsa node@<devenv-pod-ip>"
echo ""
echo "For VSCode Remote SSH:"
echo "  1. Port forward to the devenv pod:"
echo "     kubectl port-forward -n devenv svc/devenv 2222:22"
echo "  2. Add to ~/.ssh/config:"
echo "     Host devenv"
echo "       HostName localhost"
echo "       Port 2222"
echo "       User node"
echo "       IdentityFile ~/.ssh/id_rsa"
echo "       CertificateFile ~/.ssh/id_rsa-cert.pub"
echo "  3. Connect via VSCode Remote SSH to 'devenv'"
