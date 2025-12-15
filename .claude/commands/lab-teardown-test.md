# Steps to complete lab testing

compete autonomously as a performance improvement process, improvement, use opus sub agents for each task

- run teardown ./k8s/scripts/teardown-all.sh
- fix any identified issues with teardown scripts
- remove the sandbox kind cluster
- run ./k8s/scripts/deploy-all.sh
- fix any identified isses with deploy-all.sh scripts ultrathink
- ensure boundary.hashicorp.lab and keycloak.hashicorp.lab are accessible via the ingress and resolvable, fix issues and ensure fixes are part of ./k8s/scripts/deploy-all.sh
- validate full user auth flow using test-oidc-browser.py, report the results, and fix issues. THe user must be able to login.
- review ./k8s/scripts/deploy-all.sh identify areas for seed optimisation and parrallel workflows
- report the results and highlight any issues in a markdown report with date/time in ./reports/

# principles

- Test driven improvements with determinstic results and reliability is priority, always fix issues related to failing tests
- Repeat the above workflow until you have optimized deployment performance or not making percentage improvements.
- Important - measure deployment time overall prior to optimization and post optimization
- We can't change the architecture or remove products, but we can improve deployment speed and teardown speed to go fast
- summarise final results
- rather than using sleep use determinstic waits like polls with timeouts

Good luck we are counting on these efficiency gains