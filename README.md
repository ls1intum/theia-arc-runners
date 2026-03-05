# Theia ARC Runners

Infrastructure-as-code for deploying **GitHub Actions self-hosted runners** using Actions Runner Controller (ARC).

## Architecture

Stateless runners backed by a **Zot pull-through cache** (Docker Hub) and a **GitHub Actions Cache Server**.

| Cluster | Architecture | Runners | Storage Class | Zot Mirror |
|---------|--------------|---------|---------------|------------|
| theia-prod | AMD64 | `arc-runner-set-stateless` | `csi-rbd-sc` | In-cluster (`theia-arc-systems-zot.arc-systems.svc.cluster.local:5000`) |
| parma | ARM64 | `arc-runner-set-arm64` | `longhorn` | Cross-cluster NodePort (`131.159.88.30:30081`) |

## Features

- Stateless Runner Scale Sets that scale 10–50 runners per cluster
- Zot pull-through cache for `docker.io` (eliminates Docker Hub rate limits)
- GitHub Actions Cache Server for `actions/cache` compatibility (200Gi PVC)
- Memory-backed work volume on parma (30Gi RAM per runner, ~1000x faster than disk I/O)
- Organization-wide runners for `ls1intum` repositories

## Components

### Zot Registry Cache

Zot is deployed in `arc-systems` on theia-prod only. It proxies Docker Hub transparently using the `--registry-mirror` protocol — no workflow changes required.

DinD runner pods are configured with:
```
--registry-mirror=http://<zot-addr>
--insecure-registry=<zot-addr>
```

All `docker pull` calls route through Zot automatically. On cache miss, Zot fetches from `registry-1.docker.io`, caches the result, and serves it. Cache is retained for 30 days (720h) with built-in GC.

parma runners reach the same Zot instance via the NodePort at `131.159.88.30:30081`.

### GitHub Actions Cache Server

Deployed in `arc-systems`. Runners reference it via `ACTIONS_RESULTS_URL` and `CUSTOM_ACTIONS_RESULTS_URL`. Drop-in replacement for GitHub's hosted cache service, backed by a 200Gi PVC with 90-day cleanup.

### Runner Configuration

Runners use a manual DinD sidecar pattern:

- `init-dind-externals` — copies runner binaries into a shared volume
- `dind` — Docker daemon, privileged, with `--registry-mirror` and `--insecure-registry` pointing to Zot
- `runner` — `ghcr.io/falcondev-oss/actions-runner:latest`, connects to the daemon via shared Unix socket

## Deployment

See [AGENTS.md](AGENTS.md) for the canonical deploy/upgrade commands.

### Prerequisites

- `kubectl` configured for target cluster (`theia-prod` or `parma`)
- Helm 3.14+
- GitHub auth secret pre-created in `arc-runners` namespace:

```bash
# GitHub App (recommended)
kubectl create secret generic github-arc-secret \
  --namespace=arc-runners \
  --from-literal=github_app_id="<APP_ID>" \
  --from-literal=github_app_installation_id="<INSTALLATION_ID>" \
  --from-file=github_app_private_key=<path-to-private-key.pem>

# or Personal Access Token
kubectl create secret generic github-arc-secret \
  --namespace=arc-runners \
  --from-literal=github_token="ghp_xxxxxxxxxxxx"
```

### Deploy AMD64 (theia-prod)

```bash
kubectl config use-context theia-prod
cd helm-chart/theia-arc-bundle

# Part 1: Controller + Cache Server + Zot
helm upgrade --install theia-arc-systems . \
  --namespace arc-systems --create-namespace \
  --set arcRunners.enabled=false \
  --set arcRunnersArm.enabled=false \
  --wait --timeout 5m

# Part 2: Runners (zot.enabled=false — Zot is owned by Part 1)
helm upgrade --install theia-arc-runners . \
  --namespace arc-runners \
  --set cacheServer.enabled=false \
  --set arcController.enabled=false \
  --set zot.enabled=false \
  --set arcRunners.enabled=true \
  --wait --timeout 2m
```

### Deploy ARM64 (parma)

```bash
kubectl config use-context parma
cd helm-chart/theia-arc-bundle

# Part 1: Controller + Cache Server (no Zot on parma)
helm upgrade --install theia-arc-systems . \
  --namespace arc-systems --create-namespace \
  -f values-arm64.yaml \
  --set arcRunnersArm.enabled=false \
  --wait --timeout 2m

# Part 2: Runners
helm upgrade --install theia-arc-runners . \
  --namespace arc-runners \
  -f values-arm64.yaml \
  --set cacheServer.enabled=false \
  --set arcController.enabled=false \
  --set zot.enabled=false \
  --set arcRunnersArm.enabled=true \
  --wait --timeout 2m
```

### Verify

```bash
kubectl get pods -n arc-systems
kubectl get pods -n arc-runners
kubectl get autoscalingrunnersets -n arc-runners
kubectl get pvc -n arc-systems
```

Expected AutoScalingRunnerSets:
- `theia-prod`: `arc-runner-set-stateless`
- `parma`: `arc-runner-set-arm64`

## Documentation

- [Architecture](docs/ARCHITECTURE_V2.md) — System design and caching strategy
- [Troubleshooting](docs/TROUBLESHOOTING.md) — Common issues and solutions

## Cleanup and Maintenance

### Uninstall (order matters — runners before controller)

```bash
helm uninstall theia-arc-runners -n arc-runners
helm uninstall theia-arc-systems -n arc-systems
kubectl delete namespace arc-runners arc-systems
```

### Removing Orphaned Resources

```bash
# Check for orphaned AutoScalingRunnerSets
kubectl get autoscalingrunnersets -n arc-runners

# Delete orphaned runner set (terminates associated pods)
kubectl delete autoscalingrunnersets <old-name> -n arc-runners

# Then delete the orphaned service account
kubectl delete serviceaccount <old-sa-name> -n arc-runners
```

### Verifying Active Infrastructure

```bash
# theia-prod
kubectl --context=theia-prod get autoscalingrunnersets -n arc-runners
kubectl --context=theia-prod get pods -n arc-runners

# parma
kubectl --context=parma get autoscalingrunnersets -n arc-runners
kubectl --context=parma get pods -n arc-runners
```

## Related Projects

- [artemis-theia-blueprints](https://github.com/ls1intum/artemis-theia-blueprints) — Theia IDE images
- [ls1intum/.github](https://github.com/ls1intum/.github) — Reusable workflows
- [Actions Runner Controller](https://github.com/actions/actions-runner-controller) — Upstream ARC project
- [Zot Registry](https://zotregistry.dev/) — OCI-native pull-through cache
