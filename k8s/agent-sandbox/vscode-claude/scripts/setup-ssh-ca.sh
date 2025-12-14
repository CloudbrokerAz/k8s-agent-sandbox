#!/bin/bash
# setup-ssh-ca.sh - Configure Vault SSH CA for certificate authentication
# This script configures sshd to trust Vault-signed certificates
set -e

echo "Configuring Vault SSH CA..."

# Check if SSH CA public key is mounted
if [ ! -f /vault-ssh-ca/vault-ssh-ca.pub ]; then
    echo "  Vault SSH CA not mounted at /vault-ssh-ca/vault-ssh-ca.pub, skipping..."
    exit 0
fi

# Copy CA public key to SSH config directory
sudo cp /vault-ssh-ca/vault-ssh-ca.pub /etc/ssh/vault-ssh-ca.pub
sudo chmod 644 /etc/ssh/vault-ssh-ca.pub
echo "  Copied vault-ssh-ca.pub to /etc/ssh/"

# Configure sshd to trust Vault CA certificates
SSHD_CONFIG="/etc/ssh/sshd_config"

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

# Ensure SSH server directories exist
sudo mkdir -p /run/sshd
sudo chmod 0755 /run/sshd

# Generate host keys if they don't exist
sudo ssh-keygen -A 2>/dev/null || true

# Start or restart sshd
if pgrep -x sshd > /dev/null; then
    echo "  SSH server already running, reloading config..."
    sudo kill -HUP $(pgrep -x sshd | head -1) 2>/dev/null || true
else
    echo "  Starting SSH server..."
    sudo /usr/sbin/sshd 2>/dev/null || true
fi

echo "  Vault SSH CA configuration complete"
