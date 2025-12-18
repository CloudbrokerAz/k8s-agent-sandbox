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

# Pre-configure VS Code/code-server to disable workspace trust prompts
mkdir -p /home/node/.local/share/code-server/Machine
cat > /home/node/.local/share/code-server/Machine/settings.json << 'EOF'
{
    "security.workspace.trust.enabled": false,
    "security.workspace.trust.startupPrompt": "never",
    "security.workspace.trust.banner": "never"
}
EOF
chown -R node:node /home/node/.local/share/code-server

# Start code-server
/usr/bin/code-server --auth=none --bind-addr=0.0.0.0:13337 /workspaces/repos
