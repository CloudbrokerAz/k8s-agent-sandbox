# Getting Started with Kubernetes DevEnv Deployment

This guide walks you through deploying your devcontainer to a Kubernetes cluster step by step.

## Prerequisites Checklist

- [ ] Docker installed and running
- [ ] Docker Hub account created
- [ ] kubectl installed (`kubectl version --client`)
- [ ] Kubernetes cluster running (kind, K8s, or OpenShift)
- [ ] kubectl configured to access your cluster (`kubectl cluster-info`)
- [ ] Required credentials ready:
  - GitHub Personal Access Token
  - Terraform Cloud/Enterprise Token
  - AWS Access Key ID and Secret Access Key

## Step 1: Verify Your Environment

On your **local machine** (Mac), run:

```bash
# Check Docker
docker --version
docker ps

# Check kubectl
kubectl version --client

# Check cluster connectivity
kubectl cluster-info

# Verify you can access your kind cluster
kubectl get nodes
```

Expected output: You should see your kind cluster nodes.

## Step 2: Authenticate with Docker Hub

```bash
# Login to Docker Hub
docker login

# Enter your Docker Hub username and password when prompted
```

## Step 3: Build and Push the Image

From your **local machine**, navigate to where you cloned this repository:

```bash
# Navigate to the project
cd /Users/aarone/Documents/repos/testing-ai-sandbox-code

# Build and push (replace 'yourname' with your Docker Hub username)
./k8s/scripts/build-and-push.sh yourname

# This will take 10-15 minutes on first build
```

**Important**: Copy the full image name from the output (e.g., `yourname/terraform-devenv:latest`)

## Step 4: Update the StatefulSet Manifest

Edit the file `k8s/manifests/05-statefulset.yaml`:

```bash
# On Mac
open k8s/manifests/05-statefulset.yaml

# Or use any text editor
code k8s/manifests/05-statefulset.yaml
```

Find this line (around line 30):
```yaml
image: YOUR_DOCKERHUB_USERNAME/terraform-devenv:latest
```

Replace with your actual Docker Hub username:
```yaml
image: yourname/terraform-devenv:latest
```

Save the file.

## Step 5: Create Kubernetes Secrets

```bash
# Run the interactive secret creation script
./k8s/scripts/create-secrets.sh
```

You'll be prompted for:

