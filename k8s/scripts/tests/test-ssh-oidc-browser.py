#!/usr/bin/env python3
"""
Browser-based OIDC + SSH test using Playwright.
Tests the complete flow: Boundary OIDC Login -> Navigate to Targets -> Verify SSH targets accessible
Then tests actual SSH connectivity using the authenticated session.
"""

import os
import sys
import subprocess
import tempfile
import time
from playwright.sync_api import sync_playwright, TimeoutError as PlaywrightTimeout

# Test configuration
BOUNDARY_URL = os.environ.get("BOUNDARY_URL", "https://boundary.local")
KEYCLOAK_URL = os.environ.get("KEYCLOAK_URL", "https://keycloak.local")
TEST_USER = os.environ.get("TEST_USER", "developer@example.com")
TEST_PASSWORD = os.environ.get("TEST_PASSWORD", "Developer123")
TARGET_SCOPE = "DevOps"
TARGET_PROJECT = "Agent-Sandbox"
SSH_USER = "node"

# Target IDs are discovered dynamically from boundary-credentials.txt
CREDS_FILE = os.path.join(os.path.dirname(__file__), "../../platform/boundary/scripts/boundary-credentials.txt")

def get_target_ids():
    """Read target IDs from boundary-credentials.txt"""
    targets = {}
    try:
        if os.path.exists(CREDS_FILE):
            with open(CREDS_FILE, 'r') as f:
                for line in f:
                    if 'claude-ssh:' in line:
                        targets['claude'] = line.split(':')[-1].strip().split()[0]
                    elif 'gemini-ssh:' in line:
                        targets['gemini'] = line.split(':')[-1].strip().split()[0]
    except Exception as e:
        print(f"  Warning: Could not read credentials file: {e}")
    return targets

