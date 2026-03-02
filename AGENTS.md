# AGENTS.md — Theia ARC Runners

Guidance for AI coding agents working in this repository.

## Repository Overview

**Pure infrastructure-as-code** repository. No application code, no build pipeline, no tests.
The stack is: Helm 3 umbrella chart + Kubernetes YAML + GitHub Actions workflows.

**Two target clusters:**

| Cluster | Context | Arch | ARC runner set name |
|---------|---------|------|---------------------|
| theia-prod | `theia-prod` | AMD64 | `arc-runner-set-stateless` |
| parma | `parma` | ARM64 | `arc-runner-set-arm64` |

---

## Deployment Commands

There are **no build, lint, or test commands**. Deployment is done via Helm and kubectl.

### Helm — Deploy Part 1 (Controller + Cache Server)

```bash
cd helm-chart/theia-arc-bundle

# AMD64 (theia-prod)
helm upgrade --install theia-arc-systems . \
  --namespace arc-systems --create-namespace \
  --set arcRunners.enabled=false \
  --set arcRunnersArm.enabled=false \
  --wait --timeout 2m

# ARM64 (parma) — overlay values-arm64.yaml on top of values.yaml
helm upgrade --install theia-arc-systems . \
  --namespace arc-systems --create-namespace \
  -f values-arm64.yaml \
  --set arcRunnersArm.enabled=false \
  --wait --timeout 2m
```

### Helm — Deploy Part 2 (Runners)

```bash
# AMD64
helm upgrade --install theia-arc-runners . \
  --namespace arc-runners \
  --set cacheServer.enabled=false \
  --set arcController.enabled=false \
  --set harbor.enabled=false \
  --set arcRunners.enabled=true \
  --wait --timeout 2m

# ARM64
helm upgrade --install theia-arc-runners . \
  --namespace arc-runners \
  -f values-arm64.yaml \
  --set cacheServer.enabled=false \
  --set arcController.enabled=false \
  --set harbor.enabled=false \
  --set arcRunnersArm.enabled=true \
  --wait --timeout 2m
```

### Verify Deployment

```bash
kubectl get pods -n arc-systems
kubectl get pods -n arc-runners
kubectl get autoscalingrunnersets -n arc-runners
kubectl get pvc -n arc-systems
```

### Helm Lint (local validation)

```bash
helm lint helm-chart/theia-arc-bundle/
helm template helm-chart/theia-arc-bundle/ | kubectl apply --dry-run=client -f -
```

### Uninstall (order matters — runners before controller)

```bash
helm uninstall theia-arc-runners -n arc-runners
helm uninstall theia-arc-systems -n arc-systems
kubectl delete namespace arc-runners arc-systems
```

---

## Repository Structure

```
.
├── helm-chart/
│   └── theia-arc-bundle/          # Umbrella Helm chart
│       ├── Chart.yaml             # Chart metadata + dependencies
│       ├── values.yaml            # AMD64 defaults (theia-prod)
│       ├── values-arm64.yaml      # ARM64 overrides (parma)
│       ├── templates/
│       │   ├── _helpers.tpl       # Helm template helpers
│       │   ├── namespace.yaml     # arc-systems / arc-runners namespaces
│       │   ├── rbac.yaml          # ServiceAccounts + Role + RoleBindings
│       │   ├── external-secret-github.yaml  # Optional: ExternalSecrets integration
│       │   └── harbor-proxy-setup.yaml      # Post-install Job: Harbor proxy projects
│       └── charts/
│           ├── gha-runner-scale-set-0.9.3.tgz
│           ├── gha-runner-scale-set-controller-0.9.3.tgz
│           ├── harbor-1.18.2.tgz
│           └── github-actions-cache-server/   # Local subchart (vendored)
├── .github/workflows/
│   ├── deploy-manual.yml          # Workflow dispatch trigger
│   └── deploy-runners.yml         # Reusable deployment workflow
└── docs/                          # Documentation (may be outdated — trust manifests)
```

---

## Architecture (ground truth: read from manifests)

**Two Helm releases must be deployed separately** — Helm 3 cannot deploy subcharts into different namespaces in one release:

- **Part 1** (`theia-arc-systems` release, `arc-systems` ns): ARC controller, GitHub Actions Cache Server, Harbor (AMD64 only)
- **Part 2** (`theia-arc-runners` release, `arc-runners` ns): AutoscalingRunnerSet only

**The Part 1 release name MUST be `theia-arc-systems`** — the controller ServiceAccount is named `theia-arc-systems-gha-rs-controller` and Part 2 references it by exact name in `values.yaml`.

**Registry caching:** Harbor proxy cache (AMD64 only, `harbor.enabled: true` in `values.yaml`). Harbor is **disabled on parma** (`harbor.enabled: false` in `values-arm64.yaml`).

**Cache server:** `github-actions-cache-server` subchart deployed in `arc-systems`. Runners point to it via `ACTIONS_RESULTS_URL` and `CUSTOM_ACTIONS_RESULTS_URL` env vars.

**Runner pods:** Manual DinD sidecar pattern — `dind` + `runner` containers sharing `emptyDir` volumes. ARM64 runners use `emptyDir.medium: Memory` (30Gi) for the work volume.

---

## Helm / YAML Conventions

### values.yaml structure

- `global.storageClass` — storage class for all PVCs (`csi-rbd-sc` AMD64, `longhorn` ARM64)
- `global.nodeSelector` — arch selector applied to all pods
- `arcController.enabled` / `arcRunners.enabled` / `arcRunnersArm.enabled` — feature flags for split deployment
- `cache-server.*` — passed to the `github-actions-cache-server` subchart
- `harbor.*` — passed to the Harbor subchart (AMD64 only)

### Helm template style

- Use `{{- include "theia-arc-bundle.labels" . | nindent N }}` for standard labels on every resource
- Gate resources with `{{- if .Values.<flag> }}` — never deploy conditionally unneeded resources
- Helm hooks use `"helm.sh/hook": post-install,post-upgrade` and `before-hook-creation` delete policy
- Indent YAML blocks with `nindent` for inline template values

### Kubernetes YAML style

- Always set `namespace:` explicitly on every resource
- Use `kubernetes.io/arch` node selector (not `beta.kubernetes.io/arch`)
- Resources: always specify both `requests` and `limits`
- Label all resources with `app.kubernetes.io/*` labels

### Naming conventions

- Helm release names: `theia-arc-systems` (Part 1), `theia-arc-runners` (Part 2)
- Namespaces: `arc-systems` (controller tier), `arc-runners` (runner tier)
- ServiceAccounts: `arc-runner-set-stateless-sa` (AMD64), `arc-runner-set-stateless-arm-sa` (ARM64)
- Secret: `github-arc-secret` in `arc-runners`
- Runner scale set names: `arc-runner-set-stateless` (AMD64), `arc-runner-set-arm64` (ARM64)

---

## Key Operational Notes

- **Uninstall order is critical**: always remove runners (Part 2) before the controller (Part 1). Doing it in reverse leaves ARC runners stuck with finalizers that block namespace deletion.
- **`createNamespaces: false`** on parma (ARM64) — the `arc-runners` namespace is pre-created with Helm ownership labels; Helm SSA will fail if the chart tries to recreate it.
- **`externalSecrets.enabled: false`** by default — auth secret is created manually or via CI (`kubectl create secret`).
- docs/ may be out of date — always trust `values.yaml`, `values-arm64.yaml`, and the templates as ground truth.
- Harbor is only deployed on `theia-prod` (AMD64). parma uses no pull-through cache.
