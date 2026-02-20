# Helm Chart Implementation Reference

**Branch:** `feature/helm-chart-conversion`  
**Created:** 2026-02-16  
**Purpose:** Convert bash script deployment to production-grade Helm umbrella chart

---

## Executive Summary

This document serves as a comprehensive reference for implementing a Helm umbrella chart for the GitHub Actions Runner Controller (ARC) infrastructure. It consolidates all architectural decisions, configurations, and implementation details needed to complete the conversion and serve as a reference during chat compression.

---

## Current State Analysis

### Existing Deployment Method
- **Type:** Bash scripts + raw Kubernetes manifests
- **Scripts:** `scripts/deploy-amd.sh`, `scripts/deploy-arm.sh`, `scripts/setup-squid-ca.sh`
- **Manifests:** 13 YAML files × 2 architectures (26 total files)
- **Deployment Flow:** 9 sequential steps with `kubectl wait` between stages

### Pain Points
1. Manual orchestration via bash scripts
2. Duplication between AMD64 and ARM64 manifests
3. No atomic rollback capability
4. Poor GitOps integration
5. Manual secret management via environment variables
6. No version control for the full stack

---

## Target Architecture

### Helm Chart Structure
```
helm-chart/theia-arc-bundle/
├── Chart.yaml                      # Root umbrella chart with dependencies
├── values.yaml                     # AMD64/theia-prod defaults
├── values-arm64.yaml               # ARM64/parma overlay
├── README.md                       # User-facing documentation
├── charts/
│   └── build-caches/               # Local subchart for cache infrastructure
│       ├── Chart.yaml
│       ├── values.yaml
│       └── templates/
│           ├── _helpers.tpl
│           ├── registry-mirror-dockerhub.yaml
│           ├── registry-mirror-ghcr.yaml
│           ├── verdaccio.yaml
│           ├── apt-cacher-ng.yaml
│           └── squid.yaml
└── templates/
    ├── _helpers.tpl
    ├── namespace.yaml              # arc-systems, arc-runners
    ├── rbac.yaml                   # Service accounts & RBAC
    ├── external-secret-github.yaml # Optional ESO integration
    └── NOTES.txt                   # Post-install instructions
```

---

## Component Details

### 1. Root Chart (Chart.yaml)

**Dependencies:**
```yaml
dependencies:
  # Local subchart for cache infrastructure
  - name: build-caches
    version: 0.1.0
    repository: "file://charts/build-caches"
    condition: buildCaches.enabled

  # External ARC Controller
  - name: gha-runner-scale-set-controller
    version: 0.9.3
    repository: "oci://ghcr.io/actions/actions-runner-controller-charts"
    alias: arcController
    condition: arcController.enabled

  # External ARC Runner Scale Set (AMD64)
  - name: gha-runner-scale-set
    version: 0.9.3
    repository: "oci://ghcr.io/actions/actions-runner-controller-charts"
    alias: arcRunners
    condition: arcRunners.enabled

  # External ARC Runner Scale Set (ARM64)
  - name: gha-runner-scale-set
    version: 0.9.3
    repository: "oci://ghcr.io/actions/actions-runner-controller-charts"
    alias: arcRunnersArm
    condition: arcRunnersArm.enabled
```

**Key Design Decisions:**
- Single umbrella chart for unified versioning
- External ARC charts referenced via OCI registry
- Local `build-caches` subchart to encapsulate cache infrastructure
- Conditional deployment via `condition:` flags

---

### 2. Build Caches Subchart

**Components:**
1. **Docker Registry Mirror (Docker Hub)** - Transparent pull-through cache
2. **Docker Registry Mirror (GHCR)** - GHCR pull-through cache
3. **Verdaccio** - npm registry cache
4. **Apt-Cacher-NG** - Ubuntu/Debian package cache
5. **Squid** - HTTPS proxy with SSL bumping for VSIX caching

**Template Conversion Strategy:**
- Each component gets its own template file
- Parameterize storage classes, PVC sizes, resource limits
- Use `{{- if .Values.component.enabled }}` for conditional deployment
- Inherit `global.storageClass`, `global.nodeSelector`, `global.tolerations`

**Key Templating Patterns:**
```yaml
# Conditional rendering
{{- if .Values.dockerMirror.enabled }}

# Storage class inheritance with override
storageClassName: {{ .Values.dockerMirror.storageClass | default .Values.global.storageClass }}

# Node selection from global
{{- with .Values.global.nodeSelector }}
nodeSelector:
  {{- toYaml . | nindent 8 }}
{{- end }}

# Resource templating
resources:
  {{- toYaml .Values.dockerMirror.resources | nindent 12 }}
```

