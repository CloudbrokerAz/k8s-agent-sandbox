#!/bin/bash
set -x

# Setup persistent directories within single PVC
mkdir -p /workspaces/.gemini-config /workspaces/.bash_history /workspaces/repos

# Export environment
export HISTFILE=/workspaces/.bash_history/.bash_history

# Configure Vault TLS CA (if mounted)
if [ -f /vault-ca/vault-ca.crt ]; then
    sudo cp /vault-ca/vault-ca.crt /usr/local/share/ca-certificates/ 2>/dev/null && \
    sudo update-ca-certificates 2>/dev/null || \
    export NODE_EXTRA_CA_CERTS=/vault-ca/vault-ca.crt
fi

# Configure shell profile for interactive logins
cat >> /home/node/.bashrc << 'BASHRC'
# Gemini Sandbox - PATH and environment
export PATH="/usr/local/share/npm-global/bin:$PATH"
export HISTFILE=/workspaces/.bash_history/.bash_history
BASHRC

# Keep container running (sshd is started by the devcontainer sshd feature)
exec sleep infinity
