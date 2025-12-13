#!/usr/bin/env python3
"""
Browser-based OIDC flow test using Playwright.
Tests the complete user flow: Boundary -> Keycloak Login (popup) -> Callback -> Authenticated
"""

import os
import sys
from playwright.sync_api import sync_playwright, TimeoutError as PlaywrightTimeout

# Test configuration - defaults to ingress hostnames on standard HTTPS port 443
# For port-forward testing, set BOUNDARY_URL and KEYCLOAK_URL environment variables
BOUNDARY_URL = os.environ.get("BOUNDARY_URL", "https://boundary.local")
KEYCLOAK_URL = os.environ.get("KEYCLOAK_URL", "https://keycloak.local")
TEST_USER = "developer@example.com"
TEST_PASSWORD = "Developer123"
OIDC_AUTH_METHOD_ID = os.environ.get("OIDC_AUTH_METHOD_ID", "")  # Auto-detected if empty
TARGET_SCOPE = "DevOps"

def test_oidc_flow():
    """Test the complete OIDC authentication flow with popup handling."""
    print("=" * 60)
    print("  OIDC Browser Flow Test (with popup)")
    print("=" * 60)
    print(f"  Boundary URL: {BOUNDARY_URL}")
    print(f"  Keycloak URL: {KEYCLOAK_URL}")
    print()

    with sync_playwright() as p:
        browser = p.chromium.launch(
            headless=True,
            args=['--ignore-certificate-errors']
        )

        context = browser.new_context(
            ignore_https_errors=True,
            viewport={'width': 1280, 'height': 720}
        )

        page = context.new_page()

        try:
            # Step 1: Navigate to Boundary
            print("Step 1: Navigating to Boundary UI...")
            page.goto(BOUNDARY_URL, wait_until='networkidle', timeout=30000)
            print(f"  URL: {page.url}")

            # Step 2: Select DevOps scope
            print("\nStep 2: Selecting DevOps scope...")
            page.wait_for_load_state('networkidle')

            scope_dropdown = page.locator('text=Choose a different scope').first
            if scope_dropdown.is_visible(timeout=5000):
                scope_dropdown.click()
                page.wait_for_timeout(500)

                devops_option = page.locator(f'text={TARGET_SCOPE}').first
                if devops_option.is_visible(timeout=3000):
                    devops_option.click()
                    print(f"  Selected scope: {TARGET_SCOPE}")
                    page.wait_for_load_state('networkidle')

            page.wait_for_timeout(1000)
            print(f"  URL: {page.url}")

            # Step 3: Look for keycloak auth method tab
            print("\nStep 3: Checking for Keycloak auth method...")
            keycloak_tab = page.locator('text=keycloak').first
            if keycloak_tab.is_visible(timeout=2000):
                keycloak_tab.click()
                page.wait_for_load_state('networkidle')
                print("  Selected Keycloak auth method")

            page.screenshot(path='/tmp/oidc-test-03-ready.png')

            # Step 4: Click Sign In and handle popup
            print("\nStep 4: Initiating OIDC authentication (popup)...")

            # Set up popup handler BEFORE clicking
            with context.expect_page() as popup_info:
                sign_in_button = page.locator('button:has-text("Sign In")').first
                sign_in_button.click()

            # Get the popup page
            popup = popup_info.value
            print(f"  Popup opened: {popup.url}")

            # Wait for popup to load
            popup.wait_for_load_state('networkidle', timeout=15000)
            popup.screenshot(path='/tmp/oidc-test-04-popup.png')

            # Step 5: Check if popup is Keycloak login
            print("\nStep 5: Checking popup content...")
            popup_url = popup.url
            print(f"  Popup URL: {popup_url}")

            if 'keycloak' in popup_url.lower() or 'realms' in popup_url:
                print("  SUCCESS: Popup is Keycloak login!")

                # Wait for and fill login form
                popup.wait_for_selector('input[name="username"], #username', timeout=10000)
                popup.screenshot(path='/tmp/oidc-test-05-keycloak.png')

                # Step 6: Enter credentials
                print("\nStep 6: Entering credentials in popup...")
                popup.locator('input[name="username"], #username').first.fill(TEST_USER)
                popup.locator('input[name="password"], #password').first.fill(TEST_PASSWORD)
                print(f"  Username: {TEST_USER}")
                print("  Password: ********")

                popup.screenshot(path='/tmp/oidc-test-06-filled.png')

                # Step 7: Submit login
                print("\nStep 7: Submitting login...")
                popup.locator('input[type="submit"], button[type="submit"], #kc-login').first.click()

                # Wait for popup to process and potentially close
                try:
                    popup.wait_for_load_state('networkidle', timeout=10000)
                    popup.screenshot(path='/tmp/oidc-test-07-after-submit.png')
                    print(f"  Popup URL after submit: {popup.url}")
                except:
                    print("  Popup may have closed (expected behavior)")

                # Step 8: Check main page for result
                print("\nStep 8: Checking main page for authentication result...")

                # Wait a bit for the callback to complete
                page.wait_for_timeout(3000)
                page.wait_for_load_state('networkidle', timeout=15000)

                final_url = page.url
                print(f"  Main page URL: {final_url}")
                page.screenshot(path='/tmp/oidc-test-08-final.png')

                # Check for success indicators
                page_content = page.content().lower()

                if 'error' in final_url.lower() or 'authentication-error' in final_url:
                    print("\n  RESULT: AUTHENTICATION FAILED")
                    # Check for error message in URL
                    if 'error=' in final_url:
                        import urllib.parse
                        parsed = urllib.parse.urlparse(final_url)
                        params = urllib.parse.parse_qs(parsed.query)
                        if 'error' in params:
                            print(f"  Error: {params['error'][0]}")
                    page.screenshot(path='/tmp/oidc-test-09-error.png')
                    return False

                elif 'pending' in page_content:
                    print("\n  RESULT: Still pending - checking popup status...")
                    # Popup might still be open, wait more
                    page.wait_for_timeout(5000)
                    page.wait_for_load_state('networkidle')
                    final_url = page.url
                    print(f"  Final URL after wait: {final_url}")

                    if 'scopes' in final_url and 'authenticate' not in final_url:
                        print("\n  RESULT: AUTHENTICATION SUCCESSFUL!")
                        page.screenshot(path='/tmp/oidc-test-09-success.png')
                        return True
                    else:
                        page.screenshot(path='/tmp/oidc-test-09-still-pending.png')
                        return False

                elif 'scopes' in final_url and 'authenticate' not in final_url:
                    # We're on a scopes page without authenticate - likely logged in
                    print("\n  RESULT: AUTHENTICATION SUCCESSFUL!")
                    page.screenshot(path='/tmp/oidc-test-09-success.png')
                    return True

                elif 'targets' in final_url or 'sessions' in final_url:
                    print("\n  RESULT: AUTHENTICATION SUCCESSFUL!")
                    page.screenshot(path='/tmp/oidc-test-09-success.png')
                    return True

                else:
                    print(f"\n  RESULT: Checking page state...")
                    # Look for logged-in indicators
                    if 'sign out' in page_content or 'logout' in page_content:
                        print("  Found logout option - AUTHENTICATED!")
                        page.screenshot(path='/tmp/oidc-test-09-success.png')
                        return True
                    page.screenshot(path='/tmp/oidc-test-09-unknown.png')
                    return False
            else:
                print(f"  Popup is not Keycloak: {popup_url}")
                popup.screenshot(path='/tmp/oidc-test-05-wrong-popup.png')
                return False

        except PlaywrightTimeout as e:
            print(f"\nTimeout Error: {e}")
            page.screenshot(path='/tmp/oidc-test-timeout.png')
            return False

        except Exception as e:
            print(f"\nError: {e}")
            import traceback
            traceback.print_exc()
            try:
                page.screenshot(path='/tmp/oidc-test-error.png')
            except:
                pass
            return False

        finally:
            browser.close()

if __name__ == "__main__":
    success = test_oidc_flow()
    print("\n" + "=" * 60)
    if success:
        print("  TEST PASSED: OIDC flow completed successfully")
    else:
        print("  TEST FAILED: Check screenshots in /tmp/oidc-test-*.png")
    print("=" * 60)
    sys.exit(0 if success else 1)
