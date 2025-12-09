#!/bin/bash
set -euo pipefail

# Create Kubernetes secrets for dev environment
# This script prompts for sensitive values and creates the secret

NAMESPACE="devenv"

echo "Creating secrets for namespace: ${NAMESPACE}"
echo ""
echo "You'll be prompted to enter sensitive values."
echo "Press Enter to skip optional values."
echo ""

# Function to read secret value
read_secret() {
  local var_name="$1"
  local is_required="${2:-false}"
  local value=""

  while true; do
    read -sp "${var_name}: " value
    echo ""

    if [ -z "$value" ]; then
      if [ "$is_required" = "true" ]; then
        echo "This value is required. Please try again."
        continue
      else
        echo "Skipping ${var_name} (optional)"
        break
      fi
    else
      break
    fi
  done

  echo "$value"
}

# Read required secrets
GITHUB_TOKEN=$(read_secret "GITHUB_TOKEN" "true")
TFE_TOKEN=$(read_secret "TFE_TOKEN" "true")
AWS_ACCESS_KEY_ID=$(read_secret "AWS_ACCESS_KEY_ID" "true")
AWS_SECRET_ACCESS_KEY=$(read_secret "AWS_SECRET_ACCESS_KEY" "true")

# Read optional secrets
AWS_SESSION_TOKEN=$(read_secret "AWS_SESSION_TOKEN (optional)" "false")
LANGFUSE_HOST=$(read_secret "LANGFUSE_HOST (optional)" "false")
LANGFUSE_PUBLIC_KEY=$(read_secret "LANGFUSE_PUBLIC_KEY (optional)" "false")
LANGFUSE_SECRET_KEY=$(read_secret "LANGFUSE_SECRET_KEY (optional)" "false")

echo ""
echo "Creating namespace if it doesn't exist..."
kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

echo ""
echo "Creating secret..."

# Build kubectl command
CMD="kubectl create secret generic devenv-secrets -n ${NAMESPACE}"
CMD="${CMD} --from-literal=GITHUB_TOKEN='${GITHUB_TOKEN}'"
CMD="${CMD} --from-literal=TFE_TOKEN='${TFE_TOKEN}'"
CMD="${CMD} --from-literal=AWS_ACCESS_KEY_ID='${AWS_ACCESS_KEY_ID}'"
CMD="${CMD} --from-literal=AWS_SECRET_ACCESS_KEY='${AWS_SECRET_ACCESS_KEY}'"

[ -n "$AWS_SESSION_TOKEN" ] && CMD="${CMD} --from-literal=AWS_SESSION_TOKEN='${AWS_SESSION_TOKEN}'"
[ -n "$LANGFUSE_HOST" ] && CMD="${CMD} --from-literal=LANGFUSE_HOST='${LANGFUSE_HOST}'"
[ -n "$LANGFUSE_PUBLIC_KEY" ] && CMD="${CMD} --from-literal=LANGFUSE_PUBLIC_KEY='${LANGFUSE_PUBLIC_KEY}'"
[ -n "$LANGFUSE_SECRET_KEY" ] && CMD="${CMD} --from-literal=LANGFUSE_SECRET_KEY='${LANGFUSE_SECRET_KEY}'"

CMD="${CMD} --dry-run=client -o yaml | kubectl apply -f -"

# Execute (using eval to handle the pipe)
eval "$CMD"

echo ""
echo "✅ Secrets created successfully in namespace: ${NAMESPACE}"
echo ""
echo "Verify with: kubectl get secrets -n ${NAMESPACE}"
