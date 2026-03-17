# Plan: Replace Harbor with Zot Registry Pull-Through Cache

**Date:** 2026-03-02
**Status:** Completed (2026-03-17)

---

## Problem

Docker Hub rate limits (100 pulls/6h anonymous, 200 authenticated) are causing pull failures on our self-hosted GitHub Actions runners. Harbor was deployed as a pull-through cache, but **Docker's `--registry-mirror` protocol is architecturally incompatible with Harbor**:

- `--registry-mirror` sends transparent requests to `/v2/library/alpine/...`
- Harbor expects project-prefixed paths: `/v2/dockerhub-proxy/library/alpine/...`
- Harbor returns 404, Docker silently falls back to Docker Hub, **nothing is cached**
- The 5 images in Harbor's cache were from other mechanisms (explicit `dockerhub-proxy/` paths in workflows), not from `--registry-mirror`

### Alternatives Evaluated

| Option | Verdict | Reason |
|--------|---------|--------|
| **Nginx path rewriter in front of Harbor** | Rejected | Docker's token auth flow mints tokens scoped to `library/alpine`; after Nginx rewrites to `dockerhub-proxy/library/alpine`, Harbor rejects the token (scope mismatch → 403). Fixing requires intercepting URL-encoded auth parameters in `Www-Authenticate` headers — extremely brittle. |
| **CI workflow image prefixing** | Rejected | Would require modifying every workflow in every repo using these org-wide runners. `FROM alpine` in Dockerfiles can't be transparently rewritten. Impractical for `ls1intum`'s hundreds of repositories. |
| **Spegel (P2P node mirror)** | Rejected | Only shares images already on a node — doesn't solve the first-pull rate limit. Designed for host containerd, not DinD sidecars. Stateless = no persistent cache. |
| **Docker Registry v2 (`registry:2`)** | Rejected | Known filesystem locking bugs and memory leaks under heavy concurrent pulls (~50 runners). |
| **Zot Registry** | ✅ Selected | CNCF Sandbox project. Supports `--registry-mirror` transparent proxy natively. Lock-free blob storage handles concurrent pulls well. Single Go binary, ~25MB. Built-in GC. Official Helm chart available. |

---

## Solution: Deploy Zot, Remove Harbor

Replace Harbor entirely with Zot as the sole pull-through cache for Docker Hub.

- **GHCR caching is dropped.** GHCR has no rate limits comparable to Docker Hub's, so this is an acceptable tradeoff. Workflows pulling from `ghcr.io` will go direct.
- **One registry cache** instead of a multi-component Harbor deployment (core, portal, registry, redis, database, jobservice).

### Architecture After Migration

```
GitHub Actions Job
  │
  ▼
Runner Pod (arc-runners)
  │  docker pull alpine
  ▼
DinD sidecar
  │  --registry-mirror=http://zot:5000
  ▼
Zot (arc-systems)                     ← NEW: single Go binary + PVC
  ├── cache HIT  → serve from PVC
  └── cache MISS → fetch from registry-1.docker.io, cache, serve
```

**Cross-cluster access (parma → theia-prod):**
```
parma runner pod
  │  --registry-mirror=http://131.159.88.30:30081
  ▼
NodePort 30081 on theia-prod node
  │
  ▼
Zot pod in arc-systems (theia-prod)
```

---

## Zot Chart Details

| Field | Value |
|-------|-------|
| Helm repo | `https://zotregistry.dev/helm-charts` |
| Chart name | `zot` |
| Chart version | `0.1.98` |
| App version | Zot v2.1.x |
| Config mechanism | `mountConfig: true` + `configFiles."config.json"` |
| Default port | `5000` |

---

## Implementation Plan

### Step 1: Update `Chart.yaml` — Remove Harbor, Add Zot

**Remove:**
```yaml
  - name: harbor
    version: "1.18.2"
    repository: "https://helm.goharbor.io"
    alias: harbor
    condition: harbor.enabled
```

