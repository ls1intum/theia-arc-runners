# Theia ARC Bundle Helm Chart

Umbrella chart for ARC controller, ARC runner scale sets, and GitHub Actions Cache Server.

> Zot is **not** deployed by this chart. Zot is deployed via `helm-chart/theia-zot` as a separate release.

## Overview

This chart provides:

- ARC controller (`gha-runner-scale-set-controller`)
- ARC runner scale sets (`gha-runner-scale-set` aliases)
- GitHub Actions Cache Server (vendored local subchart)

Active runner scale set labels used in production:

- `arc-buildkit-eduide-amd64` (theia-prod)
- `arc-buildkit-eduide-arm64` (parma)

## Why multiple Helm releases?

Helm cannot deploy subcharts to different namespaces in a single release. We deploy:

| Part | Release | Namespace | Includes |
|------|---------|-----------|----------|
| Part 1 | `theia-arc-systems` | `arc-systems` | ARC controller + cache server |
| Part 2 | `theia-arc-runners` | `arc-runners` | Runner scale set(s) |
| Part 3 | `theia-zot` (different chart) | `zot-system` | Zot pull-through cache |

`theia-arc-systems` release name is required because runner sets reference controller SA `theia-arc-systems-gha-rs-controller`.

## Prerequisites

1. Kubernetes v1.23+
2. Helm v3.8+
3. GitHub App or PAT secret in `arc-runners` (for EduIDE org)
4. Storage classes:
   - `csi-rbd-sc` on theia-prod
   - `longhorn` on parma

## Core deployment commands

From `helm-chart/theia-arc-bundle`.

### theia-prod (AMD64 BuildKit runners)

```bash
helm upgrade --install theia-arc-systems . \
  --namespace arc-systems --create-namespace \
  --set arcRunners.enabled=false \
  --set arcRunnersArm.enabled=false \
  --set arcRunnersExp.enabled=false \
  --set arcRunnersArmBuildkit.enabled=false \
  --wait --timeout 5m

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

### parma (ARM64 BuildKit runners)

```bash
helm upgrade --install theia-arc-systems . \
  --namespace arc-systems --create-namespace \
  -f values-arm64.yaml \
  --set arcRunners.enabled=false \
  --set arcRunnersArm.enabled=false \
  --set arcRunnersExp.enabled=false \
  --set arcRunnersArmBuildkit.enabled=false \
  --wait --timeout 5m

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

## Key values

| Value | Meaning |
|------|---------|
| `arcController.enabled` | Enable ARC controller subchart |
| `cache-server.enabled` | Enable cache server subchart |
| `arcRunners.enabled` | Legacy AMD64 stateless set (disabled in current target topology) |
| `arcRunnersArm.enabled` | Legacy ARM64 stateless set (disabled in current target topology) |
| `arcRunnersExp.enabled` | AMD64 BuildKit runner set (`arc-buildkit-eduide-amd64`) |
| `arcRunnersArmBuildkit.enabled` | ARM64 BuildKit runner set (`arc-buildkit-eduide-arm64`) |

## Verification

```bash
kubectl get pods -n arc-systems
kubectl get autoscalingrunnersets -n arc-runners
kubectl get pods -n arc-runners
kubectl get pvc -n arc-systems
```

## Troubleshooting pointers

- If runner sets do not register, verify `github-arc-secret-eduidec` exists in `arc-runners`.
- If jobs do not use BuildKit workers, verify runner env vars (`BUILDKIT_NAMESPACE`, `BUILDKIT_NUM_WORKERS`) in generated pods.
- If image pulls bypass cache, inspect DinD args for mirror endpoint `131.159.88.117:30081`.