---

### 3. Deployment Ordering & Dependencies

**Problem:** Helm installs dependencies first but doesn't wait for Pod readiness.

**Solution:** InitContainers in runner pods that wait for cache services.

**Implementation:**
```yaml
initContainers:
  - name: wait-for-caches
    image: busybox:1.36
    command:
      - sh
      - -c
      - |
        echo "Waiting for cache services..."
        until nc -z registry-mirror.registry-mirror.svc.cluster.local 5000; do
          echo "Waiting for Docker mirror..."
          sleep 2
        done
        until nc -z registry-mirror-ghcr.registry-mirror.svc.cluster.local 5000; do
          echo "Waiting for GHCR mirror..."
          sleep 2
        done
        until nc -z verdaccio.verdaccio.svc.cluster.local 4873; do
          echo "Waiting for Verdaccio..."
          sleep 2
        done
        until nc -z apt-cacher-ng.apt-cacher-ng.svc.cluster.local 3142; do
          echo "Waiting for apt-cacher-ng..."
          sleep 2
        done
        until nc -z squid.squid.svc.cluster.local 3128; do
          echo "Waiting for Squid..."
          sleep 2
        done
        echo "All cache services ready!"
```

**Benefits:**
- Self-healing: runners wait for caches to become ready
- GitOps compatible: works with ArgoCD/Flux sync waves
- No bash script orchestration needed

---

### 4. Cluster-Specific Configuration

**Strategy:** Global values + architecture-specific overlays

#### values.yaml (AMD64/theia-prod defaults)
```yaml
global:
  storageClass: "csi-rbd-sc"
  nodeSelector:
    kubernetes.io/arch: amd64
  tolerations: []

buildCaches:
  enabled: true
  dockerMirror:
    pvcSize: "200Gi"
  ghcrMirror:
    pvcSize: "200Gi"
  verdaccio:
    pvcSize: "50Gi"
  aptCacher:
    pvcSize: "50Gi"
  squid:
    pvcSize: "20Gi"

arcRunners:
  enabled: true
  minRunners: 10
  maxRunners: 50
  githubConfigUrl: "https://github.com/ls1intum"
  githubConfigSecret: "github-arc-secret"

arcRunnersArm:
  enabled: false
```

#### values-arm64.yaml (ARM64/parma overlay)
```yaml
global:
  storageClass: "local-path"
  nodeSelector:
    kubernetes.io/arch: arm64

buildCaches:
  dockerMirror:
    pvcSize: "10Gi"
  ghcrMirror:
    pvcSize: "50Gi"
  verdaccio:
    pvcSize: "5Gi"
  aptCacher:
    pvcSize: "10Gi"
  squid:
    pvcSize: "10Gi"

arcRunners:
  enabled: false

arcRunnersArm:
  enabled: true
  minRunners: 10
  maxRunners: 50
  # ARM-specific: memory-backed work directory
  template:
    spec:
      volumes:
        - name: work
          emptyDir:
            medium: Memory
            sizeLimit: 30Gi
```

---

### 5. Secret Management

**Approach:** Reference secrets by name; do NOT manage content in Helm.

#### Required Secrets
1. **GitHub PAT** (`github-arc-secret`)
   - Namespace: `arc-runners`
   - Key: `github_token`
   - Management: Manual creation or External Secrets Operator (ESO)

2. **Squid CA Certificate** (`squid-ca-cert`)
   - Namespace: `squid`
   - Type: `kubernetes.io/tls`
   - Management: Generated via `scripts/setup-squid-ca.sh` (one-time)

#### Manual Creation Commands
```bash
# GitHub PAT
kubectl create secret generic github-arc-secret \
  --namespace=arc-runners \
  --from-literal=github_token="YOUR_GITHUB_PAT"

# Squid CA (via existing script)
kubectl config use-context <cluster-name>
./scripts/setup-squid-ca.sh
```

#### Optional: External Secrets Operator Integration
```yaml
# Enable in values.yaml
externalSecrets:
  enabled: true
  secretStore: "vault-backend"
  githubPat:
    remoteRef:
      key: "github/actions-pat"
      property: "token"
```

Creates `ExternalSecret` resource that syncs from Vault/AWS Secrets Manager.

---

## Testing Strategy

