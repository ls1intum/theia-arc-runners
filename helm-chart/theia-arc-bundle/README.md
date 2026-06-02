# Theia ARC Bundle Helm Chart

Umbrella chart for the ARC controller and ARC runner scale sets.

> Zot is **not** deployed by this chart. Zot is deployed via `helm-chart/theia-zot` as a separate release.

## Overview

This chart provides:

- ARC controller (`gha-runner-scale-set-controller`)
- ARC runner scale sets (`gha-runner-scale-set` aliases)

The previous vendored self-hosted actions cache subchart has been removed. Runner pods now use the official GitHub runner image; Docker image caching is handled by Zot and build caching is handled by the stateful BuildKit workers.

BuildKit workers run as separate StatefulSet pods so runner pods stay disposable while Docker layer cache, BuildKit cache layers, and BuildKit cache mounts persist across workflow runs.

Active runner scale set labels used in production:

- `arc-buildkit-eduide-stud-amd64` (stud)
- `arc-buildkit-ls1intum-stud-amd64` (stud)
- `arc-buildkit-eduide-theiaprod-amd64` (theia-prod)
- `arc-buildkit-ls1intum-theiaprod-amd64` (theia-prod)
- `arc-buildkit-eduide-parma-arm64` (parma)
- `arc-buildkit-ls1intum-parma-arm64` (parma)

## Why multiple Helm releases?

Helm cannot deploy subcharts to different namespaces in a single release. We deploy:

| Part | Release | Namespace | Includes |
|------|---------|-----------|----------|
| Part 1 | `theia-arc-systems` | `arc-systems` | ARC controller |
| Part 2 | `theia-arc-runners` | `arc-runners` | Runner scale set(s) |
| Part 3 | `theia-zot` (different chart) | `zot-system` | Zot pull-through cache |

`theia-arc-systems` release name is required because runner sets reference controller SA `theia-arc-systems-gha-rs-controller`.

## Prerequisites

1. Kubernetes v1.23+
2. Helm v3.8+
3. GitHub App secrets in `arc-runners`:
   - `github-arc-secret-eduidec` for EduIDE
   - `github-arc-secret-ls1intum` for ls1intum
4. Storage classes:
   - `csi-rbd-sc` on stud/theia-prod
   - `longhorn` on parma

The documented flow creates namespaces before Helm runs and sets `createNamespaces=false` on every ARC chart install. This avoids Helm namespace ownership conflicts because Part 1 and Part 2 are separate releases.

## Core deployment commands

Run from the repository root.

### stud (AMD64 BuildKit runners)

```bash
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

### theia-prod (AMD64 BuildKit runners)

```bash
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

### parma (ARM64 BuildKit runners)

```bash
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

## Key values

Use `values.yaml` plus exactly one cluster overlay:

| File | Purpose |
|------|---------|
| `values.yaml` | Neutral shared defaults; no production runner scale set is enabled and no concrete cluster runner name is defined by itself |
| `values-stud.yaml` | stud AMD64 BuildKit runner scale sets for EduIDE and ls1intum |
| `values-theia-prod.yaml` | theia-prod AMD64 BuildKit runner scale sets for EduIDE and ls1intum |
| `values-parma.yaml` | parma ARM64 BuildKit runner scale sets for EduIDE and ls1intum |

| Value | Meaning |
|------|---------|
| `ghaArcController.enabled` | Enable ARC controller subchart |
| `ghaArcScaleSetAmdEduide.enabled` | AMD64 BuildKit runner set for EduIDE; final name comes from the cluster overlay |
| `ghaArcScaleSetAmdLs1intum.enabled` | AMD64 BuildKit runner set for ls1intum; final name comes from the cluster overlay |
| `ghaArcScaleSetArmEduide.enabled` | ARM64 BuildKit runner set for EduIDE; final name comes from the cluster overlay |
| `ghaArcScaleSetArmLs1intum.enabled` | ARM64 BuildKit runner set for ls1intum; final name comes from the cluster overlay |

Runner ServiceAccounts are named by architecture and organization, for example `arc-runner-set-amd-eduide-sa` and `arc-runner-set-arm-ls1intum-sa`. The chart renders only the ServiceAccounts and RoleBindings needed by enabled scale sets.

## Verification

```bash
kubectl get pods -n arc-systems
kubectl get autoscalingrunnersets -n arc-runners
kubectl get pods -n arc-runners
```

## Troubleshooting pointers

- If runner sets do not register, verify `github-arc-secret-eduidec` and `github-arc-secret-ls1intum` exist in `arc-runners`.
- If jobs do not use BuildKit workers, verify runner env vars (`BUILDKIT_NAMESPACE`, `BUILDKIT_NUM_WORKERS`) in generated pods.
- If image pulls bypass cache, inspect DinD args for mirror endpoint `131.159.88.117:30081`.
