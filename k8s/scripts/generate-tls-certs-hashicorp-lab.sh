#!/bin/bash
# Generate self-signed TLS certificates for hashicorp.lab domain migration
# This script generates certificates and base64-encodes them for Kubernetes secrets

set -e

TEMP_DIR="/tmp/hashicorp-lab-certs"
mkdir -p "$TEMP_DIR"

echo "Generating self-signed TLS certificates for hashicorp.lab domain..."

# Function to generate certificate and encode
generate_and_encode_cert() {
    local service=$1
    local domain=$2
    local san=$3

    echo "Generating certificate for $service ($domain)..."

    openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
      -keyout "$TEMP_DIR/$service.key" \
      -out "$TEMP_DIR/$service.crt" \
      -subj "/CN=$domain" \
      -addext "subjectAltName=$san"

    # Base64 encode the files
    CRT_B64=$(base64 < "$TEMP_DIR/$service.crt" | tr -d '\n')
    KEY_B64=$(base64 < "$TEMP_DIR/$service.key" | tr -d '\n')

    echo "  Certificate generated and encoded"

    # Output the base64 values
    echo "TLS_CRT_$service=$CRT_B64" >> "$TEMP_DIR/encoded-values.txt"
    echo "TLS_KEY_$service=$KEY_B64" >> "$TEMP_DIR/encoded-values.txt"
}

# Generate all four certificates
generate_and_encode_cert "boundary" "boundary.hashicorp.lab" "DNS:boundary.hashicorp.lab,DNS:localhost,IP:127.0.0.1"
generate_and_encode_cert "boundary-worker" "boundary-worker.hashicorp.lab" "DNS:boundary-worker.hashicorp.lab,DNS:localhost,IP:127.0.0.1"
generate_and_encode_cert "keycloak" "keycloak.hashicorp.lab" "DNS:keycloak.hashicorp.lab,DNS:localhost,IP:127.0.0.1"
generate_and_encode_cert "vault" "vault.hashicorp.lab" "DNS:vault.hashicorp.lab,DNS:localhost,IP:127.0.0.1"

echo ""
echo "==================================================="
echo "Certificates generated successfully!"
echo "==================================================="
echo ""
echo "Encoded values saved to: $TEMP_DIR/encoded-values.txt"
echo ""
echo "Next steps:"
echo "1. Review the encoded values in: $TEMP_DIR/encoded-values.txt"
echo "2. Update the following Kubernetes secret files:"
echo "   - k8s/platform/boundary/manifests/09-tls-secret.yaml"
echo "   - k8s/platform/boundary/manifests/11-worker-tls-secret.yaml"
echo "   - k8s/platform/keycloak/manifests/07-tls-secret.yaml"
echo "   - k8s/platform/vault/manifests/08-tls-secret.yaml"
echo ""
echo "Certificate details:"
echo "  boundary:       $TEMP_DIR/boundary.{crt,key}"
echo "  boundary-worker: $TEMP_DIR/boundary-worker.{crt,key}"
echo "  keycloak:       $TEMP_DIR/keycloak.{crt,key}"
echo "  vault:          $TEMP_DIR/vault.{crt,key}"
echo ""

# Display the file contents for verification
echo "Certificate Information:"
echo "========================"
for service in boundary boundary-worker keycloak vault; do
    echo ""
    echo "--- $service ---"
    openssl x509 -in "$TEMP_DIR/$service.crt" -text -noout | grep -E "Subject:|DNS:|CN="
done
