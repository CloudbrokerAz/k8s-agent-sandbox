#!/bin/bash
# setup-ssh-ca.sh - Configure Vault SSH CA for certificate authentication
# This script configures sshd to trust Vault-signed certificates
set -e

echo "Configuring SSH server..."

SSHD_CONFIG="/etc/ssh/sshd_config"

# ALWAYS change sshd port from 2222 to 22 (devcontainer sshd feature defaults to 2222)
# This must happen before the Vault CA check to ensure SSH is always on port 22
if grep -q "^Port 2222" "$SSHD_CONFIG" 2>/dev/null; then
    sudo sed -i 's/^Port 2222/Port 22/' "$SSHD_CONFIG"
    echo "  Changed sshd port from 2222 to 22"
fi

# Enable public key authentication
if grep -q "^#PubkeyAuthentication yes" "$SSHD_CONFIG" 2>/dev/null; then
    sudo sed -i 's/^#PubkeyAuthentication yes/PubkeyAuthentication yes/' "$SSHD_CONFIG"
    echo "  Enabled public key authentication"
fi

# Configure Vault SSH CA if mounted
if [ -f /vault-ssh-ca/vault-ssh-ca.pub ]; then
    echo "  Configuring Vault SSH CA..."
    # Copy CA public key to SSH config directory
    sudo cp /vault-ssh-ca/vault-ssh-ca.pub /etc/ssh/vault-ssh-ca.pub
    sudo chmod 644 /etc/ssh/vault-ssh-ca.pub
    echo "  Copied vault-ssh-ca.pub to /etc/ssh/"

    if ! grep -q "TrustedUserCAKeys /etc/ssh/vault-ssh-ca.pub" "$SSHD_CONFIG" 2>/dev/null; then
        echo "" | sudo tee -a "$SSHD_CONFIG" > /dev/null
        echo "# Vault SSH CA Authentication - Added by setup-ssh-ca.sh" | sudo tee -a "$SSHD_CONFIG" > /dev/null
        echo "TrustedUserCAKeys /etc/ssh/vault-ssh-ca.pub" | sudo tee -a "$SSHD_CONFIG" > /dev/null
        echo "AuthorizedPrincipalsFile none" | sudo tee -a "$SSHD_CONFIG" > /dev/null
        echo "PubkeyAuthentication yes" | sudo tee -a "$SSHD_CONFIG" > /dev/null
        echo "  Added TrustedUserCAKeys to sshd_config"
    else
        echo "  TrustedUserCAKeys already configured in sshd_config"
    fi
else
    echo "  Vault SSH CA not mounted, skipping CA configuration"
fi

# Ensure SSH server directories exist
sudo mkdir -p /run/sshd
sudo chmod 0755 /run/sshd

# Generate host keys if they don't exist
sudo ssh-keygen -A 2>/dev/null || true

# Stop existing sshd (which is on port 2222) and restart on new port
if pgrep -x sshd > /dev/null; then
    echo "  Stopping existing SSH server..."
    sudo pkill -x sshd 2>/dev/null || true
    sleep 1
fi

echo "  Starting SSH server on port 22..."
sudo /usr/sbin/sshd 2>/dev/null || true

echo "  SSH server configuration complete"