### Phase 1: Template Validation
```bash
cd helm-chart/theia-arc-bundle
helm dependency build
helm template . --namespace arc-runners --debug > /tmp/rendered-amd64.yaml
helm template . -f values-arm64.yaml --namespace arc-runners --debug > /tmp/rendered-arm64.yaml
```

**Validation Checklist:**
- [ ] All namespaces created (registry-mirror, verdaccio, apt-cacher-ng, squid, arc-systems, arc-runners)
- [ ] Storage classes match cluster type
- [ ] Node selectors applied correctly
- [ ] Service names consistent with current deployment
- [ ] PVC sizes match architecture requirements
- [ ] Init containers present in runner pods
- [ ] RBAC resources created

### Phase 2: Lint & Validate
```bash
helm lint .
helm lint . -f values-arm64.yaml
```

### Phase 3: Dry-Run Deployment
```bash
# AMD64
helm install theia-arc . \
  --namespace arc-runners \
  --create-namespace \
  --dry-run \
  --debug

# ARM64
helm install theia-arc . \
  --namespace arc-runners \
  --create-namespace \
  -f values-arm64.yaml \
  --dry-run \
  --debug
```

### Phase 4: Actual Deployment (Staging/Dev)
```bash
# Prerequisites
kubectl create secret generic github-arc-secret \
  --namespace=arc-runners \
  --from-literal=github_token="$GITHUB_PAT"
./scripts/setup-squid-ca.sh

# Install
helm install theia-arc . \
  --namespace arc-runners \
  --create-namespace \
  --wait \
  --timeout 10m

# Verify
kubectl get pods --all-namespaces | grep -E "(registry|verdaccio|apt|squid|arc)"
helm status theia-arc -n arc-runners
```

### Phase 5: Functional Testing

#### Cache Functionality Tests

**1. Docker Registry Mirror (Docker Hub)**
```bash
# Deploy test pod
kubectl run test-docker-mirror --image=alpine --rm -it --restart=Never -- sh

# Inside pod:
apk add curl
curl -I http://registry-mirror.registry-mirror.svc.cluster.local:5000/v2/
# Expected: 200 OK
```

**2. Docker Registry Mirror (GHCR)**
```bash
kubectl run test-ghcr-mirror --image=alpine --rm -it --restart=Never -- sh

# Inside pod:
apk add curl
curl -I http://registry-mirror-ghcr.registry-mirror.svc.cluster.local:5000/v2/
# Expected: 200 OK
```

**3. Verdaccio (npm cache)**
```bash
kubectl run test-verdaccio --image=node:20-alpine --rm -it --restart=Never -- sh

# Inside pod:
npm config set registry http://verdaccio.verdaccio.svc.cluster.local:4873
npm view express
# Expected: Package info displayed
```

**4. Apt-Cacher-NG**
```bash
kubectl run test-apt-cacher --image=ubuntu:22.04 --rm -it --restart=Never -- sh

# Inside pod:
echo "Acquire::http::Proxy \"http://apt-cacher-ng.apt-cacher-ng.svc.cluster.local:3142\";" > /etc/apt/apt.conf.d/01proxy
apt-get update
# Expected: Packages download through cache
# Check apt-cacher-ng logs for cache hits
```

**5. Squid (HTTPS proxy)**
```bash
kubectl run test-squid --image=alpine --rm -it --restart=Never -- sh

# Inside pod:
apk add curl ca-certificates
curl -o /usr/local/share/ca-certificates/squid-ca.crt \
  http://squid.squid.svc.cluster.local:3128/squid-ca.crt
update-ca-certificates
export HTTPS_PROXY=http://squid.squid.svc.cluster.local:3129
curl -I https://open-vsx.org/api/
# Expected: 200 OK, cached by Squid
```

#### ARC Functional Tests

**1. Controller Health**
```bash
kubectl get pods -n arc-systems -l app.kubernetes.io/name=gha-runner-scale-set-controller
# Expected: 1 pod Running

kubectl logs -n arc-systems -l app.kubernetes.io/name=gha-runner-scale-set-controller --tail=50
# Expected: No errors, "Listening for webhooks" message
```

**2. Listener Pods**
```bash
kubectl get pods -n arc-systems | grep listener
# Expected: Listener pods in Running state
```

**3. Runner Scale Set**
```bash
kubectl get autoscalingrunnersets -n arc-runners
# Expected: arc-runner-set-stateless (or stateless-arm) with minRunners/maxRunners
```

