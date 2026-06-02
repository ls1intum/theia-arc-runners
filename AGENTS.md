# AGENTS.md — Theia ARC Runners

Guidance for AI coding agents working in this repository.

## Repository Overview

**Pure infrastructure-as-code** repository. No application code and no application-level test suite.
The stack is: Helm 3 umbrella chart + Kubernetes YAML + GitHub Actions workflows.

**Three target clusters:**

| Cluster | Context | Arch | Active BuildKit runner sets |
|---------|---------|------|-----------------------------|
| stud | `stud` | AMD64 | `arc-buildkit-eduide-stud-amd64`, `arc-buildkit-ls1intum-stud-amd64` |
| theia-prod | `theia-prod` | AMD64 | `arc-buildkit-eduide-theiaprod-amd64`, `arc-buildkit-ls1intum-theiaprod-amd64` |
| parma | `parma` | ARM64 | `arc-buildkit-eduide-parma-arm64`, `arc-buildkit-ls1intum-parma-arm64` |

---

## Deployment Commands

### Helm — Deploy Part 1 (Controller)

```bash
kubectl create namespace arc-systems --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace arc-runners --dry-run=client -o yaml | kubectl apply -f -
```

Assign each runtime namespace to the matching Rancher project after that namespace exists:

| Cluster | Rancher project | Namespaces |
|---------|-----------------|------------|
| `stud` | `ARC Runners Stud` | `arc-systems`, `arc-runners`, `buildkit` |
| `theia-prod` | `ARC Runners theiaprod` | `arc-systems`, `arc-runners`, `buildkit` |
| `parma` | `ARC Runners parma` | `arc-systems`, `arc-runners`, `buildkit`, `zot-system` |

Prefer the Rancher UI for project assignment. If the project does not exist, create it there first. Only use `field.cattle.io/projectId` when the cluster-specific Rancher project ID is known. `arc-systems` and `arc-runners` exist after the namespace commands above; assign `buildkit` after Part 0 creates it, and assign `zot-system` on parma after the Zot namespace exists.

```bash
# stud (AMD64)
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

# theia-prod (AMD64)
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

# parma (ARM64)
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
```

### Kubernetes — Deploy Part 0 (BuildKit Workers)

```bash
# stud
kubectl apply -f infra/stud/buildkit/namespace.yaml
kubectl wait --for=jsonpath='{.status.phase}'=Active namespace/buildkit --timeout=60s
kubectl apply -f infra/stud/buildkit/configmap.yaml
kubectl apply -f infra/stud/buildkit/service.yaml
kubectl apply -f infra/stud/buildkit/statefulset.yaml
kubectl rollout status statefulset/buildkitd -n buildkit --timeout=10m

# theia-prod
kubectl apply -f infra/theia-prod/buildkit/namespace.yaml
kubectl wait --for=jsonpath='{.status.phase}'=Active namespace/buildkit --timeout=60s
kubectl apply -f infra/theia-prod/buildkit/configmap.yaml
kubectl apply -f infra/theia-prod/buildkit/service.yaml
kubectl apply -f infra/theia-prod/buildkit/statefulset.yaml
kubectl rollout status statefulset/buildkitd -n buildkit --timeout=10m

# parma
kubectl apply -f infra/parma/buildkit/namespace.yaml
kubectl wait --for=jsonpath='{.status.phase}'=Active namespace/buildkit --timeout=60s
kubectl apply -f infra/parma/buildkit/configmap.yaml
kubectl apply -f infra/parma/buildkit/service.yaml
kubectl apply -f infra/parma/buildkit/statefulset.yaml
kubectl rollout status statefulset/buildkitd -n buildkit --timeout=10m
```

### Helm — Deploy Part 2 (BuildKit Runner Sets)

```bash
# stud AMD64 BuildKit runner sets
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

# theia-prod AMD64 BuildKit runner sets
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

# parma ARM64 BuildKit runner sets
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

### Helm — Deploy Part 3 (Zot standalone on parma)

```bash
cd helm-chart/theia-zot

helm upgrade --install theia-zot . \
  --namespace zot-system --create-namespace \
  -f values.yaml \
  -f values-parma.yaml \
  --wait --timeout 10m
```

### Verify Deployment

```bash
kubectl get pods -n arc-systems
kubectl get pods -n arc-runners
kubectl get autoscalingrunnersets -n arc-runners
kubectl get pvc -n zot-system

# BuildKit workers
kubectl get pods -n buildkit   # stud
kubectl get pods -n buildkit   # theia-prod
kubectl get pods -n buildkit   # parma
```

### Helm Lint / Template Validation (local)

```bash
helm lint helm-chart/theia-arc-bundle/ \
  -f helm-chart/theia-arc-bundle/values.yaml \
  -f helm-chart/theia-arc-bundle/values-stud.yaml
helm lint helm-chart/theia-arc-bundle/ \
  -f helm-chart/theia-arc-bundle/values.yaml \
  -f helm-chart/theia-arc-bundle/values-theia-prod.yaml
helm lint helm-chart/theia-arc-bundle/ \
  -f helm-chart/theia-arc-bundle/values.yaml \
  -f helm-chart/theia-arc-bundle/values-parma.yaml

