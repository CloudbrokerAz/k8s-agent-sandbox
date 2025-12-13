# Steps to complete lab testing

- run teardown ./k8s/scripts/teardown-all.sh
- remove the sandbox kind cluster
- run ./k8s/scripts/deploy-all.sh
- fix any identified isses with deploy-all.sh
- review the deployment script identify areas for speed optimisaiton and concurrent workflows

## Repeat this process at least 5 times

Repeat the above workflow until you have optimized deployment performance.
Important - measure deployment time overall prior to optimization and post optimization
