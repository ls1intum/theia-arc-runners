# Theia ARC Runners

Infrastructure-as-code for deploying **GitHub Actions self-hosted runners** using Actions Runner Controller (ARC).

## Architecture

BuildKit-focused runner sets backed by stateful BuildKit workers and a shared Zot pull-through cache for Docker Hub.

| Cluster | Architecture | Runner Sets | BuildKit Namespace | BuildKit Storage Class | Zot Mirror |
|---------|--------------|-------------|--------------------|------------------------|------------|
| stud | AMD64 | `arc-buildkit-eduide-stud-amd64`, `arc-buildkit-ls1intum-stud-amd64` | `buildkit` | `csi-rbd-sc` | `131.159.88.117:30081` |
| theia-prod | AMD64 | `arc-buildkit-eduide-theiaprod-amd64`, `arc-buildkit-ls1intum-theiaprod-amd64` | `buildkit` | `csi-rbd-sc` | `131.159.88.117:30081` |
| parma | ARM64 | `arc-buildkit-eduide-parma-arm64`, `arc-buildkit-ls1intum-parma-arm64` | `buildkit` | `longhorn` | `131.159.88.117:30081` |

Use `helm-chart/theia-arc-bundle/values.yaml` plus exactly one cluster overlay:

| Cluster | Values overlay |
|---------|----------------|
| stud | `helm-chart/theia-arc-bundle/values-stud.yaml` |
| theia-prod | `helm-chart/theia-arc-bundle/values-theia-prod.yaml` |
| parma | `helm-chart/theia-arc-bundle/values-parma.yaml` |

## Features

- ARC runner sets for EduIDE and ls1intum organization workloads
- Stateful BuildKit workers (currently 7 replicas per cluster, 100Gi per worker)
- BuildKit pods prefer spreading across nodes with soft pod anti-affinity
- Zot pull-through cache for `docker.io` (removes Docker Hub rate-limit pressure)
- Official ARC runner image (`ghcr.io/actions/actions-runner`) and ARC Helm charts
- Memory-backed work volume on parma runners (`emptyDir.medium: Memory`, 30Gi)

## Components

### Zot Registry Cache

Zot is deployed as a standalone release on parma:

- release: `theia-zot`
- namespace: `zot-system`
- storage: Longhorn PVC (100Gi)
- service: NodePort `30081`

Runner DinD containers are configured with:

```text
--registry-mirror=http://131.159.88.117:30081
--insecure-registry=131.159.88.117:30081
```

### Runner + BuildKit Model

Runner pods keep the DinD + runner sidecar layout. Docker builds are routed to remote BuildKit workers using workflow-provided routing logic and runner env:

- `BUILDKIT_NAMESPACE`
- `BUILDKIT_NUM_WORKERS`

BuildKit workers run as separate StatefulSet pods with persistent PVC-backed cache. This keeps runner pods disposable while preserving Docker layer cache, BuildKit cache layers, and BuildKit cache mounts across workflow runs. The current 7-worker count is arbitrary: one worker can handle multiple builds at once, and on multi-node clusters it can be increased when more nodes are available. The workers use soft pod anti-affinity, so they prefer different nodes but may co-locate if needed. On parma, be conservative because it is currently a single-node cluster. For more context, see [ARCHITECTURE_V2.md](docs/ARCHITECTURE_V2.md).

Runner scale sets currently use `minRunners: 10` and `maxRunners: 50`. These are also operational baselines, not hard architecture limits. Larger clusters can raise those values, but runner pod CPU/memory requests and limits should be reviewed at the same time so autoscaling capacity matches real node capacity.

## Deployment

See [AGENTS.md](AGENTS.md) for the canonical commands and safety notes.

### Prerequisites

- `kubectl` configured for target cluster (`stud` / `theia-prod` / `parma`)
- Helm 3.14+
- GitHub App auth secrets in `arc-runners`.
- Rancher projects exist for the target clusters:
  - `stud`: `ARC Runners Stud`
  - `theia-prod`: `ARC Runners theiaprod`
  - `parma`: `ARC Runners parma`

The deploy commands below create the namespaces first:

```bash
kubectl create namespace arc-systems --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace arc-runners --dry-run=client -o yaml | kubectl apply -f -
```

### Rancher project assignment

Assign each runtime namespace to the matching Rancher project after that namespace exists:

Cluster -> Projects/Namespaces -> Create Project

Cluster -> Projects/Namespaces -> Click the ... on the right side of the Namespace -> Move

| Cluster | Rancher project | Namespaces |
|---------|-----------------|------------|
| `stud` | `ARC Runners Stud` | `arc-systems`, `arc-runners`, `buildkit` |
| `theia-prod` | `ARC Runners theiaprod` | `arc-systems`, `arc-runners`, `buildkit` |
| `parma` | `ARC Runners parma` | `arc-systems`, `arc-runners`, `buildkit`, `zot-system` |

