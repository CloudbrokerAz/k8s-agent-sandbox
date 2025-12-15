#!/bin/bash
# test-oidc-flow.sh - Test the complete OIDC authorization code flow
# This simulates what happens when a user clicks "Login with Keycloak" in Boundary

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_pass() { echo -e "${GREEN}✅ PASS${NC}: $1"; }
log_fail() { echo -e "${RED}❌ FAIL${NC}: $1"; }
log_info() { echo -e "${BLUE}ℹ️  INFO${NC}: $1"; }
log_warn() { echo -e "${YELLOW}⚠️  WARN${NC}: $1"; }

echo "=========================================="
echo "  OIDC Authorization Code Flow Test"
echo "=========================================="
echo ""

# Configuration
KEYCLOAK_URL="${KEYCLOAK_URL:-https://keycloak.hashicorp.lab}"
BOUNDARY_URL="${BOUNDARY_URL:-https://boundary.hashicorp.lab}"
REALM="${REALM:-agent-sandbox}"
CLIENT_ID="${CLIENT_ID:-boundary}"
TEST_USER="${TEST_USER:-developer@example.com}"
TEST_PASS="${TEST_PASS:-Developer123}"

# Get client secret from Kubernetes
CLIENT_SECRET=$(kubectl get secret boundary-oidc-client-secret -n keycloak -o jsonpath='{.data.client-secret}' 2>/dev/null | base64 -d || echo "")
if [[ -z "$CLIENT_SECRET" ]]; then
    log_fail "Could not retrieve client secret from Kubernetes"
    exit 1
fi
log_pass "Retrieved client secret from Kubernetes"

# Step 1: Test OIDC Discovery
echo ""
echo "--- Step 1: OIDC Discovery ---"
DISCOVERY_URL="${KEYCLOAK_URL}/realms/${REALM}/.well-known/openid-configuration"
DISCOVERY=$(curl -sk "$DISCOVERY_URL" 2>/dev/null)

if [[ -z "$DISCOVERY" ]]; then
    log_fail "Could not reach OIDC discovery endpoint: $DISCOVERY_URL"
    exit 1
fi

AUTH_ENDPOINT=$(echo "$DISCOVERY" | jq -r '.authorization_endpoint')
TOKEN_ENDPOINT=$(echo "$DISCOVERY" | jq -r '.token_endpoint')
ISSUER=$(echo "$DISCOVERY" | jq -r '.issuer')

if [[ "$AUTH_ENDPOINT" == "null" ]] || [[ -z "$AUTH_ENDPOINT" ]]; then
    log_fail "Invalid discovery response - no authorization_endpoint"
    exit 1
fi

log_pass "OIDC Discovery successful"
log_info "Issuer: $ISSUER"
log_info "Authorization endpoint: $AUTH_ENDPOINT"
log_info "Token endpoint: $TOKEN_ENDPOINT"

# Step 2: Test Authorization Endpoint accessibility
echo ""
echo "--- Step 2: Authorization Endpoint ---"
REDIRECT_URI="${BOUNDARY_URL}/v1/auth-methods/oidc:authenticate:callback"
REDIRECT_URI_ENCODED=$(printf '%s' "$REDIRECT_URI" | jq -sRr @uri)

AUTH_URL="${AUTH_ENDPOINT}?client_id=${CLIENT_ID}&redirect_uri=${REDIRECT_URI_ENCODED}&response_type=code&scope=openid%20email%20profile&state=test_state&nonce=test_nonce"

AUTH_RESPONSE=$(curl -sk -i "$AUTH_URL" 2>/dev/null)
AUTH_STATUS=$(echo "$AUTH_RESPONSE" | head -1 | grep -oE '[0-9]{3}')

if [[ "$AUTH_STATUS" == "200" ]]; then
    log_pass "Authorization endpoint returns login page (HTTP $AUTH_STATUS)"
