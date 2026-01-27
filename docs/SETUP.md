# ARC Runner Setup Guide

Complete installation guide for deploying GitHub Actions self-hosted runners with registry caching.

## Prerequisites

1. **Kubernetes Cluster Access**
   - `kubectl` configured for target cluster (`theia-prod` or `parma`)
   - Cluster Admin rights

2. **Tools**
   - Helm v3.14+
   - `kubectl`

3. **GitHub Token**
   - Personal Access Token with scopes:
     - `repo` (Full control of private repositories)
     - `workflow` (Update GitHub Action workflows)
     - `admin:org` (Required for org-level runners)

## Deployment Steps

### 1. Set Context and Token

```bash
# For AMD64 (theia-prod)
kubectl config use-context theia-prod

# For ARM64 (parma)
kubectl config use-context parma

# Set your GitHub PAT
export GITHUB_PAT="ghp_your_token_here"
```

### 2. Deploy Registry Mirrors

Registry mirrors must be deployed first. The script handles this automatically, but for manual deployment:

```bash
# AMD64 cluster
kubectl apply -f manifests/registry-mirror.yaml
kubectl apply -f manifests/registry-mirror-ghcr.yaml

# ARM64 cluster
kubectl apply -f manifests/registry-mirror-parma.yaml
kubectl apply -f manifests/registry-mirror-ghcr-parma.yaml
```

Wait for pods to be ready:

```bash
kubectl get pods -n registry-mirror -w
```

### 3. Deploy ARC and Runners

```bash
# AMD64
./scripts/deploy-amd.sh stateless

# ARM64
./scripts/deploy-arm.sh arm64
```

The script will:
1. Create `arc-systems` and `arc-runners` namespaces
2. Install/upgrade ARC controller
3. Deploy RBAC configuration
4. Create/update GitHub PAT secret
5. Deploy registry mirrors
6. Deploy runner scale set

### 4. Verify Deployment

```bash
# Check ARC controller
kubectl get pods -n arc-systems

# Check listeners (should show 1 per runner set)
kubectl get pods -n arc-systems | grep listener

# Check registry mirrors
kubectl get pods -n registry-mirror

# Check GitHub (should show runner as Idle)
# Go to: Organization Settings -> Actions -> Runners
```

## Manual Deployment

If you prefer step-by-step commands:

```bash
# 1. Create namespaces
kubectl create namespace arc-systems --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace arc-runners --dry-run=client -o yaml | kubectl apply -f -

# 2. Install ARC Controller
helm install arc \
  --namespace arc-systems \
  oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set-controller

# 3. Wait for controller
kubectl wait --for=condition=ready pod \
  -l app.kubernetes.io/name=gha-runner-scale-set-controller \
  -n arc-systems \
  --timeout=300s

# 4. Deploy RBAC
kubectl apply -f manifests/rbac-runner.yaml

# 5. Create GitHub secret
kubectl create secret generic github-arc-secret \
  --namespace=arc-runners \
  --from-literal=github_token="$GITHUB_PAT" \
  --dry-run=client -o yaml | kubectl apply -f -

# 6. Deploy registry mirrors
kubectl apply -f manifests/registry-mirror.yaml
kubectl apply -f manifests/registry-mirror-ghcr.yaml

# 7. Deploy runner set (AMD64 example)
helm upgrade --install arc-runner-set-stateless \
  --namespace arc-runners \
  oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set \
  -f manifests/values-runner-set-stateless.yaml
```

## Configuration

### Runner Scale Set Values

Key configuration in `values-runner-set-*.yaml`:

| Setting | Value | Description |
|---------|-------|-------------|
| `minRunners` | 2 | Minimum idle runners |
| `maxRunners` | 10 | Maximum concurrent runners |
| `githubConfigUrl` | `https://github.com/ls1intum` | Organization URL |
| `--registry-mirror` | `http://registry-mirror.registry-mirror.svc.cluster.local:5000` | Docker Hub cache |

### Registry Mirror Settings

| Setting | Value | Description |
|---------|-------|-------------|
| `proxy.ttl` | 720h | Cached layers live 30 days |
| `storage` | 200Gi | PVC size per registry |
| `storageClassName` | `csi-rbd-sc` / `local-path` | Cluster-specific |

## Updating Configuration

```bash
# Update runner config
vim manifests/values-runner-set-stateless.yaml
helm upgrade arc-runner-set-stateless \
  --namespace arc-runners \
  oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set \
  -f manifests/values-runner-set-stateless.yaml

# Update registry config
kubectl apply -f manifests/registry-mirror.yaml
kubectl rollout restart deployment/registry-mirror -n registry-mirror
```

## Cleanup

```bash
# Remove runner set
helm uninstall arc-runner-set-stateless -n arc-runners

# Remove ARC controller
helm uninstall arc -n arc-systems

# Remove registry mirrors
kubectl delete namespace registry-mirror

# Remove namespaces
kubectl delete namespace arc-runners arc-systems
```

## Troubleshooting

See [TROUBLESHOOTING.md](TROUBLESHOOTING.md) for common issues.

### Quick Checks

```bash
# Listener not starting?
kubectl logs -n arc-systems -l app.kubernetes.io/name=gha-runner-scale-set-controller

# Runner pods failing?
kubectl describe pod -n arc-runners <pod-name>

# Registry cache issues?
kubectl logs -n registry-mirror deploy/registry-mirror
```