helm lint helm-chart/theia-zot/
helm template helm-chart/theia-zot/ | kubectl apply --dry-run=client -f -
```

### Uninstall (order matters — runners before controller)

```bash
helm uninstall theia-arc-runners -n arc-runners
helm uninstall theia-arc-systems -n arc-systems
helm uninstall theia-zot -n zot-system
kubectl delete namespace arc-runners arc-systems zot-system buildkit --ignore-not-found=true
```

---

## Repository Structure

```
.
├── helm-chart/
│   ├── theia-arc-bundle/          # Umbrella Helm chart (controller/runner sets)
│   │   ├── Chart.yaml             # Chart metadata + dependencies
│   │   ├── values.yaml            # neutral shared defaults; no cluster runner names here
│   │   ├── values-stud.yaml       # stud AMD64 runner scale sets
│   │   ├── values-theia-prod.yaml # theia-prod AMD64 runner scale sets
│   │   ├── values-parma.yaml      # parma ARM64 runner scale sets
│   │   ├── templates/
│   │   │   ├── _helpers.tpl       # Helm template helpers
│   │   │   ├── namespace.yaml     # arc-systems / arc-runners namespaces
│   │   │   ├── rbac.yaml          # ServiceAccounts + Role + RoleBindings
│   │   └── charts/
│   │       ├── gha-runner-scale-set-0.14.2.tgz
│   │       └── gha-runner-scale-set-controller-0.14.2.tgz
│   └── theia-zot/                 # Standalone Zot Helm wrapper chart
├── infra/
│   ├── stud/buildkit/         # AMD64 BuildKit StatefulSet manifests
│   ├── theia-prod/buildkit/   # AMD64 BuildKit StatefulSet manifests
│   └── parma/buildkit/            # ARM64 BuildKit StatefulSet manifests
└── docs/                          # Current architecture/troubleshooting plus archived historical notes
```

---

## Architecture (ground truth: manifests + values files)

Three deployable releases/components are used:

- **Part 0** (`infra/**/buildkit*`): BuildKit workers
- **Part 1** (`theia-arc-systems`, `arc-systems`): ARC controller
- **Part 2** (`theia-arc-runners`, `arc-runners`): BuildKit-focused AutoscalingRunnerSet(s)
- **Part 3** (`theia-zot`, `zot-system`): Zot pull-through registry on parma

**The Part 1 release name MUST be `theia-arc-systems`** — runner sets reference controller SA `theia-arc-systems-gha-rs-controller` by exact name.

**Registry caching:** Zot is centralized on parma and consumed by all runner clusters via NodePort `131.159.88.117:30081`.

**Build execution:** GitHub jobs run on ARC runners with DinD + runner containers. Docker builds are routed by workflow logic to stateful BuildKit workers:

- stud/theia-prod workers: namespace `buildkit` (`csi-rbd-sc`, currently 7 replicas)
- parma workers: namespace `buildkit` (`longhorn`, currently 7 replicas)

The 7-worker count is arbitrary. One BuildKit worker can handle multiple builds at once. On multi-node clusters, scale the StatefulSet replicas and matching runner `BUILDKIT_NUM_WORKERS` value together; one worker per node is reasonable if capacity exists. The pod anti-affinity is soft, so workers prefer separate nodes but can still co-locate. Be conservative on parma because it is currently a single-node cluster.

Runner scale set `minRunners: 10` and `maxRunners: 50` are arbitrary baselines too. Larger clusters can use higher values, but check runner pod CPU/memory requests and limits at the same time so scheduled capacity matches real node capacity.

---

## Naming conventions

- Helm release names:
  - `theia-arc-systems` (Part 1)
  - `theia-arc-runners` (Part 2)
  - `theia-zot` (Part 3)
- Namespaces:
  - `arc-systems`, `arc-runners`, `zot-system`
  - `buildkit` on every runner cluster
- Cluster overlays:
  - are the only source for concrete runner labels, node architecture, and storage class
  - must keep org, cluster, and architecture explicit in runner labels: `arc-buildkit-<org>-<cluster>-<arch>`
- Runner ServiceAccounts:
  - are named by architecture and organization, e.g. `arc-runner-set-amd-eduide-sa`
  - are rendered only for enabled scale sets
- Active runner set names:
  - `arc-buildkit-eduide-stud-amd64`
  - `arc-buildkit-eduide-theiaprod-amd64`
  - `arc-buildkit-eduide-parma-arm64`
  - `arc-buildkit-ls1intum-stud-amd64`
  - `arc-buildkit-ls1intum-theiaprod-amd64`
  - `arc-buildkit-ls1intum-parma-arm64`

---

## Operational Notes

- **Uninstall order is critical**: remove runners before controller to avoid ARC finalizer deadlocks.
- `createNamespaces: false` is intentional in the documented flow because namespaces are created before Helm and Part 1 / Part 2 are separate releases.
- Assign `arc-systems`, `arc-runners`, `buildkit`, and on parma `zot-system` to the matching Rancher project after namespace creation.
- GitHub App auth secrets are managed explicitly; the active chart does not create them.
- The old self-hosted actions cache subchart has been removed from the active bundle.
- Runner pods use the official `ghcr.io/actions/actions-runner:latest` image.
- BuildKit workers are separate StatefulSet pods so Docker layer cache, BuildKit cache layers, and cache mounts persist outside disposable runner pods.
- Keep BuildKit StatefulSet `replicas` and chart `buildkit.numWorkers` in sync.
- Treat runner `minRunners`, `maxRunners`, and pod resources as capacity-tuning values, not fixed architecture requirements.
- Keep docs aligned with manifests; when mismatched, trust `values.yaml`, `values-<cluster>.yaml`, and `infra/**` YAML.
- Zot startup can fail on low inotify settings (`failed to create a new hot reloader`); raise node inotify limits and restart pod.
