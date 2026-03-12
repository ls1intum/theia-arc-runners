# Plan: Migrate Zot from theia-prod to parma

**Date:** 2026-03-12
**Status:** Draft — awaiting approval before implementation

---

## Background

Zot is currently deployed on **theia-prod** (`arc-systems` namespace) with a 100 Gi Ceph RBD PVC
(`csi-rbd-sc`). parma has a far superior storage and network profile and should host Zot instead.

### Why Move Zot to parma?

| Factor | theia-prod (current) | parma (target) |
|--------|----------------------|----------------|
| Storage | 100 Gi Ceph RBD (~500 MB/s read, ~300 MB/s write) | ZFS RAIDZ1 over 4× NVMe (10.6 GB/s read, 8.7 GB/s write) |
| IOPS | ~30 K random read | ~176 K random read |
| Storage latency | Network-attached (Ceph) | Local NVMe |
| Free capacity | Quota-constrained (Ceph) | 6+ TB free on ZFS pool |
| Upload to Docker Hub | 584 Mbps | 1,007 Mbps (1.7× faster — faster initial pulls) |
| Ceph quota per node | 200 Gi cap (Longhorn), limited RBD | No cap on ZFS |

The net effect: parma will serve Zot layer cache at local NVMe speeds (~20× faster than current
Ceph), support a much larger cache (500 Gi+ instead of 100 Gi), and pull upstream images faster
due to better uplink. Both clusters are on the same `/24` datacenter subnet (`131.159.88.x`) with
~0.4 ms RTT and ~9 Gbps throughput between them, so the cross-cluster hop for theia-prod runners
is negligible.

### Current State

```
theia-prod runners  ──(in-cluster)──▶  Zot (arc-systems, theia-prod)
parma runners       ──(NodePort)─────▶  Zot (131.159.88.30:30081)
```

### Target State

```
theia-prod runners  ──(NodePort)─────▶  Zot (arc-systems, parma)
parma runners       ──(in-cluster)───▶  Zot (arc-systems, parma)
```

---

## Storage Strategy: ZFS Dataset + Static PersistentVolume

**Do NOT use Longhorn** for this PVC. The goal is raw NVMe performance; Longhorn adds replication
overhead and caps at 200 Gi per node on the current setup.

Instead, provision a ZFS dataset directly and bind it to a static Kubernetes PersistentVolume
using a `hostPath`. parma is a single-node cluster, so `hostPath` PVs are safe and reliable.

### ZFS Dataset

```bash
# SSH into parma node or run via kubectl exec on a privileged pod
zfs create local-zfs/zot
# Result: dataset mounted at /local-zfs/zot
```

> The `local-zfs` pool is a RAIDZ1 across 4× 2.91 TB NVMe drives (11.6 TB total, 6.12 TB free).

### Static PersistentVolume (applied to parma cluster)

Create `kubectl apply -f -` on `parma` context:

```yaml
apiVersion: v1
kind: PersistentVolume
metadata:
  name: zot-zfs-pv
  labels:
    app: zot
    storage: zfs-local
spec:
  storageClassName: ""          # static — not dynamically provisioned
  capacity:
    storage: 500Gi
  accessModes:
    - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  hostPath:
    path: /local-zfs/zot
    type: DirectoryOrCreate
  nodeAffinity:
    required:
      nodeSelectorTerms:
        - matchExpressions:
            - key: kubernetes.io/hostname
              operator: In
              values:
                - arm-altra-23-parma
```

### Static PersistentVolumeClaim

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: zot-zfs-pvc
  namespace: arc-systems
spec:
  storageClassName: ""
  volumeName: zot-zfs-pv       # binds to the PV above
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 500Gi
```

Apply both manifests before running Helm:
```bash
kubectl --context=parma apply -f zot-zfs-pv.yaml
kubectl --context=parma apply -f zot-zfs-pvc.yaml
kubectl --context=parma get pv zot-zfs-pv   # should be Bound
```

> Keep these manifests in the repo under `infra/parma/` or similar — they are **not** managed by
> the Helm chart (intentional: static PVs live outside Helm lifecycle management).

---

## Helm Chart Changes

### 1. `values.yaml` (theia-prod AMD64 defaults)

**Disable Zot** on theia-prod and update DinD args to point at parma's Zot NodePort.

```yaml
# Before — Zot on theia-prod, in-cluster access
zot:
  enabled: true
  ...DinD args: --registry-mirror=http://131.159.88.30:30081

