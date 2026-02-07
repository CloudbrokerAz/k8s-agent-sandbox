#!/bin/bash
# entrypoint.sh - Claude Code Sandbox initialization
# Simplified to match vscode-gemini pattern - just start code-server
set -x

# Setup persistent directories within single PVC
mkdir -p /workspaces/.claude-config /workspaces/.bash_history /workspaces/repos
chown -R node:node /workspaces/.claude-config /workspaces/.bash_history /workspaces/repos 2>/dev/null || true

# Create symlink for Claude config (Claude Code expects ~/.claude)
ln -sf /workspaces/.claude-config /home/node/.claude 2>/dev/null || true

# Configure Vault TLS CA (if mounted)
if [ -f /vault-ca/vault-ca.crt ]; then
    sudo cp /vault-ca/vault-ca.crt /usr/local/share/ca-certificates/ 2>/dev/null && \
    sudo update-ca-certificates 2>/dev/null || \
    export NODE_EXTRA_CA_CERTS=/vault-ca/vault-ca.crt
fi

# Configure shell profile for login shells (PATH must be in .profile, not .bashrc)
# .bashrc exits early for non-interactive shells, so PATH export there is unreliable
cat >> /home/node/.profile << 'PROFILE'

# npm-global bin for Claude Code CLI
if [ -d "/usr/local/share/npm-global/bin" ]; then
    PATH="/usr/local/share/npm-global/bin:$PATH"
fi
export HISTFILE=/workspaces/.bash_history/.bash_history
PROFILE

# Keep container running (sshd is started by the devcontainer sshd feature)
exec sleep infinity