**Add:**
```yaml
  - name: zot
    version: "0.1.98"
    repository: "https://zotregistry.dev/helm-charts"
    alias: zot
    condition: zot.enabled
```

### Step 2: Update `values.yaml` — Replace Harbor config with Zot config

**Remove:** The entire `harbor:` block (lines 210–259).

**Add:** New `zot:` block:
```yaml
# Zot pull-through cache for Docker Hub.
# Deployed in arc-systems on theia-prod only.
# theia-prod runners: http://theia-arc-systems-zot.arc-systems.svc.cluster.local:5000
# parma runners:      http://131.159.88.30:30081 (NodePort on theia-prod node)
zot:
  enabled: true
  mountConfig: true
  configFiles:
    config.json: |-
      {
        "distSpecVersion": "1.1.0",
        "storage": {
          "rootDirectory": "/var/lib/registry",
          "gc": true,
          "gcDelay": "1h",
          "gcInterval": "6h",
          "retention": {
            "policies": [
              {
                "repositories": ["**"],
                "keepTags": [
                  {
                    "mostRecentlyPulledCount": 100,
                    "pulledWithin": "720h"
                  }
                ]
              }
            ]
          }
        },
        "http": {
          "address": "0.0.0.0",
          "port": "5000"
        },
        "log": {
          "level": "info"
        },
        "extensions": {
          "sync": {
            "enable": true,
            "registries": [
              {
                "urls": ["https://index.docker.io"],
                "onDemand": true,
                "tlsVerify": true,
                "maxRetries": 3,
                "retryDelay": "5m",
                "content": [
                  {
                    "prefix": "**"
                  }
                ]
              }
            ]
          }
        }
      }
  persistence: true
  pvc:
    create: true
    storage: 100Gi
    storageClassName: "csi-rbd-sc"
    accessModes:
      - ReadWriteOnce
  service:
    type: NodePort
    port: 5000
    nodePort: 30081
  resources:
    requests:
      cpu: 200m
      memory: 512Mi
    limits:
      cpu: 2000m
      memory: 4Gi
  nodeSelector:
    kubernetes.io/arch: amd64
```

**Update DinD args for `arcRunners` (AMD64):**
```yaml
# OLD:
- --registry-mirror=http://harbor.arc-systems.svc.cluster.local:80
- --insecure-registry=harbor.arc-systems.svc.cluster.local:80

# NEW:
- --registry-mirror=http://theia-arc-systems-zot.arc-systems.svc.cluster.local:5000
- --insecure-registry=theia-arc-systems-zot.arc-systems.svc.cluster.local:5000
```

**Update DinD args for `arcRunnersArm` (ARM64):**
```yaml
# OLD:
- --registry-mirror=http://131.159.88.30:30080
- --insecure-registry=131.159.88.30:30080

# NEW:
- --registry-mirror=http://131.159.88.30:30081
- --insecure-registry=131.159.88.30:30081
```

**Update comments** throughout values.yaml to reference Zot instead of Harbor.

### Step 3: Update `values-arm64.yaml` — Replace Harbor override with Zot override

**Remove:**
```yaml
harbor:
  enabled: false
```

**Add:**
```yaml
zot:
  enabled: false
```

### Step 4: Delete Harbor-specific files

| File | Action |
|------|--------|
| `helm-chart/theia-arc-bundle/templates/harbor-proxy-setup.yaml` | **Delete** — Harbor post-install hook Job |
| `helm-chart/theia-arc-bundle/charts/harbor-1.18.2.tgz` | **Delete** — packaged Harbor subchart |
| `helm-chart/theia-arc-bundle/Chart.lock` | **Regenerate** — run `helm dependency update` |

### Step 5: Run `helm dependency update` + `helm lint`

```bash
cd helm-chart/theia-arc-bundle
helm dependency update .
helm lint .
helm template . | head -100   # Sanity check rendered output
```

This downloads the Zot chart `.tgz` into `charts/` and regenerates `Chart.lock`.

### Step 6: Commit changes

