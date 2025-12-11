#!/bin/bash
set -euo pipefail

# Test Boundary deployment
# Run after deploy-boundary.sh to verify all components are working

NAMESPACE="${1:-boundary}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_PASSED=0
TESTS_FAILED=0
TESTS_TOTAL=0

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

# Test function
run_test() {
    local test_name="$1"
    local test_cmd="$2"

    TESTS_TOTAL=$((TESTS_TOTAL + 1))
    printf "  Testing: %-50s " "$test_name"

    if eval "$test_cmd" > /dev/null 2>&1; then
        echo -e "[${GREEN}PASS${NC}]"
        TESTS_PASSED=$((TESTS_PASSED + 1))
        return 0
    else
        echo -e "[${RED}FAIL${NC}]"
        TESTS_FAILED=$((TESTS_FAILED + 1))
        return 1
    fi
}

# Warning test (doesn't fail the suite)
run_warning_test() {
    local test_name="$1"
    local test_cmd="$2"

    TESTS_TOTAL=$((TESTS_TOTAL + 1))
    printf "  Testing: %-50s " "$test_name"

    if eval "$test_cmd" > /dev/null 2>&1; then
        echo -e "[${GREEN}PASS${NC}]"
        TESTS_PASSED=$((TESTS_PASSED + 1))
        return 0
    else
        echo -e "[${YELLOW}WARN${NC}]"
        TESTS_PASSED=$((TESTS_PASSED + 1))  # Don't count as failure
        return 1
    fi
}

echo "=========================================="
echo "  Boundary Deployment Tests"
echo "=========================================="
echo ""
echo "Namespace: $NAMESPACE"
echo ""

# ==========================================
# Infrastructure Tests
# ==========================================
echo "Infrastructure Tests:"
echo "--------------------------------------------"

run_test "Namespace exists" \
    "kubectl get namespace $NAMESPACE"

run_test "PostgreSQL StatefulSet exists" \
    "kubectl get statefulset boundary-postgres -n $NAMESPACE"

run_test "PostgreSQL pod running" \
    "kubectl get pod -l app=boundary-postgres -n $NAMESPACE -o jsonpath='{.items[0].status.phase}' | grep -q Running"

run_test "Controller Deployment exists" \
    "kubectl get deployment boundary-controller -n $NAMESPACE"

run_test "Controller pod running" \
    "kubectl get pod -l app=boundary-controller -n $NAMESPACE -o jsonpath='{.items[0].status.phase}' | grep -q Running"

run_test "Worker Deployment exists" \
    "kubectl get deployment boundary-worker -n $NAMESPACE"

run_test "Worker pod running" \
    "kubectl get pod -l app=boundary-worker -n $NAMESPACE -o jsonpath='{.items[0].status.phase}' | grep -q Running"

echo ""

# ==========================================
# Secrets Tests
# ==========================================
echo "Secrets Tests:"
echo "--------------------------------------------"

run_test "Database secrets exist" \
    "kubectl get secret boundary-db-secrets -n $NAMESPACE"

run_test "KMS keys secret exists" \
    "kubectl get secret boundary-kms-keys -n $NAMESPACE"

run_warning_test "Enterprise license exists" \
    "kubectl get secret boundary-license -n $NAMESPACE"

run_test "TLS secret exists" \
    "kubectl get secret boundary-tls -n $NAMESPACE"

run_test "Worker TLS secret exists" \
    "kubectl get secret boundary-worker-tls -n $NAMESPACE"

echo ""

# ==========================================
# Service Tests
# ==========================================
echo "Service Tests:"
echo "--------------------------------------------"

run_test "API Service exists" \
    "kubectl get svc boundary-controller-api -n $NAMESPACE"

run_test "Cluster Service exists" \
    "kubectl get svc boundary-controller-cluster -n $NAMESPACE"

run_test "Worker Service exists" \
    "kubectl get svc boundary-worker -n $NAMESPACE"

echo ""

# ==========================================
# Ingress Tests
# ==========================================
echo "Ingress Tests:"
echo "--------------------------------------------"

run_test "Controller Ingress exists" \
    "kubectl get ingress boundary -n $NAMESPACE"

run_test "Worker Ingress exists" \
    "kubectl get ingress boundary-worker -n $NAMESPACE"

run_test "Ingress has address" \
    "kubectl get ingress boundary -n $NAMESPACE -o jsonpath='{.status.loadBalancer.ingress}' | grep -q ."

echo ""

# ==========================================
# API Connectivity Tests
# ==========================================
echo "API Connectivity Tests:"
echo "--------------------------------------------"

# Test via port-forward
run_test "API responds to health check" \
    "kubectl exec -n $NAMESPACE deploy/boundary-controller -c boundary-controller -- wget -q -O- http://localhost:9200/health 2>/dev/null | grep -q ok"

# Test internal service connectivity
run_test "Controller can reach PostgreSQL" \
    "kubectl exec -n $NAMESPACE deploy/boundary-controller -c boundary-controller -- nc -zv boundary-postgres.$NAMESPACE.svc.cluster.local 5432 2>&1 | grep -q succeeded"

# Test worker to controller connectivity
run_test "Worker can reach Controller cluster port" \
    "kubectl exec -n $NAMESPACE deploy/boundary-worker -c boundary-worker -- nc -zv boundary-controller-cluster.$NAMESPACE.svc.cluster.local 9201 2>&1 | grep -q succeeded"

echo ""

# ==========================================
# Configuration Tests
# ==========================================
echo "Configuration Tests:"
echo "--------------------------------------------"

run_test "Controller ConfigMap exists" \
    "kubectl get configmap boundary-config -n $NAMESPACE"

run_test "ConfigMap has controller.hcl" \
    "kubectl get configmap boundary-config -n $NAMESPACE -o jsonpath='{.data.controller\\.hcl}' | grep -q 'controller'"

run_test "ConfigMap has worker.hcl" \
    "kubectl get configmap boundary-config -n $NAMESPACE -o jsonpath='{.data.worker\\.hcl}' | grep -q 'worker'"

echo ""

# ==========================================
# Credentials File Tests
# ==========================================
echo "Credentials Tests:"
echo "--------------------------------------------"

CREDS_FILE="$SCRIPT_DIR/../boundary-credentials.txt"
if [[ -f "$CREDS_FILE" ]]; then
    run_test "Credentials file exists" "true"
    run_test "Credentials file has Auth Method ID" "grep -q 'Auth Method ID:' '$CREDS_FILE'"
    run_test "Credentials file has Password" "grep -q 'Password:' '$CREDS_FILE'"
else
    printf "  Testing: %-50s [${YELLOW}SKIP${NC}]\n" "Credentials file exists"
    echo "           (Run configure-targets.sh to generate)"
fi

echo ""

# ==========================================
# Summary
# ==========================================
echo "=========================================="
echo "  Test Summary"
echo "=========================================="
echo ""

if [[ $TESTS_FAILED -eq 0 ]]; then
    echo -e "  ${GREEN}All tests passed!${NC}"
else
    echo -e "  ${RED}Some tests failed${NC}"
fi
echo ""
echo "  Total:  $TESTS_TOTAL"
echo -e "  Passed: ${GREEN}$TESTS_PASSED${NC}"
echo -e "  Failed: ${RED}$TESTS_FAILED${NC}"
echo ""

# Exit with failure if any tests failed
if [[ $TESTS_FAILED -gt 0 ]]; then
    exit 1
fi