**4. Trigger Test Workflow**
Create a GitHub Actions workflow in `ls1intum/<repo>`:
```yaml
name: Test ARC Runners
on:
  workflow_dispatch:
jobs:
  test:
    runs-on: [self-hosted, Linux]
    steps:
      - run: echo "Testing ARC runner"
      - run: docker --version
```

Verify:
- [ ] Runner pod spawns in `arc-runners` namespace
- [ ] Job completes successfully
- [ ] Pod uses cache services (check logs for registry mirror usage)

### Phase 6: Upgrade Testing
```bash
# Make non-breaking change (e.g., bump runner count)
# Edit values.yaml: minRunners: 10 → 12

helm upgrade theia-arc . \
  --namespace arc-runners \
  --wait

# Verify
kubectl get pods -n arc-runners
helm history theia-arc -n arc-runners
```

### Phase 7: Rollback Testing
```bash
helm rollback theia-arc -n arc-runners
kubectl get pods -n arc-runners
# Verify minRunners reverted to 10
```

---

## Migration Path from Bash Scripts

### Step 1: Parallel Deployment (Safe)
1. Deploy Helm chart to staging cluster first
2. Keep bash scripts functional for production
3. Validate Helm chart behavior matches bash deployment

### Step 2: Production Migration
1. **AMD64 cluster (theia-prod):**
   - Uninstall bash-deployed resources during maintenance window
   - Deploy via Helm chart
   - Verify functionality

2. **ARM64 cluster (parma):**
   - Repeat AMD64 process
   - Use `values-arm64.yaml` overlay

### Step 3: Documentation Update
- Update main `README.md` to reference Helm chart
- Move bash scripts to `scripts/legacy/` with deprecation notice
- Add migration guide to `docs/MIGRATION.md`

### Step 4: GitOps Integration (Optional)
- Create ArgoCD Application or Flux HelmRelease
- Configure automated sync with pruning

---

## Rollback Plan

### If Helm Deployment Fails
```bash
# Uninstall Helm release
helm uninstall theia-arc -n arc-runners

# Redeploy via bash scripts
kubectl config use-context <cluster-name>
export GITHUB_PAT="..."
./scripts/deploy-amd.sh  # or deploy-arm.sh
```

### If Partial Failure
```bash
# Check what was deployed
helm status theia-arc -n arc-runners
kubectl get all --all-namespaces | grep -E "(registry|verdaccio|apt|squid|arc)"

# Delete specific components
kubectl delete namespace <failed-namespace>

# Retry deployment
helm upgrade --install theia-arc . --namespace arc-runners
```

---

## GitOps Integration Examples

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
  values:
    # Inline ARM64 overrides
    global:
      storageClass: "local-path"
      nodeSelector:
        kubernetes.io/arch: arm64
    arcRunners:
      enabled: false
    arcRunnersArm:
      enabled: true
  install:
    createNamespace: true
    remediation:
      retries: 3
  upgrade:
    remediation:
      retries: 3
