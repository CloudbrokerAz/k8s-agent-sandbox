# Boundary CLI Environment Configuration
# Source this file: source /Users/simon.lynch/git/k8s-agent-sandbox/k8s/platform/boundary/scripts/boundary-env.sh

# Boundary controller address
export BOUNDARY_ADDR="https://boundary.local"

# Skip TLS verification (for self-signed certs)
export BOUNDARY_TLS_INSECURE=true

# OR use CA certificate (more secure)
# export BOUNDARY_CACERT="/Users/simon.lynch/git/k8s-agent-sandbox/k8s/platform/boundary/scripts/../certs/boundary-ca-bundle.crt"
# unset BOUNDARY_TLS_INSECURE

# Auth methods available:
# OIDC (Keycloak): amoidc_Us9rH7Nwaa

# Convenience aliases
alias boundary-login='boundary authenticate oidc -auth-method-id ${BOUNDARY_OIDC_AUTH_METHOD:-amoidc_Us9rH7Nwaa}'
alias boundary-targets='boundary targets list -recursive -scope-id global'
