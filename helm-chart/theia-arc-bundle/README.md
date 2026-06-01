# Theia ARC Bundle Helm Chart

Umbrella chart for the ARC controller and ARC runner scale sets.

> Zot is **not** deployed by this chart. Zot is deployed via `helm-chart/theia-zot` as a separate release.

## Overview

This chart provides:

- ARC controller (`gha-runner-scale-set-controller`)
- ARC runner scale sets (`gha-runner-scale-set` aliases)

The previous vendored self-hosted actions cache subchart has been removed. Runner pods now use the official GitHub runner image; Docker image caching is handled by Zot and build caching is handled by the stateful BuildKit workers.

Active runner scale set labels used in production:

- `arc-buildkit-eduide-stud-amd64` (stud)
- `arc-buildkit-ls1intum-stud-amd64` (stud)
- `arc-buildkit-eduide-amd64` (theia-prod)
- `arc-buildkit-ls1intum-amd64` (theia-prod)
- `arc-buildkit-eduide-arm64` (parma)
- `arc-buildkit-ls1intum-arm64` (parma)

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
3. GitHub App or PAT secrets in `arc-runners`:
   - `github-arc-secret-eduidec` for EduIDE
   - `github-arc-secret` for ls1intum
4. Storage classes:
   - `csi-rbd-sc` on stud/theia-prod
   - `longhorn` on parma

## Core deployment commands

Run from the repository root.

### stud (AMD64 BuildKit runners)

```bash
helm upgrade --install theia-arc-systems helm-chart/theia-arc-bundle \
  --namespace arc-systems \
  -f helm-chart/theia-arc-bundle/values-stud.yaml \
  --set createNamespaces=false \
  --set arcRunners.enabled=false \
  --set arcRunnersArm.enabled=false \
  --set arcRunnersExp.enabled=false \
  --set arcRunnersArmBuildkit.enabled=false \
  --set arcRunnersLs1intumExp.enabled=false \
  --set arcRunnersLs1intumArmBuildkit.enabled=false \
  --wait --timeout 5m

helm upgrade --install theia-arc-runners helm-chart/theia-arc-bundle \
  --namespace arc-runners \
  -f helm-chart/theia-arc-bundle/values-stud.yaml \
  --set createNamespaces=false \
  --set arcController.enabled=false \
  --set arcRunners.enabled=false \
  --set arcRunnersArm.enabled=false \
  --set arcRunnersExp.enabled=true \
  --set arcRunnersArmBuildkit.enabled=false \
  --set arcRunnersLs1intumExp.enabled=true \
  --set arcRunnersLs1intumArmBuildkit.enabled=false \
  --wait --timeout 10m
```

### theia-prod (AMD64 BuildKit runners)

```bash
helm upgrade --install theia-arc-systems helm-chart/theia-arc-bundle \
  --namespace arc-systems \
  --set createNamespaces=false \
  --set arcRunners.enabled=false \
  --set arcRunnersArm.enabled=false \
  --set arcRunnersExp.enabled=false \
  --set arcRunnersArmBuildkit.enabled=false \
  --set arcRunnersLs1intumExp.enabled=false \
  --set arcRunnersLs1intumArmBuildkit.enabled=false \
  --wait --timeout 5m

helm upgrade --install theia-arc-runners helm-chart/theia-arc-bundle \
  --namespace arc-runners \
  --set createNamespaces=false \
  --set arcController.enabled=false \
  --set arcRunners.enabled=false \
  --set arcRunnersArm.enabled=false \
  --set arcRunnersExp.enabled=true \
  --set arcRunnersArmBuildkit.enabled=false \
  --set arcRunnersLs1intumExp.enabled=true \
  --set arcRunnersLs1intumArmBuildkit.enabled=false \
  --wait --timeout 10m
```

### parma (ARM64 BuildKit runners)

```bash
helm upgrade --install theia-arc-systems helm-chart/theia-arc-bundle \
  --namespace arc-systems \
  -f helm-chart/theia-arc-bundle/values-arm64.yaml \
  --set createNamespaces=false \
  --set arcRunners.enabled=false \
  --set arcRunnersArm.enabled=false \
  --set arcRunnersExp.enabled=false \
  --set arcRunnersArmBuildkit.enabled=false \
  --set arcRunnersLs1intumExp.enabled=false \
  --set arcRunnersLs1intumArmBuildkit.enabled=false \
  --wait --timeout 5m

helm upgrade --install theia-arc-runners helm-chart/theia-arc-bundle \
  --namespace arc-runners \
  -f helm-chart/theia-arc-bundle/values-arm64.yaml \
  --set createNamespaces=false \
  --set arcController.enabled=false \
  --set arcRunners.enabled=false \
  --set arcRunnersArm.enabled=false \
  --set arcRunnersExp.enabled=false \
  --set arcRunnersArmBuildkit.enabled=true \
  --set arcRunnersLs1intumExp.enabled=false \
  --set arcRunnersLs1intumArmBuildkit.enabled=true \
  --wait --timeout 10m
```

## Key values

| Value | Meaning |
|------|---------|
| `arcController.enabled` | Enable ARC controller subchart |
| `arcRunners.enabled` | Legacy AMD64 stateless set (disabled in current target topology) |
| `arcRunnersArm.enabled` | Legacy ARM64 stateless set (disabled in current target topology) |
| `arcRunnersExp.enabled` | AMD64 BuildKit runner set (`arc-buildkit-eduide-amd64`) |
| `arcRunnersArmBuildkit.enabled` | ARM64 BuildKit runner set (`arc-buildkit-eduide-arm64`) |
| `arcRunnersLs1intumExp.enabled` | AMD64 BuildKit runner set for ls1intum |
| `arcRunnersLs1intumArmBuildkit.enabled` | ARM64 BuildKit runner set for ls1intum |

## Verification

```bash
kubectl get pods -n arc-systems
kubectl get autoscalingrunnersets -n arc-runners
kubectl get pods -n arc-runners
```

## Troubleshooting pointers

- If runner sets do not register, verify `github-arc-secret-eduidec` and `github-arc-secret` exist in `arc-runners`.
- If jobs do not use BuildKit workers, verify runner env vars (`BUILDKIT_NAMESPACE`, `BUILDKIT_NUM_WORKERS`) in generated pods.
- If image pulls bypass cache, inspect DinD args for mirror endpoint `131.159.88.117:30081`.
