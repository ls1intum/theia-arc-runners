# Architecture: Stateless CI with Registry Caching

## Overview

This architecture runs ephemeral GitHub Actions runners with Docker Registry v2 pull-through caches. Runners are stateless (no PVCs) and scale 0-10 based on job demand.

## Clusters

| Cluster | Context | Architecture | Purpose |
|---------|---------|--------------|---------|
| theia-prod | `theia-prod` | AMD64 | General CI, multi-arch manifest creation |
| parma | `parma` | ARM64 | ARM64 image builds |

## Components

### 1. Docker Registry v2 Pull-Through Cache

Each cluster runs two registry instances:

**Docker Hub Mirror** (`registry-mirror`):
- Caches pulls from `docker.io`
- Used by DinD via `--registry-mirror` flag
- Transparent to `docker pull alpine` commands

**GHCR Mirror** (`registry-mirror-ghcr`):
- Caches pulls from `ghcr.io`
- Used by BuildKit via registry mirror config
- Caches base images and build cache layers

**Configuration:**
- TTL: 720h (30 days) - cached layers live this long
- Storage: 200Gi per registry
- Freshness: Tags checked against upstream on every pull

### 2. Actions Runner Controller (ARC)

**Mode:** Kubernetes mode with manual DinD sidecar

**Components:**
- Controller (`arc-systems` namespace): Manages runner lifecycle
- Listeners: Polls GitHub for jobs
- Runner pods (`arc-runners` namespace): Ephemeral, created per job

**Runner Pod Structure:**
```
┌─────────────────────────────────────────┐
│ Runner Pod                              │
├─────────────────────────────────────────┤
│ init: copy externals                    │
├──────────────────┬──────────────────────┤
│ dind container   │ runner container     │
│ - docker daemon  │ - actions runner     │
│ - registry-mirror│ - DOCKER_HOST=sock   │
│ - privileged     │ - runs workflow      │
└──────────────────┴──────────────────────┘
        │
        ▼
  /var/run/docker.sock (emptyDir)
```

### 3. Caching Strategy

**Layer 1: Registry Pull-Through Cache**
- Base images (`node:22`, `alpine`, etc.) cached in-cluster
- ~2-3s pulls vs 30-60s from internet
- Shared across all runners

**Layer 2: BuildKit Registry Cache**
- Build layers pushed to `ghcr.io/{org}/{repo}/build-cache`
- Persists across runner restarts
- Per-image, keyed by Dockerfile hash

**Layer 3: BuildKit Mount Cache**
- `--mount=type=cache` for npm/yarn/pip
- Lives within single build only (emptyDir)
- Useful for multi-stage builds

## Network Flow

```
GitHub ─────────────────────────────────────────┐
   │                                            │
   │ Job request                                │
   ▼                                            │
┌─────────────────────────────────────────────┐ │
│ Kubernetes Cluster                          │ │
│                                             │ │
│  ┌─────────────┐    ┌─────────────────────┐ │ │
│  │ ARC         │───▶│ Runner Pod          │ │ │
│  │ Controller  │    │                     │ │ │
│  └─────────────┘    │  docker pull alpine │ │ │
│                     │         │           │ │ │
│                     │         ▼           │ │ │
│  ┌─────────────────────────────────────┐  │ │ │
│  │ registry-mirror (Docker Hub cache)  │  │ │ │
│  │         │                           │  │ │ │
│  │    ┌────┴────┐                      │  │ │ │
│  │  Cache    Upstream                  │  │ │ │
│  │   HIT      MISS                     │  │ │ │
│  │    │         │                      │  │ │ │
│  │    ▼         ▼                      │  │ │ │
│  │  Return   Fetch ──────────────────────────┼───▶ registry-1.docker.io
│  │           Cache                     │  │ │ │
│  │           Return                    │  │ │ │
│  └─────────────────────────────────────┘  │ │ │
│                     │                     │ │ │
│                     ▼                     │ │ │
│                   Image                   │ │ │
│                     │                     │ │ │
│                     ▼                     │ │ │
│              Workflow step                │◀┘ │
│                     │                     │   │
│                     ▼                     │   │
│              Push to GHCR ────────────────────▶ ghcr.io
└─────────────────────────────────────────────┘
```

## Deployment

### AMD64 (theia-prod)

```bash
kubectl config use-context theia-prod
./scripts/deploy-amd.sh stateless
```

### ARM64 (parma)

```bash
kubectl config use-context parma
./scripts/deploy-arm.sh arm64
```

## Verification

```bash
# Check registry mirrors
kubectl get pods -n registry-mirror

# Check ARC controller
kubectl get pods -n arc-systems

# Check runners
kubectl get pods -n arc-runners

# Test cache hit
kubectl exec -it deploy/registry-mirror -n registry-mirror -- \
  wget -qO- http://localhost:5000/v2/_catalog
```

## Why Not Harbor/Spegel?

**Harbor:** Architecturally incompatible with `--registry-mirror`. Harbor's proxy cache requires explicit project paths (`harbor.example.com/dockerhub/library/alpine`) but `--registry-mirror` expects transparent proxying. Result: every request was a cache miss.

**Spegel:** P2P cache that requires containerd runtime modifications. On RKE2 clusters, this conflicts with embedded-registry feature and caused pod scheduling failures.

**Docker Registry v2:** Simple, lightweight, fully compatible with `--registry-mirror`. Single binary, no complex setup.
