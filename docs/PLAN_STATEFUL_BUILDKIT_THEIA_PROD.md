# Plan: Stateful BuildKit Workers on theia-prod

**Date:** 2026-03-12
**Branch:** `feat/stateful-buildkit-runners`
**Status:** Completed (2026-03-17)
**Scope:** theia-prod only. parma gets the same treatment in a follow-up.

> **Deployment strategy:** BuildKit workers are deployed to an isolated `buildkit-exp` namespace.
> An experimental runner scale set (`arc-runner-set-buildkit-exp`) is added alongside the
> existing production set (`arc-runner-set-stateless`). Both coexist — production workflows
> are untouched. Tear down the experiment with a single `kubectl delete namespace buildkit-exp`
> plus removing the experimental runner set.

---

## Problem

Current build pipeline on theia-prod:

```
ARC runner pod (ephemeral)
  └── dind sidecar
        └── docker build   ← full layer download on every run
```

Every ephemeral runner starts cold. Docker layer cache is stored in the `dind` container's
`emptyDir` — it vanishes when the pod terminates. This means:

- **Every build re-downloads base image layers** from Zot/Docker Hub (even if they haven't changed)
- **Every build re-runs unchanged intermediate steps** (`RUN apt-get install`, `RUN pip install`, etc.)
- Cache primitives like `--cache-from type=registry` help at the registry layer, but not for
  BuildKit's internal snapshot store — they add push/pull overhead on every build
- Multi-stage builds with large intermediate stages are rebuilt from scratch on every run

## Goal

Replace the cold-start DinD build layer with **stateful BuildKit workers**: long-lived pods with
persistent PVCs that accumulate warm layer cache over time. Route each repository deterministically
to the same worker so cache always hits.

```
ARC runner pod (ephemeral, experimental runner set)
  └── buildx remote driver
        └── BuildKit worker pod (stateful, persistent PVC)
              └── warm layer cache → fast incremental builds
```

---

## Architecture

### Two Runner Sets, Side by Side

| Runner Set | Name | Status | Namespace | Builds via |
|------------|------|--------|-----------|-----------|
| Production | `arc-runner-set-stateless` | unchanged | `arc-runners` | DinD (as today) |
| Experimental | `arc-runner-set-buildkit-exp` | new | `arc-runners` | BuildKit remote driver |

Workflows opt into the experiment explicitly by targeting the experimental runner:

```yaml
# Production (unchanged)
runs-on: arc-runner-set-stateless

# Experimental
runs-on: arc-runner-set-buildkit-exp
```

Nothing changes for any existing workflow. The production runner set runs exactly as before.

### Components

| Component | Kind | Namespace | Count |
|-----------|------|-----------|-------|
| `buildkitd` daemon | StatefulSet | `buildkit-exp` | 5 replicas |
| `buildkitd` headless Service | Service (ClusterIP: None) | `buildkit-exp` | 1 |
| Per-worker PVC | PersistentVolumeClaim | `buildkit-exp` | 5 (auto via `volumeClaimTemplates`) |
| Experimental runner scale set | AutoscalingRunnerSet | `arc-runners` | 1 |

> `buildkit-exp` is completely standalone. `kubectl delete namespace buildkit-exp` removes all
> BuildKit workers, PVCs and Services in one command with zero impact on the rest of the cluster.

### How It Works

**Routing (deterministic consistent hashing):**

Each GitHub repository is hashed to a worker index. The same repo always goes to the same
BuildKit pod, so its layer cache is always warm:

```bash
NUM_WORKERS=5
WORKER_ID=$(echo -n "${{ github.repository }}" | cksum | awk '{print $1 % NUM_WORKERS}')
# "ls1intum/artemis"     → always worker 2
# "ls1intum/Ares2"       → always worker 0
# "ls1intum/Hephaestus"  → always worker 4
```

**Connection (in-cluster TCP via headless Service):**

The StatefulSet + headless Service gives each pod a stable DNS name. ARC runner pods in
`arc-runners` can reach them directly since all namespaces are on the same cluster network:

```
buildkitd-0.buildkitd.buildkit-exp.svc.cluster.local:1234
buildkitd-1.buildkitd.buildkit-exp.svc.cluster.local:1234
...
buildkitd-4.buildkitd.buildkit-exp.svc.cluster.local:1234
```

No `kube-pod://` exec, no extra RBAC — plain TCP within the cluster.

**Cache storage:**

Each BuildKit worker has its own Ceph RBD PVC (`csi-rbd-sc`, 100 Gi). The PVC survives pod
restarts. BuildKit stores its internal snapshot store at
`/home/user/.local/share/buildkit` (rootless). This is native BuildKit cache — not
registry-push/pull, just raw local layer storage on disk.

### Network Flow

```
GitHub
  │  job triggered, runs-on: arc-runner-set-buildkit-exp
  ▼
ARC Controller (arc-systems)
  │  creates ephemeral runner pod (experimental set)
  ▼
Runner Pod (arc-runners)
  ├── step: compute worker ID  →  WORKER_ID = hash("ls1intum/artemis") % 5 = 2
  ├── step: setup buildx       →  buildx create --driver remote \
  │                                  tcp://buildkitd-2.buildkitd.buildkit-exp.svc.cluster.local:1234
  └── step: docker build       →  dispatched to buildkitd-2
                                        │
                                        ▼
                              BuildKit Worker: buildkitd-2 (buildkit-exp)
                                ├── cache HIT  → layer served from PVC instantly
                                └── cache MISS → pull from Zot, build, cache on PVC
```

---

## BuildKit StatefulSet Design

Based on the [official upstream example][upstream-statefulset] with these modifications:
- `emptyDir` → `volumeClaimTemplates` (persistent Ceph RBD PVC per pod)
- TCP listener on port 1234 (required for `docker buildx --driver=remote`)
- Rootless mode (`moby/buildkit:latest-rootless`) — no privileged containers
- `podManagementPolicy: Parallel` — all 5 pods start simultaneously
- Liveness/readiness probes via `buildctl debug workers`

[upstream-statefulset]: https://github.com/moby/buildkit/blob/master/examples/kubernetes/statefulset.rootless.yaml

> For the experiment, these are deployed as **raw manifests** (not via the Helm chart).
> This keeps the Helm chart clean and makes teardown trivial.

### `buildkit-exp-namespace.yaml`

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: buildkit-exp
```

### `buildkit-exp-statefulset.yaml`

```yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: buildkitd
  namespace: buildkit-exp
  labels:
    app: buildkitd
spec:
  serviceName: buildkitd
  podManagementPolicy: Parallel
  replicas: 5
  selector:
    matchLabels:
      app: buildkitd
  template:
    metadata:
      labels:
        app: buildkitd
    spec:
      nodeSelector:
        kubernetes.io/arch: amd64
      containers:
        - name: buildkitd
          image: moby/buildkit:latest-rootless
          args:
            - --addr
            - tcp://0.0.0.0:1234
            - --oci-worker-no-process-sandbox
          ports:
            - containerPort: 1234
              name: buildkitd
          readinessProbe:
            exec:
              command: [buildctl, debug, workers]
            initialDelaySeconds: 5
            periodSeconds: 30
          livenessProbe:
            exec:
              command: [buildctl, debug, workers]
            initialDelaySeconds: 5
            periodSeconds: 30
          securityContext:
            seccompProfile:
              type: Unconfined
            appArmorProfile:
              type: Unconfined
            runAsUser: 1000
            runAsGroup: 1000
          resources:
            requests:
              cpu: 500m
              memory: 1Gi
            limits:
              cpu: 8000m
              memory: 16Gi
          volumeMounts:
            - name: buildkit-cache
              mountPath: /home/user/.local/share/buildkit
  volumeClaimTemplates:
    - metadata:
        name: buildkit-cache
      spec:
        accessModes: [ReadWriteOnce]
        storageClassName: csi-rbd-sc
        resources:
          requests:
            storage: 100Gi
```

### `buildkit-exp-service.yaml`

```yaml
apiVersion: v1
kind: Service
metadata:
  name: buildkitd
  namespace: buildkit-exp
  labels:
    app: buildkitd
spec:
  clusterIP: None       # headless — stable per-pod DNS, no load balancing
  selector:
    app: buildkitd
  ports:
    - name: buildkitd
      port: 1234
      targetPort: 1234
```

> Store these three files in a new directory `infra/theia-prod/buildkit-exp/` in this repo.

---

## Helm Chart Changes: Experimental Runner Set

The **only** Helm change is adding `arcRunnersExp` — the new experimental scale set. The
BuildKit workers themselves are managed via raw manifests (above), not Helm.

### `values.yaml` addition

```yaml
# Experimental runner set that uses stateful BuildKit workers.
# Opt in per-workflow with: runs-on: arc-runner-set-buildkit-exp
# Set enabled: false to remove the experimental runner set without touching production runners.
arcRunnersExp:
  enabled: false          # flip to true when ready to deploy
  githubConfigUrl: "https://github.com/ls1intum"
  githubConfigSecret: "github-arc-secret"
  minRunners: 0           # scale to zero when idle
  maxRunners: 10          # fewer than production — experimental load only
  runnerScaleSetName: "arc-runner-set-buildkit-exp"
  controllerServiceAccount:
    namespace: arc-systems
    name: theia-arc-systems-gha-rs-controller
  template:
    spec:
      serviceAccountName: arc-runner-set-stateless-sa   # reuse existing SA
      initContainers:
        - name: init-dind-externals
          image: ghcr.io/falcondev-oss/actions-runner:latest
          command: ["cp", "-r", "/home/runner/externals/.", "/home/runner/tmpDir/"]
          volumeMounts:
            - name: dind-externals
              mountPath: /home/runner/tmpDir
      containers:
        - name: dind
          image: docker:dind
          args:
            - dockerd
            - --host=unix:///var/run/docker.sock
            - --group=1001
            - --registry-mirror=http://131.159.88.30:30081
            - --insecure-registry=131.159.88.30:30081
          securityContext:
            privileged: true
          volumeMounts:
            - name: work
              mountPath: /home/runner/_work
            - name: dind-sock
              mountPath: /var/run
            - name: dind-externals
              mountPath: /home/runner/externals
        - name: runner
          image: ghcr.io/falcondev-oss/actions-runner:latest
          command: ["/home/runner/run.sh"]
          env:
            - name: DOCKER_HOST
              value: unix:///var/run/docker.sock
            - name: ACTIONS_RUNNER_REQUIRE_JOB_CONTAINER
              value: "false"
            - name: ACTIONS_RESULTS_URL
              value: http://theia-arc-systems-cache-server.arc-systems.svc.cluster.local:3000/
            - name: CUSTOM_ACTIONS_RESULTS_URL
              value: http://theia-arc-systems-cache-server.arc-systems.svc.cluster.local:3000/
            # Tells workflow scripts which BuildKit namespace to target.
            - name: BUILDKIT_NAMESPACE
              value: buildkit-exp
            - name: BUILDKIT_NUM_WORKERS
              value: "5"
          volumeMounts:
            - name: work
              mountPath: /home/runner/_work
            - name: dind-sock
              mountPath: /var/run
          resources:
            requests:
              cpu: 500m
              memory: 1Gi
            limits:
              cpu: 4000m
              memory: 8Gi
      volumes:
        - name: work
          emptyDir: {}
        - name: dind-sock
          emptyDir: {}
        - name: dind-externals
          emptyDir: {}
```

### `values-arm64.yaml` addition

```yaml
arcRunnersExp:
  enabled: false    # parma is out of scope for this experiment
```

### Template wiring (`templates/arc-runners-exp.yaml`)

The runner scale set needs its own template since ARC subcharts can't be instantiated twice
from a single `values.yaml` key. Add a new template:

```yaml
{{- if .Values.arcRunnersExp.enabled }}
# Experimental runner scale set — uses stateful BuildKit workers in buildkit-exp namespace.
# Identical to arcRunners but with a distinct scale set name and BUILDKIT_* env vars injected.
apiVersion: actions.github.com/v1alpha1
kind: AutoscalingRunnerSet
metadata:
  name: {{ .Values.arcRunnersExp.runnerScaleSetName }}
  namespace: arc-runners
  labels:
    {{- include "theia-arc-bundle.labels" . | nindent 4 }}
spec:
  githubConfigUrl: {{ .Values.arcRunnersExp.githubConfigUrl }}
  githubConfigSecret: {{ .Values.arcRunnersExp.githubConfigSecret }}
  minRunners: {{ .Values.arcRunnersExp.minRunners }}
  maxRunners: {{ .Values.arcRunnersExp.maxRunners }}
  runnerScaleSetName: {{ .Values.arcRunnersExp.runnerScaleSetName }}
  controllerServiceAccountName: {{ .Values.arcRunnersExp.controllerServiceAccount.name }}
  controllerServiceAccountNamespace: {{ .Values.arcRunnersExp.controllerServiceAccount.namespace }}
  template:
    {{- toYaml .Values.arcRunnersExp.template | nindent 4 }}
{{- end }}
```

> **Note:** Double-check whether ARC's `AutoscalingRunnerSet` CRD accepts `spec` in this format
> or if it needs to go through the `gha-runner-scale-set` subchart. If the subchart approach is
> required, the runner set must be its own Helm release (Part 3), not a raw template.

---

## How Experimental Workflows Use BuildKit

### Routing and Buildx Setup

```yaml
jobs:
  build:
    runs-on: arc-runner-set-buildkit-exp    # ← experimental runner, not production
    steps:
      - uses: actions/checkout@v4

      - name: Route to BuildKit worker
        id: route
        run: |
          NUM_WORKERS="${BUILDKIT_NUM_WORKERS:-5}"
          NS="${BUILDKIT_NAMESPACE:-buildkit-exp}"
          WORKER_ID=$(echo -n "${{ github.repository }}" | cksum | awk "{print \$1 % $NUM_WORKERS}")
          ADDR="tcp://buildkitd-${WORKER_ID}.buildkitd.${NS}.svc.cluster.local:1234"
          echo "worker_id=${WORKER_ID}" >> $GITHUB_OUTPUT
          echo "addr=${ADDR}" >> $GITHUB_OUTPUT
          echo "BuildKit: ${{ github.repository }} → buildkitd-${WORKER_ID} @ ${ADDR}"

      - name: Set up Docker Buildx (remote driver → stateful BuildKit worker)
        uses: docker/setup-buildx-action@v3
        with:
          driver: remote
          endpoint: ${{ steps.route.outputs.addr }}

      - name: Build and push
        uses: docker/build-push-action@v6
        with:
          context: .
          push: true
          tags: ghcr.io/ls1intum/my-image:${{ github.sha }}
          # No cache-from/cache-to needed — BuildKit worker's PVC is always warm.
```

### What Changes, What Stays

| Concern | Production runner | Experimental runner |
|---------|-------------------|---------------------|
| Runner name | `arc-runner-set-stateless` | `arc-runner-set-buildkit-exp` |
| DinD sidecar | ✅ present (docker run, compose, etc.) | ✅ present (same) |
| `docker build` | runs inside DinD (cold, emptyDir) | dispatched to BuildKit worker (warm PVC) |
| Zot mirror | ✅ `131.159.88.30:30081` | ✅ same |
| GHA Cache Server | ✅ present | ✅ same |
| Min runners | 10 | 0 (scale to zero) |
| Max runners | 50 | 10 |

DinD stays in both runner types for `docker run`, `docker compose`, and job containers.
Only `docker build` / `docker buildx build` is offloaded to the stateful BuildKit worker.

---

## Implementation Steps

### Step 1: Store manifests in repo

Create `infra/theia-prod/buildkit-exp/` with the three files:
- `namespace.yaml`
- `statefulset.yaml`
- `service.yaml`

### Step 2: Deploy BuildKit workers

```bash
kubectl config use-context theia-prod

kubectl apply -f infra/theia-prod/buildkit-exp/namespace.yaml
kubectl apply -f infra/theia-prod/buildkit-exp/service.yaml
kubectl apply -f infra/theia-prod/buildkit-exp/statefulset.yaml
```

**Verify all 5 pods reach `Running`:**
```bash
kubectl --context=theia-prod get pods -n buildkit-exp -w
# buildkitd-0   1/1   Running   ...
# buildkitd-1   1/1   Running   ...
# buildkitd-2   1/1   Running   ...
# buildkitd-3   1/1   Running   ...
# buildkitd-4   1/1   Running   ...

kubectl --context=theia-prod get pvc -n buildkit-exp
# 5 PVCs, all Bound, 100Gi each on csi-rbd-sc

kubectl --context=theia-prod get svc -n buildkit-exp
# buildkitd   ClusterIP   None   <none>   1234/TCP
```

**Verify BuildKit responds:**
```bash
kubectl --context=theia-prod run -n buildkit-exp -it --rm buildctl-test \
  --image=moby/buildkit:latest-rootless --restart=Never -- \
  buildctl \
    --addr tcp://buildkitd-0.buildkitd.buildkit-exp.svc.cluster.local:1234 \
    debug workers
# Expected: shows worker info with OCI snapshotter
```

### Step 3: Deploy experimental runner set

```bash
kubectl config use-context theia-prod
cd helm-chart/theia-arc-bundle

# Part 1 — register new runner set name with controller (no Helm change needed if using raw CRD)
# Part 2 — deploy the experimental runner scale set
helm upgrade --install theia-arc-runners . \
  --namespace arc-runners \
  --set cacheServer.enabled=false \
  --set arcController.enabled=false \
  --set zot.enabled=false \
  --set arcRunners.enabled=true \
  --set arcRunnersExp.enabled=true \
  --wait --timeout 2m
```

**Verify both runner sets exist:**
```bash
kubectl --context=theia-prod get autoscalingrunnersets -n arc-runners
# NAME                           ...
# arc-runner-set-stateless       ...   ← production, untouched
# arc-runner-set-buildkit-exp    ...   ← new experimental set
```

### Step 4: Smoke test — verify TCP reachability from a runner pod

Wait for an experimental runner pod to start (trigger a job, or check if any are idle):

```bash
kubectl --context=theia-prod get pods -n arc-runners | grep buildkit-exp

# Exec into one and test connectivity
kubectl --context=theia-prod exec -n arc-runners <buildkit-exp-runner-pod> -c runner -- \
  sh -c 'echo -n "ls1intum/artemis" | cksum | awk "{print \$1 % 5}"'
# Returns a stable number 0-4

kubectl --context=theia-prod exec -n arc-runners <buildkit-exp-runner-pod> -c runner -- \
  nc -zv buildkitd-2.buildkitd.buildkit-exp.svc.cluster.local 1234
# Expected: open
```

### Step 5: Pilot workflow

Pick one repo with a slow build. Switch it to `runs-on: arc-runner-set-buildkit-exp` and add
the routing + buildx steps. Run twice:

1. **First run** (cold): BuildKit pulls layers, builds, caches on PVC. Expect similar speed to DinD.
2. **Second run** (warm): BuildKit serves layers from PVC. Expect significantly faster.

Watch BuildKit logs during both runs:
```bash
kubectl --context=theia-prod logs -n buildkit-exp buildkitd-2 -f
```

### Step 6: Evaluate and decide

If the pilot shows meaningful speedups → roll out to more repos and eventually graduate to `arc-systems`.
If problems arise → tear down the experiment cleanly (see Rollback).

---

## Rollback / Teardown

```bash
# Remove experimental runner set
helm upgrade --install theia-arc-runners helm-chart/theia-arc-bundle \
  --namespace arc-runners \
  --set cacheServer.enabled=false \
  --set arcController.enabled=false \
  --set zot.enabled=false \
  --set arcRunners.enabled=true \
  --set arcRunnersExp.enabled=false   # ← disables the experimental set
  --wait --timeout 2m

# Remove all BuildKit workers, PVCs, and the namespace in one command
kubectl --context=theia-prod delete namespace buildkit-exp
# This deletes: StatefulSet, Service, all 5 PVCs (and their Ceph RBD volumes), all pods
```

Production runner set (`arc-runner-set-stateless`) and all existing workflows are completely
unaffected throughout the experiment and after teardown.

---

## Storage

| Workers | PVC per Worker | Total Ceph |
|---------|----------------|------------|
| 5 | 100 Gi | 500 Gi |

Start at 100 Gi. BuildKit's built-in GC kicks in at 75% capacity and trims to 60%, so the
workers self-manage. Monitor usage:

```bash
for i in 0 1 2 3 4; do
  echo "=== buildkitd-$i ==="
  kubectl --context=theia-prod exec -n buildkit-exp buildkitd-$i -- \
    df -h /home/user/.local/share/buildkit
done
```

Ceph RBD supports online PVC resize if 100 Gi turns out to be too small.

---

## Summary of Files to Create/Change

| File | Action |
|------|--------|
| `infra/theia-prod/buildkit-exp/namespace.yaml` | **New** — `buildkit-exp` namespace |
| `infra/theia-prod/buildkit-exp/statefulset.yaml` | **New** — BuildKit StatefulSet |
| `infra/theia-prod/buildkit-exp/service.yaml` | **New** — headless Service |
| `helm-chart/theia-arc-bundle/values.yaml` | Add `arcRunnersExp:` block |
| `helm-chart/theia-arc-bundle/values-arm64.yaml` | Add `arcRunnersExp: enabled: false` |
| `helm-chart/theia-arc-bundle/templates/arc-runners-exp.yaml` | **New** — AutoscalingRunnerSet template |
| Pilot workflow in one `ls1intum/*` repo | Add `runs-on: arc-runner-set-buildkit-exp` + routing steps |

---

## Risks and Mitigations

| Risk | Impact | Mitigation |
|------|--------|------------|
| BuildKit pod restarts | PVC preserved; warm cache survives | `Retain` reclaim policy on PVCs |
| Worker fills up (100 Gi) | BuildKit GC handles automatically | Built-in GC at 75% usage |
| Two builds for same repo run concurrently | Both land on same worker; BuildKit serializes safely | BuildKit handles concurrent requests (content-addressed locking) |
| `--oci-worker-no-process-sandbox` not supported | Build fails with kernel/seccomp error | Fall back to `statefulset.privileged.yaml` variant if rootless doesn't work on this kernel |
| `AutoscalingRunnerSet` CRD doesn't support raw template | Helm deploy fails | Use a dedicated third Helm release (`theia-arc-runners-exp`) for the experimental runner set instead |

---

## Follow-up: parma

Same approach: BuildKit StatefulSet in `buildkit-exp` namespace on parma, new
`arc-runner-set-arm64-buildkit-exp` runner scale set. Storage uses ZFS-backed static PVs
instead of Ceph (see `PLAN_ZOT_MOVE_TO_PARMA.md` for the ZFS PV pattern). Everything else
— consistent hashing, headless service, remote driver — is identical.
