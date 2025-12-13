# Steps to complete lab testing

- run teardown ./k8s/scripts/teardown-all.sh
- remove the sandbox kind cluster
- run ./k8s/scripts/deploy-all.sh
- fix any identified isses with deploy-all.sh
- validate full user auth flow using test-oidc-browser.py
- review the deployment script identify areas for speed optimisaiton and concurrent workflows

## Repeat this process at least 10 times

Repeat the above workflow until you have optimized deployment performance or not making percentage improvements.
Important - measure deployment time overall prior to optimization and post optimization