```

---

## Key Decisions & Rationale

### 1. Single Umbrella Chart vs Multiple Charts
**Decision:** Single umbrella chart  
**Rationale:** 
- Unified versioning for the entire stack
- Caches and runners are tightly coupled
- Simplifies dependency management
- Users deploy one product, not multiple

### 2. Local Subchart vs External Dependencies for Caches
**Decision:** Local subchart (`build-caches`)  
**Rationale:**
- No public Helm charts exist for this specific cache configuration
- Full control over templates
- Easier to maintain and iterate
- Can be extracted later if needed

### 3. InitContainers vs Helm Hooks for Ordering
**Decision:** InitContainers  
**Rationale:**
- More robust and self-healing
- Works with GitOps (ArgoCD/Flux)
- No race conditions on upgrade
- Standard Kubernetes pattern

### 4. Manual Secrets vs Helm-Managed Secrets
**Decision:** Reference by name (manual creation or ESO)  
**Rationale:**
- Security best practice (no secrets in values files)
- Supports multiple secret management strategies
- Compatible with GitOps (secrets never in Git)
- Squid CA must be stable (not regenerated on upgrade)

### 5. AMD64/ARM64 Handling
**Decision:** Single chart with value overlays  
**Rationale:**
- DRY principle
- Easier to maintain
- Standard Helm pattern
- Cluster differences are configuration, not architecture

---

## Success Criteria

### Functional Requirements
- [ ] All cache services deploy successfully
- [ ] ARC controller and runners deploy successfully
- [ ] Runners can pull images through Docker registry mirrors
- [ ] Runners can install npm packages through Verdaccio
- [ ] Runners can install apt packages through apt-cacher-ng
- [ ] Runners can download VSIX through Squid proxy
- [ ] GitHub Actions workflows execute successfully on self-hosted runners

### Non-Functional Requirements
- [ ] Deployment is idempotent (can run multiple times safely)
- [ ] Upgrades preserve PVC data
- [ ] Rollback works without data loss
- [ ] Chart passes `helm lint` with no errors
- [ ] `helm template` output matches existing manifests (functionally equivalent)
- [ ] Documentation is comprehensive and accurate

### GitOps Requirements (Optional)
- [ ] ArgoCD can sync the chart
- [ ] Flux can deploy via HelmRelease
- [ ] Drift detection works correctly

---

## Timeline & Effort

| Phase | Tasks | Estimated Time |
|-------|-------|----------------|
| Setup | Directory structure, Chart.yaml | 1 hour |
| Build Caches | Convert 5 manifests to templates | 4 hours |
| Root Chart | Values files, root templates | 2 hours |
| Testing | Template validation, linting | 2 hours |
| Documentation | README, NOTES, PR description | 1 hour |
| **Total** | | **10 hours (1.5 days)** |

---

## File Checklist

### Required Files
- [x] `HELM_IMPLEMENTATION.md` (this file)
- [ ] `helm-chart/theia-arc-bundle/Chart.yaml`
- [ ] `helm-chart/theia-arc-bundle/values.yaml`
- [ ] `helm-chart/theia-arc-bundle/values-arm64.yaml`
- [ ] `helm-chart/theia-arc-bundle/charts/build-caches/Chart.yaml`
- [ ] `helm-chart/theia-arc-bundle/charts/build-caches/values.yaml`
- [ ] `helm-chart/theia-arc-bundle/charts/build-caches/templates/_helpers.tpl`
- [ ] `helm-chart/theia-arc-bundle/charts/build-caches/templates/registry-mirror-dockerhub.yaml`
- [ ] `helm-chart/theia-arc-bundle/charts/build-caches/templates/registry-mirror-ghcr.yaml`
- [ ] `helm-chart/theia-arc-bundle/charts/build-caches/templates/verdaccio.yaml`
- [ ] `helm-chart/theia-arc-bundle/charts/build-caches/templates/apt-cacher-ng.yaml`
- [ ] `helm-chart/theia-arc-bundle/charts/build-caches/templates/squid.yaml`
- [ ] `helm-chart/theia-arc-bundle/templates/_helpers.tpl`
- [ ] `helm-chart/theia-arc-bundle/templates/namespace.yaml`
- [ ] `helm-chart/theia-arc-bundle/templates/rbac.yaml`
- [ ] `helm-chart/theia-arc-bundle/templates/NOTES.txt`
- [ ] `helm-chart/theia-arc-bundle/README.md`
- [ ] `docs/TESTING.md` (comprehensive test plan)
- [ ] `docs/PR_DESCRIPTION.md` (PR summary)

### Optional Files
- [ ] `helm-chart/theia-arc-bundle/templates/external-secret-github.yaml`
- [ ] `docs/MIGRATION.md` (bash → Helm migration guide)

---

## Contact & References

**Implementation Lead:** Nikolas  
**Repository:** `ls1intum/theia-arc-runners`  
**Branch:** `feature/helm-chart-conversion`  
**Target PR:** `main`

**Key References:**
- Helm Documentation: https://helm.sh/docs/
- ARC Charts: https://github.com/actions/actions-runner-controller
- External Secrets Operator: https://external-secrets.io/
- Umbrella Chart Pattern: https://helm.sh/docs/howto/charts_tips_and_tricks/

---

## Appendix: Quick Command Reference

```bash
# Branch Management
git checkout -b feature/helm-chart-conversion
git status

# Chart Development
cd helm-chart/theia-arc-bundle
helm dependency build
helm template . --debug > output.yaml
helm lint .

# Deployment
helm install theia-arc . --namespace arc-runners --create-namespace --wait
helm upgrade theia-arc . --namespace arc-runners --wait
helm rollback theia-arc -n arc-runners
helm uninstall theia-arc -n arc-runners

# Debugging
kubectl get pods --all-namespaces | grep -E "(registry|verdaccio|apt|squid|arc)"
kubectl logs -n <namespace> <pod-name>
kubectl describe pod -n <namespace> <pod-name>

# Testing
kubectl run test-pod --image=alpine --rm -it --restart=Never -- sh
```

---

**Document Version:** 1.0  
**Last Updated:** 2026-02-16  
**Status:** Active Implementation
