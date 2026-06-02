# AGENTS.md — Theia ARC Runners

Guidance for AI coding agents working in this repository.

## Repository Overview

**Pure infrastructure-as-code** repository. No application code and no application-level test suite.
The stack is: Helm 3 umbrella chart + Kubernetes YAML + GitHub Actions workflows.

**Two target clusters:**

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
kubectl apply -f infra/stud/buildkit-exp/namespace.yaml
kubectl wait --for=jsonpath='{.status.phase}'=Active namespace/buildkit-exp --timeout=60s
kubectl apply -f infra/stud/buildkit-exp/configmap.yaml
kubectl apply -f infra/stud/buildkit-exp/service.yaml
kubectl apply -f infra/stud/buildkit-exp/statefulset.yaml
kubectl rollout status statefulset/buildkitd -n buildkit-exp --timeout=10m

# theia-prod
kubectl apply -f infra/theia-prod/buildkit-exp/namespace.yaml
kubectl wait --for=jsonpath='{.status.phase}'=Active namespace/buildkit-exp --timeout=60s
kubectl apply -f infra/theia-prod/buildkit-exp/configmap.yaml
kubectl apply -f infra/theia-prod/buildkit-exp/service.yaml
kubectl apply -f infra/theia-prod/buildkit-exp/statefulset.yaml
kubectl rollout status statefulset/buildkitd -n buildkit-exp --timeout=10m

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
kubectl get pods -n buildkit-exp   # theia-prod
kubectl get pods -n buildkit       # parma
```

### Helm Lint / Template Validation (local)

```bash
helm lint helm-chart/theia-arc-bundle/
helm template helm-chart/theia-arc-bundle/ | kubectl apply --dry-run=client -f -

helm lint helm-chart/theia-zot/
helm template helm-chart/theia-zot/ | kubectl apply --dry-run=client -f -
```

### Uninstall (order matters — runners before controller)

```bash
helm uninstall theia-arc-runners -n arc-runners
helm uninstall theia-arc-systems -n arc-systems
helm uninstall theia-zot -n zot-system
kubectl delete namespace arc-runners arc-systems zot-system buildkit buildkit-exp --ignore-not-found=true
```

---

## Repository Structure

```
.
├── helm-chart/
│   ├── theia-arc-bundle/          # Umbrella Helm chart (controller/runner sets)
│   │   ├── Chart.yaml             # Chart metadata + dependencies
│   │   ├── values.yaml            # shared defaults; no production scale set enabled by itself
│   │   ├── values-stud.yaml       # stud AMD64 runner scale sets
│   │   ├── values-theia-prod.yaml # theia-prod AMD64 runner scale sets
│   │   ├── values-parma.yaml      # parma ARM64 runner scale sets
│   │   ├── templates/
│   │   │   ├── _helpers.tpl       # Helm template helpers
│   │   │   ├── namespace.yaml     # arc-systems / arc-runners namespaces
│   │   │   ├── rbac.yaml          # ServiceAccounts + Role + RoleBindings
│   │   │   └── external-secret-github.yaml  # Optional: ExternalSecrets integration
│   │   └── charts/
│   │       ├── gha-runner-scale-set-0.14.2.tgz
│   │       └── gha-runner-scale-set-controller-0.14.2.tgz
│   └── theia-zot/                 # Standalone Zot Helm wrapper chart
├── infra/
│   ├── stud/buildkit-exp/         # AMD64 BuildKit StatefulSet manifests
│   ├── theia-prod/buildkit-exp/   # AMD64 BuildKit StatefulSet manifests
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

- stud/theia-prod workers: namespace `buildkit-exp` (`csi-rbd-sc`, 7 replicas)
- parma workers: namespace `buildkit` (`longhorn`, 7 replicas)

---

## Naming conventions

- Helm release names:
  - `theia-arc-systems` (Part 1)
  - `theia-arc-runners` (Part 2)
  - `theia-zot` (Part 3)
- Namespaces:
  - `arc-systems`, `arc-runners`, `zot-system`
  - `buildkit-exp` (stud/theia-prod BuildKit), `buildkit` (parma BuildKit)
- Active runner set names:
  - `arc-buildkit-eduide-theiaprod-amd64`
  - `arc-buildkit-eduide-parma-arm64`
  - `arc-buildkit-ls1intum-theiaprod-amd64`
  - `arc-buildkit-ls1intum-parma-arm64`

---

## Operational Notes

- **Uninstall order is critical**: remove runners before controller to avoid ARC finalizer deadlocks.
- `createNamespaces: false` is intentional in the documented flow because namespaces are created before Helm and Part 1 / Part 2 are separate releases.
- `externalSecrets.enabled: false` by default; auth secrets are managed explicitly.
- The old self-hosted actions cache subchart has been removed from the active bundle.
- Runner pods use the official `ghcr.io/actions/actions-runner:latest` image.
- BuildKit workers are separate StatefulSet pods so Docker layer cache, BuildKit cache layers, and cache mounts persist outside disposable runner pods.
- Keep docs aligned with manifests; when mismatched, trust `values.yaml`, `values-<cluster>.yaml`, and `infra/**` YAML.
- Zot startup can fail on low inotify settings (`failed to create a new hot reloader`); raise node inotify limits and restart pod.
