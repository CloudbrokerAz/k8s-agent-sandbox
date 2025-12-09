#!/bin/bash
# Keycloak Deployment Validation Script

echo "============================================"
echo "Keycloak Deployment Validation"
echo "============================================"
echo ""

PASSED=0
FAILED=0

check() {
    if [ $? -eq 0 ]; then
        echo "  ✓ PASS: $1"
        ((PASSED++))
    else
        echo "  ✗ FAIL: $1"
        ((FAILED++))
    fi
}

# Check kubectl
kubectl version --client > /dev/null 2>&1
check "kubectl is installed"

# Check if manifests exist
echo ""
echo "Checking manifest files..."
test -f "../manifests/01-namespace.yaml"
check "01-namespace.yaml exists"
test -f "../manifests/02-secrets.yaml"
check "02-secrets.yaml exists"
test -f "../manifests/03-postgres.yaml"
check "03-postgres.yaml exists"
test -f "../manifests/04-deployment.yaml"
check "04-deployment.yaml exists"
test -f "../manifests/05-service.yaml"
check "05-service.yaml exists"

# Check if scripts are executable
echo ""
echo "Checking script permissions..."
test -x "deploy-keycloak.sh"
check "deploy-keycloak.sh is executable"
test -x "configure-realm.sh"
check "configure-realm.sh is executable"
test -x "teardown-keycloak.sh"
check "teardown-keycloak.sh is executable"
test -x "boundary-oidc-setup.sh"
check "boundary-oidc-setup.sh is executable"

# Check if documentation exists
echo ""
echo "Checking documentation..."
test -f "../README.md"
check "README.md exists"
test -f "../QUICKSTART.md"
check "QUICKSTART.md exists"
test -f "../BOUNDARY_INTEGRATION.md"
check "BOUNDARY_INTEGRATION.md exists"

# Validate YAML syntax
echo ""
echo "Validating YAML syntax..."
for manifest in ../manifests/*.yaml; do
    if [[ $(basename "$manifest") != "kustomization.yaml" ]]; then
        kubectl apply --dry-run=client -f "$manifest" > /dev/null 2>&1
        check "$(basename $manifest) is valid YAML"
    fi
done

echo ""
echo "============================================"
echo "Validation Summary"
echo "============================================"
echo "Passed: $PASSED"
echo "Failed: $FAILED"
echo ""

if [ $FAILED -eq 0 ]; then
    echo "✓ All checks passed! Ready to deploy."
    exit 0
else
    echo "✗ Some checks failed. Please review."
    exit 1
fi
