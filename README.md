# Theia ARC Runners

Infrastructure-as-code for deploying **GitHub Actions self-hosted runners** using Actions Runner Controller (ARC).

## Architecture

**Stateless runners with Docker Registry v2 pull-through caches** for both Docker Hub and GHCR.

| Cluster | Architecture | Runners | Storage Class |
|---------|--------------|---------|---------------|
| theia-prod | AMD64 | `arc-runner-set-stateless` | `csi-rbd-sc` |
| parma | ARM64 | `arc-runner-set-arm64` | `local-path` |

## Features

- Stateless Runner Scale Sets that scale 0-10 runners per cluster
- Docker Registry v2 pull-through caches for `docker.io` and `ghcr.io`
- 30-day TTL on cached layers (720h)
- 200GB cache storage per registry per cluster
- BuildKit cache layers pushed to `ghcr.io/.../build-cache`
- Organization-wide runners for `ls1intum` repositories

## Quick Start

### Prerequisites

- `kubectl` configured for target cluster
- Helm 3.14+
- `GITHUB_PAT` environment variable (org admin token)

### Deploy AMD64 Runners (theia-prod)

```bash
kubectl config use-context theia-prod
export GITHUB_PAT="ghp_xxxxxxxxxxxx"
./scripts/deploy-amd.sh stateless
```

### Deploy ARM64 Runners (parma)

```bash
kubectl config use-context parma
export GITHUB_PAT="ghp_xxxxxxxxxxxx"
./scripts/deploy-arm.sh arm64
```

## Components

### Registry Mirrors

Each cluster has two Docker Registry v2 instances in `registry-mirror` namespace:

| Service | Upstream | Internal Address |
|---------|----------|------------------|
| `registry-mirror` | docker.io | `registry-mirror.registry-mirror.svc.cluster.local:5000` |
| `registry-mirror-ghcr` | ghcr.io | `registry-mirror-ghcr.registry-mirror.svc.cluster.local:5000` |

The DinD sidecar uses `--registry-mirror` flag to pull through the cache.

### Runner Configuration

Runners use manual DinD sidecar configuration with:
- `emptyDir` volumes (stateless)
- Registry mirror for Docker Hub pulls
- BuildKit configured via workflow to use GHCR mirror

## Manifests

| File | Purpose | Cluster |
|------|---------|---------|
| `registry-mirror.yaml` | Docker Hub cache | theia-prod |
| `registry-mirror-ghcr.yaml` | GHCR cache | theia-prod |
| `registry-mirror-parma.yaml` | Docker Hub cache | parma |
| `registry-mirror-ghcr-parma.yaml` | GHCR cache | parma |
| `values-runner-set-stateless.yaml` | AMD64 runner config | theia-prod |
| `values-runner-set-arm64.yaml` | ARM64 runner config | parma |
| `rbac-runner.yaml` | ServiceAccount for runners | both |

## Documentation

- [Architecture](docs/ARCHITECTURE_V2.md) - System design and caching strategy
- [Setup Guide](docs/SETUP.md) - Detailed installation instructions
- [Troubleshooting](docs/TROUBLESHOOTING.md) - Common issues and solutions

## Related Projects

- [artemis-theia-blueprints](https://github.com/ls1intum/artemis-theia-blueprints) - Theia IDE images
- [ls1intum/.github](https://github.com/ls1intum/.github) - Reusable workflows with `use-cluster-cache` support
- [Actions Runner Controller](https://github.com/actions/actions-runner-controller) - Upstream ARC project
