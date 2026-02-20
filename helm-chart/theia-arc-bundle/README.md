# Theia ARC Bundle Helm Chart

Production-grade Helm umbrella chart for GitHub Actions Runner Controller (ARC) with build cache infrastructure.

## Overview

This chart deploys a complete ARC setup with integrated build caches:

- **Build Caches** (local subchart):
  - Docker Registry Mirror (Docker Hub)
  - Docker Registry Mirror (GHCR)
  - Verdaccio (npm cache)
  - Apt-Cacher-NG (Ubuntu/Debian packages)
  - Squid (HTTPS proxy with SSL bumping for VSIX)

- **ARC Components** (external charts):
  - gha-runner-scale-set-controller (v0.9.3)
  - gha-runner-scale-set (AMD64 and/or ARM64)

## Prerequisites

1. **Kubernetes cluster** (v1.23+)
2. **Helm** (v3.8+)
3. **GitHub Personal Access Token** with `repo`, `admin:org` scopes
4. **Storage provisioner** configured (StorageClass available)

## Quick Start

### AMD64 Cluster (theia-prod)

```bash
kubectl create secret generic github-arc-secret \
  --namespace=arc-runners \
  --from-literal=github_token="YOUR_GITHUB_PAT"

./scripts/setup-squid-ca.sh

helm install theia-arc ./helm-chart/theia-arc-bundle \
  --namespace arc-runners \
  --create-namespace \
  --wait \
  --timeout 10m
```

### ARM64 Cluster (parma)

```bash
kubectl create secret generic github-arc-secret \
  --namespace=arc-runners \
  --from-literal=github_token="YOUR_GITHUB_PAT"

./scripts/setup-squid-ca.sh

helm install theia-arc ./helm-chart/theia-arc-bundle \
  --namespace arc-runners \
  --create-namespace \
  -f ./helm-chart/theia-arc-bundle/values-arm64.yaml \
  --wait \
  --timeout 10m
```

## Architecture

### Two-Cluster Deployment

This chart is designed for deployment across two distinct Kubernetes clusters:

| Cluster | Architecture | Storage | PVC Sizes | Use Case |
|---------|-------------|---------|-----------|----------|
| **theia-prod** | AMD64 | Ceph RBD (`csi-rbd-sc`) | Large (200Gi Docker, 50Gi npm) | Production workloads |
| **parma** | ARM64 | local-path | Small (10Gi Docker, 5Gi npm) + memory-backed work | ARM builds, testing |

### Dependency Management

Runners include init containers that wait for all cache services to be ready:

```yaml
initContainers:
  - name: wait-for-caches
    image: busybox:1.36
    command: [sh, -c]
    args:
      - |
        until nc -z registry-mirror.registry-mirror.svc.cluster.local 5000; do sleep 2; done
        until nc -z verdaccio.verdaccio.svc.cluster.local 4873; do sleep 2; done
        # ... checks for all 5 cache services
```

This ensures runners never start before caches are available (no race conditions).

## Configuration

### Values Files

- **`values.yaml`**: AMD64/theia-prod defaults
- **`values-arm64.yaml`**: ARM64/parma overlay (merge with values.yaml)

### Key Configuration Options

#### Global Settings

```yaml
global:
  storageClass: "csi-rbd-sc"
  nodeSelector:
    kubernetes.io/arch: amd64
  tolerations: []
```

#### Build Caches

```yaml
buildCaches:
  enabled: true
  dockerMirror:
    enabled: true
    pvcSize: "200Gi"
  ghcrMirror:
    enabled: true
    pvcSize: "200Gi"
  verdaccio:
    enabled: true
    pvcSize: "50Gi"
  aptCacher:
    enabled: true
    pvcSize: "50Gi"
  squid:
    enabled: true
    pvcSize: "20Gi"
    caSecretName: "squid-ca-cert"
```

#### ARC Runners

