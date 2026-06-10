# Architecture: BuildKit-backed CI with Zot Registry Cache

## Overview

Ephemeral GitHub Actions runners backed by stateful BuildKit workers and a Zot pull-through cache. Runner pods are disposable; BuildKit cache persists on dedicated worker PVCs so Docker layer cache, BuildKit cache layers, and BuildKit cache mounts survive between workflow runs.

## Clusters

| Cluster | Context | Architecture | Runner Scale Sets |
|---------|---------|--------------|-------------------|
| stud | `stud` | AMD64 | `arc-buildkit-eduide-stud-amd64`, `arc-buildkit-ls1intum-stud-amd64` |
| theia-prod | `theia-prod` | AMD64 | `arc-buildkit-eduide-theiaprod-amd64`, `arc-buildkit-ls1intum-theiaprod-amd64` |
| parma | `parma` | ARM64 | `arc-buildkit-eduide-parma-arm64`, `arc-buildkit-ls1intum-parma-arm64` |

## Components

### 1. Zot Registry Cache (shared)

Zot is deployed on parma as a standalone Helm release (`theia-zot`) in namespace `zot-system`. It is a CNCF Sandbox OCI registry that supports the `--registry-mirror` transparent proxy protocol natively.

On a cache miss, Zot fetches from `registry-1.docker.io`, caches the blob, and serves it. On subsequent pulls the blob is served from the PVC without contacting Docker Hub.

Zot is HTTP-only and is used by the BuildKit worker topology to reduce Docker Hub traffic. Workflows do not need registry-cache-specific changes.

All runner clusters reach the current shared Zot deployment on parma via NodePort `131.159.88.117:30081`.

### Docker Hub rate-limit strategy

The current Zot mirror exists mainly to avoid Docker Hub pull rate limits for anonymous or low-tier authenticated pulls. GitHub Container Registry does not have the same Docker Hub pull-rate-limit pressure for this setup, so the mirror primarily protects Docker Hub traffic.

The longer-term tradeoff between keeping Zot and using a paid Docker Hub CI account is documented in [ZOT_VS_DOCKER_HUB_SUBSCRIPTION.md](ZOT_VS_DOCKER_HUB_SUBSCRIPTION.md).

### 2. Build cache model

The old self-hosted actions cache subchart is no longer deployed by `theia-arc-bundle`. Runner pods use the official `ghcr.io/actions/actions-runner` image, so the chart does not inject cache endpoint overrides.

Docker image pull caching is handled by Zot. Docker build caching is handled by the stateful BuildKit workers, including layer cache, BuildKit cache layers, and cache mounts.

### 3. Actions Runner Controller (ARC)

**Mode:** ARC documented DinD pod topology with native sidecar initContainer

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
│ init sidecar: dind                              │
│   docker daemon, privileged, restartPolicy=Always│
├─────────────────────────────────────────────────┤
│ runner container                                │
│ - actions runner binary                         │
│ - DOCKER_HOST=unix://sock                       │
│ - runs workflow steps                           │
└─────────────────────────────────────────────────┘
         shared volumes:
           dind-sock   → /var/run        (docker socket)
           work        → /home/runner/_work
           externals   → runner binaries
```

The DinD sidecar follows the official ARC chart's documented DinD pod topology, but the pod spec is kept explicit in this repository instead of enabling `containerMode.type: dind` directly. The chart-generated DinD startup probe cannot currently be tuned via values, and parma needs a longer `docker info` timeout when many runner pods start at once. This keeps the Docker daemon lifecycle aligned with ARC runner cleanup behavior while avoiding one-second startup probe timeouts under load.

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
ARC-managed DinD / remote BuildKit
  │  Docker Hub traffic reduced by Zot/BuildKit cache topology
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
| Zot PVC | `zot-system` | 100Gi | `longhorn` |
| BuildKit worker PVCs | `buildkit` on every runner cluster | 7 x 100Gi per cluster | `csi-rbd-sc` on stud/theia-prod, `longhorn` on parma |

The current 7 BuildKit workers per cluster are an arbitrary operational baseline, not a hard architectural limit. One BuildKit worker can handle multiple builds at once. On multi-node clusters, especially if stud grows, the worker count can be increased and may reasonably move toward one worker per node. BuildKit StatefulSets use soft pod anti-affinity across `kubernetes.io/hostname`: workers prefer different nodes, but scheduling can still proceed if the cluster cannot spread all replicas. Be conservative on parma because it is currently a single-node cluster.

Runner scale set `minRunners: 10` is an arbitrary operational baseline as well. The shared default `maxRunners: 50` applies to the multi-node AMD64 clusters; parma overrides `maxRunners: 10` because it is currently a single ARM64 node and should not burst a large DinD runner pool onto one machine. These values can be increased for larger clusters, but changes should be evaluated together with runner pod CPU and memory requests/limits so the configured runner pool does not overcommit the available nodes.

## Verification

```bash
# ARC controller
kubectl get pods -n arc-systems

# Runner scale sets
kubectl get autoscalingrunnersets -n arc-runners

# Active runner pods
kubectl get pods -n arc-runners

# Zot sync activity
kubectl logs -n zot-system -l app.kubernetes.io/name=zot --tail=50
```
