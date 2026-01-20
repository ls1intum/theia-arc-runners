# Theia ARC Runners

Infrastructure-as-code for deploying **GitHub Actions self-hosted runners** using Actions Runner Controller (ARC).

We have transitioned from **stateful (PVC-based)** runners to **stateless runners with transparent registry caching** and a local Harbor mirror.

## Features

- ✅ **Stateless Runner Scale Set** (`arc-runner-set-stateless`) that scales horizontally (up to 10 runners).
- ✅ **Transparent Registry Caching** using Harbor as a pull-through cache for `docker.io` and `ghcr.io`.
- ✅ **Optimized Build Pipelines** leveraging Docker's `cache-from` / `cache-to` (Registry Cache) for speed.
- ✅ **Automated GitHub Actions deployment** or manual deployment via script.
- ✅ **Organization-wide runners** for `ls1intum` repositories.

## Quick Start

### Prerequisites

- Kubernetes cluster (same cluster as Theia Cloud recommended)
- `kubectl` configured for your cluster
- Helm 3.14+ installed
- GITHUB_PAT environment variable set (or secret created manually)

### Option 1: GitHub Actions Deployment (Recommended)

1. **Configure GitHub Environment**:
   - Create environment named `arc-runners` in this repository settings
   - Add secrets:
     - `KUBECONFIG`: Kubernetes cluster configuration (contents of ~/.kube/config)
     - `GH_PAT`: GitHub Personal Access Token
   - Enable protection rules if desired (e.g., require manual approval)

2. **Trigger Deployment**:
   - Go to **Actions** → **Manual Deployment**
   - Select runner set to deploy: `stateless`
   - Click **Run workflow**

### Option 2: Manual Deployment

You can deploy directly from your local machine using the provided script.

```bash
# Set your GitHub PAT
export GITHUB_PAT="ghp_xxxxxxxxxxxx"

# Deploy stateless runner set
./scripts/deploy.sh stateless
```

## Architecture

The system deploys a single, scalable runner set. Runners are ephemeral and stateless, meaning they start with a clean slate for every job. Caching is handled via:

1.  **Registry Caching:** BuildKit pushes cache layers to `ghcr.io/.../build-cache`.
2.  **Harbor Mirror:** A local Harbor instance acts as a pull-through cache for base images (e.g., `node:22`), avoiding repeated internet downloads.

## Performance

- **Stateless + Registry Cache:** Comparable to warm stateful runners for build steps, but significantly more scalable and resilient.
- **Base Image Pulls:** < 5s (cached in Harbor/Local Network) vs 30-60s (Internet).
- **Dependency Caching:** Handled via Docker BuildKit (`--mount=type=cache`).

## Documentation

- [Setup Guide](docs/SETUP.md) - Complete installation instructions
- [Architecture](docs/ARCHITECTURE.md) - System design and components
- [Troubleshooting](docs/TROUBLESHOOTING.md) - Common issues and solutions

## Related Projects

- [artemis-theia-blueprints](https://github.com/ls1intum/artemis-theia-blueprints) - Theia IDE images
- [theia-cloud](https://github.com/ls1intum/theia-cloud) - Theia Cloud platform
- [Actions Runner Controller](https://github.com/actions/actions-runner-controller) - Upstream ARC project
