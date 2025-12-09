#!/bin/bash
set -euo pipefail

# Test script to verify Keycloak IDP deployment and configuration
# Tests deployment, realm, users, groups, and OIDC endpoints

KEYCLOAK_NAMESPACE="${1:-keycloak}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
K8S_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

PASSED=0
FAILED=0
WARNINGS=0

test_pass() {
    echo -e "${GREEN}✅ PASS${NC}: $1"
    PASSED=$((PASSED + 1))
}

test_fail() {
    echo -e "${RED}❌ FAIL${NC}: $1"
    FAILED=$((FAILED + 1))
}

test_warn() {
    echo -e "${YELLOW}⚠️  WARN${NC}: $1"
    WARNINGS=$((WARNINGS + 1))
}

test_info() {
    echo -e "${BLUE}ℹ️  INFO${NC}: $1"
}

echo "=========================================="
echo "  Keycloak IDP Test Suite"
echo "=========================================="
echo ""

# ==========================================
# Infrastructure Tests
# ==========================================
echo "--- Infrastructure Tests ---"

# Check namespace
if kubectl get namespace "$KEYCLOAK_NAMESPACE" &>/dev/null; then
    test_pass "Keycloak namespace exists"
else
    test_fail "Keycloak namespace does not exist"
    echo "Keycloak not deployed. Exiting."
    exit 1
fi

# Check PostgreSQL
POSTGRES_STATUS=$(kubectl get pod -l app=keycloak-postgres -n "$KEYCLOAK_NAMESPACE" -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "NotFound")
if [[ "$POSTGRES_STATUS" == "Running" ]]; then
    test_pass "Keycloak PostgreSQL running"
else
    test_fail "Keycloak PostgreSQL status: $POSTGRES_STATUS"
fi

# Check PostgreSQL PVC
if kubectl get pvc -l app=keycloak-postgres -n "$KEYCLOAK_NAMESPACE" -o jsonpath='{.items[0].status.phase}' 2>/dev/null | grep -q "Bound"; then
    test_pass "PostgreSQL PVC bound"
else
    test_warn "PostgreSQL PVC not bound"
fi

# Check Keycloak deployment
KEYCLOAK_STATUS=$(kubectl get pod -l app=keycloak -n "$KEYCLOAK_NAMESPACE" -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "NotFound")
if [[ "$KEYCLOAK_STATUS" == "Running" ]]; then
    test_pass "Keycloak pod running"
else
    test_fail "Keycloak pod status: $KEYCLOAK_STATUS"
fi

# Check ready status
KEYCLOAK_READY=$(kubectl get pod -l app=keycloak -n "$KEYCLOAK_NAMESPACE" -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "False")
if [[ "$KEYCLOAK_READY" == "True" ]]; then
    test_pass "Keycloak pod ready"
else
    test_warn "Keycloak pod not ready yet"
fi

# Check services
if kubectl get svc keycloak -n "$KEYCLOAK_NAMESPACE" &>/dev/null; then
    test_pass "Keycloak service exists"
else
    test_fail "Keycloak service missing"
fi

echo ""

# ==========================================
# Connectivity Tests
# ==========================================
echo "--- Connectivity Tests ---"