Single commit with all chart changes before deploying.

### Step 7: Deploy to theia-prod

**Part 1 — Deploy Zot + remove Harbor:**
```bash
kubectl config use-context theia-prod
cd helm-chart/theia-arc-bundle

helm upgrade --install theia-arc-systems . \
  --namespace arc-systems --create-namespace \
  --set arcRunners.enabled=false \
  --set arcRunnersArm.enabled=false \
  --wait --timeout 5m
```

> Timeout increased to 5m because Helm needs to tear down Harbor (6 pods) and spin up Zot.

**Verify Zot is running:**
```bash
kubectl get pods -n arc-systems | grep zot
kubectl logs -n arc-systems -l app.kubernetes.io/name=zot --tail=20
# Should show: "sync: enabling on-demand sync for https://index.docker.io"
```

**Verify NodePort is exposed:**
```bash
kubectl get svc -n arc-systems | grep zot
# Expected: theia-arc-systems-zot   NodePort   ...   5000:30081/TCP
```

**Part 2 — Update runner DinD args:**
```bash
helm upgrade --install theia-arc-runners . \
  --namespace arc-runners \
  --set cacheServer.enabled=false \
  --set arcController.enabled=false \
  --set zot.enabled=false \
  --set arcRunners.enabled=true \
  --wait --timeout 2m
```

> Note: Part 2 now passes `--set zot.enabled=false` instead of `--set harbor.enabled=false`.

### Step 8: Deploy to parma

**Part 2 only — update runner DinD args:**
```bash
kubectl config use-context parma
cd helm-chart/theia-arc-bundle

helm upgrade --install theia-arc-runners . \
  --namespace arc-runners \
  -f values-arm64.yaml \
  --set cacheServer.enabled=false \
  --set arcController.enabled=false \
  --set zot.enabled=false \
  --set arcRunnersArm.enabled=true \
  --wait --timeout 2m
```

> Part 1 on parma does NOT need upgrading — parma never had Harbor, and parma doesn't deploy its own Zot. Parma runners reach theia-prod's Zot via NodePort.

### Step 9: Verify caching works

**Test from theia-prod runner:**
```bash
# Find a running runner pod
kubectl --context=theia-prod get pods -n arc-runners | head -5

# Check DinD args include Zot mirror
kubectl --context=theia-prod get pod -n arc-runners <runner-pod> \
  -o jsonpath='{.spec.containers[?(@.name=="dind")].args}'

# Check Zot logs for sync activity after a docker pull happens
kubectl --context=theia-prod logs -n arc-systems -l app.kubernetes.io/name=zot --tail=50
# Look for: "sync: on-demand sync for image library/alpine"
```

**Test from parma (cross-cluster):**
```bash
# Test Zot reachability from a parma pod
kubectl --context=parma run -it --rm debug --image=alpine --restart=Never -- \
  wget -qO- http://131.159.88.30:30081/v2/
# Expected: {} (empty JSON — Zot v2 API root)
```

**Trigger a real workflow and verify:**
1. Run a GitHub Actions job that does `docker pull alpine` on a self-hosted runner
2. Watch Zot logs: `kubectl logs -n arc-systems -l app.kubernetes.io/name=zot -f`
3. Confirm log shows sync from Docker Hub on first pull, then cache hit on second pull
4. Verify the runner doesn't hit Docker Hub rate limits

### Step 10: Clean up Harbor PVCs (manual)

After verifying everything works, delete leftover Harbor PVCs:

```bash
kubectl --context=theia-prod get pvc -n arc-systems | grep harbor
kubectl --context=theia-prod delete pvc -n arc-systems \
  data-theia-arc-systems-harbor-database-0 \
  data-theia-arc-systems-harbor-redis-0 \
  theia-arc-systems-harbor-jobservice \
  theia-arc-systems-harbor-registry
```

> The exact PVC names depend on the Harbor release. List them first with `kubectl get pvc`.

### Step 11: Update documentation

