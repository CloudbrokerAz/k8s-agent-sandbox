#!/bin/bash
set -euo pipefail

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Configuration
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMP_DIR="/tmp/hashicorp-lab-certs-$$"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

# Create temporary directory
mkdir -p "$TEMP_DIR"
trap "rm -rf $TEMP_DIR" EXIT

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}TLS Certificate Generation - hashicorp.lab${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""

# Certificate configurations
declare -a CERTS=(
    "boundary|boundary.hashicorp.lab|DNS:boundary.hashicorp.lab,DNS:localhost,IP:127.0.0.1|k8s/platform/boundary/manifests/09-tls-secret.yaml|boundary|boundary-tls"
    "boundary-worker|boundary-worker.hashicorp.lab|DNS:boundary-worker.hashicorp.lab,DNS:localhost,IP:127.0.0.1|k8s/platform/boundary/manifests/11-worker-tls-secret.yaml|boundary|boundary-worker-tls"
    "keycloak|keycloak.hashicorp.lab|DNS:keycloak.hashicorp.lab,DNS:localhost,IP:127.0.0.1|k8s/platform/keycloak/manifests/07-tls-secret.yaml|keycloak|keycloak-tls"
    "vault|vault.hashicorp.lab|DNS:vault.hashicorp.lab,DNS:localhost,IP:127.0.0.1|k8s/platform/vault/manifests/08-tls-secret.yaml|vault|vault-tls"
)

# Function to generate certificate
generate_cert() {
    local name=$1
    local domain=$2
    local san=$3

    echo -e "${YELLOW}Generating certificate for: $name ($domain)${NC}"

    openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
      -keyout "$TEMP_DIR/$name.key" \
      -out "$TEMP_DIR/$name.crt" \
      -subj "/CN=$domain" \
      -addext "subjectAltName=$san" 2>/dev/null

    echo -e "${GREEN}✓ Certificate generated${NC}"
}

# Function to base64 encode file
encode_b64() {
    base64 < "$1" | tr -d '\n'
}

# Function to update YAML file
update_yaml_file() {
    local name=$1
    local yaml_file=$2
    local domain=$3
    local san=$4
    local namespace=$5
    local secret_name=$6
    local crt_b64=$7
    local key_b64=$8

    # Determine app label
    local app_label=$(echo "$name" | cut -d'-' -f1)

    # Create backup
    if [ -f "$REPO_ROOT/$yaml_file" ]; then
        cp "$REPO_ROOT/$yaml_file" "$REPO_ROOT/$yaml_file.bak-$TIMESTAMP"
        echo -e "${YELLOW}  Backup created: $yaml_file.bak-$TIMESTAMP${NC}"
    fi

    # Create new YAML content
    cat > "$REPO_ROOT/$yaml_file" << EOF
# Self-signed TLS certificate for $domain
# Generated with: openssl req -x509 -nodes -days 365 -newkey rsa:2048 \\
#   -keyout $name.key -out $name.crt \\
#   -subj "/CN=$domain" \\
#   -addext "subjectAltName=$san"
apiVersion: v1
kind: Secret
metadata:
  name: $secret_name
  namespace: $namespace
  labels:
    app: $app_label
type: kubernetes.io/tls
data:
  tls.crt: $crt_b64
  tls.key: $key_b64
EOF

    echo -e "${GREEN}✓ Updated: $yaml_file${NC}"
}

# Generate all certificates
echo -e "${BLUE}Step 1: Generating certificates...${NC}"
echo ""

for cert_config in "${CERTS[@]}"; do
    IFS='|' read -r name domain san yaml_file namespace secret_name <<< "$cert_config"
    generate_cert "$name" "$domain" "$san"
done

echo ""
echo -e "${BLUE}Step 2: Encoding certificates to base64...${NC}"
echo ""

# Update YAML files
for cert_config in "${CERTS[@]}"; do
    IFS='|' read -r name domain san yaml_file namespace secret_name <<< "$cert_config"

    echo -e "${YELLOW}Processing: $name${NC}"

    # Encode files
    crt_b64=$(encode_b64 "$TEMP_DIR/$name.crt")
    key_b64=$(encode_b64 "$TEMP_DIR/$name.key")

    # Update YAML
    update_yaml_file "$name" "$yaml_file" "$domain" "$san" "$namespace" "$secret_name" "$crt_b64" "$key_b64"
done

echo ""
echo -e "${BLUE}Step 3: Certificate verification...${NC}"
echo ""

for cert_config in "${CERTS[@]}"; do
    IFS='|' read -r name domain san yaml_file namespace secret_name <<< "$cert_config"

    echo -e "${YELLOW}$name ($domain):${NC}"
    openssl x509 -in "$TEMP_DIR/$name.crt" -text -noout | grep -E "Subject:|Not Before|Not After|DNS:" | sed 's/^/  /'
    echo ""
done

echo -e "${BLUE}========================================${NC}"
echo -e "${GREEN}✓ Certificate generation complete!${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""

echo -e "${BLUE}Updated files:${NC}"
for cert_config in "${CERTS[@]}"; do
    IFS='|' read -r name domain san yaml_file namespace secret_name <<< "$cert_config"
    echo -e "${GREEN}  ✓ $yaml_file${NC}"
done

echo ""
echo -e "${YELLOW}Next steps:${NC}"
echo "1. Review the updated YAML files with: git diff"
echo "2. Commit the changes: git add k8s/platform/*/manifests/*-tls-secret.yaml && git commit -m 'Update TLS certs for hashicorp.lab'"
echo "3. Apply to Kubernetes:"
echo "   kubectl apply -f k8s/platform/boundary/manifests/09-tls-secret.yaml"
echo "   kubectl apply -f k8s/platform/boundary/manifests/11-worker-tls-secret.yaml"
echo "   kubectl apply -f k8s/platform/keycloak/manifests/07-tls-secret.yaml"
echo "   kubectl apply -f k8s/platform/vault/manifests/08-tls-secret.yaml"
echo ""
echo -e "${YELLOW}Temporary certificate files (will be deleted):${NC}"
echo "  $TEMP_DIR"
echo ""
