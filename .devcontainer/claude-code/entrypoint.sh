#!/bin/bash
# Entrypoint script for Claude Code Sandbox (used by envbuilder in Kubernetes)
# Configures Vault CA trust, SSH CA authentication, and starts services
set -e

echo "========================================="
echo "Claude Code Sandbox Initializing..."
echo "========================================="

# Configure Vault TLS CA trust (for HTTPS to Vault)
if [ -f /vault-ca/vault-ca.crt ]; then
    echo "[1/5] Configuring Vault TLS CA trust..."
    sudo cp /vault-ca/vault-ca.crt /usr/local/share/ca-certificates/vault-ca.crt
    sudo update-ca-certificates 2>/dev/null || true
    echo "  ✓ Vault TLS CA trusted"
else
    echo "[1/5] Vault TLS CA not found, skipping..."
fi

# Configure Vault SSH CA for certificate-based authentication
if [ -f /vault-ssh-ca/vault-ssh-ca.pub ]; then
    echo "[2/5] Configuring Vault SSH CA..."
    sudo cp /vault-ssh-ca/vault-ssh-ca.pub /etc/ssh/vault-ssh-ca.pub
    sudo chmod 644 /etc/ssh/vault-ssh-ca.pub

    # Configure SSHD for Vault CA-signed key authentication
    if ! grep -q "TrustedUserCAKeys /etc/ssh/vault-ssh-ca.pub" /etc/ssh/sshd_config 2>/dev/null; then
        sudo tee -a /etc/ssh/sshd_config > /dev/null << 'SSHD_APPEND'

# Vault CA signed key authentication
TrustedUserCAKeys /etc/ssh/vault-ssh-ca.pub
AuthorizedPrincipalsFile none
SSHD_APPEND
    fi
    echo "  ✓ Vault SSH CA configured"
else
    echo "[2/5] Vault SSH CA not found, skipping..."
fi

# Ensure SSH server is running
echo "[3/5] Starting SSH server..."
if command -v sshd &> /dev/null; then
    # Create runtime directory
    sudo mkdir -p /run/sshd
    sudo chmod 0755 /run/sshd

    # Generate host keys if missing
    sudo ssh-keygen -A 2>/dev/null || true

    # Start SSHD if not already running
    if ! pgrep -x sshd > /dev/null; then
        sudo /usr/sbin/sshd
        echo "  ✓ SSH server started"
    else
        echo "  ✓ SSH server already running"
    fi
else
    echo "  - SSHD not installed, skipping..."
fi

# Verify Claude Code installation
echo "[4/5] Verifying Claude Code..."
if command -v claude &> /dev/null; then
    echo "  ✓ Claude Code installed: $(claude --version 2>/dev/null || echo 'available')"
else
    echo "  - Claude Code not found, installing..."
    npm install -g @anthropic-ai/claude-code 2>&1 | tail -5
    if command -v claude &> /dev/null; then
        echo "  ✓ Claude Code installed successfully"
    else
        echo "  ✗ Claude Code installation failed"
    fi
fi

# Start code-server (devcontainer feature should have installed it)
echo "[5/5] Starting code-server..."
if command -v code-server &> /dev/null; then
    # Kill any existing code-server process
    pkill -f code-server 2>/dev/null || true
    sleep 1

    # Start code-server in background
    code-server --bind-addr 0.0.0.0:13337 --auth none /workspace &
    CODE_SERVER_PID=$!
    sleep 2

    if kill -0 $CODE_SERVER_PID 2>/dev/null; then
        echo "  ✓ code-server started on port 13337"
    else
        echo "  ✗ code-server failed to start"
    fi
else
    echo "  - code-server not installed, skipping..."
fi

echo "========================================="
echo "Claude Code Sandbox Ready!"
echo ""
echo "Access methods:"
echo "  kubectl exec: kubectl exec -it claude-code-sandbox-0 -n devenv -- /bin/bash"
echo "  SSH:          boundary connect ssh -target-id=<target> -- -l node"
echo "  code-server:  kubectl port-forward svc/claude-code-sandbox 13337:13337 -n devenv"
echo "========================================="

# Keep container running - wait for SSHD or code-server
if pgrep -x sshd > /dev/null; then
    # Wait for SSHD
    wait $(pgrep -x sshd | head -1) 2>/dev/null || exec tail -f /dev/null
elif [[ -n "${CODE_SERVER_PID:-}" ]]; then
    # Wait for code-server
    wait $CODE_SERVER_PID 2>/dev/null || exec tail -f /dev/null
else
    # Fallback - keep container running
    exec tail -f /dev/null
fi
