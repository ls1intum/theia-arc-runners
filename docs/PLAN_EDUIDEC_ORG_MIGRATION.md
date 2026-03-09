# Plan: Add EduIDE Org Runner Support

**Status:** Pending  
**Author:** Nikolas  
**Date:** 2026-03-09

---

## Background

Self-hosted runners are currently deployed for the `ls1intum` GitHub org only. Repos have migrated (or are migrating) to the new `EduIDE` GitHub org, and those repos need self-hosted runners too.

ARC hard constraint: a single `AutoscalingRunnerSet` can only target **one** `githubConfigUrl`. You cannot point one runner set at two orgs. A second runner set is required.

---

## Decision: New Helm Release via `values-eduidec.yaml` Overlay

**Chosen approach:** stamp out a second Helm release (`theia-arc-runners-eduidec`) using the existing chart with a new values overlay — **zero changes to `Chart.yaml` or `values.yaml`**.

Alternatives considered:

| Option | Description | Rejected because |
|--------|-------------|------------------|
| A | Add new `arcRunnersEduIDE` blocks to `Chart.yaml` | Monolithic — one bad upgrade risks both orgs' runners simultaneously |
| B | Pass `--set githubConfigUrl=...` at deploy time | Not version-controlled, not reviewable |
| **C** | New `values-eduidec.yaml` + new Helm release | ✅ Chosen — isolated lifecycle, reviewable, easy to extend |

The existing ARC controller (deployed in `arc-systems`) manages runner sets cluster-wide. It will automatically pick up the new EduIDE runner set — no controller changes or RBAC additions are needed.

---

## What Needs To Be Done

### 1. Create `values-eduidec.yaml`

Create `helm-chart/theia-arc-bundle/values-eduidec.yaml`:

```yaml
# EduIDE org overrides — deploy as a second Helm release on top of values.yaml.
# The controller, cache server, and Zot are already running from theia-arc-systems;
# this release deploys only the runner scale set(s).

arcController:
  enabled: false

cache-server:
  enabled: false

zot:
  enabled: false

arcRunners:
  enabled: true
  githubConfigUrl: "https://github.com/EduIDE"
  githubConfigSecret: "github-arc-secret-eduidec"
  runnerScaleSetName: "arc-runner-set-eduidec"
  # All other runner pod settings (image, resources, DinD, Zot mirror) inherit
  # from values.yaml and need no changes.

arcRunnersArm:
  enabled: false
  # Enable and configure if ARM64 runners are needed for EduIDE repos in future.
  # githubConfigUrl: "https://github.com/EduIDE"
  # githubConfigSecret: "github-arc-secret-eduidec"
  # runnerScaleSetName: "arc-runner-set-eduidec-arm64"
```

### 2. Create the GitHub Auth Secret

Create a **separate** K8s secret for EduIDE in the `arc-runners` namespace. Use a GitHub App (preferred) or a PAT scoped **only** to the `EduIDE` org.

```bash
# Option A: GitHub App (recommended — no expiry, least privilege)
kubectl create secret generic github-arc-secret-eduidec \
  --namespace=arc-runners \
  --from-literal=github_app_id="<EDUIDEC_APP_ID>" \
  --from-literal=github_app_installation_id="<EDUIDEC_INSTALLATION_ID>" \
  --from-file=github_app_private_key=<path-to-private-key.pem>

# Option B: Personal Access Token
kubectl create secret generic github-arc-secret-eduidec \
  --namespace=arc-runners \
  --from-literal=github_token="ghp_xxxxxxxxxxxx"
```

> **Do not reuse `github-arc-secret`.** The ls1intum and EduIDE secrets must remain independent. If one token is compromised or needs rotation, the other org is unaffected.

The GitHub App or PAT must have the following permissions on the `EduIDE` org:
- `Actions: Read & Write` (to register and manage runners)
- `Administration: Read & Write` (org-level runner registration)

### 3. Deploy the Second Helm Release

#### AMD64 (theia-prod cluster)

```bash
kubectl config use-context theia-prod
cd helm-chart/theia-arc-bundle

helm upgrade --install theia-arc-runners-eduidec . \
  -f values.yaml \
  -f values-eduidec.yaml \
  --namespace arc-runners \
  --wait --timeout 2m
```

#### ARM64 (parma cluster) — only if ARM runners are needed for EduIDE

```bash
kubectl config use-context parma
cd helm-chart/theia-arc-bundle

# First update values-eduidec.yaml to enable arcRunnersArm, then:
helm upgrade --install theia-arc-runners-eduidec . \
  -f values.yaml \
  -f values-arm64.yaml \
  -f values-eduidec.yaml \
  --namespace arc-runners \
  --wait --timeout 2m
```

### 4. Verify

```bash
# Confirm both runner sets are registered and healthy
kubectl get autoscalingrunnersets -n arc-runners

# Expected output includes:
#   arc-runner-set-stateless    (ls1intum, AMD64)
#   arc-runner-set-arm64        (ls1intum, ARM64)
#   arc-runner-set-eduidec      (EduIDE, AMD64)

# Check listener pods
kubectl get pods -n arc-systems | grep listener

# Check GitHub → EduIDE org → Settings → Actions → Runners
# "arc-runner-set-eduidec" should appear as an active org-level runner group
```

### 5. Update EduIDE Workflow Files

All workflows in EduIDE repos that need self-hosted runners must use the new runner set name:

```yaml
# Before (ls1intum repos):
jobs:
  build:
    runs-on: arc-runner-set-stateless

# After (EduIDE repos):
jobs:
  build:
    runs-on: arc-runner-set-eduidec
```

The `runs-on` value must exactly match `runnerScaleSetName` from `values-eduidec.yaml`.

---

## Naming Reference

| Resource | ls1intum (existing) | EduIDE (new) |
|----------|---------------------|--------------|
| Helm release | `theia-arc-runners` | `theia-arc-runners-eduidec` |
| Runner set name | `arc-runner-set-stateless` | `arc-runner-set-eduidec` |
| ARM64 runner set name | `arc-runner-set-arm64` | `arc-runner-set-eduidec-arm64` |
| K8s auth secret | `github-arc-secret` | `github-arc-secret-eduidec` |
| `runs-on` label | `arc-runner-set-stateless` | `arc-runner-set-eduidec` |
| Values overlay | `values.yaml` | `values-eduidec.yaml` |

Shared (no changes needed):
- Helm release `theia-arc-systems` (controller + cache + Zot)
- Namespaces `arc-systems`, `arc-runners`
- ServiceAccounts `arc-runner-set-stateless-sa`, `arc-runner-set-stateless-arm-sa`
- All Zot and cache server config

---

## Uninstall (if rollback needed)

```bash
# Remove EduIDE runners only — does NOT affect ls1intum runners
helm uninstall theia-arc-runners-eduidec -n arc-runners
kubectl delete secret github-arc-secret-eduidec -n arc-runners
```

---

## Future: ARM64 for EduIDE

Not needed at migration time. When required:

1. Enable `arcRunnersArm` in `values-eduidec.yaml` (see commented block above)
2. Set `runnerScaleSetName: "arc-runner-set-eduidec-arm64"`
3. Deploy with `-f values-arm64.yaml -f values-eduidec.yaml` on parma
4. Update ARM64 workflows in EduIDE repos to use `runs-on: arc-runner-set-eduidec-arm64`