If the project does not exist yet, create it in the Rancher UI first. Prefer assigning namespaces in the Rancher UI because Rancher project IDs are cluster-specific and are not the same as the display names above. `arc-systems` and `arc-runners` exist after the namespace commands above; assign `buildkit` after Part 0 creates it, and assign `zot-system` on parma after the Zot namespace exists.

If the Rancher project ID is known, namespace assignment can also be applied by annotation:

```bash
kubectl annotate namespace arc-systems field.cattle.io/projectId="<cluster-id>:<project-id>" --overwrite
kubectl annotate namespace arc-runners field.cattle.io/projectId="<cluster-id>:<project-id>" --overwrite
kubectl annotate namespace buildkit field.cattle.io/projectId="<cluster-id>:<project-id>" --overwrite

# parma only, after Zot namespace exists
kubectl annotate namespace zot-system field.cattle.io/projectId="<cluster-id>:<project-id>" --overwrite
```

Then create one secret per GitHub organization:

```bash
# EduIDE GitHub App
kubectl create secret generic github-arc-secret-eduidec \
  --namespace=arc-runners \
  --from-literal=github_app_id="<APP_ID>" \
  --from-literal=github_app_installation_id="<INSTALLATION_ID>" \
  --from-file=github_app_private_key=<path-to-private-key.pem>

# ls1intum GitHub App
kubectl create secret generic github-arc-secret-ls1intum \
  --namespace=arc-runners \
  --from-literal=github_app_id="<APP_ID>" \
  --from-literal=github_app_installation_id="<INSTALLATION_ID>" \
  --from-file=github_app_private_key=<path-to-private-key.pem>
```

The documented Helm flow creates namespaces before Helm runs and therefore sets `createNamespaces=false` on every ARC chart install. This avoids Helm namespace ownership conflicts when Part 1 and Part 2 are installed as separate releases.

### Deploy stud (AMD64 BuildKit runners)

```bash
kubectl config use-context stud

# Part 0: BuildKit workers
kubectl apply -f infra/stud/buildkit/namespace.yaml
kubectl wait --for=jsonpath='{.status.phase}'=Active namespace/buildkit --timeout=60s
kubectl apply -f infra/stud/buildkit/configmap.yaml
kubectl apply -f infra/stud/buildkit/service.yaml
kubectl apply -f infra/stud/buildkit/statefulset.yaml
kubectl rollout status statefulset/buildkitd -n buildkit --timeout=10m

# Part 1: Controller
helm upgrade --install theia-arc-systems helm-chart/theia-arc-bundle \
  --namespace arc-systems \
  -f helm-chart/theia-arc-bundle/values.yaml \
  -f helm-chart/theia-arc-bundle/values-stud.yaml \
  --set createNamespaces=false \
  --set ghaArcController.enabled=true \
  --set ghaArcScaleSetAmdEduide.enabled=false \
  --set ghaArcScaleSetArmEduide.enabled=false \
  --set ghaArcScaleSetAmdLs1intum.enabled=false \
  --set ghaArcScaleSetArmLs1intum.enabled=false \
  --wait --timeout 5m

# Part 2: AMD64 BuildKit runner sets for EduIDE and ls1intum
helm upgrade --install theia-arc-runners helm-chart/theia-arc-bundle \
  --namespace arc-runners \
  -f helm-chart/theia-arc-bundle/values.yaml \
  -f helm-chart/theia-arc-bundle/values-stud.yaml \
  --set createNamespaces=false \
  --set ghaArcController.enabled=false \
  --set ghaArcScaleSetAmdEduide.enabled=true \
  --set ghaArcScaleSetArmEduide.enabled=false \
  --set ghaArcScaleSetAmdLs1intum.enabled=true \
  --set ghaArcScaleSetArmLs1intum.enabled=false \
  --wait --timeout 10m
```

### Deploy theia-prod (AMD64 BuildKit runners)

```bash
kubectl config use-context theia-prod

# Part 0: BuildKit workers
kubectl apply -f infra/theia-prod/buildkit/namespace.yaml
kubectl wait --for=jsonpath='{.status.phase}'=Active namespace/buildkit --timeout=60s
kubectl apply -f infra/theia-prod/buildkit/configmap.yaml
kubectl apply -f infra/theia-prod/buildkit/service.yaml
kubectl apply -f infra/theia-prod/buildkit/statefulset.yaml
kubectl rollout status statefulset/buildkitd -n buildkit --timeout=10m

# Part 1: Controller
helm upgrade --install theia-arc-systems helm-chart/theia-arc-bundle \
  --namespace arc-systems \
  -f helm-chart/theia-arc-bundle/values.yaml \
  -f helm-chart/theia-arc-bundle/values-theia-prod.yaml \
  --set createNamespaces=false \
  --set ghaArcController.enabled=true \
  --set ghaArcScaleSetAmdEduide.enabled=false \
  --set ghaArcScaleSetArmEduide.enabled=false \
  --set ghaArcScaleSetAmdLs1intum.enabled=false \
  --set ghaArcScaleSetArmLs1intum.enabled=false \
  --wait --timeout 5m

# Part 2: AMD64 BuildKit runner sets for EduIDE and ls1intum
helm upgrade --install theia-arc-runners helm-chart/theia-arc-bundle \
  --namespace arc-runners \
  -f helm-chart/theia-arc-bundle/values.yaml \
  -f helm-chart/theia-arc-bundle/values-theia-prod.yaml \
  --set createNamespaces=false \
  --set ghaArcController.enabled=false \
  --set ghaArcScaleSetAmdEduide.enabled=true \
  --set ghaArcScaleSetArmEduide.enabled=false \
  --set ghaArcScaleSetAmdLs1intum.enabled=true \
  --set ghaArcScaleSetArmLs1intum.enabled=false \
  --wait --timeout 10m
```

