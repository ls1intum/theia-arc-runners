# Architecture: BuildKit-backed CI with Zot Registry Cache

## Overview

Ephemeral GitHub Actions runners backed by stateful BuildKit workers and a Zot pull-through cache. Runner pods are stateless; BuildKit cache persists on dedicated worker PVCs.

## Clusters

| Cluster | Context | Architecture | Runner Scale Set |
|---------|---------|--------------|-----------------|
| theia-prod | `theia-prod` | AMD64 | `arc-buildkit-eduide-amd64` |
| parma | `parma` | ARM64 | `arc-buildkit-eduide-arm64` |

## Components

### 1. Zot Registry Cache (shared)

Zot is deployed on parma as a standalone Helm release (`theia-zot`) in namespace `zot-system`. It is a CNCF Sandbox OCI registry that supports the `--registry-mirror` transparent proxy protocol natively.

On a cache miss, Zot fetches from `registry-1.docker.io`, caches the blob, and serves it. On subsequent pulls the blob is served from the PVC without contacting Docker Hub.

Zot is HTTP-only. DinD containers are configured with:
```
--registry-mirror=http://<zot-addr>
--insecure-registry=<zot-addr>
```

This makes all `docker pull` calls route through Zot transparently — workflows do not need any changes.

Both clusters reach Zot via NodePort `131.159.88.117:30081`.

### 2. Build cache model

The old self-hosted actions cache subchart is no longer deployed by `theia-arc-bundle`. Runner pods use the official `ghcr.io/actions/actions-runner` image, so the chart does not inject cache endpoint overrides.

Docker image pull caching is handled by Zot. Docker build caching is handled by the stateful BuildKit workers.

### 3. Actions Runner Controller (ARC)

**Mode:** custom runner pod template with manual DinD sidecar

**Namespace split** (GitHub security best practice):
- `arc-systems`: ARC controller, listeners
- `arc-runners`: AutoscalingRunnerSet, ephemeral runner pods
- `zot-system`: Zot registry

**Runner pod structure:**

```
┌─────────────────────────────────────────────────┐
│ Runner Pod                                      │
├─────────────────────────────────────────────────┤
│ init: init-dind-externals                       │
│   copies runner binaries → shared emptyDir      │
├──────────────────────┬──────────────────────────┤
│ dind container       │ runner container          │
│ - docker daemon      │ - actions runner binary   │
│ - privileged         │ - DOCKER_HOST=unix://sock │
│ - --registry-mirror  │ - runs workflow steps     │
│   → Zot              │                           │
└──────────────────────┴──────────────────────────┘
         shared volumes:
           dind-sock   → /var/run        (docker socket)
           work        → /home/runner    (emptyDir, Memory on ARM64)
           externals   → runner binaries
```

On parma, the work volume uses `emptyDir.medium: Memory` (30Gi) — RAM-backed, ~1000x faster than network storage.

## Network Flow

```
GitHub
  │  job request
  ▼
ARC Controller (arc-systems)
  │  creates runner pod
  ▼
Runner Pod (arc-runners)
  │  docker pull alpine
  ▼
dind container
  │  --registry-mirror → Zot
  ▼
Zot (zot-system)
  ├── cache HIT  → serve from PVC immediately
  └── cache MISS → fetch from registry-1.docker.io, cache, serve
```

## Helm Deployment Model

The chart is deployed in **two separate Helm releases** because Helm 3 cannot deploy subcharts into different namespaces in one release:

| Release | Namespace | Contains |
|---------|-----------|----------|
| `theia-arc-systems` | `arc-systems` | ARC controller |
| `theia-arc-runners` | `arc-runners` | AutoscalingRunnerSet only |
| `theia-zot` | `zot-system` | Zot registry |

> **The Part 1 release name must be `theia-arc-systems`** — the controller ServiceAccount is named `theia-arc-systems-gha-rs-controller` and Part 2 references it by that exact name.

> Zot is managed separately by the `theia-zot` release in `zot-system`.

## Storage

| Resource | Namespace | Size | Storage Class |
|----------|-----------|------|---------------|
| Zot PVC | `zot-system` | 250Gi | `longhorn` |
| BuildKit worker PVCs | `buildkit-exp` / `buildkit` | 7 x 500Gi per cluster | `csi-rbd-sc` / `longhorn` |

## Verification

```bash
# ARC controller
kubectl get pods -n arc-systems

# Runner scale sets
kubectl get autoscalingrunnersets -n arc-runners

# Active runner pods (scale from 0 when jobs arrive)
kubectl get pods -n arc-runners

# Zot sync activity
kubectl logs -n zot-system -l app.kubernetes.io/name=zot --tail=50
```