# After — Zot disabled on theia-prod, cross-cluster to parma
zot:
  enabled: false

# Update DinD args in arcRunners section:
- --registry-mirror=http://<parma-node-ip>:30081
- --insecure-registry=<parma-node-ip>:30081
```

> `<parma-node-ip>` is the node IP of `arm-altra-23-parma` on the `131.159.88.x` subnet. Confirm
> with: `kubectl --context=parma get node -o wide`

**Move the canonical Zot config into `values-arm64.yaml`** (since Zot now lives on parma).

### 2. `values-arm64.yaml` (parma ARM64 overrides)

Enable Zot on parma with the ARM64 nodeSelector and ZFS PVC:

```yaml
zot:
  enabled: true
  mountConfig: true
  configFiles:
    config.json: |-
      {
        "distSpecVersion": "1.1.0",
        "storage": {
          "rootDirectory": "/var/lib/registry",
          "dedupe": true,
          "gc": true,
          "gcDelay": "1h",
          "gcInterval": "6h",
          "retention": {
            "policies": [
              {
                "repositories": ["**"],
                "keepTags": [
                  {
                    "mostRecentlyPulledCount": 200,
                    "pulledWithin": "720h"
                  }
                ]
              }
            ]
          }
        },
        "http": {
          "address": "0.0.0.0",
          "port": "5000",
          "Compat": true
        },
        "log": {
          "level": "info"
        },
        "extensions": {
          "sync": {
            "enable": true,
            "credentialsFile": "/etc/zot-credentials/credentials.json",
            "registries": [
              {
                "urls": ["https://registry-1.docker.io"],
                "onDemand": true,
                "pollInterval": "24h",
                "tlsVerify": true,
                "preserveDigest": true,
                "maxRetries": 3,
                "retryDelay": "1m",
                "content": [{ "prefix": "**" }]
              }
            ]
          }
        }
      }
  extraVolumes:
    - name: zot-credentials
      secret:
        secretName: zot-dockerhub-credentials
  extraVolumeMounts:
    - name: zot-credentials
      mountPath: /etc/zot-credentials
      readOnly: true
  # Use the pre-created static ZFS PVC (not dynamically provisioned)
  persistence: true
  pvc:
    create: false               # PVC pre-created manually (zot-zfs-pvc)
    existingClaim: zot-zfs-pvc
  service:
    type: NodePort
    port: 5000
    nodePort: 30081
  resources:
    requests:
      cpu: 200m
      memory: 512Mi
    limits:
      cpu: 4000m
      memory: 8Gi
  nodeSelector:
    kubernetes.io/arch: arm64
```

> Verify the Zot Helm chart's exact field name for existing PVC — it may be `pvc.existingClaim` or
> similar. Check with: `helm show values zot --repo https://zotregistry.dev/helm-charts --version 0.1.98`

### 3. Update `arcRunnersArm` DinD args (parma runners → in-cluster)

In `values-arm64.yaml`, override the DinD mirror to use the in-cluster Zot service:

```yaml
arcRunnersArm:
  template:
    spec:
      containers:
        - name: dind
          args:
            - dockerd
            - --host=unix:///var/run/docker.sock
            - --group=1001
            - --registry-mirror=http://theia-arc-systems-zot.arc-systems.svc.cluster.local:5000
            - --insecure-registry=theia-arc-systems-zot.arc-systems.svc.cluster.local:5000
```

### 4. Secret: `zot-dockerhub-credentials`

The DockerHub credentials secret must exist in `arc-systems` on parma before deploying:

```bash
kubectl --context=parma create secret generic zot-dockerhub-credentials \
  --namespace=arc-systems \
  --from-literal=credentials.json='{
    "credentialsFile": {
      "https://registry-1.docker.io": {
        "username": "<DOCKERHUB_USER>",
        "password": "<DOCKERHUB_TOKEN>"
      }
    }
  }'
```

> On theia-prod, this secret already exists. Copy its content:
> ```bash
> kubectl --context=theia-prod get secret zot-dockerhub-credentials \
>   -n arc-systems -o json | \
>   jq '.metadata = {"name": .metadata.name, "namespace": .metadata.namespace}' | \
>   kubectl --context=parma apply -f -
> ```

---

## Data Migration (Optional)

Migrating the existing 100 Gi Zot cache from theia-prod to parma eliminates the warm-up period
where runners re-pull everything from Docker Hub. This is optional but recommended.

