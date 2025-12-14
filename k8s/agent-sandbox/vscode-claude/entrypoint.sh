#!/bin/bash
# entrypoint.sh - Claude Code Sandbox initialization
# Simplified to match vscode-gemini pattern - just start code-server
set -x

# Setup persistent directories within single PVC
mkdir -p /workspaces/.claude-config /workspaces/.bash_history /workspaces/repos
chown -R node:node /workspaces/.claude-config /workspaces/.bash_history /workspaces/repos 2>/dev/null || true

# Create symlink for Claude config (Claude Code expects ~/.claude)
ln -sf /workspaces/.claude-config /home/node/.claude 2>/dev/null || true

# Start code-server
/usr/bin/code-server --auth=none --bind-addr=0.0.0.0:13337 /workspaces/repos
