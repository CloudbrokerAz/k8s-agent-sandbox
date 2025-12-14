#!/bin/bash
# entrypoint.sh - Claude Code Sandbox initialization
# Simplified to match vscode-gemini pattern
set -x

# Setup persistent directories within single PVC
mkdir -p /workspaces/.claude-config /workspaces/.bash_history /workspaces/repos
chown -R node:node /workspaces/.claude-config /workspaces/.bash_history /workspaces/repos 2>/dev/null || true

# Create symlink for Claude config (Claude Code expects ~/.claude)
ln -sf /workspaces/.claude-config /home/node/.claude 2>/dev/null || true

# Export environment
export HISTFILE=/workspaces/.bash_history/.bash_history
export CLAUDE_CONFIG_DIR=/workspaces/.claude-config

# Configure Vault TLS CA (if mounted)
if [ -f /vault-ca/vault-ca.crt ]; then
    sudo cp /vault-ca/vault-ca.crt /usr/local/share/ca-certificates/ 2>/dev/null && \
    sudo update-ca-certificates 2>/dev/null || \
    export NODE_EXTRA_CA_CERTS=/vault-ca/vault-ca.crt
fi

# Configure shell profile for interactive logins (ensure claude is in PATH)
if ! grep -q "Claude Code Sandbox" /home/node/.bashrc 2>/dev/null; then
    cat >> /home/node/.bashrc << 'BASHRC'

# Claude Code Sandbox - PATH and environment
export PATH="/usr/local/share/npm-global/bin:$PATH"
export HISTFILE=/workspaces/.bash_history/.bash_history
export CLAUDE_CONFIG_DIR=/workspaces/.claude-config
BASHRC
fi

# Start code-server
/usr/bin/code-server --auth=none --bind-addr=0.0.0.0:13337 /workspaces/repos
