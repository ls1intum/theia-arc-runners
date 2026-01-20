# ARC Runner Setup Guide

This guide describes how to deploy the Actions Runner Controller (ARC) infrastructure with persistent Docker layer caching for `ls1intum` repositories.

## Prerequisites

1. **Kubernetes Cluster**
   - Recommended: Same cluster where Theia Cloud runs
   - Can be Docker Desktop (local), minikube, or a production cluster
   - Must support PersistentVolumeClaims (PVCs)

2. **Tools**
   - `kubectl` configured for your cluster
   - `helm` v3.14+ installed
   - `gh` CLI (optional, for validation)

3. **Permissions**
   - Cluster Admin rights (to create namespaces and CRDs)
   - GitHub Organization Admin rights (to register org-level runners)

## GitHub Configuration

### 1. Create Personal Access Token (PAT)
You need a GitHub PAT to register the runners.

1. Go to [GitHub Settings -> Developer settings -> Personal access tokens](https://github.com/settings/tokens)
2. Generate new token (classic)
3. **Scopes Required**:
   - `repo` (Full control of private repositories)
   - `workflow` (Update GitHub Action workflows)
   - `admin:org` (Full control of orgs and teams, read:org) - **Required for org-level runners**

### 2. Configure Environment (Optional but Recommended)
If deploying via GitHub Actions:

1. Go to this repository's **Settings -> Environments**
2. Create environment `arc-runners`
3. Add Secrets:
   - `KUBECONFIG`: Output of `cat ~/.kube/config`
   - `GH_PAT`: Your PAT from step 1

## Deployment

### Option 1: Manual Deployment (Script)

The easiest way to deploy from your local machine.

```bash
# 1. Set your PAT
export GITHUB_PAT="ghp_your_token_here"

# 2. Run deployment script
./scripts/deploy.sh all
```

This will:
1. Create namespaces `arc-systems` and `arc-runners`
2. Install the ARC Controller
3. Create the GitHub secret
4. Create 3 PVCs (100Gi each)
5. Deploy 3 runner scale sets

### Option 2: Step-by-Step Manual Deployment

If you prefer to run commands manually:

```bash
# 1. Create namespaces
kubectl create namespace arc-systems
kubectl create namespace arc-runners

# 2. Install ARC Controller
helm repo add actions-runner-controller https://actions.github.io/actions-runner-controller
helm install arc \
  --namespace arc-systems \
  oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set-controller

# 3. Create Secret
kubectl create secret generic github-arc-secret \
  --namespace=arc-runners \
  --from-literal=github_token="YOUR_PAT_HERE"

# 4. Create PVCs
kubectl apply -f manifests/pvc-docker-cache-1.yaml
kubectl apply -f manifests/pvc-docker-cache-2.yaml
kubectl apply -f manifests/pvc-docker-cache-3.yaml

# 5. Deploy Runners
helm install arc-runner-set-1 \
  --namespace arc-runners \
  oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set \
  -f manifests/values-runner-set-1.yaml

# (Repeat for runner sets 2 and 3)
```

## Verification

### 1. Check Pods
```bash
# Check Controller
kubectl get pods -n arc-systems

# Check Listeners (should be 3)
kubectl get pods -n arc-systems | grep listener
```

### 2. Check PVCs
```bash
kubectl get pvc -n arc-runners
# Should show 3 Bound PVCs of 100Gi each
```

### 3. Check GitHub
Go to **Organization Settings -> Actions -> Runners**. You should see:
- `arc-runner-set-1` (Idle)
- `arc-runner-set-2` (Idle)
- `arc-runner-set-3` (Idle)

## Maintenance

### Updating Configuration
Modify the values files in `manifests/` and re-run the deployment script:
```bash
./scripts/deploy.sh all
```

### Cleaning Up
To remove everything:
```bash
helm uninstall arc-runner-set-1 -n arc-runners
helm uninstall arc-runner-set-2 -n arc-runners
helm uninstall arc-runner-set-3 -n arc-runners
kubectl delete pvc --all -n arc-runners
helm uninstall arc -n arc-systems
kubectl delete namespace arc-runners arc-systems
```
**Warning**: Deleting PVCs will lose the Docker cache!
