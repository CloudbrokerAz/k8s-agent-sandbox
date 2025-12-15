#!/usr/bin/env python3
"""
Generate self-signed TLS certificates for hashicorp.lab domain migration
and update Kubernetes secret YAML files with base64-encoded values.
"""

import subprocess
import base64
import os
from pathlib import Path

# Certificate configurations
CERTS_CONFIG = [
    {
        'name': 'boundary',
        'domain': 'boundary.hashicorp.lab',
        'san': 'DNS:boundary.hashicorp.lab,DNS:localhost,IP:127.0.0.1',
        'yaml_file': 'k8s/platform/boundary/manifests/09-tls-secret.yaml',
        'namespace': 'boundary',
        'secret_name': 'boundary-tls'
    },
    {
        'name': 'boundary-worker',
        'domain': 'boundary-worker.hashicorp.lab',
        'san': 'DNS:boundary-worker.hashicorp.lab,DNS:localhost,IP:127.0.0.1',
        'yaml_file': 'k8s/platform/boundary/manifests/11-worker-tls-secret.yaml',
        'namespace': 'boundary',
        'secret_name': 'boundary-worker-tls'
    },
    {
        'name': 'keycloak',
        'domain': 'keycloak.hashicorp.lab',
        'san': 'DNS:keycloak.hashicorp.lab,DNS:localhost,IP:127.0.0.1',
        'yaml_file': 'k8s/platform/keycloak/manifests/07-tls-secret.yaml',
        'namespace': 'keycloak',
        'secret_name': 'keycloak-tls'
    },
    {
        'name': 'vault',
        'domain': 'vault.hashicorp.lab',
        'san': 'DNS:vault.hashicorp.lab,DNS:localhost,IP:127.0.0.1',
        'yaml_file': 'k8s/platform/vault/manifests/08-tls-secret.yaml',
        'namespace': 'vault',
        'secret_name': 'vault-tls'
    }
]

TEMP_DIR = '/tmp/hashicorp-lab-certs'
os.makedirs(TEMP_DIR, exist_ok=True)

def generate_certificate(name, domain, san):
    """Generate a self-signed certificate."""
    key_file = os.path.join(TEMP_DIR, f'{name}.key')
    crt_file = os.path.join(TEMP_DIR, f'{name}.crt')

    cmd = [
        'openssl', 'req', '-x509', '-nodes', '-days', '365',
        '-newkey', 'rsa:2048',
        '-keyout', key_file,
        '-out', crt_file,
        '-subj', f'/CN={domain}',
        '-addext', f'subjectAltName={san}'
    ]

    try:
        result = subprocess.run(cmd, capture_output=True, text=True, check=True)
        print(f"✓ Generated certificate for {name}")
        return key_file, crt_file
    except subprocess.CalledProcessError as e:
        print(f"✗ Error generating certificate for {name}: {e.stderr}")
        raise

def base64_encode_file(filepath):
    """Read file and return base64-encoded content."""
    with open(filepath, 'rb') as f:
        return base64.b64encode(f.read()).decode('ascii')

def generate_k8s_secret_yaml(config, crt_b64, key_b64):
    """Generate Kubernetes TLS secret YAML content."""
    yaml_content = f"""# Self-signed TLS certificate for {config['domain']}
# Generated with: openssl req -x509 -nodes -days 365 -newkey rsa:2048 \\
#   -keyout {config['name']}.key -out {config['name']}.crt \\
#   -subj "/CN={config['domain']}" \\
#   -addext "subjectAltName={config['san']}"
apiVersion: v1
kind: Secret
metadata:
  name: {config['secret_name']}
  namespace: {config['namespace']}
  labels:
    app: {config['name'].split('-')[0]}
type: kubernetes.io/tls
data:
  tls.crt: {crt_b64}
  tls.key: {key_b64}
"""
    return yaml_content

def main():
    """Main execution function."""
    print("=" * 60)
    print("Generating self-signed TLS certificates for hashicorp.lab")
    print("=" * 60)
    print()

    # Generate all certificates
    cert_data = {}
    for config in CERTS_CONFIG:
        key_file, crt_file = generate_certificate(
            config['name'],
            config['domain'],
            config['san']
        )

        # Encode to base64
        crt_b64 = base64_encode_file(crt_file)
        key_b64 = base64_encode_file(key_file)

        cert_data[config['name']] = {
            'config': config,
            'crt_b64': crt_b64,
            'key_b64': key_b64,
            'key_file': key_file,
            'crt_file': crt_file
        }

    print()
    print("=" * 60)
    print("Certificate Generation Summary")
    print("=" * 60)
    print()

    # Display certificate details
    for name, data in cert_data.items():
        print(f"Certificate: {data['config']['domain']}")
        print(f"  Subject Alt Names: {data['config']['san']}")
        print(f"  YAML file: {data['config']['yaml_file']}")

        # Show cert details
        crt_file = data['crt_file']
        cmd = ['openssl', 'x509', '-in', crt_file, '-text', '-noout']
        result = subprocess.run(cmd, capture_output=True, text=True)

        # Extract subject and dates
        for line in result.stdout.split('\n'):
            if 'Subject:' in line or 'Not Before' in line or 'Not After' in line or 'DNS:' in line:
                print(f"  {line.strip()}")
        print()

    # Update YAML files
    print("=" * 60)
    print("Updating Kubernetes Secret YAML files...")
    print("=" * 60)
    print()

    updated_files = []
    for name, data in cert_data.items():
        config = data['config']
        yaml_path = config['yaml_file']

        # Generate new YAML content
        yaml_content = generate_k8s_secret_yaml(
            config,
            data['crt_b64'],
            data['key_b64']
        )

        # Write to file
        with open(yaml_path, 'w') as f:
            f.write(yaml_content)

        print(f"✓ Updated: {yaml_path}")
        updated_files.append(yaml_path)

    print()
    print("=" * 60)
    print("Success! All certificates have been generated and YAML files updated")
    print("=" * 60)
    print()
    print(f"Certificate files (temporary): {TEMP_DIR}")
    print()
    print("Updated files:")
    for filepath in updated_files:
        print(f"  - {filepath}")
    print()
    print("Next steps:")
    print("1. Review the updated YAML files")
    print("2. Commit the changes to git")
    print("3. Apply the updated secrets to your Kubernetes cluster")
    print()

if __name__ == '__main__':
    main()
