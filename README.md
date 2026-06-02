# Theia ARC Runners

Infrastructure-as-code for deploying **GitHub Actions self-hosted runners** using Actions Runner Controller (ARC).

## Architecture

BuildKit-focused runner sets backed by stateful BuildKit workers and a shared Zot pull-through cache for Docker Hub.

| Cluster | Architecture | Runner Sets | BuildKit Namespace | BuildKit Storage Class | Zot Mirror |
|---------|--------------|-------------|--------------------|------------------------|------------|
| stud | AMD64 | `arc-buildkit-eduide-stud-amd64`, `arc-buildkit-ls1intum-stud-amd64` | `buildkit` | `csi-rbd-sc` | `131.159.88.117:30081` |
| theia-prod | AMD64 | `arc-buildkit-eduide-theiaprod-amd64`, `arc-buildkit-ls1intum-theiaprod-amd64` | `buildkit` | `csi-rbd-sc` | `131.159.88.117:30081` |
| parma | ARM64 | `arc-buildkit-eduide-parma-arm64`, `arc-buildkit-ls1intum-parma-arm64` | `buildkit` | `longhorn` | `131.159.88.117:30081` |

Use `helm-chart/theia-arc-bundle/values.yaml` plus exactly one cluster overlay:

| Cluster | Values overlay |
|---------|----------------|
| stud | `helm-chart/theia-arc-bundle/values-stud.yaml` |
| theia-prod | `helm-chart/theia-arc-bundle/values-theia-prod.yaml` |
| parma | `helm-chart/theia-arc-bundle/values-parma.yaml` |

## Features

- ARC runner sets for EduIDE and ls1intum organization workloads
- Stateful BuildKit workers (7 replicas per cluster, 100Gi per worker)
- BuildKit pods prefer spreading across nodes with soft pod anti-affinity
- Zot pull-through cache for `docker.io` (removes Docker Hub rate-limit pressure)
- Official ARC runner image (`ghcr.io/actions/actions-runner`) and ARC Helm charts
- Memory-backed work volume on parma runners (`emptyDir.medium: Memory`, 30Gi)

## Components

### Zot Registry Cache

Zot is deployed as a standalone release on parma:

- release: `theia-zot`
- namespace: `zot-system`
- storage: Longhorn PVC (100Gi)
- service: NodePort `30081`

Runner DinD containers are configured with:

```text
--registry-mirror=http://131.159.88.117:30081
--insecure-registry=131.159.88.117:30081
```

### Runner + BuildKit Model

Runner pods keep the DinD + runner sidecar layout. Docker builds are routed to remote BuildKit workers using workflow-provided routing logic and runner env:

- `BUILDKIT_NAMESPACE`
- `BUILDKIT_NUM_WORKERS`

BuildKit workers run as separate StatefulSet pods with persistent PVC-backed cache. This keeps runner pods disposable while preserving Docker layer cache, BuildKit cache layers, and BuildKit cache mounts across workflow runs. For more context, see [ARCHITECTURE_V2.md](docs/ARCHITECTURE_V2.md).

## Deployment

See [AGENTS.md](AGENTS.md) for the canonical commands and safety notes.

### Prerequisites

- `kubectl` configured for target cluster (`stud` / `theia-prod` / `parma`)
- Helm 3.14+
- GitHub App auth secrets in `arc-runners`.

The deploy commands below create the namespaces first. Then create one secret per GitHub organization:

```bash
kubectl create namespace arc-systems --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace arc-runners --dry-run=client -o yaml | kubectl apply -f -

# EduIDE GitHub App
kubectl create secret generic github-arc-secret-eduidec \
  --namespace=arc-runners \
  --from-literal=github_app_id="<APP_ID>" \
  --from-literal=github_app_installation_id="<INSTALLATION_ID>" \
  --from-file=github_app_private_key=<path-to-private-key.pem>

# ls1intum GitHub App
kubectl create secret generic github-arc-secret-ls1intum \
  --namespace=arc-runners \
  --from-literal=github_app_id="<APP_ID>" \
  --from-literal=github_app_installation_id="<INSTALLATION_ID>" \
  --from-file=github_app_private_key=<path-to-private-key.pem>
```