KEYCLOAK_POD=$(kubectl get pod -l app=keycloak -n "$KEYCLOAK_NAMESPACE" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

if [[ -n "$KEYCLOAK_POD" ]]; then
    # Test Keycloak HTTP port
    if kubectl exec -n "$KEYCLOAK_NAMESPACE" "$KEYCLOAK_POD" -- curl -sf http://127.0.0.1:8080/health/ready &>/dev/null; then
        test_pass "Keycloak health endpoint responding"
    else
        test_warn "Keycloak health endpoint not responding"
    fi

    # Test database connectivity
    if kubectl exec -n "$KEYCLOAK_NAMESPACE" "$KEYCLOAK_POD" -- nc -z keycloak-postgres.keycloak.svc.cluster.local 5432 2>/dev/null; then
        test_pass "Database connectivity from Keycloak"
    else
        test_fail "Cannot reach database from Keycloak"
    fi
fi

echo ""

# ==========================================
# Configuration Tests
# ==========================================
echo "--- Configuration Tests ---"

# Get admin credentials
ADMIN_PASSWORD=$(kubectl get secret keycloak-admin -n "$KEYCLOAK_NAMESPACE" -o jsonpath='{.data.KEYCLOAK_ADMIN_PASSWORD}' 2>/dev/null | base64 -d || echo "")

if [[ -z "$ADMIN_PASSWORD" ]]; then
    test_warn "Cannot find admin password secret"
else
    test_pass "Admin credentials secret exists"

    if [[ -n "$KEYCLOAK_POD" ]]; then
        # Get admin token
        TOKEN=$(kubectl exec -n "$KEYCLOAK_NAMESPACE" "$KEYCLOAK_POD" -- \
            curl -sf -X POST "http://127.0.0.1:8080/realms/master/protocol/openid-connect/token" \
            -H "Content-Type: application/x-www-form-urlencoded" \
            -d "username=admin" \
            -d "password=$ADMIN_PASSWORD" \
            -d "grant_type=password" \
            -d "client_id=admin-cli" 2>/dev/null | jq -r '.access_token' || echo "")

        if [[ -n "$TOKEN" ]] && [[ "$TOKEN" != "null" ]]; then
            test_pass "Admin authentication successful"

            # Check for boundary realm
            REALMS=$(kubectl exec -n "$KEYCLOAK_NAMESPACE" "$KEYCLOAK_POD" -- \
                curl -sf "http://127.0.0.1:8080/admin/realms" \
                -H "Authorization: Bearer $TOKEN" 2>/dev/null | jq -r '.[].realm' || echo "")

            if echo "$REALMS" | grep -q "boundary"; then
                test_pass "Boundary realm exists"

                # Check realm clients
                CLIENTS=$(kubectl exec -n "$KEYCLOAK_NAMESPACE" "$KEYCLOAK_POD" -- \
                    curl -sf "http://127.0.0.1:8080/admin/realms/boundary/clients" \
                    -H "Authorization: Bearer $TOKEN" 2>/dev/null | jq -r '.[].clientId' || echo "")

                if echo "$CLIENTS" | grep -q "boundary"; then
                    test_pass "Boundary OIDC client configured"
                else
                    test_warn "Boundary OIDC client not found"
                fi

                # Check users
                USERS=$(kubectl exec -n "$KEYCLOAK_NAMESPACE" "$KEYCLOAK_POD" -- \
                    curl -sf "http://127.0.0.1:8080/admin/realms/boundary/users" \
                    -H "Authorization: Bearer $TOKEN" 2>/dev/null | jq -r '.[].username' || echo "")

                USER_COUNT=$(echo "$USERS" | grep -v '^$' | wc -l)
                if [[ "$USER_COUNT" -ge 3 ]]; then
                    test_pass "Demo users configured ($USER_COUNT users found)"
                else
                    test_warn "Demo users not configured (found $USER_COUNT)"
                fi

                # Check groups
                GROUPS=$(kubectl exec -n "$KEYCLOAK_NAMESPACE" "$KEYCLOAK_POD" -- \
                    curl -sf "http://127.0.0.1:8080/admin/realms/boundary/groups" \
                    -H "Authorization: Bearer $TOKEN" 2>/dev/null | jq -r '.[].name' || echo "")

                GROUP_COUNT=$(echo "$GROUPS" | grep -v '^$' | wc -l)
                if [[ "$GROUP_COUNT" -ge 3 ]]; then
                    test_pass "Groups configured ($GROUP_COUNT groups found)"
                else
                    test_warn "Groups not configured (found $GROUP_COUNT)"
                fi
            else
                test_warn "Boundary realm not configured (run configure-realm.sh)"
            fi
        else
            test_fail "Admin authentication failed"
        fi
    fi
fi

echo ""

# ==========================================
# OIDC Endpoint Tests
# ==========================================
echo "--- OIDC Endpoint Tests ---"

if [[ -n "$KEYCLOAK_POD" ]]; then
    # Test OIDC discovery endpoint
    DISCOVERY=$(kubectl exec -n "$KEYCLOAK_NAMESPACE" "$KEYCLOAK_POD" -- \
        curl -sf "http://127.0.0.1:8080/realms/boundary/.well-known/openid-configuration" 2>/dev/null || echo "")

    if [[ -n "$DISCOVERY" ]] && echo "$DISCOVERY" | jq -e '.issuer' &>/dev/null; then
        test_pass "OIDC discovery endpoint available"

        ISSUER=$(echo "$DISCOVERY" | jq -r '.issuer')
        test_info "Issuer: $ISSUER"

        # Check required endpoints
        AUTH_ENDPOINT=$(echo "$DISCOVERY" | jq -r '.authorization_endpoint // empty')
        TOKEN_ENDPOINT=$(echo "$DISCOVERY" | jq -r '.token_endpoint // empty')
        USERINFO_ENDPOINT=$(echo "$DISCOVERY" | jq -r '.userinfo_endpoint // empty')

        if [[ -n "$AUTH_ENDPOINT" ]]; then
            test_pass "Authorization endpoint configured"
        else
            test_fail "Authorization endpoint missing"
        fi

        if [[ -n "$TOKEN_ENDPOINT" ]]; then
            test_pass "Token endpoint configured"
        else
            test_fail "Token endpoint missing"
        fi

        if [[ -n "$USERINFO_ENDPOINT" ]]; then
            test_pass "Userinfo endpoint configured"
        else
            test_fail "Userinfo endpoint missing"
        fi
    else
        test_warn "OIDC discovery endpoint not available (realm may not exist)"
    fi
fi

echo ""

# ==========================================
# Summary
# ==========================================
echo "=========================================="
echo "  Test Summary"
echo "=========================================="
echo ""
echo -e "${GREEN}Passed${NC}: $PASSED"
echo -e "${YELLOW}Warnings${NC}: $WARNINGS"
echo -e "${RED}Failed${NC}: $FAILED"
echo ""

if [[ $FAILED -gt 0 ]]; then
    echo -e "${RED}RESULT: SOME TESTS FAILED${NC}"
    exit 1
elif [[ $WARNINGS -gt 0 ]]; then
    echo -e "${YELLOW}RESULT: PASSED WITH WARNINGS${NC}"
    echo ""
    echo "To resolve warnings, run:"
    echo "  ./platform/keycloak/scripts/configure-realm.sh"
    exit 0
else
    echo -e "${GREEN}RESULT: ALL TESTS PASSED${NC}"
    exit 0
fi
