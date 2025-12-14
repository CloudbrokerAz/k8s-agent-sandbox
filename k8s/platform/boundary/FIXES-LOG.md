# Boundary Configuration Fixes Log

This document tracks fixes made to get Boundary SSH proxy working with nginx-ingress.

## Issue Summary

Boundary worker uses dynamic SNI-based TLS where session IDs (e.g., `s_vVHOFTrgR8`) are passed as SNI values. Standard nginx-ingress TLS termination cannot handle this because it expects SNI to match host rules.

## Changes Made

### 1. TCP Passthrough via nginx-ingress ConfigMap

**Problem:** nginx-ingress with SSL passthrough still inspects SNI for routing, breaking Boundary's session-based SNI.

**Solution:** Use nginx-ingress TCP services ConfigMap to expose raw TCP port without TLS handling.

**Files to create/update:**

```yaml
# Create: ingress-nginx/tcp-services ConfigMap
apiVersion: v1
kind: ConfigMap
metadata:
  name: tcp-services
  namespace: ingress-nginx
data:
  "9202": "boundary/boundary-worker:9202"
```

**Commands to run:**
```bash
# Add TCP ConfigMap to nginx-ingress deployment args
kubectl patch deployment ingress-nginx-controller -n ingress-nginx \
  --type='json' \
  -p='[{"op": "add", "path": "/spec/template/spec/containers/0/args/-", "value": "--tcp-services-configmap=ingress-nginx/tcp-services"}]'

# Add port 9202 to nginx-ingress service
kubectl patch svc ingress-nginx-controller -n ingress-nginx \
  --type='json' \
  -p='[{"op": "add", "path": "/spec/ports/-", "value": {"name": "boundary-proxy", "port": 9202, "protocol": "TCP", "targetPort": 9202}}]'
```

### 2. Worker Configuration Updates

**File:** `k8s/platform/boundary/manifests/03-configmap.yaml`

**Changes:**
- `public_addr` changed from `boundary-worker.local:443` to `localhost:9202`
- Worker proxy listener `tls_disable = true` for dev environment

### 3. Worker Ingress Annotations

**File:** `k8s/platform/boundary/manifests/12-worker-ingress.yaml`

**Changes:**
- Removed `ssl-passthrough: "true"` annotation
- Added `backend-protocol: "HTTP"` annotation
- Added WebSocket timeout annotations

### 4. Kind Cluster Port Mapping

Ensure Kind config includes port 9202 mapping:

```yaml
extraPortMappings:
  - containerPort: 9202
    hostPort: 9202
    protocol: TCP
```

## Current Status

- TCP passthrough configured but SSH connection still shows EOF error
- Further investigation needed on Boundary worker listener configuration
- May need to enable TLS on worker with proper certificate handling

## Deployment Script Integration

Add to `k8s/scripts/deploy-all.sh` after Boundary deployment:

```bash
# Configure nginx-ingress for Boundary TCP passthrough
configure_boundary_tcp_passthrough() {
    log "Configuring nginx-ingress TCP passthrough for Boundary..."

    # Create TCP services ConfigMap
    kubectl apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: tcp-services
  namespace: ingress-nginx
data:
  "9202": "boundary/boundary-worker:9202"
EOF

    # Patch nginx-ingress deployment
    if ! kubectl get deployment -n ingress-nginx ingress-nginx-controller -o yaml | grep -q "tcp-services-configmap"; then
        kubectl patch deployment ingress-nginx-controller -n ingress-nginx \
          --type='json' \
          -p='[{"op": "add", "path": "/spec/template/spec/containers/0/args/-", "value": "--tcp-services-configmap=ingress-nginx/tcp-services"}]'
    fi

    # Add port 9202 to nginx-ingress service
    if ! kubectl get svc ingress-nginx-controller -n ingress-nginx -o yaml | grep -q "boundary-proxy"; then
        kubectl patch svc ingress-nginx-controller -n ingress-nginx \
          --type='json' \
          -p='[{"op": "add", "path": "/spec/ports/-", "value": {"name": "boundary-proxy", "port": 9202, "protocol": "TCP", "targetPort": 9202}}]'
    fi

    kubectl rollout status deployment/ingress-nginx-controller -n ingress-nginx --timeout=120s
}
```

## References

- [Boundary TLS Connections](https://developer.hashicorp.com/boundary/docs/concepts/security/connections-tls)
- [nginx-ingress TCP Services](https://kubernetes.github.io/ingress-nginx/user-guide/exposing-tcp-udp-services/)