The documented Helm flow creates namespaces before Helm runs and therefore sets `createNamespaces=false` on every ARC chart install. This avoids Helm namespace ownership conflicts when Part 1 and Part 2 are installed as separate releases.

### Deploy stud (AMD64 BuildKit runners)

```bash
kubectl config use-context stud

# Part 0: BuildKit workers
kubectl apply -f infra/stud/buildkit/namespace.yaml
kubectl wait --for=jsonpath='{.status.phase}'=Active namespace/buildkit --timeout=60s
kubectl apply -f infra/stud/buildkit/configmap.yaml
kubectl apply -f infra/stud/buildkit/service.yaml
kubectl apply -f infra/stud/buildkit/statefulset.yaml
kubectl rollout status statefulset/buildkitd -n buildkit --timeout=10m

# Part 1: Controller
helm upgrade --install theia-arc-systems helm-chart/theia-arc-bundle \
  --namespace arc-systems \
  -f helm-chart/theia-arc-bundle/values.yaml \
  -f helm-chart/theia-arc-bundle/values-stud.yaml \
  --set createNamespaces=false \
  --set ghaArcController.enabled=true \
  --set ghaArcScaleSetAmdEduide.enabled=false \
  --set ghaArcScaleSetArmEduide.enabled=false \
  --set ghaArcScaleSetAmdLs1intum.enabled=false \
  --set ghaArcScaleSetArmLs1intum.enabled=false \
  --wait --timeout 5m

# Part 2: AMD64 BuildKit runner sets for EduIDE and ls1intum
helm upgrade --install theia-arc-runners helm-chart/theia-arc-bundle \
  --namespace arc-runners \
  -f helm-chart/theia-arc-bundle/values.yaml \
  -f helm-chart/theia-arc-bundle/values-stud.yaml \
  --set createNamespaces=false \
  --set ghaArcController.enabled=false \
  --set ghaArcScaleSetAmdEduide.enabled=true \
  --set ghaArcScaleSetArmEduide.enabled=false \
  --set ghaArcScaleSetAmdLs1intum.enabled=true \
  --set ghaArcScaleSetArmLs1intum.enabled=false \
  --wait --timeout 10m
```

### Deploy theia-prod (AMD64 BuildKit runners)

```bash
kubectl config use-context theia-prod

# Part 0: BuildKit workers
kubectl apply -f infra/theia-prod/buildkit/namespace.yaml
kubectl wait --for=jsonpath='{.status.phase}'=Active namespace/buildkit --timeout=60s
kubectl apply -f infra/theia-prod/buildkit/configmap.yaml
kubectl apply -f infra/theia-prod/buildkit/service.yaml
kubectl apply -f infra/theia-prod/buildkit/statefulset.yaml
kubectl rollout status statefulset/buildkitd -n buildkit --timeout=10m

# Part 1: Controller
helm upgrade --install theia-arc-systems helm-chart/theia-arc-bundle \
  --namespace arc-systems \
  -f helm-chart/theia-arc-bundle/values.yaml \
  -f helm-chart/theia-arc-bundle/values-theia-prod.yaml \
  --set createNamespaces=false \
  --set ghaArcController.enabled=true \
  --set ghaArcScaleSetAmdEduide.enabled=false \
  --set ghaArcScaleSetArmEduide.enabled=false \
  --set ghaArcScaleSetAmdLs1intum.enabled=false \
  --set ghaArcScaleSetArmLs1intum.enabled=false \
  --wait --timeout 5m

# Part 2: AMD64 BuildKit runner sets for EduIDE and ls1intum
helm upgrade --install theia-arc-runners helm-chart/theia-arc-bundle \
  --namespace arc-runners \
  -f helm-chart/theia-arc-bundle/values.yaml \
  -f helm-chart/theia-arc-bundle/values-theia-prod.yaml \
  --set createNamespaces=false \
  --set ghaArcController.enabled=false \
  --set ghaArcScaleSetAmdEduide.enabled=true \
  --set ghaArcScaleSetArmEduide.enabled=false \
  --set ghaArcScaleSetAmdLs1intum.enabled=true \
  --set ghaArcScaleSetArmLs1intum.enabled=false \
  --wait --timeout 10m
```

