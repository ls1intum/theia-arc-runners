# Troubleshooting ARC Runners

Common issues and solutions for the self-hosted runner infrastructure.

## 1. "Cannot connect to the Docker daemon at unix:///var/run/docker.sock"

**Symptom**: Workflow fails immediately with Docker connection error.
**Cause**: The runner container started before the Docker-in-Docker (DinD) sidecar was ready.

**Solution**:
Ensure your runner command includes the wait script (already included in our templates):

```bash
echo "Waiting for Docker daemon..."
for i in {1..60}; do
  if docker info >/dev/null 2>&1; then
    break
  fi
  sleep 1
done
```

## 2. "Runner not finding docker.sock"

**Symptom**: `docker: command not found` or socket errors.
**Cause**: `DOCKER_HOST` environment variable is incorrect or volumes aren't mounted.

**Solution**:
- Check `DOCKER_HOST` is set to `unix:///var/run/docker.sock` (NOT `tcp://...`)
- Ensure both containers mount `dind-sock` to `/var/run`

## 3. PVC Stuck in "Pending"

**Symptom**: `kubectl get pvc` shows `Pending`.
**Cause**: Storage class issues or WaitForFirstConsumer binding mode.

**Solution**:
- If using `WaitForFirstConsumer` (default in many clusters), the PVC won't bind until a pod uses it. Trigger a workflow to start a runner pod.
- Check storage class: `kubectl get storageclass`

## 4. "You must be an organization owner"

**Symptom**: Listener pod logs show permission errors.
**Cause**: The GitHub PAT lacks `admin:org` scope or isn't an owner of `ls1intum`.

**Solution**:
- Verify PAT scopes: `repo`, `workflow`, `admin:org`
- Verify user role in the organization

## 5. Slow Builds (Cache Not Working)

**Symptom**: Every build takes full time (cold cache).
**Cause**: 
1. `maxRunners` > 1 (PVC can't be shared)
2. Runners aren't sticky (job landing on wrong runner set)
3. Cache invalidation in Dockerfile

**Solution**:
- Ensure `maxRunners: 1` in `values-runner-set-X.yaml`
- Verify `runs-on: arc-runner-set-X` in workflow matches the intended runner
- Check Dockerfile for early invalidation (e.g., `COPY . .` before `RUN npm install`)

## 6. Runner Pods Not Starting

**Symptom**: Workflow queued but no pods appear in `arc-runners`.
**Cause**: Listener not registered or controller issues.

**Solution**:
- Check controller logs: `kubectl logs -n arc-systems -l app.kubernetes.io/name=gha-runner-scale-set-controller`
- Check listener logs: `kubectl logs -n arc-systems -l app.kubernetes.io/name=arc-runner-set-1-listener` 

## Debugging Commands

```bash
# Check all system components
kubectl get pods -n arc-systems

# Check runner state
kubectl get pods -n arc-runners

# View listener logs (crucial for registration errors)
kubectl logs -n arc-systems -l app.kubernetes.io/name=arc-runner-set-1-listener

# View runner logs (while job is running)
kubectl logs -n arc-runners -l app=arc-runner -c runner

# View DinD logs (for Docker daemon errors)
kubectl logs -n arc-runners -l app=arc-runner -c dind
```