```bash
# 1. Scale down Zot on theia-prod (read-only source)
kubectl --context=theia-prod scale statefulset -n arc-systems \
  -l app.kubernetes.io/name=zot --replicas=0

# 2. Find the Zot PVC on theia-prod
kubectl --context=theia-prod get pvc -n arc-systems | grep zot
# Note the PVC name: theia-arc-systems-zot (or similar)

# 3. Rsync data from theia-prod Zot PVC to parma ZFS dataset
#    Run a temporary pod on theia-prod that mounts the PVC and streams to parma via SSH/rsync
kubectl --context=theia-prod run zot-migrate --rm -it \
  --image=alpine \
  --overrides='{
    "spec": {
      "containers": [{
        "name": "zot-migrate",
        "image": "alpine",
        "command": ["sh"],
        "volumeMounts": [{"name": "zot-data", "mountPath": "/data"}]
      }],
      "volumes": [{
        "name": "zot-data",
        "persistentVolumeClaim": {"claimName": "theia-arc-systems-zot"}
      }]
    }
  }' -- sh

# Inside the pod: install rsync, then rsync to parma node
apk add rsync openssh
rsync -avz --progress /data/ <parma-node-ip>:/local-zfs/zot/

# 4. Bring Zot back up on theia-prod (or skip if switching over immediately)
kubectl --context=theia-prod scale statefulset -n arc-systems \
  -l app.kubernetes.io/name=zot --replicas=1
```

> Approximate transfer time: 100 Gi at 9 Gbps inter-cluster throughput ≈ ~90 seconds.

---

## Deployment Steps

### Step 1: Prepare parma storage

```bash
# Create ZFS dataset on parma node
kubectl --context=parma run zfs-setup --rm -it --privileged \
  --image=alpine --restart=Never \
  --overrides='{"spec":{"hostPID":true,"hostIPC":true,"volumes":[{"name":"host","hostPath":{"path":"/"}}],"containers":[{"name":"zfs-setup","image":"alpine","command":["chroot","/host"],"volumeMounts":[{"name":"host","mountPath":"/host"}],"securityContext":{"privileged":true}}]}}' \
  -- zfs create local-zfs/zot

# Apply static PV + PVC
kubectl --context=parma apply -f infra/parma/zot-zfs-pv.yaml
kubectl --context=parma apply -f infra/parma/zot-zfs-pvc.yaml
kubectl --context=parma get pv zot-zfs-pv   # must be Bound
```

### Step 2: Copy DockerHub credentials secret to parma

```bash
kubectl --context=theia-prod get secret zot-dockerhub-credentials \
  -n arc-systems -o json | \
  jq 'del(.metadata.resourceVersion, .metadata.uid, .metadata.creationTimestamp, .metadata.annotations, .metadata.ownerReferences)' | \
  kubectl --context=parma apply -f -
```

### Step 3: Deploy Zot on parma (Part 1)

```bash
kubectl config use-context parma
cd helm-chart/theia-arc-bundle

helm upgrade --install theia-arc-systems . \
  --namespace arc-systems --create-namespace \
  -f values-arm64.yaml \
  --set arcRunnersArm.enabled=false \
  --wait --timeout 5m
```

**Verify Zot is running on parma:**
```bash
kubectl --context=parma get pods -n arc-systems | grep zot
kubectl --context=parma logs -n arc-systems -l app.kubernetes.io/name=zot --tail=20
# Should show: "sync: enabling on-demand sync for https://registry-1.docker.io"

kubectl --context=parma get svc -n arc-systems | grep zot
# Expected: theia-arc-systems-zot   NodePort   ...   5000:30081/TCP
```

**Verify the ZFS mount is working:**
```bash
kubectl --context=parma exec -n arc-systems \
  -l app.kubernetes.io/name=zot -- df -h /var/lib/registry
# Should show /local-zfs/zot mounted, ~500 Gi available
```

### Step 4: Optional — migrate Zot data from theia-prod

