#!/bin/bash
set -e

# Docker entrypoint script for agent-sandbox container
# Starts SSH server and keeps container running for kubectl exec and SSH access

echo "=== Agent Sandbox Container Starting ==="

# Configure Vault SSH CA trust if mounted
VAULT_CA_PATH="/etc/ssh/vault-ca/vault-ssh-ca.pub"
SSHD_CONFIG="/etc/ssh/sshd_config.d/kubernetes.conf"

if [[ -f "$VAULT_CA_PATH" ]]; then
    echo "Configuring Vault SSH CA trust..."
    # Check if already configured
    if ! grep -q "^TrustedUserCAKeys" "$SSHD_CONFIG" 2>/dev/null; then
        echo "TrustedUserCAKeys $VAULT_CA_PATH" | sudo tee -a "$SSHD_CONFIG" > /dev/null
        echo "Vault SSH CA configured at: $VAULT_CA_PATH"
    else
        echo "Vault SSH CA already configured"
    fi
else
    echo "No Vault SSH CA found at $VAULT_CA_PATH (certificate auth disabled)"
fi

# Start SSH server
echo "Starting SSH server..."
sudo /usr/sbin/sshd

# Verify SSH server started
sleep 1
if pgrep -x sshd > /dev/null; then
    echo "SSH server started successfully"
else
    echo "Warning: SSH server may not have started"
fi

# Create environment file for SSH sessions
# This allows SSH sessions to inherit environment variables
ENV_FILE="/home/node/.ssh/environment"
touch "$ENV_FILE"
chmod 600 "$ENV_FILE"

# Export critical environment variables for SSH sessions
printenv | grep -E "^(GITHUB_TOKEN|TFE_TOKEN|LANGFUSE|AWS_|VAULT_|ANTHROPIC_|SHELL|PATH|HOME|USER|GOPATH|GOROOT|NPM_CONFIG_PREFIX)=" > "$ENV_FILE" 2>/dev/null || true
echo "Environment variables exported for SSH sessions"

echo "=== Agent Sandbox Ready ==="
echo "  - SSH: port 22"
echo "  - User: node"
echo "  - Shell: /bin/zsh"
echo ""

# Keep container running
exec tail -f /dev/null
