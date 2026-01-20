# Theia ARC Runners

Infrastructure-as-code for deploying **GitHub Actions self-hosted runners** using Actions Runner Controller (ARC) with **persistent Docker layer caching**.

## Features

- ✅ **3 Runner Scale Sets** with sticky assignment for optimal cache reuse
- ✅ **Persistent Docker Layer Caching** (100Gi PVCs per runner)
- ✅ **Docker-in-Docker (DinD)** configuration with validated working setup
- ✅ **Automated GitHub Actions deployment** or manual deployment via script
- ✅ **Organization-wide runners** for `ls1intum` repositories

## Quick Start

### Prerequisites

- Kubernetes cluster (same cluster as Theia Cloud recommended)
- `kubectl` configured for your cluster
- Helm 3.14+ installed
- GitHub PAT with `repo` + `workflow` + `admin:org` scopes

### Option 1: GitHub Actions Deployment (Recommended)

1. **Configure GitHub Environment**:
   - Create environment named `arc-runners` in this repository settings
   - Add secrets:
     - `KUBECONFIG`: Kubernetes cluster configuration (contents of ~/.kube/config)
     - `GH_PAT`: GitHub Personal Access Token
   - Enable protection rules if desired (e.g., require manual approval)

2. **Trigger Deployment**:
   - Go to **Actions** → **Manual Deployment**
   - Select runner set to deploy: `all`, `1`, `2`, or `3`
   - Click **Run workflow**

### Option 2: Manual Deployment

You can deploy directly from your local machine using the provided script.

```bash
# Set your GitHub PAT
export GITHUB_PAT="ghp_xxxxxxxxxxxx"

# Deploy all runner sets
./scripts/deploy.sh all

# Or deploy a specific runner set
./scripts/deploy.sh 1
```

## Architecture

The system deploys 3 independent runner scale sets, each with its own persistent volume claim (PVC) for Docker caching.

```
┌───────────────────────────────────────────────────┐
│         ls1intum GitHub Organization              │
├───────────────────────────────────────────────────┤
│  ┌──────────────────┐   ┌──────────────────┐      │
│  │ artemis-theia-   │   │  theia-cloud     │      │
│  │   blueprints     │   │                  │      │
│  └────────┬─────────┘   └────────┬─────────┘      │
│           │                      │                │
│           └──────────┬───────────┘                │
│                      │                            │
└──────────────────────┼────────────────────────────┘
                       │ (Workflows trigger jobs)
                       ▼
┌───────────────────────────────────────────────────┐
│           Kubernetes Cluster (arc-*)              │
├───────────────────────────────────────────────────┤
│  Namespace: arc-systems                           │
│  ┌─────────────────────────────────────────────┐  │
│  │  ARC Controller                             │  │
│  │  ├─ Listener: arc-runner-set-1              │  │
│  │  ├─ Listener: arc-runner-set-2              │  │
│  │  └─ Listener: arc-runner-set-3              │  │
│  └─────────────────────────────────────────────┘  │
│                                                   │
│  Namespace: arc-runners                           │
│  ┌────────────┐  ┌────────────┐  ┌────────────┐   │
│  │ Runner 1   │  │ Runner 2   │  │ Runner 3   │   │
│  │  (100Gi)   │  │  (100Gi)   │  │  (100Gi)   │   │
│  │  PVC-1     │  │  PVC-2     │  │  PVC-3     │   │
│  └────────────┘  └────────────┘  └────────────┘   │
└───────────────────────────────────────────────────┘
```

## Runner Assignment Strategy

To maximize cache hit rates, we use "sticky" runner assignment:

| Runner Set | Target Repositories | Sticky Jobs (Cache Affinity) |
|-----------|-------------------|-----------------------------|
| `arc-runner-set-1` | artemis-theia-blueprints | Base + Haskell + Python |
| `arc-runner-set-2` | artemis-theia-blueprints | JavaScript + OCaml + Java-17 |
| `arc-runner-set-3` | artemis-theia-blueprints | C + Rust |
| All sets | theia-cloud | landing-page, operator, service |

## Performance

**Validated Results** (Test Image):
- Cold cache: ~2 minutes
- Warm cache: ~25 seconds
- **Improvement: 76% faster (4.3x speedup)**

**Expected Results** (Production Images):
- Cold cache: 15-20 minutes
- Warm cache: 5-8 minutes
- **Improvement: 60-70% faster**

## Documentation

- [Setup Guide](docs/SETUP.md) - Complete installation instructions
- [Architecture](docs/ARCHITECTURE.md) - System design and components
- [Troubleshooting](docs/TROUBLESHOOTING.md) - Common issues and solutions

## Related Projects

- [artemis-theia-blueprints](https://github.com/ls1intum/artemis-theia-blueprints) - Theia IDE images
- [theia-cloud](https://github.com/ls1intum/theia-cloud) - Theia Cloud platform
- [Actions Runner Controller](https://github.com/actions/actions-runner-controller) - Upstream ARC project