### Deploy parma (ARM64 BuildKit runners)

```bash
kubectl config use-context parma

# Part 0: BuildKit workers
kubectl apply -f infra/parma/buildkit/namespace.yaml
kubectl wait --for=jsonpath='{.status.phase}'=Active namespace/buildkit --timeout=60s
kubectl apply -f infra/parma/buildkit/configmap.yaml
kubectl apply -f infra/parma/buildkit/service.yaml
kubectl apply -f infra/parma/buildkit/statefulset.yaml
kubectl rollout status statefulset/buildkitd -n buildkit --timeout=10m

# Part 1: Controller
helm upgrade --install theia-arc-systems helm-chart/theia-arc-bundle \
  --namespace arc-systems \
  -f helm-chart/theia-arc-bundle/values.yaml \
  -f helm-chart/theia-arc-bundle/values-parma.yaml \
  --set createNamespaces=false \
  --set ghaArcController.enabled=true \
  --set ghaArcScaleSetAmdEduide.enabled=false \
  --set ghaArcScaleSetArmEduide.enabled=false \
  --set ghaArcScaleSetAmdLs1intum.enabled=false \
  --set ghaArcScaleSetArmLs1intum.enabled=false \
  --wait --timeout 5m

# Part 2: ARM64 BuildKit runner sets for EduIDE and ls1intum
helm upgrade --install theia-arc-runners helm-chart/theia-arc-bundle \
  --namespace arc-runners \
  -f helm-chart/theia-arc-bundle/values.yaml \
  -f helm-chart/theia-arc-bundle/values-parma.yaml \
  --set createNamespaces=false \
  --set ghaArcController.enabled=false \
  --set ghaArcScaleSetAmdEduide.enabled=false \
  --set ghaArcScaleSetArmEduide.enabled=true \
  --set ghaArcScaleSetAmdLs1intum.enabled=false \
  --set ghaArcScaleSetArmLs1intum.enabled=true \
  --wait --timeout 10m
```

### Deploy Zot (standalone)

The current shared Zot deployment runs on `parma` and is consumed by all runner clusters via `131.159.88.117:30081`.

```bash
kubectl config use-context parma

kubectl create namespace zot-system --dry-run=client -o yaml | kubectl apply -f -

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
kubectl create secret generic zot-dockerhub-credentials \
  --namespace=zot-system \
  --from-file=credentials.json="${ZOT_CREDS}" \
  --dry-run=client -o yaml | kubectl apply -f -

cd helm-chart/theia-zot
helm upgrade --install theia-zot . \
  --namespace zot-system \
  -f values.yaml \
  -f values-parma.yaml \
  --wait --timeout 10m
```

`zot-dockerhub-credentials` must exist before the Helm install because the Zot config mounts `/etc/zot-credentials/credentials.json` as the Docker Hub sync credentials file. Use a Docker Hub personal access token as `DOCKERHUB_PAT`; do not store the token or generated JSON file in this repository.

### Verify

```bash
kubectl get pods -n arc-systems
kubectl get pods -n arc-runners
kubectl get autoscalingrunnersets -n arc-runners
kubectl get pvc -n zot-system

# BuildKit workers
kubectl --context=stud get pods -n buildkit
kubectl --context=theia-prod get pods -n buildkit
kubectl --context=parma get pods -n buildkit
```

Expected runner sets:

- `stud`: `arc-buildkit-eduide-stud-amd64`, `arc-buildkit-ls1intum-stud-amd64`
- `theia-prod`: `arc-buildkit-eduide-theiaprod-amd64`, `arc-buildkit-ls1intum-theiaprod-amd64`
- `parma`: `arc-buildkit-eduide-parma-arm64`, `arc-buildkit-ls1intum-parma-arm64`

## Documentation

- [Architecture](docs/ARCHITECTURE_V2.md)
- [Troubleshooting](docs/TROUBLESHOOTING.md)
- [BuildKit ARM64 deployment record](docs/archive/DEPLOY_ARM64_STATEFUL_BUILDKIT_2026-03-17.md)

## Cleanup

```bash
helm uninstall theia-arc-runners -n arc-runners
helm uninstall theia-arc-systems -n arc-systems
helm uninstall theia-zot -n zot-system
kubectl delete namespace arc-runners arc-systems zot-system buildkit --ignore-not-found=true
```
