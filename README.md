# Theia ARC Runners

Infrastructure-as-code for deploying **GitHub Actions self-hosted runners** using Actions Runner Controller (ARC).

## Architecture

**Stateless runners with Docker Registry v2 pull-through caches** for both Docker Hub and GHCR.

| Cluster | Architecture | Runners | Storage Class |
|---------|--------------|---------|---------------|
| theia-prod | AMD64 | `arc-runner-set-stateless` | `csi-rbd-sc` |
| parma | ARM64 | `arc-runner-set-stateless-arm` | `local-path` |

## Features

- Stateless Runner Scale Sets that scale 5-50 runners per cluster
- Docker Registry v2 pull-through caches for `docker.io` and `ghcr.io`
- Verdaccio npm registry cache for faster `yarn install` / `npm install`
- apt-cacher-ng for Ubuntu package caching
- Squid proxy with SSL bumping for HTTPS caching (VSCode extensions)
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
./scripts/deploy-amd.sh
```

### Deploy ARM64 Runners (parma)

```bash
kubectl config use-context parma
export GITHUB_PAT="ghp_xxxxxxxxxxxx"
./scripts/deploy-arm.sh
```

## Components

### Registry Mirrors

Each cluster has two Docker Registry v2 instances in `registry-mirror` namespace:

| Service | Upstream | Internal Address |
|---------|----------|------------------|
| `registry-mirror` | docker.io | `registry-mirror.registry-mirror.svc.cluster.local:5000` |
| `registry-mirror-ghcr` | ghcr.io | `registry-mirror-ghcr.registry-mirror.svc.cluster.local:5000` |

The DinD sidecar uses `--registry-mirror` flag to pull through the cache.

### Verdaccio (npm Cache)

Each cluster has a Verdaccio instance in `verdaccio` namespace:

| Service | Upstream | Internal Address |
|---------|----------|------------------|
| `verdaccio` | npmjs.org | `http://verdaccio.verdaccio.svc.cluster.local:4873` |

**Usage in Dockerfiles:**
```dockerfile
ARG NPM_REGISTRY=https://registry.npmjs.org
RUN yarn config set registry ${NPM_REGISTRY} && yarn install
```

Pass `--build-arg NPM_REGISTRY=http://verdaccio.verdaccio.svc.cluster.local:4873` when building on cluster runners.

### apt-cacher-ng (Ubuntu Package Cache)

Each cluster has an apt-cacher-ng instance in `apt-cacher-ng` namespace:

| Service | Purpose | Internal Address |
|---------|---------|------------------|
| `apt-cacher-ng` | Debian/Ubuntu packages | `http://apt-cacher-ng.apt-cacher-ng.svc.cluster.local:3142` |

**Usage in Dockerfiles:**
```dockerfile
ARG APT_HTTP_PROXY=""
RUN if [ -n "$APT_HTTP_PROXY" ]; then \
      echo "Acquire::http::Proxy \"$APT_HTTP_PROXY\";" > /etc/apt/apt.conf.d/01proxy; \
    fi
```

Pass `--build-arg APT_HTTP_PROXY=http://apt-cacher-ng.apt-cacher-ng.svc.cluster.local:3142` when building.

### Squid Proxy (HTTPS Caching)

Each cluster has a Squid proxy with SSL bumping in `squid` namespace:

| Service | Purpose | Internal Address |
|---------|---------|------------------|
| `squid` | HTTPS caching for VSCode extensions | HTTP: `http://squid.squid.svc.cluster.local:3128`<br>HTTPS: `http://squid.squid.svc.cluster.local:3129` |

**SSL Domains:** `.vsassets.io`, `.visualstudio.com`, `.open-vsx.org`, `.eclipsecontent.org`

**Usage in Dockerfiles:**
```dockerfile
ARG HTTPS_PROXY=""
RUN if [ -n "$HTTPS_PROXY" ]; then \
      # Download Squid CA certificate
      curl -o /usr/local/share/ca-certificates/squid-ca.crt http://squid.squid.svc.cluster.local:3128/squid-ca.crt && \
      update-ca-certificates; \
    fi
```

Pass `--build-arg HTTPS_PROXY=http://squid.squid.svc.cluster.local:3129` when building.

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
| `verdaccio.yaml` | npm cache | theia-prod |
| `verdaccio-parma.yaml` | npm cache | parma |
| `apt-cacher-ng.yaml` | apt cache | theia-prod |
| `apt-cacher-ng-parma.yaml` | apt cache | parma |
| `squid-cache.yaml` | HTTPS proxy cache | theia-prod |
| `squid-cache-parma.yaml` | HTTPS proxy cache | parma |
| `values-runner-set-stateless.yaml` | AMD64 runner config | theia-prod |
| `values-runner-set-stateless-arm.yaml` | ARM64 runner config | parma |
| `rbac-runner.yaml` | ServiceAccount for runners | both |

## Documentation

- [Architecture](docs/ARCHITECTURE_V2.md) - System design and caching strategy
- [Setup Guide](docs/SETUP.md) - Detailed installation instructions
- [Troubleshooting](docs/TROUBLESHOOTING.md) - Common issues and solutions

## Related Projects

- [artemis-theia-blueprints](https://github.com/ls1intum/artemis-theia-blueprints) - Theia IDE images
- [ls1intum/.github](https://github.com/ls1intum/.github) - Reusable workflows with `use-cluster-cache` support
- [Actions Runner Controller](https://github.com/actions/actions-runner-controller) - Upstream ARC project