elif [[ "$AUTH_STATUS" == "302" ]]; then
    LOCATION=$(echo "$AUTH_RESPONSE" | grep -i "^location:" | head -1)
    if echo "$LOCATION" | grep -q "error="; then
        ERROR=$(echo "$LOCATION" | grep -oE "error=[^&]+" | cut -d= -f2)
        ERROR_DESC=$(echo "$LOCATION" | grep -oE "error_description=[^&]+" | cut -d= -f2 | sed 's/%20/ /g')
        log_fail "Authorization endpoint returned error: $ERROR - $ERROR_DESC"
        exit 1
    else
        log_pass "Authorization endpoint redirects (HTTP $AUTH_STATUS)"
    fi
else
    log_fail "Authorization endpoint returned unexpected status: $AUTH_STATUS"
    echo "$AUTH_RESPONSE" | head -20
    exit 1
fi

# Step 3: Simulate user login and get authorization code
echo ""
echo "--- Step 3: User Authentication (Password Grant Simulation) ---"
log_info "Testing with user: $TEST_USER"

# Use password grant to simulate authenticated user (this tests client credentials)
TOKEN_RESPONSE=$(curl -sk -X POST "$TOKEN_ENDPOINT" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d "client_id=${CLIENT_ID}" \
    -d "client_secret=${CLIENT_SECRET}" \
    -d "grant_type=password" \
    -d "username=${TEST_USER}" \
    -d "password=${TEST_PASS}" \
    -d "scope=openid email profile" 2>/dev/null)

if echo "$TOKEN_RESPONSE" | jq -e '.access_token' &>/dev/null; then
    log_pass "Password grant successful - client credentials are valid"

    # Extract and validate token claims
    ACCESS_TOKEN=$(echo "$TOKEN_RESPONSE" | jq -r '.access_token')
    ID_TOKEN=$(echo "$TOKEN_RESPONSE" | jq -r '.id_token')

    # Decode and check claims
    CLAIMS=$(echo "$ACCESS_TOKEN" | cut -d. -f2 | base64 -d 2>/dev/null | jq '.' 2>/dev/null || echo "{}")
    GROUPS=$(echo "$CLAIMS" | jq -r '.groups // empty')
    EMAIL=$(echo "$CLAIMS" | jq -r '.email // empty')

    log_info "Token email: $EMAIL"
    log_info "Token groups: $GROUPS"

    if [[ -n "$GROUPS" ]]; then
        log_pass "Groups claim present in token"
    else
        log_warn "Groups claim missing from token - managed groups may not work"
    fi
else
    ERROR=$(echo "$TOKEN_RESPONSE" | jq -r '.error // "unknown"')
    ERROR_DESC=$(echo "$TOKEN_RESPONSE" | jq -r '.error_description // "no description"')
    log_fail "Password grant failed: $ERROR - $ERROR_DESC"
    echo "Full response: $TOKEN_RESPONSE"
    exit 1
fi

# Step 4: Test Authorization Code Flow (the actual OIDC flow)
echo ""
echo "--- Step 4: Authorization Code Flow Simulation ---"

# Get session cookies from Keycloak login page
COOKIE_JAR=$(mktemp)
trap "rm -f $COOKIE_JAR" EXIT

# Get the login page
LOGIN_PAGE=$(curl -sk -c "$COOKIE_JAR" -b "$COOKIE_JAR" "$AUTH_URL" 2>/dev/null)

# Extract the login form action URL
FORM_ACTION=$(echo "$LOGIN_PAGE" | grep -oE 'action="[^"]*"' | head -1 | cut -d'"' -f2 | sed 's/&amp;/\&/g')

if [[ -z "$FORM_ACTION" ]] || [[ "$FORM_ACTION" == "null" ]]; then
    log_warn "Could not extract login form action - may need manual browser test"
