# Architecture V2: High-Speed Stateless CI (AMD & ARM)

## Overview
This architecture transitions the CI runners from a "Docker-in-Docker" (DinD) stateful model to a high-performance **Stateless Kubernetes Mode**. It is designed for two distinct clusters:
1.  **TheiaProd (AMD)**: General purpose runners.
2.  **Parma (ARM)**: ARM64 runners for multi-arch builds.

Both clusters are considered **Development Environments**, requiring aggressive image freshness and caching.

## Components

### 1. Spegel (P2P Caching Layer)
*   **Type**: DaemonSet (Global)
*   **Function**: Enables peer-to-peer image distribution between nodes.
*   **Configuration**:
    *   `containerdSock`: `/run/containerd/containerd.sock`
    *   `registry.mirror.enabled`: `true`
    *   Runs on **all nodes** to maximize cache hit rates.

### 2. k8s-digester (Freshness Layer)
*   **Type**: Deployment + MutatingWebhook
*   **Function**: Intercepts pod creation and resolves mutable tags (e.g., `:latest`) to immutable SHA digests.
*   **Scope**: **Global** (All Namespaces), with safety exclusions.
    *   **Excluded**: `kube-system` (to protect critical cluster components).
    *   **Included**: `arc-runners`, `default`, and all other dev namespaces.
*   **Why**: Ensures runners and dev workloads always use the absolute latest image version immediately after a push, preventing stale cache issues.

### 3. Actions Runner Controller (ARC) - Kubernetes Mode
*   **Type**: Helm Release
*   **Mode**: `containerMode: kubernetes`
*   **Function**:
    *   Controller spawns a "Listener" pod.
    *   When a job is received, the Listener creates a **new Pod** for that specific job.
    *   No DinD sidecar. No PVCs.
    *   Leverages host `containerd` (and thus Spegel) for image pulls.

## Cluster Specifics

### TheiaProd (AMD)
*   **Context**: `theia-prod`
*   **Namespaces**: `arc-systems`, `arc-runners`
*   **Script**: `scripts/deploy-amd.sh`

### Parma (ARM)
*   **Context**: `parma`
*   **Namespaces**: `arc-systems` (or `parma` - check script), `arc-runners`
*   **Script**: `scripts/deploy-arm.sh`
*   **Network**: Now confirmed to have Internet Access.

## Deployment Strategy
1.  **Switch Context**: Target the correct cluster (`kubectl config use-context ...`).
2.  **Deploy Stack**: Run the respective script to install Spegel -> Digester -> ARC.
3.  **Verify**: Check Spegel peers, Digester logs, and Runner Listener status.

## Usage
The CI pipelines (in `artemis-theia-blueprints` etc.) target these runners using:
*   `runs-on: arc-runner-set-stateless` (AMD)
*   `runs-on: arc-runner-set-arm64` (ARM)