```yaml
arcRunners:
  enabled: true
  githubConfigUrl: "https://github.com/ls1intum"
  githubConfigSecret: "github-arc-secret"
  minRunners: 10
  maxRunners: 50
  runnerScaleSetName: "arc-runner-set-stateless"
  controllerServiceAccount:
    namespace: arc-systems
    name: gha-rs-controller
```

#### External Secrets (Optional)

```yaml
externalSecrets:
  enabled: true
  secretStore: "vault-backend"
  githubPat:
    remoteRef:
      key: "github/actions-pat"
      property: "token"
```

## Installation

### Step 1: Create Prerequisites

#### GitHub PAT Secret (Required)

```bash
kubectl create secret generic github-arc-secret \
  --namespace=arc-runners \
  --from-literal=github_token="ghp_xxxxxxxxxxxxxxxxxxxx"
```

**Required scopes:**
- `repo` (full control of private repositories)
- `admin:org` → `manage_runners:org` (manage self-hosted runners)

#### Squid CA Certificate (Required for VSIX caching)

```bash
kubectl config use-context <cluster-name>
./scripts/setup-squid-ca.sh
```

This creates a `squid-ca-cert` secret in the `squid` namespace with a self-signed CA for SSL bumping.

### Step 2: Install Chart

#### AMD64 (Default)

```bash
cd helm-chart/theia-arc-bundle
helm dependency build

helm install theia-arc . \
  --namespace arc-runners \
  --create-namespace \
  --wait \
  --timeout 10m
```

#### ARM64 (With Overlay)

```bash
helm install theia-arc . \
  --namespace arc-runners \
  --create-namespace \
  -f values-arm64.yaml \
  --wait \
  --timeout 10m
```

### Step 3: Verify Installation

```bash
kubectl get pods --all-namespaces | grep -E "(registry|verdaccio|apt|squid|arc)"

kubectl get autoscalingrunnersets -n arc-runners

helm status theia-arc -n arc-runners
```

## Upgrading

### Update Configuration

Edit `values.yaml` or create a new overlay file.

### Apply Upgrade

```bash
helm upgrade theia-arc . \
  --namespace arc-runners \
  --wait \
  --timeout 10m
```

### Rollback (If Needed)

```bash
helm rollback theia-arc -n arc-runners

helm history theia-arc -n arc-runners
```

## Uninstallation

```bash
helm uninstall theia-arc -n arc-runners

kubectl delete namespace arc-systems arc-runners
kubectl delete namespace registry-mirror verdaccio apt-cacher-ng squid
```

**Warning:** This will delete all PVCs and cached data.

## Troubleshooting

### Runners Not Starting

**Symptom:** Runner pods stuck in `Init:0/2` or `Init:1/2`

**Diagnosis:**
```bash
kubectl logs -n arc-runners <runner-pod> -c wait-for-caches
```

**Common Causes:**
1. Cache services not running
2. Network policies blocking traffic
3. Service DNS resolution failing

**Fix:**
```bash
kubectl get pods -n registry-mirror
kubectl get pods -n verdaccio
kubectl get pods -n squid

kubectl describe pod -n arc-runners <runner-pod>
```

### GitHub Workflows Not Triggering Runners

**Symptom:** Workflows queue indefinitely, no runner pods spawn

**Diagnosis:**
```bash
kubectl logs -n arc-systems -l app.kubernetes.io/name=gha-runner-scale-set-controller --tail=100
```

**Common Causes:**
1. Invalid GitHub PAT
2. Wrong GitHub org URL
3. Controller not running

**Fix:**
```bash
kubectl get secret github-arc-secret -n arc-runners -o jsonpath='{.data.github_token}' | base64 -d

kubectl get pods -n arc-systems
```

### Cache Not Working

**Symptom:** Builds still download from internet, no cache hits