All documentation references to Harbor need to be rewritten for Zot:

| File | Changes needed |
|------|----------------|
| `AGENTS.md` | Replace Harbor references with Zot. Remove `--set harbor.enabled=false` from deploy commands, add `--set zot.enabled=false`. Update architecture section. Remove `harbor-proxy-setup.yaml` from repo structure. |
| `README.md` | Replace "Harbor pull-through proxy cache" with "Zot pull-through cache". Update component descriptions, DinD args, URLs, NodePorts. Remove Harbor proxy projects table. |
| `helm-chart/theia-arc-bundle/README.md` | Replace Harbor sections with Zot. Update configuration table, troubleshooting, dependencies. |
| `docs/ARCHITECTURE_V2.md` | Full rewrite — replace Harbor architecture with Zot. Update network flow diagram, storage table, namespace contents. |
| `docs/TROUBLESHOOTING.md` | Replace Harbor troubleshooting with Zot troubleshooting. Update rate-limit debugging steps. Remove "port already allocated" section (no longer applicable). |

---

## What Changes for Deployment Commands

**Before (with Harbor):**
```bash
# Part 2 REQUIRED --set harbor.enabled=false to avoid NodePort conflict
helm upgrade --install theia-arc-runners . \
  --namespace arc-runners \
  --set cacheServer.enabled=false \
  --set arcController.enabled=false \
  --set harbor.enabled=false \        # ← was needed to prevent port conflict
  --set arcRunners.enabled=true
```

**After (with Zot):**
```bash
# Part 2 needs --set zot.enabled=false (same pattern, different flag)
helm upgrade --install theia-arc-runners . \
  --namespace arc-runners \
  --set cacheServer.enabled=false \
  --set arcController.enabled=false \
  --set zot.enabled=false \           # ← Zot is owned by Part 1
  --set arcRunners.enabled=true
```

---

## Risks and Mitigations

| Risk | Impact | Mitigation |
|------|--------|------------|
| Zot service name mismatch | DinD can't reach mirror → silent fallback to Docker Hub | Verify service name with `helm template` before deploying. Check `kubectl get svc -n arc-systems`. |
| Zot digest conversion (OCI vs Docker v2) | `docker pull image@sha256:...` fails from cache | Monitor after deploy. If needed, add `"compat": ["docker2s2"]` to Zot HTTP config. |
| parma can't reach Zot NodePort 30081 | ARM64 runners fall back to direct Docker Hub | Test with `wget` from parma pod before upgrading Part 2 on parma. |
| Harbor PVCs block namespace cleanup | PVCs remain, consume disk | Manual PVC deletion in Step 10. |
| Zot PVC fills up | Cache stops working, runners fall back to Docker Hub | 100Gi + 30-day retention + GC should be sufficient. Monitor with `kubectl exec ... df -h`. |

## Rollback Plan

If Zot doesn't work:
1. Revert the commit (git revert)
2. `helm dependency update` to restore Harbor chart
3. `helm upgrade` Part 1 and Part 2 on both clusters
4. Harbor PVCs may need to be recreated (data lost if already deleted)

---

## Summary of Files Changed

| File | Action |
|------|--------|
| `Chart.yaml` | Remove harbor dependency, add zot dependency |
| `Chart.lock` | Regenerated by `helm dependency update` |
| `values.yaml` | Remove `harbor:` block, add `zot:` block, update DinD args |
| `values-arm64.yaml` | Replace `harbor: enabled: false` with `zot: enabled: false` |
| `templates/harbor-proxy-setup.yaml` | **Delete** |
| `charts/harbor-1.18.2.tgz` | **Delete** (replaced by zot chart) |
| `AGENTS.md` | Update for Zot |
| `README.md` | Update for Zot |
| `helm-chart/theia-arc-bundle/README.md` | Update for Zot |
| `docs/ARCHITECTURE_V2.md` | Full rewrite for Zot |
| `docs/TROUBLESHOOTING.md` | Full rewrite for Zot |
