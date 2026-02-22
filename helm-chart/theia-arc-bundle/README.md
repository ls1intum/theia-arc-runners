# Theia ARC Bundle Helm Chart

Production-grade Helm umbrella chart for GitHub Actions Runner Controller (ARC) with build cache infrastructure.

## Overview

This chart deploys a complete ARC setup with integrated build caches:

- **Build Caches** (local subchart):
  - Docker Registry Mirror (Docker Hub)
  - Docker Registry Mirror (GHCR)
  - Verdaccio (npm cache)
  - Apt-Cacher-NG (Ubuntu/Debian packages)
  - Squid (HTTPS proxy with SSL bumping for VSIX)

- **ARC Components** (external charts):
  - gha-runner-scale-set-controller (v0.9.3)
  - gha-runner-scale-set (AMD64 and/or ARM64)

## Why Two Helm Commands?

GitHub's security best practice requires the ARC **controller** and **runners** to live in separate namespaces (`arc-systems` and `arc-runners`). Helm 3 cannot deploy subcharts into different namespaces within a single release — it's a hard constraint of Helm's ownership model.

The solution is to deploy the **same chart twice** using feature flags:

| Command | Release name | Namespace | What gets deployed |
|---------|-------------|-----------|-------------------|
| Part 1 | `theia-arc-systems` | `arc-systems` | Controller + all build caches |
| Part 2 | `theia-arc-runners` | `arc-runners` | AutoscalingRunnerSet only |

> **Important:** The Part 1 release name **must** be `theia-arc-systems`. The controller creates a ServiceAccount named `<release-name>-gha-rs-controller`, and Part 2 references it by that exact name.

Note: The build caches land in their own namespaces (`squid`, `verdaccio`, etc.) even though they are part of the Part 1 release. This works because the `build-caches` local subchart hardcodes `namespace:` on each resource directly in its templates — so Helm's release still belongs to `arc-systems` but individual resources are written to their respective namespaces. The upstream ARC charts (third-party) use `Release.Namespace` throughout and cannot be overridden this way, hence the split.

## Prerequisites

1. **Kubernetes cluster** (v1.23+)
2. **Helm** (v3.8+)
3. **GitHub App** (recommended) or Personal Access Token with `repo` + `admin:org` scopes
4. **StorageClass** configured (default: `csi-rbd-sc`)
5. **Squid CA certificate** secret pre-created (see below)

## Quick Start (AMD64 / theia-prod)

### Step 1: Create the Squid CA secret

Squid uses SSL bumping to cache HTTPS traffic. It needs a CA cert+key pair to sign intercepted connections. Generate one and create the secret **before** installing the chart:

```bash
openssl req -new -newkey rsa:4096 -days 3650 -nodes -x509 \
  -subj "/CN=Squid CA/O=Theia/C=DE" \
  -keyout squid-ca.key -out squid-ca.crt

kubectl create namespace squid --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic squid-ca-cert \
  --namespace=squid \
  --from-file=tls.crt=squid-ca.crt \
  --from-file=tls.key=squid-ca.key

rm squid-ca.crt squid-ca.key
```

### Step 2: Create the GitHub auth secret

**Option A — GitHub App (recommended):**

```bash
kubectl create namespace arc-runners --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic github-arc-secret \
  --namespace=arc-runners \
  --from-literal=github_app_id="<APP_ID>" \
  --from-literal=github_app_installation_id="<INSTALLATION_ID>" \
  --from-file=github_app_private_key=<path-to-private-key.pem>
```

**Option B — Personal Access Token:**

```bash
kubectl create namespace arc-runners --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic github-arc-secret \
  --namespace=arc-runners \
  --from-literal=github_token="ghp_xxxxxxxxxxxxxxxxxxxx"
```

### Step 3: Deploy Part 1 — Controller + Build Caches

```bash
cd helm-chart/theia-arc-bundle

helm install theia-arc-systems . \
  --namespace arc-systems \
  --create-namespace \
  --set arcRunners.enabled=false \
  --set arcRunnersArm.enabled=false \
  --wait \
  --timeout 10m
```

Verify the controller is running before proceeding:

```bash
kubectl get pods -n arc-systems
# Expected: theia-arc-systems-gha-rs-controller-... 1/1 Running
```

### Step 4: Deploy Part 2 — Runners

```bash
helm install theia-arc-runners . \
  --namespace arc-runners \
  --create-namespace \
  --set buildCaches.enabled=false \
  --set arcController.enabled=false \
  --set arcRunners.enabled=true \
  --wait \
  --timeout 10m
```

### Step 5: Verify

```bash
kubectl get pods -n arc-systems
kubectl get pods -n arc-runners
kubectl get pods -n squid
kubectl get pods -n verdaccio
kubectl get pods -n registry-mirror
kubectl get pods -n apt-cacher-ng
kubectl get autoscalingrunnersets -n arc-runners
```

## ARM64 Cluster (parma)

Use `values-arm64.yaml` as an overlay. The two-step process is identical:

```bash
# Part 1
helm install theia-arc-systems . \
  --namespace arc-systems \
  --create-namespace \
  -f values-arm64.yaml \
  --set arcRunnersArm.enabled=false \
  --wait --timeout 10m

# Part 2
helm install theia-arc-runners . \
  --namespace arc-runners \
  --create-namespace \
  -f values-arm64.yaml \
  --set buildCaches.enabled=false \
  --set arcController.enabled=false \
  --set arcRunnersArm.enabled=true \
  --wait --timeout 10m
```

