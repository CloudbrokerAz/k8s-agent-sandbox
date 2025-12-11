#!/bin/bash
set -euo pipefail

# Setup local client for Boundary external access
# This script:
# 1. Exports TLS certificates from the cluster
# 2. Configures the local system to trust them
# 3. Sets up environment variables for Boundary CLI

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CERTS_DIR="$SCRIPT_DIR/../certs"
NAMESPACE="${1:-boundary}"

echo "=========================================="
echo "  Boundary Client Setup"
echo "=========================================="
echo ""

# Check for kubectl
if ! command -v kubectl &> /dev/null; then
    echo "❌ kubectl is required but not installed"
    exit 1
fi

# Check cluster connectivity
if ! kubectl cluster-info &> /dev/null; then
    echo "❌ Cannot connect to Kubernetes cluster"
    exit 1
fi

echo "✅ Connected to Kubernetes cluster"
echo ""

# Create certs directory
mkdir -p "$CERTS_DIR"

echo "📜 Exporting TLS certificates..."
echo ""

# Export Boundary controller TLS certificate
if kubectl get secret boundary-tls -n "$NAMESPACE" &>/dev/null; then
    kubectl get secret boundary-tls -n "$NAMESPACE" -o jsonpath='{.data.tls\.crt}' | base64 -d > "$CERTS_DIR/boundary.crt"
    echo "  ✅ Controller cert: $CERTS_DIR/boundary.crt"
else
    echo "  ⚠️  Controller TLS secret not found"
fi

# Export Boundary worker TLS certificate
if kubectl get secret boundary-worker-tls -n "$NAMESPACE" &>/dev/null; then
    kubectl get secret boundary-worker-tls -n "$NAMESPACE" -o jsonpath='{.data.tls\.crt}' | base64 -d > "$CERTS_DIR/boundary-worker.crt"
    echo "  ✅ Worker cert: $CERTS_DIR/boundary-worker.crt"
else
    echo "  ⚠️  Worker TLS secret not found"
fi

# Combine certificates into a CA bundle
cat "$CERTS_DIR/boundary.crt" "$CERTS_DIR/boundary-worker.crt" > "$CERTS_DIR/boundary-ca-bundle.crt" 2>/dev/null || true
echo "  ✅ CA bundle: $CERTS_DIR/boundary-ca-bundle.crt"

echo ""
echo "🔧 Checking /etc/hosts entries..."

# Check for hosts entries
HOSTS_ENTRIES="127.0.0.1 boundary.local boundary-worker.local"
if grep -q "boundary.local" /etc/hosts; then
    echo "  ✅ /etc/hosts entries already exist"
else
    echo "  ⚠️  Missing /etc/hosts entries. Add the following:"
    echo ""
    echo "    sudo sh -c 'echo \"$HOSTS_ENTRIES\" >> /etc/hosts'"
    echo ""
fi

# Get auth method info
echo ""
echo "🔐 Fetching Boundary configuration..."
AUTH_METHODS=$(curl -sk "https://boundary.local/v1/auth-methods?scope_id=global" 2>/dev/null || echo "{}")
OIDC_AUTH_METHOD=$(echo "$AUTH_METHODS" | jq -r '.items[]? | select(.type=="oidc") | .id' 2>/dev/null || echo "")
PASSWORD_AUTH_METHOD=$(echo "$AUTH_METHODS" | jq -r '.items[]? | select(.type=="password") | .id' 2>/dev/null || echo "")

echo ""
echo "=========================================="
echo "  Client Configuration"
echo "=========================================="
echo ""

# Create shell profile snippet
cat > "$SCRIPT_DIR/boundary-env.sh" << EOF
# Boundary CLI Environment Configuration
# Source this file: source $SCRIPT_DIR/boundary-env.sh

# Boundary controller address
export BOUNDARY_ADDR="https://boundary.local"

# Skip TLS verification (for self-signed certs)
export BOUNDARY_TLS_INSECURE=true

# OR use CA certificate (more secure)
# export BOUNDARY_CACERT="$CERTS_DIR/boundary-ca-bundle.crt"
# unset BOUNDARY_TLS_INSECURE

# Auth methods available:
EOF

if [[ -n "$OIDC_AUTH_METHOD" ]]; then
    echo "# OIDC (Keycloak): $OIDC_AUTH_METHOD" >> "$SCRIPT_DIR/boundary-env.sh"
fi
if [[ -n "$PASSWORD_AUTH_METHOD" ]]; then
    echo "# Password: $PASSWORD_AUTH_METHOD" >> "$SCRIPT_DIR/boundary-env.sh"
fi

cat >> "$SCRIPT_DIR/boundary-env.sh" << 'EOF'

# Convenience aliases
alias boundary-login='boundary authenticate oidc -auth-method-id ${BOUNDARY_OIDC_AUTH_METHOD:-amoidc_Us9rH7Nwaa}'
alias boundary-targets='boundary targets list -recursive -scope-id global'
EOF

chmod +x "$SCRIPT_DIR/boundary-env.sh"
echo "✅ Environment file created: $SCRIPT_DIR/boundary-env.sh"

echo ""
echo "=========================================="
echo "  Usage Instructions"
echo "=========================================="
echo ""
echo "1. Source the environment file:"
echo "   source $SCRIPT_DIR/boundary-env.sh"
echo ""
echo "2. Authenticate via OIDC (Keycloak):"
if [[ -n "$OIDC_AUTH_METHOD" ]]; then
    echo "   boundary authenticate oidc -auth-method-id $OIDC_AUTH_METHOD"
else
    echo "   (OIDC auth method not found - check Keycloak configuration)"
fi
echo ""
if [[ -n "$PASSWORD_AUTH_METHOD" ]]; then
    echo "3. Or authenticate with password:"
    echo "   boundary authenticate password -auth-method-id $PASSWORD_AUTH_METHOD -login-name admin"
    echo ""
fi
echo "4. List available targets:"
echo "   boundary targets list -recursive -scope-id global"
echo ""
echo "5. Connect to SSH target:"
echo "   boundary connect ssh -target-id <target_id>"
echo ""
echo "=========================================="
echo "  macOS Keychain Trust (Optional)"
echo "=========================================="
echo ""
echo "To add certificates to macOS system trust:"
echo ""
echo "  sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain $CERTS_DIR/boundary.crt"
echo "  sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain $CERTS_DIR/boundary-worker.crt"
echo ""
echo "Or use BOUNDARY_TLS_INSECURE=true (less secure but simpler)"
echo ""
