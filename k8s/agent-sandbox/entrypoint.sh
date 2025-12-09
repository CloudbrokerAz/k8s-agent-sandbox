#!/bin/bash
# entrypoint.sh - Claude Code Sandbox initialization
# Called by envbuilder after devcontainer build completes
set -e

echo "========================================="
echo "  Claude Code Sandbox Initializing..."
echo "========================================="

# -----------------------------------------------------------------------------
# 1. Configure Vault TLS CA Trust
# -----------------------------------------------------------------------------
if [ -f /vault-ca/vault-ca.crt ]; then
    echo "[1/5] Configuring Vault TLS CA trust..."
    sudo cp /vault-ca/vault-ca.crt /usr/local/share/ca-certificates/vault-ca.crt
    sudo update-ca-certificates 2>/dev/null || true
    echo "  ✓ Vault TLS CA trusted"
else
    echo "[1/5] Vault TLS CA not mounted, skipping..."
fi

# -----------------------------------------------------------------------------
# 2. Configure Vault SSH CA for Certificate Authentication
# -----------------------------------------------------------------------------
if [ -f /vault-ssh-ca/vault-ssh-ca.pub ]; then
    echo "[2/5] Configuring Vault SSH CA..."
    sudo cp /vault-ssh-ca/vault-ssh-ca.pub /etc/ssh/vault-ssh-ca.pub
    sudo chmod 644 /etc/ssh/vault-ssh-ca.pub

    # Add TrustedUserCAKeys to sshd_config if not present
    if ! grep -q "TrustedUserCAKeys /etc/ssh/vault-ssh-ca.pub" /etc/ssh/sshd_config 2>/dev/null; then
        echo "" | sudo tee -a /etc/ssh/sshd_config > /dev/null
        echo "# Vault SSH CA Authentication" | sudo tee -a /etc/ssh/sshd_config > /dev/null
        echo "TrustedUserCAKeys /etc/ssh/vault-ssh-ca.pub" | sudo tee -a /etc/ssh/sshd_config > /dev/null
        echo "AuthorizedPrincipalsFile none" | sudo tee -a /etc/ssh/sshd_config > /dev/null
    fi
    echo "  ✓ Vault SSH CA configured"
else
    echo "[2/5] Vault SSH CA not mounted, skipping..."
fi

# -----------------------------------------------------------------------------
# 3. Ensure SSH Server is Running
# -----------------------------------------------------------------------------
echo "[3/5] Starting SSH server..."
if command -v sshd &> /dev/null; then
    sudo mkdir -p /run/sshd
    sudo chmod 0755 /run/sshd
    sudo ssh-keygen -A 2>/dev/null || true

    if ! pgrep -x sshd > /dev/null; then
        sudo /usr/sbin/sshd
        echo "  ✓ SSH server started on port 22"
    else
        echo "  ✓ SSH server already running"
    fi
else
    echo "  - SSHD not installed"
fi

# -----------------------------------------------------------------------------
# 4. Verify Claude Code Installation
# -----------------------------------------------------------------------------
echo "[4/5] Verifying Claude Code..."
if command -v claude &> /dev/null; then
    CLAUDE_VERSION=$(claude --version 2>/dev/null || echo "installed")
    echo "  ✓ Claude Code: ${CLAUDE_VERSION}"
else
    echo "  - Installing Claude Code..."
    npm install -g @anthropic-ai/claude-code 2>&1 | tail -3
    if command -v claude &> /dev/null; then
        echo "  ✓ Claude Code installed"
    else
        echo "  ✗ Claude Code installation failed"
    fi
fi

# -----------------------------------------------------------------------------
# 5. Start code-server
# -----------------------------------------------------------------------------
echo "[5/5] Starting code-server..."
if command -v code-server &> /dev/null; then
    # Kill any existing instance
    pkill -f "code-server" 2>/dev/null || true
    sleep 1

    # Start code-server in background
    code-server --bind-addr 0.0.0.0:13337 --auth none /workspaces &
    CODE_SERVER_PID=$!
    sleep 2

    if kill -0 $CODE_SERVER_PID 2>/dev/null; then
        echo "  ✓ code-server started on port 13337"
    else
        echo "  ✗ code-server failed to start"
    fi
else
    echo "  - code-server not installed"
fi

# -----------------------------------------------------------------------------
# Print Access Information
# -----------------------------------------------------------------------------
echo ""
echo "========================================="
echo "  Claude Code Sandbox Ready!"
echo "========================================="
echo ""
echo "Access Methods:"
echo "  - code-server: http://localhost:13337 (via port-forward)"
echo "  - SSH: port 22 (via Boundary or port-forward)"
echo "  - kubectl exec: direct shell access"
echo ""
echo "========================================="

# -----------------------------------------------------------------------------
# Keep Container Running
# -----------------------------------------------------------------------------
# Wait for code-server or sshd, fallback to tail
if [[ -n "${CODE_SERVER_PID:-}" ]] && kill -0 $CODE_SERVER_PID 2>/dev/null; then
    wait $CODE_SERVER_PID
elif pgrep -x sshd > /dev/null; then
    wait $(pgrep -x sshd | head -1) 2>/dev/null || exec tail -f /dev/null
else
    exec tail -f /dev/null
fi
