# AGENTS.md — Theia ARC Runners

Guidance for AI coding agents working in this repository.

## Repository Overview

**Pure infrastructure-as-code** repository. No application code and no application-level test suite.
The stack is: Helm 3 umbrella chart + Kubernetes YAML + GitHub Actions workflows.

**Two target clusters:**

| Cluster | Context | Arch | Active BuildKit runner set |
|---------|---------|------|-----------------------------|
| theia-prod | `theia-prod` | AMD64 | `arc-buildkit-eduide-amd64` |
| parma | `parma` | ARM64 | `arc-buildkit-eduide-arm64` |

---

## Deployment Commands

### Helm — Deploy Part 1 (Controller + Cache Server)

```bash
cd helm-chart/theia-arc-bundle

# AMD64 (theia-prod)
helm upgrade --install theia-arc-systems . \
  --namespace arc-systems --create-namespace \
  --set arcRunners.enabled=false \
  --set arcRunnersArm.enabled=false \
  --set arcRunnersExp.enabled=false \
  --set arcRunnersArmBuildkit.enabled=false \
  --wait --timeout 5m

# ARM64 (parma) — overlay values-arm64.yaml on top of values.yaml
helm upgrade --install theia-arc-systems . \
  --namespace arc-systems --create-namespace \
  -f values-arm64.yaml \
  --set arcRunners.enabled=false \
  --set arcRunnersArm.enabled=false \
  --set arcRunnersExp.enabled=false \
  --set arcRunnersArmBuildkit.enabled=false \
  --wait --timeout 5m
```

### Helm — Deploy Part 2 (BuildKit Runner Sets)

```bash
# AMD64 BuildKit runner set on theia-prod
helm upgrade --install theia-arc-runners . \
  --namespace arc-runners \
  --set cache-server.enabled=false \
  --set arcController.enabled=false \
  --set arcRunners.enabled=false \
  --set arcRunnersArm.enabled=false \
  --set arcRunnersExp.enabled=true \
  --set arcRunnersArmBuildkit.enabled=false \
  --wait --timeout 10m

# ARM64 BuildKit runner set on parma
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
kubectl get pvc -n arc-systems
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
kubectl delete namespace arc-runners arc-systems zot-system
```

---

## Repository Structure

```
.
├── helm-chart/
│   ├── theia-arc-bundle/          # Umbrella Helm chart (controller/cache/runner sets)
│   │   ├── Chart.yaml             # Chart metadata + dependencies
│   │   ├── values.yaml            # AMD64 defaults (theia-prod)
│   │   ├── values-arm64.yaml      # ARM64 overrides (parma)
│   │   ├── templates/
│   │   │   ├── _helpers.tpl       # Helm template helpers
│   │   │   ├── namespace.yaml     # arc-systems / arc-runners namespaces
│   │   │   ├── rbac.yaml          # ServiceAccounts + Role + RoleBindings
│   │   │   └── external-secret-github.yaml  # Optional: ExternalSecrets integration
│   │   └── charts/
│   │       ├── gha-runner-scale-set-0.9.3.tgz
│   │       ├── gha-runner-scale-set-controller-0.9.3.tgz
│   │       └── github-actions-cache-server/   # Local subchart (vendored)
│   └── theia-zot/                 # Standalone Zot Helm wrapper chart
├── infra/
│   ├── theia-prod/buildkit-exp/   # AMD64 BuildKit StatefulSet manifests
│   └── parma/buildkit/            # ARM64 BuildKit StatefulSet manifests
└── docs/                          # Operational plans and architecture notes
```

---

## Architecture (ground truth: manifests + values files)

Three deployable releases/components are used:

- **Part 1** (`theia-arc-systems`, `arc-systems`): ARC controller + GitHub Actions Cache Server
- **Part 2** (`theia-arc-runners`, `arc-runners`): BuildKit-focused AutoscalingRunnerSet(s)
- **Part 3** (`theia-zot`, `zot-system`): Zot pull-through registry on parma

**The Part 1 release name MUST be `theia-arc-systems`** — runner sets reference controller SA `theia-arc-systems-gha-rs-controller` by exact name.

**Registry caching:** Zot is centralized on parma and consumed by both clusters via NodePort `131.159.88.117:30081`.

**Build execution:** GitHub jobs run on ARC runners with DinD + runner containers. Docker builds are routed by workflow logic to stateful BuildKit workers:

- theia-prod workers: namespace `buildkit-exp` (`csi-rbd-sc`, 7 replicas)
- parma workers: namespace `buildkit` (`longhorn`, 7 replicas)

---

## Naming conventions

- Helm release names:
  - `theia-arc-systems` (Part 1)
  - `theia-arc-runners` (Part 2)
  - `theia-zot` (Part 3)
- Namespaces:
  - `arc-systems`, `arc-runners`, `zot-system`
  - `buildkit-exp` (theia-prod BuildKit), `buildkit` (parma BuildKit)
- Active runner set names:
  - `arc-buildkit-eduide-amd64`
  - `arc-buildkit-eduide-arm64`

---

## Operational Notes

- **Uninstall order is critical**: remove runners before controller to avoid ARC finalizer deadlocks.
- `createNamespaces: false` on parma is intentional to avoid Helm SSA ownership conflicts for `arc-runners`.
- `externalSecrets.enabled: false` by default; auth secrets are managed explicitly.
- Keep docs aligned with manifests; when mismatched, trust `values.yaml`, `values-arm64.yaml`, and `infra/**` YAML.
- Zot startup can fail on low inotify settings (`failed to create a new hot reloader`); raise node inotify limits and restart pod.
