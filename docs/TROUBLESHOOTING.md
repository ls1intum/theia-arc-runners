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
kubectl get pods -n zot-system | grep zot

# 2. Confirm dind is using the registry mirror
kubectl get pod -n arc-runners <runner-pod> \
  -o jsonpath='{.spec.containers[?(@.name=="dind")].args}'
# Expected: [..., "--registry-mirror=http://131.159.88.117:30081", ...]

# 3. Check Zot logs for sync activity
kubectl logs -n zot-system -l app.kubernetes.io/name=zot --tail=50
# Look for: "sync: on-demand sync for image library/alpine"
```

If Zot is down, runners will fall back to direct Docker Hub pulls (and hit rate limits). Fix Zot first, then recreate runner pods.

### Image pull errors on parma (ARM64)

Both clusters reach Zot on parma via NodePort `131.159.88.117:30081`. If that endpoint is unreachable, runners will hit Docker Hub directly.

```bash
# From a parma pod, test Zot reachability
kubectl run -it --rm debug --image=alpine --restart=Never --context=parma -- \
  wget -qO- http://131.159.88.117:30081/v2/
# Expected: {} (empty JSON — Zot v2 API root)
```

### Digest mismatch errors (OCI vs Docker v2)

If `docker pull image@sha256:...` fails from the cache, Zot may be returning an OCI manifest where Docker expects Docker v2 schema.

```bash
# Check Zot logs for conversion errors
kubectl logs -n zot-system -l app.kubernetes.io/name=zot --tail=100 | grep -i digest
```

The Zot config sets `preserveDigest: false` to allow manifest conversion. If errors persist, verify the config is applied:

```bash
kubectl exec -n zot-system statefulset/theia-zot -- cat /etc/zot/config.json | grep preserveDigest
```

---

## Runner lifecycle issues

### Runners don't pick up GitHub Actions jobs

```bash
# Check listener is running
kubectl get pods -n arc-systems | grep listener

# Check controller logs
kubectl logs -n arc-systems -l app.kubernetes.io/name=gha-runner-scale-set-controller --tail=50

# Verify both org secrets exist and have required keys
kubectl get secret github-arc-secret-eduidec -n arc-runners -o jsonpath='{.data}' | jq 'keys'
kubectl get secret github-arc-secret-ls1intum -n arc-runners -o jsonpath='{.data}' | jq 'keys'
```

### Runner set remains Pending after creating a missing GitHub App secret

If an organization secret is created after the Helm release was already installed, the existing `AutoscalingRunnerSet` may stay in `Pending` until ARC reconciles it again.

First rerun the normal README `helm upgrade --install` command for that cluster. If the runner set still does not reconcile, restart only the controller pod so it reloads the existing resources:

```bash
kubectl delete pod -n arc-systems -l app.kubernetes.io/name=gha-rs-controller
kubectl rollout status deploy/theia-arc-systems-gha-rs-controller -n arc-systems --timeout=3m
```

Healthy logs show ARC creating or reusing the runner scale set, adding the scale set ID annotation, creating an `AutoscalingListener`, and creating `EphemeralRunner` resources.

If a listener repeatedly starts and exits with a message like `ephemeralrunnersets.actions.github.com "<name>" not found`, it likely kept a stale listener config for an `EphemeralRunnerSet` that ARC already cleaned up. Delete only that `AutoscalingListener`; ARC recreates it from the current runner set:

```bash
kubectl delete autoscalinglistener -n arc-systems <listener-name>
```

Then verify:

```bash
kubectl get autoscalingrunnersets,autoscalinglisteners,ephemeralrunnersets -A
kubectl get pods -n arc-systems
kubectl get pods -n arc-runners
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

### `helm upgrade` fails in `theia-zot` with startup crash

If the Zot pod is stuck in `ContainerCreating` and events show `secret "zot-dockerhub-credentials" not found`, create the Docker Hub credentials secret before re-running Helm:

```bash
kubectl --context parma create namespace zot-system --dry-run=client -o yaml | kubectl --context parma apply -f -

export DOCKERHUB_USERNAME="<dockerhub-username>"
export DOCKERHUB_PAT="<dockerhub-personal-access-token>"
ZOT_CREDS="$(mktemp)"
trap 'rm -f "${ZOT_CREDS}"' EXIT
cat > "${ZOT_CREDS}" <<EOF
{
  "registry-1.docker.io": {
    "username": "${DOCKERHUB_USERNAME}",
    "password": "${DOCKERHUB_PAT}"
  },
  "docker.io": {
    "username": "${DOCKERHUB_USERNAME}",
    "password": "${DOCKERHUB_PAT}"
  }
}
EOF
kubectl --context parma create secret generic zot-dockerhub-credentials \
  --namespace=zot-system \
  --from-file=credentials.json="${ZOT_CREDS}" \
  --dry-run=client -o yaml | kubectl --context parma apply -f -
```

If Zot fails with `failed to create a new hot reloader` / `too many open files`, increase node inotify limits on the parma node and restart Zot:

```bash
kubectl --context parma debug node/arm-altra-23-parma --image=busybox -- \
  chroot /host sh -c 'sysctl -w fs.inotify.max_user_instances=1024; sysctl -w fs.inotify.max_user_watches=1048576; sysctl -w fs.inotify.max_queued_events=32768'

kubectl --context parma delete pod -n zot-system theia-zot-0
```

---

## General debugging commands

```bash
# All system components
kubectl get pods -n arc-systems

# Runner scale sets and active runner pods
kubectl get autoscalingrunnersets -n arc-runners
kubectl get pods -n arc-runners

# PVCs (Zot + BuildKit)
kubectl get pvc -n zot-system
kubectl get pvc -n buildkit   # theia-prod
kubectl get pvc -n buildkit       # parma

# Controller logs
kubectl logs -n arc-systems -l app.kubernetes.io/name=gha-runner-scale-set-controller --tail=100

# Runner logs (while job is running)
kubectl logs -n arc-runners <runner-pod> -c runner --follow

# DinD logs (for Docker daemon errors)
kubectl logs -n arc-runners <runner-pod> -c dind

# Zot cache activity
kubectl logs -n zot-system -l app.kubernetes.io/name=zot --tail=100

# Zot PVC usage
kubectl exec -n zot-system -l app.kubernetes.io/name=zot -- df -h /var/lib/registry
```