## Uninstallation

> **Always uninstall in this order.** Deleting namespaces before Helm uninstall causes ARC runners to get stuck with finalizers that block namespace deletion indefinitely.

```bash
# Step 1: Runners first — ARC gracefully deregisters from GitHub
helm uninstall theia-arc-runners -n arc-runners

# Step 2: Controller + caches
helm uninstall theia-arc-systems -n arc-systems

# Step 3: Delete namespaces
kubectl delete namespace arc-runners arc-systems
kubectl delete namespace squid verdaccio registry-mirror apt-cacher-ng
```

**Warning:** This deletes all PVCs and cached data.

## Upgrading

Upgrade each release independently:

```bash
helm upgrade theia-arc-systems . \
  --namespace arc-systems \
  --set arcRunners.enabled=false \
  --set arcRunnersArm.enabled=false \
  --wait --timeout 10m

helm upgrade theia-arc-runners . \
  --namespace arc-runners \
  --set buildCaches.enabled=false \
  --set arcController.enabled=false \
  --set arcRunners.enabled=true \
  --wait --timeout 10m
```

## Configuration

### Key values

| Value | Default | Description |
|-------|---------|-------------|
| `global.storageClass` | `csi-rbd-sc` | StorageClass for all PVCs |
| `global.nodeSelector` | `kubernetes.io/arch: amd64` | Node selector for all pods |
| `buildCaches.enabled` | `true` | Deploy build cache services |
| `arcController.enabled` | `true` | Deploy ARC controller |
| `arcRunners.enabled` | `true` | Deploy AMD64 runner scale set |
| `arcRunnersArm.enabled` | `false` | Deploy ARM64 runner scale set |
| `arcRunners.minRunners` | `10` | Minimum idle runners |
| `arcRunners.maxRunners` | `50` | Maximum runners |
| `arcRunners.githubConfigUrl` | `https://github.com/ls1intum` | GitHub org URL |
| `arcRunners.githubConfigSecret` | `github-arc-secret` | Name of auth secret in `arc-runners` |
| `buildCaches.squid.caSecretName` | `squid-ca-cert` | Name of Squid CA secret in `squid` ns |

### Namespace summary

| Namespace | Created by | Contains |
|-----------|-----------|----------|
| `arc-systems` | Part 1 (`--create-namespace`) | Controller, Listener pod |
| `arc-runners` | Part 2 (`--create-namespace`) | AutoscalingRunnerSet, Runner pods |
| `squid` | Part 1 (build-caches subchart) | Squid proxy |
| `verdaccio` | Part 1 (build-caches subchart) | npm cache |
| `registry-mirror` | Part 1 (build-caches subchart) | Docker Hub + GHCR mirrors |
| `apt-cacher-ng` | Part 1 (build-caches subchart) | apt package cache |

## Troubleshooting

### Runners stuck in `Init:0/2`

The `wait-for-caches` init container is waiting for a cache service. Check which one:

```bash
kubectl logs -n arc-runners <runner-pod> -c wait-for-caches
kubectl get pods -n squid -n verdaccio -n registry-mirror -n apt-cacher-ng
```

Most common cause: Squid in `CrashLoopBackOff` due to an invalid CA key. Verify:

```bash
kubectl get secret squid-ca-cert -n squid -o jsonpath='{.data.tls\.key}' | base64 -d | openssl rsa -check -noout
# Expected: RSA key ok
```

### Runners don't pick up GitHub Actions jobs

```bash
kubectl get pods -n arc-systems | grep listener
kubectl logs -n arc-systems -l app.kubernetes.io/name=gha-runner-scale-set-controller --tail=50
kubectl get secret github-arc-secret -n arc-runners
```

### `helm install` fails with "invalid ownership metadata"

A namespace was manually created before Helm. Strip its finalizers and delete it, then re-run with `--create-namespace`:

```bash
kubectl get namespace arc-runners -o json \
  | jq '.spec.finalizers = []' \
  | kubectl replace --raw /api/v1/namespaces/arc-runners/finalize -f -
kubectl delete namespace arc-runners --force --grace-period=0
```

### Runners stuck terminating after `helm uninstall`

The controller was deleted before runners finished deregistering. Strip finalizers manually:

```bash
kubectl get ephemeralrunners -n arc-runners -o name | xargs -I{} kubectl patch {} -n arc-runners \
  --type=json -p='[{"op":"remove","path":"/metadata/finalizers"}]'
kubectl get autoscalingrunnersets -n arc-runners -o name | xargs -I{} kubectl patch {} -n arc-runners \
  --type=json -p='[{"op":"remove","path":"/metadata/finalizers"}]'
```

## Chart Dependencies

- **build-caches** (v0.1.0) — local subchart (`charts/build-caches`)
- **gha-runner-scale-set-controller** (v0.9.3) — `ghcr.io/actions/actions-runner-controller-charts`
- **gha-runner-scale-set** (v0.9.3 × 2) — AMD64 + ARM64 aliases

## References

- [GitHub Actions Runner Controller](https://github.com/actions/actions-runner-controller)
- [ARC Security Best Practices](https://docs.github.com/en/actions/hosting-your-own-runners/managing-self-hosted-runners-with-actions-runner-controller/deploying-runner-scale-sets-with-actions-runner-controller#security-considerations)
