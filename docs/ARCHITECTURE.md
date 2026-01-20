# Architecture & Design

This document details the design decisions and architecture of the self-hosted runner infrastructure.

## High-Level Overview

The system provides 3 independent runner "lanes" (Scale Sets), each with dedicated persistent storage. This enables parallel execution while maintaining cache affinity for specific technology stacks.

```
                                  ┌─────────────────┐
                                  │ GitHub Actions  │
                                  └────────┬────────┘
                                           │
          ┌────────────────────────────────┼────────────────────────────────┐
          ▼                                ▼                                ▼
  ┌──────────────┐                 ┌──────────────┐                 ┌──────────────┐
  │ Runner Set 1 │                 │ Runner Set 2 │                 │ Runner Set 3 │
  │ (Base/Py/Hs) │                 │ (JS/OCaml)   │                 │ (C/Rust)     │
  └───────┬──────┘                 └───────┬──────┘                 └───────┬──────┘
          │                                │                                │
  ┌───────▼──────┐                 ┌───────▼──────┐                 ┌───────▼──────┐
  │   PVC 1      │                 │   PVC 2      │                 │   PVC 3      │
  │   100 Gi     │                 │   100 Gi     │                 │   100 Gi     │
  └──────────────┘                 └──────────────┘                 └──────────────┘
```

## Key Design Decisions

### 1. Sticky Runner Assignment
**Problem**: Docker layer caching only works if the build runs on a machine that has the layers cached. Random assignment destroys cache performance.
**Solution**: We define specific runner sets for specific image types.

- **Set 1**: Heavy base images + Python + Haskell
- **Set 2**: JavaScript + OCaml + Java
- **Set 3**: C + Rust

This ensures that a Python build always lands on Runner Set 1, reusing the cached layers from previous Python builds.

### 2. Persistent Volume Claims (PVC)
**Problem**: Standard Kubernetes pods are ephemeral. When a runner pod dies, its disk (and Docker cache) is lost.
**Solution**: We mount a 100Gi PVC to `/var/lib/docker` in the DinD container. This persists the Docker graph driver data between pod restarts.

### 3. Max Runners = 1 (Per Set)
**Constraint**: Standard PVCs (`ReadWriteOnce`) can only be mounted by one pod at a time.
**Implication**: We cannot scale a single runner set to >1 replica while using PVCs.
**Mitigation**: We use 3 independent runner sets to achieve parallelism (3 concurrent jobs) while maintaining persistence.

### 4. Docker-in-Docker (DinD) with Unix Socket
**Security**: We use a privileged DinD sidecar but communicate via a shared Unix socket (`/var/run/docker.sock`) rather than exposing TCP ports.
**Performance**: Avoids network overhead of TCP-based Docker connections.

## Component Interactions

1. **ARC Controller**: Watcher that runs in `arc-systems`. It creates "Listener" pods.
2. **Listener Pods**: Long-running pods that connect to GitHub using the PAT. They listen for job events.
3. **Runner Pods**: Ephemeral pods created *only* when a job is queued.
   - **Container 1 (Runner)**: The GitHub Actions runner agent.
   - **Container 2 (DinD)**: The Docker daemon with the PVC mounted.

## Storage Strategy

- **Size**: 100Gi per runner set (Total 300Gi)
- **Retention**: Permanent (until manually deleted)
- **Cleanup**: Docker's internal GC or manual pruning jobs (future enhancement)

## Scaling

To add more capacity:
1. Create `pvc-docker-cache-4.yaml`
2. Create `values-runner-set-4.yaml`
3. Deploy `arc-runner-set-4`
4. Assign workflows to `runs-on: arc-runner-set-4`