See [Data Migration](#data-migration-optional) section above.

### Step 5: Disable Zot on theia-prod (Part 1)

```bash
kubectl config use-context theia-prod
cd helm-chart/theia-arc-bundle

helm upgrade --install theia-arc-systems . \
  --namespace arc-systems --create-namespace \
  --set arcRunners.enabled=false \
  --set arcRunnersArm.enabled=false \
  --set zot.enabled=false \
  --wait --timeout 5m
```

> At this point, Zot is no longer running on theia-prod. Runners must not be updated until parma's
> Zot is confirmed healthy (Step 3 + 4 verification).

### Step 6: Update runners on theia-prod to use parma's Zot (Part 2)

```bash
kubectl config use-context theia-prod
helm upgrade --install theia-arc-runners . \
  --namespace arc-runners \
  --set cacheServer.enabled=false \
  --set arcController.enabled=false \
  --set zot.enabled=false \
  --set arcRunners.enabled=true \
  --wait --timeout 2m
```

### Step 7: Update runners on parma to use local Zot (Part 2)

```bash
kubectl config use-context parma
helm upgrade --install theia-arc-runners . \
  --namespace arc-runners \
  -f values-arm64.yaml \
  --set cacheServer.enabled=false \
  --set arcController.enabled=false \
  --set zot.enabled=false \
  --set arcRunnersArm.enabled=true \
  --wait --timeout 2m
```

### Step 8: Verify end-to-end

**From theia-prod runner (cross-cluster pull):**
```bash
# Check a runner pod's DinD args point to parma's NodePort
kubectl --context=theia-prod get pod -n arc-runners <runner-pod> \
  -o jsonpath='{.spec.containers[?(@.name=="dind")].args}'

# Test reachability from theia-prod
kubectl --context=theia-prod run -it --rm debug --image=alpine --restart=Never -- \
  wget -qO- http://<parma-node-ip>:30081/v2/
# Expected: {}
```

**From parma runner (in-cluster pull):**
```bash
kubectl --context=parma run -it --rm debug --image=alpine --restart=Never -- \
  wget -qO- http://theia-arc-systems-zot.arc-systems.svc.cluster.local:5000/v2/
# Expected: {}
```

**Trigger a real GitHub Actions workflow and verify cache hit:**
```bash
kubectl --context=parma logs -n arc-systems -l app.kubernetes.io/name=zot -f
# First pull: "sync: on-demand sync for image library/alpine"
# Second pull: served directly from cache (no sync log)
```

### Step 9: Clean up Zot PVC on theia-prod

After verifying everything works, release the 100 Gi Ceph RBD PVC:

```bash
kubectl --context=theia-prod get pvc -n arc-systems | grep zot
kubectl --context=theia-prod delete pvc -n arc-systems theia-arc-systems-zot
# Releases 100 Gi from Ceph — frees Ceph quota for other workloads
```

---

## Files to Change

| File | Change |
|------|--------|
| `values.yaml` | `zot: enabled: false`; update `arcRunners` DinD args to parma NodePort |
| `values-arm64.yaml` | `zot: enabled: true` with full Zot config, ARM64 nodeSelector, ZFS PVC |
| `infra/parma/zot-zfs-pv.yaml` | **New** — static PV backed by `/local-zfs/zot` |
| `infra/parma/zot-zfs-pvc.yaml` | **New** — static PVC referencing above PV |
| `docs/ARCHITECTURE_V2.md` | Update storage table, network flow diagram |
| `README.md` | Update Zot Mirror column (both clusters now point to parma) |

---

## Risks and Mitigations

| Risk | Impact | Mitigation |
|------|--------|------------|
| Zot Helm chart doesn't support `existingClaim` | Helm creates its own PVC on wrong storage | Check chart's `pvc` fields beforehand; fallback: pre-create PVC with same name Helm would generate |
| theia-prod runners can't reach parma NodePort 30081 | Runners fall back to Docker Hub (rate limited) | Test with `wget` from theia-prod pod before Step 6 |
| ZFS dataset not mounted correctly | Zot pod CrashLoopBackOff | Verify `/local-zfs/zot` exists on parma node before applying PV |
| Credentials secret missing on parma | Zot fails to authenticate to DockerHub | Copy secret (Step 2) before Helm deploy (Step 3) |
| Warm-up period after migration | Slower first pulls until cache fills | Optional: run data migration step to pre-populate cache |

## Rollback Plan

1. Re-enable Zot on theia-prod: `helm upgrade theia-arc-systems . --set arcRunners.enabled=false ... ` (without `zot.enabled=false`)
2. Repoint DinD args back to `131.159.88.30:30081` (in-cluster on theia-prod)
3. Disable Zot on parma: `helm upgrade theia-arc-systems . -f values-arm64.yaml --set zot.enabled=false ...`
4. Zot PVC on theia-prod is **Retain** policy — data is preserved unless manually deleted