1. **GITHUB_TOKEN**:
   - Go to https://github.com/settings/tokens
   - Generate a new token (classic) with `repo` scope
   - Paste the token (it won't be visible as you type)

2. **TFE_TOKEN**:
   - Go to https://app.terraform.io/app/settings/tokens
   - Generate a new API token
   - Paste the token

3. **AWS_ACCESS_KEY_ID** and **AWS_SECRET_ACCESS_KEY**:
   - From your AWS IAM console
   - Or use `aws configure` output

4. **Optional values**: Press Enter to skip if you don't have them

## Step 6: Deploy to Kubernetes

```bash
# Deploy all manifests
./k8s/scripts/deploy.sh
```

Expected output:
```
✅ Namespace created/updated
✅ Service created/updated
✅ StatefulSet created/updated
✅ Deployment complete!
```

## Step 7: Verify Deployment

```bash
# Check if the pod is running (may take 2-5 minutes to start)
kubectl get pods -n devenv -w

# You should see:
# NAME       READY   STATUS    RESTARTS   AGE
# devenv-0   1/1     Running   0          2m
```

**Troubleshooting**:
- If status is `ImagePullBackOff`: Double-check the image name in step 4
- If status is `Pending`: Check PVC status with `kubectl get pvc -n devenv`
- If status is `CrashLoopBackOff`: Check logs with `kubectl logs -n devenv devenv-0`

## Step 8: Access Your Dev Environment

```bash
# Shell into the pod
kubectl exec -it -n devenv devenv-0 -- /bin/zsh

# You should now be inside the dev environment!
# Try running some commands:
terraform version
claude --version
aws --version
gh --version
```

## Step 9: Test Your Setup

Inside the pod (from step 8):

```bash
# Test GitHub authentication
gh auth status

# Test Terraform Cloud authentication
terraform login -no-input
# Should see: "Saved API token"

# Test AWS authentication
aws sts get-caller-identity

# Clone a test repository
cd /workspace
git clone https://github.com/yourusername/your-repo.git
```

## Step 10: Access from Multiple Terminals (Multi-User)

To simulate multiple users or just have multiple sessions:

```bash
# Terminal 1
kubectl exec -it -n devenv devenv-0 -- /bin/zsh

# Terminal 2 (same pod)
kubectl exec -it -n devenv devenv-0 -- /bin/zsh

# Or scale to multiple users:
./k8s/scripts/scale.sh 3

# Then access different pods:
kubectl exec -it -n devenv devenv-0 -- /bin/zsh  # User 1
kubectl exec -it -n devenv devenv-1 -- /bin/zsh  # User 2
kubectl exec -it -n devenv devenv-2 -- /bin/zsh  # User 3
```

## Understanding Your Persistent Storage

Your data persists across pod restarts in these locations:

- `/workspace`: Your code and projects (10Gi PVC)
- `/commandhistory`: Bash/zsh history (1Gi PVC)
- `/home/node/.claude`: Claude Code configuration (1Gi PVC)

```bash
# View your persistent volumes
kubectl get pvc -n devenv

# Example output:
# NAME                        STATUS   VOLUME                 CAPACITY
# workspace-devenv-0          Bound    pvc-abc123...         10Gi
# bash-history-devenv-0       Bound    pvc-def456...         1Gi
# claude-config-devenv-0      Bound    pvc-ghi789...         1Gi
```

## Common Tasks

### View Logs

```bash
# Follow logs in real-time
kubectl logs -n devenv devenv-0 -f

# View last 100 lines
kubectl logs -n devenv devenv-0 --tail=100
```

### Restart the Pod

```bash
# Delete the pod (StatefulSet will recreate it)
kubectl delete pod devenv-0 -n devenv

# Your data is safe on the PVCs!
```

### Port Forwarding (for web services)

```bash
# If you're running a web server on port 8080 inside the pod
kubectl port-forward -n devenv devenv-0 8080:8080

# Access at http://localhost:8080 on your Mac
```

### Copy Files In/Out

```bash
# Copy FROM your Mac TO the pod
kubectl cp ./myfile.txt devenv/devenv-0:/workspace/myfile.txt

# Copy FROM the pod TO your Mac
kubectl cp devenv/devenv-0:/workspace/output.txt ./output.txt
```

## What You've Accomplished

✅ Built a production-ready Docker image from your devcontainer
✅ Deployed it to Kubernetes with persistent storage
✅ Configured secrets management
✅ Set up isolated dev environments
✅ Created a scalable multi-user platform

## Next Steps

1. **Add Remote Access**: Set up ingress for web-based access
2. **User Authentication**: Implement OAuth for user management
3. **Monitoring**: Add Prometheus/Grafana for observability
4. **Backup Strategy**: Automate workspace backups
5. **CI/CD Integration**: Automate builds and deployments

## Getting Help

If something isn't working:

```bash
# Check pod status
kubectl describe pod devenv-0 -n devenv

# Check events
kubectl get events -n devenv --sort-by='.lastTimestamp'

# Check secret exists
kubectl get secret devenv-secrets -n devenv

# Check PVCs
kubectl get pvc -n devenv
```

## Cleanup (When Done)

```bash
# Remove everything (CAUTION: deletes all data!)
./k8s/scripts/teardown.sh

# Or just scale down (keeps data)
./k8s/scripts/scale.sh 0
```

---

**Congratulations!** You now have a cloud-native, multi-user development platform running on Kubernetes! 🎉
