# Theia ARC Bundle Helm Chart

Production-grade Helm umbrella chart for GitHub Actions Runner Controller (ARC) with GitHub Actions Cache Server.

## Overview

This chart deploys a complete ARC setup with integrated caching:

- **GitHub Actions Cache Server** (vendored subchart):
  - Drop-in replacement for GitHub's hosted cache service
  - Compatible with official `actions/cache` action
  - Persistent storage backend (filesystem + SQLite)
  - 200GB PVC per cluster

- **Harbor Registry** (AMD64 only):
  - Pull-through proxy cache for Docker Hub (`dockerhub-proxy`) and GHCR (`ghcr-proxy`)
  - Eliminates Docker Hub rate limit errors on self-hosted runners
  - DinD containers configured with `--registry-mirror` pointing to Harbor

- **ARC Components** (external charts):
  - gha-runner-scale-set-controller (v0.9.3)
  - gha-runner-scale-set (AMD64 and/or ARM64)

## Why Two Helm Commands?

GitHub's security best practice requires the ARC **controller** and **runners** to live in separate namespaces (`arc-systems` and `arc-runners`). Helm 3 cannot deploy subcharts into different namespaces within a single release.

The solution is to deploy the **same chart twice** using feature flags:

| Command | Release name | Namespace | What gets deployed |
|---------|-------------|-----------|-------------------|
| Part 1 | `theia-arc-systems` | `arc-systems` | Controller + Cache Server |
| Part 2 | `theia-arc-runners` | `arc-runners` | AutoscalingRunnerSet only |

> **Important:** The Part 1 release name **must** be `theia-arc-systems`. The controller creates a ServiceAccount named `<release-name>-gha-rs-controller`, and Part 2 references it by that exact name.

## Prerequisites

1. **Kubernetes cluster** (v1.23+)
2. **Helm** (v3.8+)
3. **GitHub App** (recommended) or Personal Access Token with `repo` + `admin:org` scopes
4. **StorageClass** configured (default: `csi-rbd-sc` for AMD64, `longhorn` for ARM64)

## Setup

### Clone Repository

```bash
git clone https://github.com/ls1intum/theia-arc-runners.git
cd theia-arc-runners
```