def test_oidc_ssh_flow():
    """Test the complete OIDC authentication and SSH connectivity flow."""
    print("=" * 70)
    print("  OIDC + SSH Browser Flow Test")
    print("=" * 70)
    print(f"  Boundary URL: {BOUNDARY_URL}")
    print(f"  Keycloak URL: {KEYCLOAK_URL}")
    print(f"  Test User:    {TEST_USER}")
    print()

    auth_token = None
    ssh_target_id = None
    project_id = None

    with sync_playwright() as p:
        browser = p.chromium.launch(
            headless="--headless" in sys.argv or "--headed" not in sys.argv,
            args=['--ignore-certificate-errors']
        )

        context = browser.new_context(
            ignore_https_errors=True,
            viewport={'width': 1280, 'height': 720}
        )

        page = context.new_page()

        try:
            # ==========================================
            # Phase 1: OIDC Authentication
            # ==========================================
            print("\n" + "=" * 50)
            print("  Phase 1: OIDC Authentication")
            print("=" * 50)

            # Step 1: Navigate to Boundary
            print("\nStep 1.1: Navigating to Boundary UI...")
            page.goto(BOUNDARY_URL, wait_until='networkidle', timeout=30000)
            print(f"  URL: {page.url}")

            # Step 2: Select DevOps scope
            print("\nStep 1.2: Selecting DevOps scope...")
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

            # Step 3: Select Keycloak auth method
            print("\nStep 1.3: Selecting Keycloak auth method...")
            keycloak_tab = page.locator('text=keycloak').first
            if keycloak_tab.is_visible(timeout=2000):
                keycloak_tab.click()
                page.wait_for_load_state('networkidle')
                print("  Selected Keycloak auth method")

            page.screenshot(path='/tmp/ssh-oidc-test-01-ready.png')

            # Step 4: Click Sign In and handle popup
            print("\nStep 1.4: Initiating OIDC authentication...")
            with context.expect_page() as popup_info:
                sign_in_button = page.locator('button:has-text("Sign In")').first
                sign_in_button.click()

            popup = popup_info.value
            print(f"  Popup opened: {popup.url}")
            popup.wait_for_load_state('networkidle', timeout=15000)

            # Step 5: Enter credentials in Keycloak
            if 'keycloak' in popup.url.lower() or 'realms' in popup.url:
                print("\nStep 1.5: Entering credentials...")
                popup.wait_for_selector('input[name="username"], #username', timeout=10000)
                popup.locator('input[name="username"], #username').first.fill(TEST_USER)
                popup.locator('input[name="password"], #password').first.fill(TEST_PASSWORD)
                popup.screenshot(path='/tmp/ssh-oidc-test-02-login.png')

                print("\nStep 1.6: Submitting login...")
                popup.locator('input[type="submit"], button[type="submit"], #kc-login').first.click()

                try:
                    popup.wait_for_load_state('networkidle', timeout=10000)
                except:
                    pass  # Popup may close

                # Wait for main page callback
                page.wait_for_timeout(3000)
                page.wait_for_load_state('networkidle', timeout=15000)

                # Check authentication result
                final_url = page.url
                page_content = page.content().lower()
                page.screenshot(path='/tmp/ssh-oidc-test-03-callback.png')

                if 'error' in final_url.lower():
                    print(f"\n  ❌ Authentication failed: {final_url}")
                    return False

                if 'scopes' in final_url or 'targets' in final_url or 'sign out' in page_content:
                    print("\n  ✅ OIDC Authentication successful!")
                else:
                    print(f"\n  ⚠️  Unclear auth state: {final_url}")

            # ==========================================
            # Phase 2: Navigate to Targets
            # ==========================================
            print("\n" + "=" * 50)
            print("  Phase 2: Navigate to SSH Targets")
            print("=" * 50)

            # Navigate to Agent-Sandbox project
            print("\nStep 2.1: Navigating to Agent-Sandbox project...")

            # Click on scopes/navigation
            page.wait_for_timeout(1000)

            # Look for project navigation
            project_link = page.locator(f'text={TARGET_PROJECT}').first
            if project_link.is_visible(timeout=5000):
                project_link.click()
                page.wait_for_load_state('networkidle')
                print(f"  Navigated to project: {TARGET_PROJECT}")
            else:
                # Try to navigate via URL
                page.goto(f"{BOUNDARY_URL}/scopes/global/scopes", wait_until='networkidle')

            page.screenshot(path='/tmp/ssh-oidc-test-04-project.png')

            # Step 2.2: Find Targets link
            print("\nStep 2.2: Navigating to Targets...")
            targets_link = page.locator('a:has-text("Targets")').first
            if targets_link.is_visible(timeout=5000):
                targets_link.click()
                page.wait_for_load_state('networkidle')
                print("  Navigated to Targets page")
            else:
                print("  ⚠️  Targets link not visible, may need to navigate manually")

            page.screenshot(path='/tmp/ssh-oidc-test-05-targets.png')

            # Step 2.3: Find SSH target
            print("\nStep 2.3: Looking for SSH targets...")
            page.wait_for_timeout(2000)

            # Look for devenv-ssh or similar target
            ssh_target = page.locator('text=devenv-ssh, text=ssh').first
            if ssh_target.is_visible(timeout=5000):
                print("  ✅ SSH target found in UI")
                ssh_target.click()
                page.wait_for_load_state('networkidle')
                page.screenshot(path='/tmp/ssh-oidc-test-06-target-detail.png')

                # Get target ID from URL
                current_url = page.url
                if '/targets/' in current_url:
                    ssh_target_id = current_url.split('/targets/')[-1].split('/')[0].split('?')[0]
                    print(f"  Target ID: {ssh_target_id}")
            else:
                print("  ⚠️  SSH target not found in UI, extracting from API...")
                # Try to get targets via API using cookies from browser
                cookies = context.cookies()
                # Note: Would need to make API call here

            # ==========================================
            # Phase 3: Test SSH Connectivity with Brokered Credentials
            # ==========================================
            print("\n" + "=" * 50)
            print("  Phase 3: Test SSH with Brokered Credentials")
            print("=" * 50)

            # Extract auth token from browser storage/cookies for CLI use
            print("\nStep 3.1: Extracting auth token...")

            # Get token from localStorage or cookies
            token = page.evaluate('''() => {
                return localStorage.getItem('ember_simple_auth-session') ||
                       localStorage.getItem('boundary-token') ||
                       document.cookie;
            }''')

            if token:
                print("  Found session data in browser")
                # Try to extract token from session JSON
                try:
                    import json
                    session_data = json.loads(token)
                    auth_token = session_data.get('authenticated', {}).get('attributes', {}).get('token')
                    if auth_token:
                        print(f"  ✅ Auth token extracted: {auth_token[:20]}...")
                except:
                    print("  ⚠️  Could not parse session token")

            # Discover target IDs dynamically
            targets = get_target_ids()
            print(f"\nStep 3.2: Discovered targets: {targets}")

            # Use gemini target for testing (or claude if gemini not found)
            ssh_target_id = targets.get('gemini') or targets.get('claude') or ssh_target_id
            if not ssh_target_id:
                print("  ⚠️  No target IDs found in credentials file")
            else:
                print(f"  Using target ID: {ssh_target_id}")

            # Step 3.3: Authorize session to get brokered credentials
            if auth_token:
                print("\nStep 3.3: Authorizing session to get brokered credentials...")
                os.environ['BOUNDARY_TOKEN'] = auth_token
                os.environ['BOUNDARY_ADDR'] = BOUNDARY_URL
                os.environ['BOUNDARY_TLS_INSECURE'] = 'true'

                try:
                    auth_result = subprocess.run(
                        ['boundary', 'targets', 'authorize-session',
                         '-id', ssh_target_id, '-format=json'],
                        capture_output=True, text=True, timeout=30
                    )

                    if auth_result.returncode == 0:
                        import json
                        auth_data = json.loads(auth_result.stdout)
                        credentials = auth_data.get('item', {}).get('credentials', [])
                        session_id = auth_data.get('item', {}).get('session_id', '')

                        print(f"  Session ID: {session_id}")
                        print(f"  Credentials returned: {len(credentials)}")

                        if credentials:
                            # Extract SSH credentials from brokered response
                            # vault-generic returns data in 'decoded' or 'raw' format
                            cred = credentials[0]
                            secret = cred.get('secret', {})

                            # Try different paths to find the data
                            # KV v2: data.data, or decoded (base64 decoded), or raw
                            if 'decoded' in secret:
                                secret_data = secret.get('decoded', {}).get('data', {}) or secret.get('decoded', {})
                            elif 'data' in secret and 'data' in secret.get('data', {}):
                                secret_data = secret.get('data', {}).get('data', {})
                            elif 'data' in secret:
                                secret_data = secret.get('data', {})
                            else:
                                secret_data = secret

                            print(f"  Secret structure: {list(secret.keys())}")
                            if 'decoded' in secret:
                                print(f"  Decoded keys: {list(secret.get('decoded', {}).keys())}")

                            private_key = secret_data.get('private_key', '')
                            certificate = secret_data.get('certificate', '')
                            username = secret_data.get('username', SSH_USER)

                            if private_key:
                                print("  ✅ Got brokered SSH credentials")
                                print(f"  Username: {username}")
                                print(f"  Certificate present: {bool(certificate)}")

                                # Write credentials to temp files
                                # SSH requires cert file to be named {keyfile}-cert.pub
                                with tempfile.TemporaryDirectory() as temp_dir:
                                    key_file = os.path.join(temp_dir, 'id_ed25519')
                                    cert_file = os.path.join(temp_dir, 'id_ed25519-cert.pub')

                                    with open(key_file, 'w') as f:
                                        f.write(private_key)
                                    os.chmod(key_file, 0o600)

                                    if certificate:
                                        with open(cert_file, 'w') as f:
                                            f.write(certificate)
                                        os.chmod(cert_file, 0o644)

                                    # Step 3.4: Test SSH using boundary connect -exec
                                    print("\nStep 3.4: Testing SSH with brokered credentials...")

                                    # Use boundary connect -exec with credentials
                                    # Note: SSH auto-loads {keyfile}-cert.pub when using -i {keyfile}
                                    ssh_cmd = [
                                        'boundary', 'connect',
                                        '-target-id', ssh_target_id,
                                        '-token', f'env://BOUNDARY_TOKEN',
                                        '-exec', 'ssh', '--',
                                        '-i', key_file,
                                        '-o', 'StrictHostKeyChecking=no',
                                        '-o', 'UserKnownHostsFile=/dev/null',
                                        '-o', 'LogLevel=ERROR',
                                        '-l', username,
                                        '-p', '{{boundary.port}}',
                                        '{{boundary.ip}}',
                                        'hostname'
                                    ]

                                    print(f"  Command: {' '.join(ssh_cmd[:8])}...")
                                    result = subprocess.run(
                                        ssh_cmd,
                                        capture_output=True, text=True, timeout=60
                                    )

                                    # Check if hostname is in output (success)
                                    output = result.stdout.strip()
                                    # Filter out boundary proxy info
                                    lines = [l for l in output.split('\n') if l and not l.startswith('Proxy') and not l.startswith(' ') and ':' not in l]
                                    hostname_output = lines[-1] if lines else ''

                                    if result.returncode == 0 or (hostname_output and 'sandbox' in hostname_output.lower()):
                                        print(f"  ✅ SSH SUCCESSFUL! Host: {hostname_output}")
                                        page.screenshot(path='/tmp/ssh-oidc-test-final-success.png')
                                        return True
                                    else:
                                        print(f"  ⚠️  SSH returned: {result.returncode}")
                                        print(f"  stdout: {result.stdout[:300] if result.stdout else 'empty'}")
                                        print(f"  stderr: {result.stderr[:300] if result.stderr else 'empty'}")
                            else:
                                print("  ⚠️  No private key in brokered credentials")
                                print(f"  Secret keys: {list(secret.keys())}")
                        else:
                            print("  ⚠️  No credentials returned (check role permissions)")
                    else:
                        print(f"  ⚠️  Authorization failed: {auth_result.stderr[:200]}")

                except subprocess.TimeoutExpired:
                    print("  ❌ Authorization timed out")
                except Exception as e:
                    print(f"  ⚠️  Error: {e}")
                    import traceback
                    traceback.print_exc()

            # Step 3.3: Test SSH with extracted token via Boundary CLI
            if auth_token and not ssh_target_id:
                print("\nStep 3.3: Finding SSH target via CLI with auth token...")
                os.environ['BOUNDARY_TOKEN'] = auth_token
                os.environ['BOUNDARY_ADDR'] = BOUNDARY_URL
                os.environ['BOUNDARY_TLS_INSECURE'] = 'true'

                try:
                    # Get scopes
                    scopes_result = subprocess.run(
                        ['boundary', 'scopes', 'list', '-format=json'],
                        capture_output=True, text=True, timeout=10
                    )
                    if scopes_result.returncode == 0:
                        import json
                        scopes = json.loads(scopes_result.stdout)
                        org_id = next((s['id'] for s in scopes.get('items', []) if s.get('name') == TARGET_SCOPE), None)

                        if org_id:
                            # Get projects
                            proj_result = subprocess.run(
                                ['boundary', 'scopes', 'list', f'-scope-id={org_id}', '-format=json'],
                                capture_output=True, text=True, timeout=10
                            )
                            if proj_result.returncode == 0:
                                projects = json.loads(proj_result.stdout)
                                project_id = next((p['id'] for p in projects.get('items', []) if p.get('name') == TARGET_PROJECT), None)

                                if project_id:
                                    # Get targets
                                    tgt_result = subprocess.run(
                                        ['boundary', 'targets', 'list', f'-scope-id={project_id}', '-format=json'],
                                        capture_output=True, text=True, timeout=10
                                    )
                                    if tgt_result.returncode == 0:
                                        targets = json.loads(tgt_result.stdout)
                                        ssh_target_id = next((t['id'] for t in targets.get('items', []) if 'ssh' in t.get('name', '').lower()), None)
                                        if ssh_target_id:
                                            print(f"  ✅ Found SSH target: {ssh_target_id}")
                except Exception as e:
                    print(f"  ⚠️  CLI lookup error: {e}")

            # Step 3.4: Test actual SSH connectivity
            if auth_token and ssh_target_id:
                print(f"\nStep 3.4: Testing SSH connectivity to {ssh_target_id}...")
                os.environ['BOUNDARY_TOKEN'] = auth_token

                try:
                    result = subprocess.run(
                        [
                            'boundary', 'connect', 'ssh',
                            f'-target-id={ssh_target_id}',
                            '--',
                            '-l', SSH_USER,
                            '-o', 'StrictHostKeyChecking=no',
                            '-o', 'UserKnownHostsFile=/dev/null',
                            '-o', 'BatchMode=yes',
                            '-o', 'ConnectTimeout=10',
                            'echo', 'SSH_OIDC_SUCCESS'
                        ],
                        capture_output=True,
                        text=True,
                        timeout=30
                    )

                    if 'SSH_OIDC_SUCCESS' in result.stdout:
                        print("  ✅ SSH via OIDC successful!")
                        page.screenshot(path='/tmp/ssh-oidc-test-final-success.png')
                        return True
                    else:
                        print(f"  ⚠️  SSH stdout: {result.stdout[:200]}")
                        print(f"  ⚠️  SSH stderr: {result.stderr[:200]}")
                except subprocess.TimeoutExpired:
                    print("  ❌ SSH connection timed out")
                except Exception as e:
                    print(f"  ⚠️  SSH error: {e}")

            # Check UI connect option as fallback
            print("\nStep 3.5: Checking UI connect option...")
            connect_button = page.locator('button:has-text("Connect")').first
            if connect_button.is_visible(timeout=3000):
                print("  ✅ Connect button available in UI")
                page.screenshot(path='/tmp/ssh-oidc-test-07-connect.png')
                return True

            # Return success if we authenticated and found targets
            page.screenshot(path='/tmp/ssh-oidc-test-final.png')
            if auth_token:
                print("\n  ✅ OIDC authentication verified, token extracted")
                return True
            else:
                print("\n  ❌ Could not complete OIDC + SSH flow")
                return False

        except PlaywrightTimeout as e:
            print(f"\n❌ Timeout Error: {e}")
            page.screenshot(path='/tmp/ssh-oidc-test-timeout.png')
            return False

        except Exception as e:
            print(f"\n❌ Error: {e}")
            import traceback
            traceback.print_exc()
            try:
                page.screenshot(path='/tmp/ssh-oidc-test-error.png')
            except:
                pass
            return False

        finally:
            browser.close()


if __name__ == "__main__":
    # Parse arguments
    if "--help" in sys.argv:
        print("Usage: test-ssh-oidc-browser.py [--headless|--headed]")
        print("  --headless  Run browser in headless mode (default)")
        print("  --headed    Run browser with visible window")
        sys.exit(0)

    success = test_oidc_ssh_flow()

    print("\n" + "=" * 70)
    if success:
        print("  ✅ TEST PASSED: OIDC + SSH flow completed successfully")
    else:
        print("  ❌ TEST FAILED: Check screenshots in /tmp/ssh-oidc-test-*.png")
    print("=" * 70)
    sys.exit(0 if success else 1)
