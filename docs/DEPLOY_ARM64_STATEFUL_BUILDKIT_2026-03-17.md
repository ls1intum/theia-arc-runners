# Deployment Log: ARM64 Stateful BuildKit on parma

Date: 2026-03-17
Cluster: `parma`
Scope: Add and deploy stateful BuildKit workers plus dedicated ARM64 BuildKit ARC runner set.

## What was implemented

### 1) New parma BuildKit infrastructure manifests

Added directory:

- `infra/parma/buildkit/namespace.yaml`
- `infra/parma/buildkit/service.yaml`
- `infra/parma/buildkit/configmap.yaml`
- `infra/parma/buildkit/statefulset.yaml`

Key choices:

- Namespace: `buildkit` (without `-exp` suffix)
- Architecture: `arm64` node selector on BuildKit StatefulSet
- StorageClass: `longhorn`
- Persistent cache: 7 PVCs (`100Gi` each) via `volumeClaimTemplates`
- BuildKit endpoint DNS pattern:
  - `tcp://buildkitd-<N>.buildkitd.buildkit.svc.cluster.local:1234`
- Docker mirror in `buildkitd.toml`: Zot NodePort `http://131.159.88.117:30081`

### 2) Helm chart wiring for new ARM BuildKit ARC runner set

Updated:

- `helm-chart/theia-arc-bundle/Chart.yaml`
  - Added dependency alias: `arcRunnersArmBuildkit`
- `helm-chart/theia-arc-bundle/values.yaml`
  - Added full `arcRunnersArmBuildkit` block
  - Runner scale set name: `arc-buildkit-eduide-arm64`
  - Added env vars for workflow routing:
    - `BUILDKIT_NAMESPACE=buildkit`
    - `BUILDKIT_NUM_WORKERS=7`
- `helm-chart/theia-arc-bundle/values-arm64.yaml`
  - Enabled: `arcRunnersArmBuildkit.enabled: true`
- `helm-chart/theia-arc-bundle/templates/rbac.yaml`
  - Extended condition so RBAC renders when `arcRunnersExp` or `arcRunnersArmBuildkit` is enabled
- `helm-chart/theia-arc-bundle/templates/namespace.yaml`
  - Extended `arc-runners` namespace condition for same flags

## Validation performed

### Static/chart validation

1. `helm lint helm-chart/theia-arc-bundle` → success
2. `helm template ... -f values.yaml -f values-arm64.yaml | kubectl apply --dry-run=client -f -` → success
3. `kubectl apply --dry-run=client -f infra/parma/buildkit/*.yaml` → success

### Deployment

Applied BuildKit manifests:

```bash
kubectl --context parma apply -f infra/parma/buildkit/namespace.yaml \
  -f infra/parma/buildkit/service.yaml \
  -f infra/parma/buildkit/configmap.yaml \
  -f infra/parma/buildkit/statefulset.yaml
```

Upgraded runner release (parma context):

```bash
helm upgrade --install theia-arc-runners helm-chart/theia-arc-bundle \
  --namespace arc-runners --kube-context parma \
  -f helm-chart/theia-arc-bundle/values.yaml \
  -f helm-chart/theia-arc-bundle/values-arm64.yaml \
  --set cache-server.enabled=false \
  --set arcController.enabled=false \
  --set arcRunnersArm.enabled=false \
  --set arcRunnersArmBuildkit.enabled=true \
  --wait --timeout 10m
```

Note: First attempt timed out at default 2m timeout; second attempt with 10m succeeded.

## Post-deploy verification

Verified healthy state:

- BuildKit StatefulSet pods: `buildkitd-0..6` all `Running`
- BuildKit PVCs: all 7 `Bound` on `longhorn`
- Headless service `buildkitd` present in namespace `buildkit`
- AutoscalingRunnerSet present:
  - `arc-buildkit-eduide-arm64`
- Runner pods for that set: all `2/2 Running`
- Secret used by set exists:
  - `github-arc-secret-eduidec` in `arc-runners`

## Operational notes

- This rollout is **manual selection only**; no automatic fallback behavior was introduced.
- Workflow jobs should target the new label explicitly:
  - `runs-on: arc-buildkit-eduide-arm64`
- BuildKit routing variables are injected via runner env and expected by workflow logic.
