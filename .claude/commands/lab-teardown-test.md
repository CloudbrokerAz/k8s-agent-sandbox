# Steps to complete lab testing

compete autonomously as a performance improvement process, go through upto 10 complete cycles of improvement

- run teardown ./k8s/scripts/teardown-all.sh
- remove the sandbox kind cluster
- run ./k8s/scripts/deploy-all.sh
- fix any identified isses with deploy-all.sh
- validate full user auth flow using test-oidc-browser.py
- review the deployment script identify areas for speed optimisaiton and concurrent workflows

## Repeat this process at least 10 times

- Repeat the above workflow until you have optimized deployment performance or not making percentage improvements.
- Important - measure deployment time overall prior to optimization and post optimization
- We can't change the architecture or remove products, but we can improve deployment speed and teardown speed to go fast

Good luck we are counting on these efficiency gains