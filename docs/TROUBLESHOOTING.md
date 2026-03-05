# Troubleshooting ARC Runners

Common issues and solutions for the self-hosted runner infrastructure.

## Docker daemon issues

### "Cannot connect to the Docker daemon at unix:///var/run/docker.sock"

**Symptom:** Workflow fails immediately with a Docker connection error.  
**Cause:** The runner container started before the DinD sidecar was ready.

The runner template already includes a wait loop that polls for the daemon. If this still occurs:

```bash
# Check dind container status
kubectl get pod -n arc-runners <runner-pod> -o jsonpath='{.status.containerStatuses[*].name}'
kubectl logs -n arc-runners <runner-pod> -c dind --previous
```

### "Runner not finding docker.sock"

**Cause:** `DOCKER_HOST` is wrong or the `dind-sock` volume isn't mounted.

Verify both containers share the volume:

```bash
kubectl get pod -n arc-runners <runner-pod> -o jsonpath='{.spec.volumes}'
```

Both `dind` and `runner` containers must mount `dind-sock` to `/var/run`.

---

## Registry / pull failures

### Docker Hub rate limit errors (429 / "toomanyrequests")

Zot is the pull-through cache for Docker Hub. If runners still hit rate limits:

```bash
# 1. Confirm Zot pod is Running
kubectl get pods -n arc-systems | grep zot

# 2. Confirm dind is using the registry mirror
kubectl get pod -n arc-runners <runner-pod> \
  -o jsonpath='{.spec.containers[?(@.name=="dind")].args}'
# Expected: [..., "--registry-mirror=http://theia-arc-systems-zot.arc-systems.svc.cluster.local:5000", ...]

# 3. Check Zot logs for sync activity
kubectl logs -n arc-systems -l app.kubernetes.io/name=zot --tail=50
# Look for: "sync: on-demand sync for image library/alpine"
```

If Zot is down, runners will fall back to direct Docker Hub pulls (and hit rate limits). Fix Zot first, then recreate runner pods.

### Image pull errors on parma (ARM64)

Parma reaches Zot on theia-prod via NodePort `131.159.88.30:30081`. If that node is unreachable or Zot is down on theia-prod, ARM64 runners will hit Docker Hub directly.

```bash
# From a parma pod, test Zot reachability
kubectl run -it --rm debug --image=alpine --restart=Never --context=parma -- \
  wget -qO- http://131.159.88.30:30081/v2/
# Expected: {} (empty JSON — Zot v2 API root)
```

### Digest mismatch errors (OCI vs Docker v2)

If `docker pull image@sha256:...` fails from the cache, Zot may be returning an OCI manifest where Docker expects Docker v2 schema.

```bash
# Check Zot logs for conversion errors
kubectl logs -n arc-systems -l app.kubernetes.io/name=zot --tail=100 | grep -i digest
```

The Zot config sets `preserveDigest: false` to allow manifest conversion. If errors persist, verify the config is applied:

```bash
kubectl exec -n arc-systems deploy/theia-arc-systems-zot -- cat /etc/zot/config.json | grep preserveDigest
```

---

## Runner lifecycle issues

### Runners don't pick up GitHub Actions jobs

```bash
# Check listener is running
kubectl get pods -n arc-systems | grep listener

# Check controller logs
kubectl logs -n arc-systems -l app.kubernetes.io/name=gha-runner-scale-set-controller --tail=50

# Verify secret exists and has required keys
kubectl get secret github-arc-secret -n arc-runners -o jsonpath='{.data}' | jq 'keys'
```

### Runner pods not starting (stuck Pending)

```bash
# Check events for scheduling failures
kubectl describe pod -n arc-runners <runner-pod>

# Check node selector — runners require arch label
kubectl get nodes --show-labels | grep kubernetes.io/arch
```

### Runners stuck terminating after `helm uninstall`

The controller was deleted before runners finished deregistering from GitHub. Strip finalizers manually:

```bash
kubectl get ephemeralrunners -n arc-runners -o name | \
  xargs -I{} kubectl patch {} -n arc-runners \
  --type=json -p='[{"op":"remove","path":"/metadata/finalizers"}]'

kubectl get autoscalingrunnersets -n arc-runners -o name | \
  xargs -I{} kubectl patch {} -n arc-runners \
  --type=json -p='[{"op":"remove","path":"/metadata/finalizers"}]'
```

---

## Helm issues

### `helm install` fails with "invalid ownership metadata"

The `arc-runners` namespace was created without Helm ownership labels. Add them so Helm can adopt it:

```bash
kubectl label namespace arc-runners app.kubernetes.io/managed-by=Helm
kubectl annotate namespace arc-runners \
  meta.helm.sh/release-name=theia-arc-runners \
  meta.helm.sh/release-namespace=arc-runners
```

Then re-run the `helm install` / `helm upgrade` command.

### `helm upgrade` fails with "port already allocated" (Zot NodePort conflict)

Part 2 (`theia-arc-runners`) was run without `--set zot.enabled=false`. Zot is owned by Part 1 (`theia-arc-systems` in `arc-systems`); when Part 2 also tries to create the Zot NodePort service in `arc-runners`, Kubernetes rejects it.

Always pass `--set zot.enabled=false` for Part 2 upgrades:

```bash
helm upgrade theia-arc-runners . \
  --namespace arc-runners \
  --set cacheServer.enabled=false \
  --set arcController.enabled=false \
  --set zot.enabled=false \
  --set arcRunners.enabled=true \
  --wait --timeout 2m
```

---

## Cache server issues

### `actions/cache` not working / cache misses every run

```bash
# Verify cache server pod and service
kubectl get pods -n arc-systems -l app.kubernetes.io/name=github-actions-cache-server
kubectl get svc -n arc-systems github-actions-cache-server

# Check runner env vars point to cache server
kubectl get pod -n arc-runners <runner-pod> \
  -o jsonpath='{.spec.containers[?(@.name=="runner")].env}' | jq '.[] | select(.name | startswith("ACTIONS"))'
```

### Cache data growing too large

```bash
# Current PVC usage
kubectl exec -n arc-systems deploy/github-actions-cache-server -- df -h /data

# Shorten cleanup window (default 90 days)
helm upgrade theia-arc-systems . \
  --namespace arc-systems \
  --set cacheServer.config.cacheCleanupOlderThanDays=30 \
  --reuse-values

# Or expand the PVC (requires StorageClass that supports expansion)
kubectl edit pvc github-actions-cache-server -n arc-systems
```

---

## General debugging commands

```bash
# All system components
kubectl get pods -n arc-systems

# Runner scale sets and active runner pods
kubectl get autoscalingrunnersets -n arc-runners
kubectl get pods -n arc-runners

# PVCs (cache server + Zot)
kubectl get pvc -n arc-systems

# Controller logs
kubectl logs -n arc-systems -l app.kubernetes.io/name=gha-runner-scale-set-controller --tail=100

# Runner logs (while job is running)
kubectl logs -n arc-runners <runner-pod> -c runner --follow

# DinD logs (for Docker daemon errors)
kubectl logs -n arc-runners <runner-pod> -c dind

# Zot cache activity
kubectl logs -n arc-systems -l app.kubernetes.io/name=zot --tail=100

# Zot PVC usage
kubectl exec -n arc-systems -l app.kubernetes.io/name=zot -- df -h /var/lib/registry
```