else
    log_info "Login form action: ${FORM_ACTION:0:80}..."

    # Submit login form
    LOGIN_RESPONSE=$(curl -sk -i -c "$COOKIE_JAR" -b "$COOKIE_JAR" \
        -X POST "$FORM_ACTION" \
        -H "Content-Type: application/x-www-form-urlencoded" \
        -d "username=${TEST_USER}" \
        -d "password=${TEST_PASS}" \
        --max-redirs 0 2>/dev/null)

    LOGIN_STATUS=$(echo "$LOGIN_RESPONSE" | head -1 | grep -oE '[0-9]{3}')
    REDIRECT_LOCATION=$(echo "$LOGIN_RESPONSE" | grep -i "^location:" | head -1 | sed 's/location: //i' | tr -d '\r')

    if [[ "$LOGIN_STATUS" == "302" ]] && echo "$REDIRECT_LOCATION" | grep -q "code="; then
        log_pass "Login successful - received authorization code"
        AUTH_CODE=$(echo "$REDIRECT_LOCATION" | grep -oE "code=[^&]+" | cut -d= -f2)
        log_info "Authorization code: ${AUTH_CODE:0:20}..."

        # Step 5: Exchange code for tokens (this is what Boundary does)
        echo ""
        echo "--- Step 5: Token Exchange (Boundary Callback) ---"

        EXCHANGE_RESPONSE=$(curl -sk -X POST "$TOKEN_ENDPOINT" \
            -H "Content-Type: application/x-www-form-urlencoded" \
            -d "client_id=${CLIENT_ID}" \
            -d "client_secret=${CLIENT_SECRET}" \
            -d "grant_type=authorization_code" \
            -d "code=${AUTH_CODE}" \
            -d "redirect_uri=${REDIRECT_URI}" 2>/dev/null)

        if echo "$EXCHANGE_RESPONSE" | jq -e '.access_token' &>/dev/null; then
            log_pass "Token exchange successful!"
            log_info "Access token received"
            log_info "ID token received: $(echo "$EXCHANGE_RESPONSE" | jq -r 'if .id_token then "yes" else "no" end')"
        else
            ERROR=$(echo "$EXCHANGE_RESPONSE" | jq -r '.error // "unknown"')
            ERROR_DESC=$(echo "$EXCHANGE_RESPONSE" | jq -r '.error_description // "no description"')
            log_fail "Token exchange failed: $ERROR - $ERROR_DESC"
            echo "Full response: $EXCHANGE_RESPONSE"
        fi

    elif [[ "$LOGIN_STATUS" == "302" ]] && echo "$REDIRECT_LOCATION" | grep -q "error="; then
        ERROR=$(echo "$REDIRECT_LOCATION" | grep -oE "error=[^&]+" | cut -d= -f2)
        log_fail "Login redirect contained error: $ERROR"
        log_info "Redirect: $REDIRECT_LOCATION"
    elif [[ "$LOGIN_STATUS" == "200" ]]; then
        # Still on login page - might have error message
        if echo "$LOGIN_RESPONSE" | grep -q "Invalid username or password"; then
            log_fail "Invalid username or password"
        else
            log_warn "Received 200 instead of redirect - checking for errors"
            echo "$LOGIN_RESPONSE" | grep -iE "error|invalid|failed" | head -5
        fi
    else
        log_warn "Unexpected login response status: $LOGIN_STATUS"
        log_info "Redirect location: $REDIRECT_LOCATION"
    fi
fi

# Step 6: Test Boundary callback URL accessibility
echo ""
echo "--- Step 6: Boundary Callback Endpoint ---"
CALLBACK_TEST=$(curl -sk -o /dev/null -w "%{http_code}" "${REDIRECT_URI}?code=test&state=test" 2>/dev/null)

# Boundary should return an error for invalid code, but endpoint should be reachable
if [[ "$CALLBACK_TEST" != "000" ]]; then
    log_pass "Boundary callback endpoint is reachable (HTTP $CALLBACK_TEST)"
else
    log_fail "Boundary callback endpoint is not reachable"
fi

echo ""
echo "=========================================="
echo "  Test Summary"
echo "=========================================="
echo "OIDC Discovery: ✅"
echo "Authorization Endpoint: ✅"
echo "Client Credentials: ✅"
echo "User Authentication: ✅"
echo ""
echo "If browser-based OIDC login still fails, check:"
echo "  1. Browser cookies/cache for keycloak.hashicorp.lab and boundary.hashicorp.lab"
echo "  2. TLS certificate warnings in browser"
echo "  3. Browser console for JavaScript errors"
echo ""