**Diagnosis:**
```bash
kubectl run test-cache --image=alpine --rm -it --restart=Never -- sh
nc -zv registry-mirror.registry-mirror.svc.cluster.local 5000
nc -zv verdaccio.verdaccio.svc.cluster.local 4873
```

**Common Causes:**
1. Runners not configured with cache endpoints
2. Services not exposing correct ports
3. ConfigMaps not mounted

**Fix:**
```bash
kubectl get svc -n registry-mirror
kubectl logs -n registry-mirror <registry-pod>
```

### PVC Stuck in Pending

**Symptom:** Pods can't start because PVCs won't bind

**Diagnosis:**
```bash
kubectl get pvc -A | grep Pending
kubectl describe pvc <pvc-name> -n <namespace>
```

**Common Causes:**
1. StorageClass doesn't exist
2. No available PVs
3. Node affinity mismatch

**Fix:**
```bash
kubectl get storageclass

helm upgrade theia-arc . \
  --set global.storageClass="<correct-class>" \
  --namespace arc-runners
```

## Testing

See [../../docs/TESTING.md](../../docs/TESTING.md) for comprehensive test procedures.

## GitOps Integration

### ArgoCD Application

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: theia-arc-amd64
  namespace: argocd
spec:
  project: infrastructure
  source:
    repoURL: https://github.com/ls1intum/theia-arc-runners
    targetRevision: main
    path: helm-chart/theia-arc-bundle
    helm:
      valueFiles:
        - values.yaml
  destination:
    server: https://kubernetes.default.svc
    namespace: arc-runners
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

### Flux HelmRelease

```yaml
apiVersion: helm.toolkit.fluxcd.io/v2beta1
kind: HelmRelease
metadata:
  name: theia-arc-arm64
  namespace: flux-system
spec:
  interval: 10m
  chart:
    spec:
      chart: ./helm-chart/theia-arc-bundle
      sourceRef:
        kind: GitRepository
        name: theia-arc-runners
      interval: 1m
  valuesFrom:
    - kind: ConfigMap
      name: theia-arc-values-arm64
  install:
    createNamespace: true
    remediation:
      retries: 3
  upgrade:
    remediation:
      retries: 3
```

## Advanced Configuration

### Custom Runner Images

```yaml
arcRunners:
  template:
    spec:
      containers:
        - name: runner
          image: ghcr.io/ls1intum/custom-runner:latest
```

### Resource Limits

```yaml
arcRunners:
  template:
    spec:
      containers:
        - name: runner
          resources:
            requests:
              cpu: 1000m
              memory: 2Gi
            limits:
              cpu: 8000m
              memory: 16Gi
```

### Custom Init Commands

```yaml
arcRunners:
  template:
    spec:
      initContainers:
        - name: custom-setup
          image: alpine:latest
          command: [sh, -c, "echo 'Custom setup'"]
```

## Chart Dependencies

This chart depends on:

- **build-caches** (v0.1.0) - Local subchart (`file://charts/build-caches`)
- **gha-runner-scale-set-controller** (v0.9.3) - OCI registry (`ghcr.io/actions/actions-runner-controller-charts`)
- **gha-runner-scale-set** (v0.9.3 × 2) - OCI registry (AMD64 + ARM64 aliases)

Dependencies are fetched automatically during `helm dependency build`.

## Version History

| Version | Date | Changes |
|---------|------|---------|
| 0.1.0 | 2026-02-16 | Initial Helm chart conversion from bash scripts |

## Contributing

See [CONTRIBUTING.md](../../CONTRIBUTING.md) for development guidelines.

## License

See [LICENSE](../../LICENSE) for license information.

## References

- [GitHub Actions Runner Controller](https://github.com/actions/actions-runner-controller)
- [Helm Documentation](https://helm.sh/docs/)
- [Kubernetes Storage Concepts](https://kubernetes.io/docs/concepts/storage/)
- [Implementation Reference](../../HELM_IMPLEMENTATION.md)
