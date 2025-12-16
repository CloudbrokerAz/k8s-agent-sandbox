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

# Configure Vault SSH CA - point directly to mount path
# VSO will sync the secret and rolloutRestartTargets will restart the pod
VAULT_CA_MOUNT="/vault-ssh-ca/vault-ssh-ca.pub"

# Remove any existing TrustedUserCAKeys configuration (may point to wrong path)
if grep -q "TrustedUserCAKeys" "$SSHD_CONFIG" 2>/dev/null; then
    echo "  Removing existing TrustedUserCAKeys configuration..."
    sudo sed -i '/# Vault SSH CA Authentication/d' "$SSHD_CONFIG"
    sudo sed -i '/# Points directly to mounted secret/d' "$SSHD_CONFIG"
    sudo sed -i '/TrustedUserCAKeys/d' "$SSHD_CONFIG"
    sudo sed -i '/AuthorizedPrincipalsFile none/d' "$SSHD_CONFIG"
    sudo sed -i '/AllowTcpForwarding yes/d' "$SSHD_CONFIG"
    sudo sed -i '/# Vault CA signed key authentication/d' "$SSHD_CONFIG"
fi

# Add TrustedUserCAKeys pointing to mount path
echo "" | sudo tee -a "$SSHD_CONFIG" > /dev/null
echo "# Vault SSH CA Authentication - Added by setup-ssh-ca.sh" | sudo tee -a "$SSHD_CONFIG" > /dev/null
echo "# Points directly to mounted secret path (synced by VSO)" | sudo tee -a "$SSHD_CONFIG" > /dev/null
echo "TrustedUserCAKeys $VAULT_CA_MOUNT" | sudo tee -a "$SSHD_CONFIG" > /dev/null
echo "AuthorizedPrincipalsFile none" | sudo tee -a "$SSHD_CONFIG" > /dev/null
echo "AllowTcpForwarding yes" | sudo tee -a "$SSHD_CONFIG" > /dev/null
echo "LogLevel DEBUG3" | sudo tee -a "$SSHD_CONFIG" > /dev/null
echo "  Configured TrustedUserCAKeys to use mount path: $VAULT_CA_MOUNT"
echo "  Enabled TCP forwarding"
echo "  Enabled DEBUG3 logging"

# Setup SSH logging to file (since rsyslog is not running)
SSH_LOG_DIR="/var/log/ssh"
sudo mkdir -p "$SSH_LOG_DIR"
sudo chmod 755 "$SSH_LOG_DIR"
echo "  Created SSH log directory: $SSH_LOG_DIR"

if [ -f "$VAULT_CA_MOUNT" ]; then
    echo "  Vault SSH CA is available at mount path"
else
    echo "  Vault SSH CA not yet mounted (will be available after VSO sync)"
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

echo "  Starting SSH server on port 22 with logging..."
# Start sshd with logging to file (-E option) for debugging
sudo /usr/sbin/sshd -E /var/log/ssh/sshd.log 2>/dev/null || true
echo "  SSH logs available at: /var/log/ssh/sshd.log"

echo "  SSH server configuration complete"