### Deploy parma (ARM64 BuildKit runners)

```bash
kubectl config use-context parma

# Part 0: BuildKit workers
kubectl apply -f infra/parma/buildkit/namespace.yaml
kubectl wait --for=jsonpath='{.status.phase}'=Active namespace/buildkit --timeout=60s
kubectl apply -f infra/parma/buildkit/configmap.yaml
kubectl apply -f infra/parma/buildkit/service.yaml
kubectl apply -f infra/parma/buildkit/statefulset.yaml
kubectl rollout status statefulset/buildkitd -n buildkit --timeout=10m

# Part 1: Controller
helm upgrade --install theia-arc-systems helm-chart/theia-arc-bundle \
  --namespace arc-systems \
  -f helm-chart/theia-arc-bundle/values.yaml \
  -f helm-chart/theia-arc-bundle/values-parma.yaml \
  --set createNamespaces=false \
  --set ghaArcController.enabled=true \
  --set ghaArcScaleSetAmdEduide.enabled=false \
  --set ghaArcScaleSetArmEduide.enabled=false \
  --set ghaArcScaleSetAmdLs1intum.enabled=false \
  --set ghaArcScaleSetArmLs1intum.enabled=false \
  --wait --timeout 5m

# Part 2: ARM64 BuildKit runner sets for EduIDE and ls1intum
helm upgrade --install theia-arc-runners helm-chart/theia-arc-bundle \
  --namespace arc-runners \
  -f helm-chart/theia-arc-bundle/values.yaml \
  -f helm-chart/theia-arc-bundle/values-parma.yaml \
  --set createNamespaces=false \
  --set ghaArcController.enabled=false \
  --set ghaArcScaleSetAmdEduide.enabled=false \
  --set ghaArcScaleSetArmEduide.enabled=true \
  --set ghaArcScaleSetAmdLs1intum.enabled=false \
  --set ghaArcScaleSetArmLs1intum.enabled=true \
  --wait --timeout 10m
```

### Deploy Zot (standalone)

The current shared Zot deployment runs on `parma` and is consumed by all runner clusters via `131.159.88.117:30081`.

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
kubectl get pvc -n zot-system

# BuildKit workers
kubectl --context=stud get pods -n buildkit
kubectl --context=theia-prod get pods -n buildkit
kubectl --context=parma get pods -n buildkit
```

Expected runner sets:

- `stud`: `arc-buildkit-eduide-stud-amd64`, `arc-buildkit-ls1intum-stud-amd64`
- `theia-prod`: `arc-buildkit-eduide-theiaprod-amd64`, `arc-buildkit-ls1intum-theiaprod-amd64`
- `parma`: `arc-buildkit-eduide-parma-arm64`, `arc-buildkit-ls1intum-parma-arm64`

## Documentation

- [Architecture](docs/ARCHITECTURE_V2.md)
- [Troubleshooting](docs/TROUBLESHOOTING.md)
- [BuildKit ARM64 deployment record](docs/archive/DEPLOY_ARM64_STATEFUL_BUILDKIT_2026-03-17.md)

## Cleanup

```bash
helm uninstall theia-arc-runners -n arc-runners
helm uninstall theia-arc-systems -n arc-systems
helm uninstall theia-zot -n zot-system
kubectl delete namespace arc-runners arc-systems zot-system buildkit --ignore-not-found=true
```
