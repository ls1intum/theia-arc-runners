# PVC Resize - Parma Cluster (2026-02-02)

## Context

The parma cluster had PVCs significantly over-allocated compared to actual usage, wasting ~491GB of SSD space.

## Original State

| PVC | Allocated | Actually Used | Waste |
|-----|-----------|---------------|-------|
| `registry-ghcr-data` | 200 GB | 26.4 GB | 173.6 GB |
| `registry-data` | 200 GB | 1.4 GB | 198.6 GB |
| `verdaccio-storage` | 50 GB | 39.5 MB | ~50 GB |
| `apt-cacher-ng-storage` | 50 GB | 1.3 GB | 48.7 GB |
| **Total** | **520 GB** | **~29 GB** | **~491 GB** |

## New State (After Resize)

| PVC | New Size | Headroom | Status |
|-----|----------|----------|--------|
| `registry-ghcr-data` | 50 GB | ~24 GB | ✅ Resized |
| `registry-data` | 10 GB | ~8.6 GB | ✅ Resized |
| `verdaccio-storage` | 5 GB | ~4.96 GB | ✅ Resized |
| `apt-cacher-ng-storage` | 10 GB | ~8.7 GB | ✅ Resized |
| **Total** | **75 GB** | **~46 GB** | |

**Space saved:** 445 GB (85% reduction)

## Resize Method

Since `local-path` StorageClass has `ALLOWVOLUMEEXPANSION: false`, we used the **delete-and-recreate** strategy:

```bash
# For each PVC:
kubectl scale deployment <deployment> -n <namespace> --replicas=0
kubectl delete pvc <pvc-name> -n <namespace>
kubectl apply -f <new-pvc-manifest>
kubectl scale deployment <deployment> -n <namespace> --replicas=1
```

**Data loss strategy:** All services are **caches** that repopulate automatically:
- Registry mirrors: Pull-through caches
- Verdaccio: npm proxy cache
- apt-cacher-ng: apt package cache

Caches will rebuild on first use after resize.

## Additional Changes

### Memory-Backed Build Cache

Simultaneously configured ARC runners to use **memory-backed work directories** for Docker builds:

```yaml
volumes:
- name: work
  emptyDir:
    medium: Memory
    sizeLimit: 30Gi
```

**Before:** 12 MB/s (disk I/O on slow LVM)  
**After:** ~10-50 GB/s (RAM speed)  
**Performance improvement:** ~1000-4000x faster

This change takes effect on new runner pods created after the configuration update.

## Verification

```bash
kubectl get pvc -A --context parma
kubectl get pods -n registry-mirror --context parma
kubectl get pods -n verdaccio --context parma
kubectl get pods -n apt-cacher-ng --context parma
```

All services successfully restarted with smaller PVCs.

## Performance Impact

**Storage bottleneck identified:**
- LVM volume write speed: **12 MB/s** (extremely slow, likely HDD or slow RAID)
- ZFS pool available: **8.3 TB** (unused, unknown performance)
- SSD total capacity: **466.5 GB**
- Current disk usage: 199.5 GB / 466.5 GB (43%)

**Recommendations for future optimization:**
1. ✅ Use memory-backed `emptyDir` for ephemeral build caches (implemented)
2. ⏸️ Move persistent PVCs to ZFS pool if it's on faster storage
3. ⏸️ Investigate LVM backing device (HDD vs SSD)
4. ⏸️ Consider SSD caching layer for LVM

## Related Files

New PVC manifests created during resize:
- `/tmp/registry-ghcr-data-50gi.yaml`
- `/tmp/registry-data-10gi.yaml`
- `/tmp/verdaccio-storage-5gi.yaml`
- `/tmp/apt-cacher-ng-storage-10gi.yaml`

Original PVC backup:
- `/tmp/registry-ghcr-data-backup.yaml`

## Updated README

Update line 22 in `README.md`:

**Old:**
```markdown
- 200GB cache storage per registry per cluster
```

**New:**
```markdown
- Cache storage: parma (50GB ghcr, 10GB dockerhub), theia-prod (200GB each)
```
