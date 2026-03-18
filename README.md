# Theia ARC Runners

Infrastructure-as-code for deploying **GitHub Actions self-hosted runners** using Actions Runner Controller (ARC).

## Architecture

BuildKit-focused runner sets backed by stateful BuildKit workers, a shared Zot pull-through cache (Docker Hub), and a GitHub Actions Cache Server.

| Cluster | Architecture | Runner Set | BuildKit Namespace | BuildKit Storage Class | Zot Mirror |
|---------|--------------|------------|--------------------|------------------------|------------|
| theia-prod | AMD64 | `arc-buildkit-eduide-amd64` | `buildkit-exp` | `csi-rbd-sc` | `131.159.88.117:30081` |
| parma | ARM64 | `arc-buildkit-eduide-arm64` | `buildkit` | `longhorn` | `131.159.88.117:30081` |

## Features

- ARC runner sets for EduIDE organization workloads
- Stateful BuildKit workers (7 replicas per cluster, 100Gi per worker)
- Zot pull-through cache for `docker.io` (removes Docker Hub rate-limit pressure)
- GitHub Actions Cache Server for `actions/cache` compatibility (200Gi PVC)
- Memory-backed work volume on parma runners (`emptyDir.medium: Memory`, 30Gi)

## Components

### Zot Registry Cache

Zot is deployed as a standalone release on parma:

- release: `theia-zot`
- namespace: `zot-system`
- storage: Longhorn PVC (250Gi)
- service: NodePort `30081`

Runner DinD containers are configured with:

```text
--registry-mirror=http://131.159.88.117:30081
--insecure-registry=131.159.88.117:30081
```

### GitHub Actions Cache Server

Deployed in `arc-systems`. Runners use:

- `ACTIONS_RESULTS_URL`
- `CUSTOM_ACTIONS_RESULTS_URL`

Backed by a 200Gi PVC with cleanup policy.

### Runner + BuildKit Model

Runner pods keep the DinD + runner sidecar layout. Docker builds are routed to remote BuildKit workers using workflow-provided routing logic and runner env:

- `BUILDKIT_NAMESPACE`
- `BUILDKIT_NUM_WORKERS`

## Deployment

See [AGENTS.md](AGENTS.md) for the canonical commands and safety notes.

### Prerequisites

- `kubectl` configured for target cluster (`theia-prod` / `parma`)
- Helm 3.14+
- GitHub auth secret in `arc-runners`:

```bash
# GitHub App (recommended)
kubectl create secret generic github-arc-secret-eduidec \
  --namespace=arc-runners \
  --from-literal=github_app_id="<APP_ID>" \
  --from-literal=github_app_installation_id="<INSTALLATION_ID>" \
  --from-file=github_app_private_key=<path-to-private-key.pem>

# or PAT
kubectl create secret generic github-arc-secret-eduidec \
  --namespace=arc-runners \
  --from-literal=github_token="ghp_xxxxxxxxxxxx"
```

### Deploy theia-prod (AMD64 BuildKit runners)

```bash
kubectl config use-context theia-prod
cd helm-chart/theia-arc-bundle

# Part 1: Controller + Cache Server
helm upgrade --install theia-arc-systems . \
  --namespace arc-systems --create-namespace \
  --set arcRunners.enabled=false \
  --set arcRunnersArm.enabled=false \
  --set arcRunnersExp.enabled=false \
  --set arcRunnersArmBuildkit.enabled=false \
  --wait --timeout 5m

# Part 2: AMD64 BuildKit runner set
helm upgrade --install theia-arc-runners . \
  --namespace arc-runners \
  --set cache-server.enabled=false \
  --set arcController.enabled=false \
  --set arcRunners.enabled=false \
  --set arcRunnersArm.enabled=false \
  --set arcRunnersExp.enabled=true \
  --set arcRunnersArmBuildkit.enabled=false \
  --wait --timeout 10m
```

### Deploy parma (ARM64 BuildKit runners)

```bash
kubectl config use-context parma
cd helm-chart/theia-arc-bundle

# Part 1: Controller + Cache Server
helm upgrade --install theia-arc-systems . \
  --namespace arc-systems --create-namespace \
  -f values-arm64.yaml \
  --set arcRunners.enabled=false \
  --set arcRunnersArm.enabled=false \
  --set arcRunnersExp.enabled=false \
  --set arcRunnersArmBuildkit.enabled=false \
  --wait --timeout 5m

# Part 2: ARM64 BuildKit runner set
helm upgrade --install theia-arc-runners . \
  --namespace arc-runners \
  -f values-arm64.yaml \
  --set cache-server.enabled=false \
  --set arcController.enabled=false \
  --set arcRunners.enabled=false \
  --set arcRunnersArm.enabled=false \
  --set arcRunnersExp.enabled=false \
  --set arcRunnersArmBuildkit.enabled=true \
  --wait --timeout 10m
```

### Deploy Zot (standalone)

```bash
kubectl config use-context parma
cd helm-chart/theia-zot

helm upgrade --install theia-zot . \
  --namespace zot-system --create-namespace \
  -f values.yaml \
  -f values-parma.yaml \
  --wait --timeout 10m
```

### Verify

```bash
kubectl get pods -n arc-systems
kubectl get pods -n arc-runners
kubectl get autoscalingrunnersets -n arc-runners
kubectl get pvc -n arc-systems
kubectl get pvc -n zot-system

# BuildKit workers
kubectl --context=theia-prod get pods -n buildkit-exp
kubectl --context=parma get pods -n buildkit
```

Expected runner sets:

- `theia-prod`: `arc-buildkit-eduide-amd64`
- `parma`: `arc-buildkit-eduide-arm64`

## Documentation

- [Architecture](docs/ARCHITECTURE_V2.md)
- [Troubleshooting](docs/TROUBLESHOOTING.md)
- [BuildKit ARM64 deployment record](docs/DEPLOY_ARM64_STATEFUL_BUILDKIT_2026-03-17.md)

## Cleanup

```bash
helm uninstall theia-arc-runners -n arc-runners
helm uninstall theia-arc-systems -n arc-systems
helm uninstall theia-zot -n zot-system
kubectl delete namespace arc-runners arc-systems zot-system
```
