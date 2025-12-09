#!/bin/bash
set -e

# Entrypoint script for Agent Sandbox (used by envbuilder)
# Configures Vault CA trust, SSH CA, and starts services

echo "=== Agent Sandbox Initializing ==="

# Configure Vault TLS CA trust
if [ -f /vault-ca/vault-ca.crt ]; then
    echo "Configuring Vault TLS CA trust..."
    sudo cp /vault-ca/vault-ca.crt /usr/local/share/ca-certificates/vault-ca.crt
    sudo update-ca-certificates
    echo "Vault TLS CA trusted"
fi

# Configure Vault SSH CA for certificate authentication
if [ -f /vault-ssh-ca/vault-ssh-ca.pub ]; then
    echo "Configuring Vault SSH CA..."
    sudo cp /vault-ssh-ca/vault-ssh-ca.pub /etc/ssh/vault-ssh-ca.pub
    sudo chmod 644 /etc/ssh/vault-ssh-ca.pub

    # Add TrustedUserCAKeys to sshd config if not present
    if ! grep -q "TrustedUserCAKeys" /etc/ssh/sshd_config 2>/dev/null; then
        echo "TrustedUserCAKeys /etc/ssh/vault-ssh-ca.pub" | sudo tee -a /etc/ssh/sshd_config > /dev/null
    fi
    echo "Vault SSH CA configured"
fi

# Ensure SSH server is running (devcontainer sshd feature should handle this)
if command -v sshd &> /dev/null; then
    if ! pgrep -x sshd > /dev/null; then
        echo "Starting SSH server..."
        sudo /usr/sbin/sshd
    fi
fi

# Start code-server if installed (devcontainer feature)
if command -v code-server &> /dev/null; then
    echo "Starting code-server on port 13337..."
    code-server --bind-addr 0.0.0.0:13337 --auth none /workspaces &
fi

echo "=== Agent Sandbox Ready ==="
echo "  - SSH: port 22 (for VS Code Remote SSH)"
echo "  - code-server: port 13337 (browser-based VS Code)"
echo ""

# Keep container running
exec tail -f /dev/null
