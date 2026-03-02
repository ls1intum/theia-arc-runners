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

Harbor is the pull-through cache for Docker Hub. If runners still hit rate limits:

```bash
# 1. Confirm Harbor pods are Running
kubectl get pods -n arc-systems | grep harbor

# 2. Confirm dind is using the registry mirror
kubectl get pod -n arc-runners <runner-pod> \
  -o jsonpath='{.spec.containers[?(@.name=="dind")].args}'
# Expected: [..., "--registry-mirror=http://harbor.arc-systems.svc.cluster.local:80", ...]

# 3. Check Harbor proxy project exists
kubectl logs -n arc-systems -l job-name=harbor-proxy-setup
```

If Harbor pods are down, runners will fall back to direct Docker Hub pulls (and hit rate limits). Fix Harbor first, then recreate runner pods.

### Image pull errors on parma (ARM64)

Parma reaches Harbor on theia-prod via NodePort `131.159.88.30:30080`. If that node is unreachable or Harbor is down on theia-prod, ARM64 runners will hit Docker Hub directly.

```bash
# From a parma pod, test Harbor reachability
kubectl run -it --rm debug --image=alpine --restart=Never --context=parma -- \
  wget -qO- http://131.159.88.30:30080/v2/
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

### `helm upgrade` fails with "port already allocated" (Harbor NodePort conflict)

Part 2 (`theia-arc-runners`) was run without `--set harbor.enabled=false`. Harbor is owned by Part 1 (`theia-arc-systems` in `arc-systems`); when Part 2 also tries to create the Harbor NodePort service in `arc-runners`, Kubernetes rejects it.

Always pass `--set harbor.enabled=false` for Part 2 upgrades:

```bash
helm upgrade theia-arc-runners . \
  --namespace arc-runners \
  --set cacheServer.enabled=false \
  --set arcController.enabled=false \
  --set harbor.enabled=false \
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

# PVCs (cache server + Harbor)
kubectl get pvc -n arc-systems

# Controller logs
kubectl logs -n arc-systems -l app.kubernetes.io/name=gha-runner-scale-set-controller --tail=100

# Runner logs (while job is running)
kubectl logs -n arc-runners <runner-pod> -c runner --follow

# DinD logs (for Docker daemon errors)
kubectl logs -n arc-runners <runner-pod> -c dind
```
