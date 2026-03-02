# Architecture: Stateless CI with Harbor Registry Cache

## Overview

Ephemeral GitHub Actions runners backed by a Harbor pull-through proxy cache and a GitHub Actions Cache Server. Runners are stateless (no PVCs) and scale 10–50 based on job demand.

## Clusters

| Cluster | Context | Architecture | Runner Scale Set |
|---------|---------|--------------|-----------------|
| theia-prod | `theia-prod` | AMD64 | `arc-runner-set-stateless` |
| parma | `parma` | ARM64 | `arc-runner-set-arm64` |

## Components

### 1. Harbor Registry Cache (AMD64 only)

Harbor is deployed in `arc-systems` on theia-prod. It exposes two proxy cache projects:

| Project | Upstream | In-cluster pull URL |
|---------|----------|---------------------|
| `dockerhub-proxy` | `registry-1.docker.io` | `harbor.arc-systems.svc.cluster.local:80/dockerhub-proxy/` |
| `ghcr-proxy` | `ghcr.io` | `harbor.arc-systems.svc.cluster.local:80/ghcr-proxy/` |

These projects are created automatically by the `harbor-proxy-setup` Helm post-install hook Job on every install/upgrade.

Harbor is HTTP-only (no TLS). DinD containers are configured with:
```
--registry-mirror=http://<harbor-addr>
--insecure-registry=<harbor-addr>
```

This makes all `docker pull` calls route through Harbor transparently — workflows do not need any changes.

**parma (ARM64)** has no local Harbor. It reaches theia-prod's Harbor via a Kubernetes NodePort at `131.159.88.30:30080`.

### 2. GitHub Actions Cache Server

Deployed in `arc-systems` alongside the ARC controller. It is a drop-in replacement for GitHub's hosted cache service, compatible with `actions/cache`. Runners reference it via environment variables injected at the runner pod level:

- `ACTIONS_RESULTS_URL`
- `CUSTOM_ACTIONS_RESULTS_URL`

Backed by a 200Gi PVC. Cache entries older than 90 days are pruned automatically.

### 3. Actions Runner Controller (ARC)

**Mode:** Kubernetes mode with manual DinD sidecar

**Namespace split** (GitHub security best practice):
- `arc-systems`: ARC controller, listeners, Cache Server, Harbor
- `arc-runners`: AutoscalingRunnerSet, ephemeral runner pods

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
│   → Harbor           │                           │
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
  │  --registry-mirror → Harbor
  ▼
Harbor (arc-systems)
  ├── cache HIT  → return cached layer immediately
  └── cache MISS → fetch from registry-1.docker.io, cache, return
```

## Helm Deployment Model

The chart is deployed in **two separate Helm releases** because Helm 3 cannot deploy subcharts into different namespaces in one release:

| Release | Namespace | Contains |
|---------|-----------|----------|
| `theia-arc-systems` | `arc-systems` | ARC controller, Cache Server, Harbor |
| `theia-arc-runners` | `arc-runners` | AutoscalingRunnerSet only |

> **The Part 1 release name must be `theia-arc-systems`** — the controller ServiceAccount is named `theia-arc-systems-gha-rs-controller` and Part 2 references it by that exact name.

> **Part 2 must always pass `--set harbor.enabled=false`** — Harbor is owned by the `theia-arc-systems` release in `arc-systems`. If omitted, Helm tries to create the Harbor NodePort in `arc-runners` and fails with "port already allocated".

## Storage

| Resource | Namespace | Size | Storage Class |
|----------|-----------|------|---------------|
| `github-actions-cache-server` PVC | `arc-systems` | 200Gi | `csi-rbd-sc` (AMD64) / `longhorn` (ARM64) |
| Harbor core PVC | `arc-systems` | 10Gi | `csi-rbd-sc` |
| Harbor registry PVC | `arc-systems` | 200Gi | `csi-rbd-sc` |

Harbor is AMD64 only — parma has no local Harbor PVCs.

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

# Harbor proxy projects
kubectl logs -n arc-systems -l job-name=harbor-proxy-setup
```