The `github-actions-cache-server` chart is included as a local subchart (vendored from [falcondev-oss/github-actions-cache-server](https://github.com/falcondev-oss/github-actions-cache-server)).

## Quick Start (AMD64 / theia-prod)

### Step 1: Create the GitHub auth secret

The `arc-runners` namespace must exist before the secret can be created, but it also needs to be Helm-owned so Part 2 can adopt it. Pre-create it with the correct labels:

```bash
kubectl create namespace arc-runners
kubectl label namespace arc-runners app.kubernetes.io/managed-by=Helm
kubectl annotate namespace arc-runners \
  meta.helm.sh/release-name=theia-arc-runners \
  meta.helm.sh/release-namespace=arc-runners
```

Then create the secret:

**Option A — GitHub App (recommended):**

```bash
kubectl create secret generic github-arc-secret \
  --namespace=arc-runners \
  --from-literal=github_app_id="<APP_ID>" \
  --from-literal=github_app_installation_id="<INSTALLATION_ID>" \
  --from-file=github_app_private_key=<path-to-private-key.pem>
```

**Option B — Personal Access Token:**

```bash
kubectl create secret generic github-arc-secret \
  --namespace=arc-runners \
  --from-literal=github_token="ghp_xxxxxxxxxxxxxxxxxxxx"
```

### Step 2: Deploy Part 1 — Controller + Cache Server

```bash
cd helm-chart/theia-arc-bundle

helm install theia-arc-systems . \
  --namespace arc-systems \
  --create-namespace \
  --set arcRunners.enabled=false \
  --set arcRunnersArm.enabled=false \
  --wait \
  --timeout 2m
```

Verify the controller and cache server are running before proceeding:

```bash
kubectl get pods -n arc-systems
# Expected: 
# - theia-arc-systems-gha-rs-controller-... 1/1 Running
# - github-actions-cache-server-...        1/1 Running
```

### Step 3: Deploy Part 2 — Runners

```bash
helm install theia-arc-runners . \
  --namespace arc-runners \
  --create-namespace \
  --set cacheServer.enabled=false \
  --set arcController.enabled=false \
  --set harbor.enabled=false \
  --set arcRunners.enabled=true \
  --wait \
  --timeout 2m
```

### Step 4: Verify

```bash
kubectl get pods -n arc-systems
kubectl get pods -n arc-runners
kubectl get autoscalingrunnersets -n arc-runners
kubectl get pvc -n arc-systems
# Expected PVC: github-actions-cache-server (200Gi, Bound)
```

## ARM64 Cluster (parma)

Use `values-arm64.yaml` as an overlay. It sets `storageClass: local-path`, `nodeSelector: arm64`, and configures ARM64 runners.

### Step 1: Pre-create the `arc-runners` namespace

Same as the AMD64 flow:

```bash
kubectl --context=parma create namespace arc-runners
kubectl --context=parma label namespace arc-runners app.kubernetes.io/managed-by=Helm
kubectl --context=parma annotate namespace arc-runners \
  meta.helm.sh/release-name=theia-arc-runners \
  meta.helm.sh/release-namespace=arc-runners
```

Then create the GitHub auth secret (see AMD64 Step 1 for secret options).

### Step 2: Deploy Part 1 — Controller + Cache Server

```bash
helm install theia-arc-systems . \
  --namespace arc-systems \
  --create-namespace \
  -f values-arm64.yaml \
  --set arcRunnersArm.enabled=false \
  --wait --timeout 2m
```

### Step 3: Deploy Part 2 — ARM64 Runners

```bash
helm install theia-arc-runners . \
  --namespace arc-runners \
  -f values-arm64.yaml \
  --set cacheServer.enabled=false \
  --set arcController.enabled=false \
  --set harbor.enabled=false \
  --set arcRunnersArm.enabled=true \
  --wait --timeout 2m
```

## Uninstallation

> **Always uninstall in this order.** Deleting namespaces before Helm uninstall causes ARC runners to get stuck with finalizers that block namespace deletion indefinitely.

```bash
# Step 1: Runners first — ARC gracefully deregisters from GitHub
helm uninstall theia-arc-runners -n arc-runners

# Step 2: Controller + cache server
helm uninstall theia-arc-systems -n arc-systems

# Step 3: Delete namespaces
kubectl delete namespace arc-runners arc-systems
```

**Warning:** This deletes all PVCs and cached data.

## Upgrading

Upgrade each release independently:

```bash
helm upgrade theia-arc-systems . \
  --namespace arc-systems \
  --set arcRunners.enabled=false \
  --set arcRunnersArm.enabled=false \
  --wait --timeout 2m

helm upgrade theia-arc-runners . \
  --namespace arc-runners \
  --set cacheServer.enabled=false \
  --set arcController.enabled=false \
  --set harbor.enabled=false \
  --set arcRunners.enabled=true \
  --wait --timeout 2m
```

## Configuration

### Key values

| Value | Default | Description |
|-------|---------|-------------|
| `global.storageClass` | `csi-rbd-sc` | StorageClass for all PVCs |
| `global.nodeSelector` | `kubernetes.io/arch: amd64` | Node selector for all pods |
| `cacheServer.enabled` | `true` | Deploy GitHub Actions Cache Server |
| `cacheServer.persistentVolumeClaim.storage` | `200Gi` | PVC size for cache data |
| `arcController.enabled` | `true` | Deploy ARC controller |
| `arcRunners.enabled` | `true` | Deploy AMD64 runner scale set |
| `arcRunnersArm.enabled` | `false` | Deploy ARM64 runner scale set |
| `harbor.enabled` | `true` | Deploy Harbor registry (AMD64 only; disable in Part 2) |
| `arcRunners.minRunners` | `10` | Minimum idle runners |
| `arcRunners.maxRunners` | `50` | Maximum runners |
| `arcRunners.githubConfigUrl` | `https://github.com/ls1intum` | GitHub org URL |
| `arcRunners.githubConfigSecret` | `github-arc-secret` | Name of auth secret in `arc-runners` |

### Namespace summary

| Namespace | Created by | Contains |
|-----------|-----------|----------|
| `arc-systems` | Part 1 (`--create-namespace`) | Controller, Cache Server |
| `arc-runners` | Manually (pre-created with Helm labels) | AutoscalingRunnerSet, Runner pods |

## Troubleshooting

### Docker Hub rate limits / pull failures

Harbor acts as a pull-through cache for Docker Hub. If runners still hit rate limits:

```bash
# Verify Harbor is running in arc-systems
kubectl get pods -n arc-systems | grep harbor

# Check dind args include --registry-mirror
kubectl get pod -n arc-runners <runner-pod> -o jsonpath='{.spec.containers[?(@.name=="dind")].args}'

# Check Harbor proxy project exists
kubectl logs -n arc-systems -l app.kubernetes.io/name=harbor-proxy-setup
```

### Cache server not accessible from runners

Verify the cache server service is running:

```bash
kubectl get svc -n arc-systems github-actions-cache-server
kubectl logs -n arc-systems -l app.kubernetes.io/name=github-actions-cache-server
```

Check runner logs for cache connectivity:

```bash
kubectl logs -n arc-runners <runner-pod> -c runner
```

### Runners don't pick up GitHub Actions jobs

```bash
kubectl get pods -n arc-systems | grep listener
kubectl logs -n arc-systems -l app.kubernetes.io/name=gha-runner-scale-set-controller --tail=50
kubectl get secret github-arc-secret -n arc-runners
```

### `helm install` fails with "invalid ownership metadata"

The `arc-runners` namespace was created without Helm labels. Add them so Helm can adopt it:

```bash
kubectl label namespace arc-runners app.kubernetes.io/managed-by=Helm
kubectl annotate namespace arc-runners \
  meta.helm.sh/release-name=theia-arc-runners \
  meta.helm.sh/release-namespace=arc-runners
```

Then re-run the `helm install` command.

### Runners stuck terminating after `helm uninstall`

The controller was deleted before runners finished deregistering. Strip finalizers manually:

```bash
kubectl get ephemeralrunners -n arc-runners -o name | xargs -I{} kubectl patch {} -n arc-runners \
  --type=json -p='[{"op":"remove","path":"/metadata/finalizers"}]'
kubectl get autoscalingrunnersets -n arc-runners -o name | xargs -I{} kubectl patch {} -n arc-runners \
  --type=json -p='[{"op":"remove","path":"/metadata/finalizers"}]'
```

### Cache data growing too large

The cache server automatically cleans up entries older than 90 days. To adjust this:

```bash
helm upgrade theia-arc-systems . \
  --namespace arc-systems \
  --set cacheServer.config.cacheCleanupOlderThanDays=30 \
  --reuse-values
```

Or increase PVC size:

```bash
kubectl edit pvc github-actions-cache-server -n arc-systems
# Edit spec.resources.requests.storage to desired size
```

## Chart Dependencies

- **github-actions-cache-server** (v1.0.0) — local subchart (vendored from https://github.com/falcondev-oss/github-actions-cache-server)
- **harbor** (v1.18.2) — pull-through proxy cache for Docker Hub + GHCR (AMD64 only)
- **gha-runner-scale-set-controller** (v0.9.3) — `ghcr.io/actions/actions-runner-controller-charts`
- **gha-runner-scale-set** (v0.9.3 × 2) — AMD64 + ARM64 aliases

## References

- [GitHub Actions Runner Controller](https://github.com/actions/actions-runner-controller)
- [GitHub Actions Cache Server](https://github.com/falcondev-oss/github-actions-cache-server)
- [Harbor Registry](https://goharbor.io/)
- [ARC Security Best Practices](https://docs.github.com/en/actions/hosting-your-own-runners/managing-self-hosted-runners-with-actions-runner-controller/deploying-runner-scale-sets-with-actions-runner-controller#security-considerations)
