# Architecture: BuildKit-backed CI with Zot Registry Cache

## Overview

Ephemeral GitHub Actions runners backed by stateful BuildKit workers, a Zot pull-through cache, and a GitHub Actions Cache Server. Runner pods are stateless; BuildKit cache persists on dedicated worker PVCs.

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

### 2. GitHub Actions Cache Server

Deployed in `arc-systems` alongside the ARC controller. It is a drop-in replacement for GitHub's hosted cache service, compatible with `actions/cache`. Runners reference it via environment variables injected at the runner pod level:

- `ACTIONS_RESULTS_URL`
- `CUSTOM_ACTIONS_RESULTS_URL`

Backed by a 200Gi PVC. Cache entries older than 90 days are pruned automatically.

### 3. Actions Runner Controller (ARC)

**Mode:** Kubernetes mode with manual DinD sidecar

**Namespace split** (GitHub security best practice):
- `arc-systems`: ARC controller, listeners, Cache Server
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
| `theia-arc-systems` | `arc-systems` | ARC controller, Cache Server |
| `theia-arc-runners` | `arc-runners` | AutoscalingRunnerSet only |
| `theia-zot` | `zot-system` | Zot registry |

> **The Part 1 release name must be `theia-arc-systems`** — the controller ServiceAccount is named `theia-arc-systems-gha-rs-controller` and Part 2 references it by that exact name.

> Zot is managed separately by the `theia-zot` release in `zot-system`.

## Storage

| Resource | Namespace | Size | Storage Class |
|----------|-----------|------|---------------|
| `github-actions-cache-server` PVC | `arc-systems` | 200Gi | `csi-rbd-sc` (AMD64) / `longhorn` (ARM64) |
| Zot PVC | `zot-system` | 100Gi | `longhorn` |

## Verification

```bash
# ARC controller and cache server
kubectl get pods -n arc-systems

# Runner scale sets
kubectl get autoscalingrunnersets -n arc-runners

# Active runner pods (scale from 0 when jobs arrive)
kubectl get pods -n arc-runners

# PVCs
kubectl get pvc -n arc-systems

# Zot sync activity
kubectl logs -n zot-system -l app.kubernetes.io/name=zot --tail=50
```
