# Plan: Replace Harbor with Zot Registry Pull-Through Cache

**Date:** 2026-03-02  
**Status:** Completed (2026-03-18)

## Final implemented outcome

- Harbor-based caching was fully removed.
- Zot is the sole Docker Hub pull-through cache.
- Zot now runs as standalone release:
  - release: `theia-zot`
  - namespace: `zot-system`
  - location: parma cluster
  - storage: Longhorn PVC (`250Gi`)
  - service: NodePort `30081`
- Both runner clusters use the same mirror endpoint:
  - `http://131.159.88.117:30081`

## Runner mirror configuration (current)

- DinD args in active runner sets include:
  - `--registry-mirror=http://131.159.88.117:30081`
  - `--insecure-registry=131.159.88.117:30081`

## BuildKit mirror configuration (current)

- theia-prod BuildKit configmap (`buildkit-exp`):
  - `docker.io` mirror → `http://131.159.88.117:30081`
- parma BuildKit configmap (`buildkit`):
  - `docker.io` mirror → `http://theia-zot.zot-system.svc.cluster.local:5000`

## Operational notes from rollout

- Existing Docker Hub credential secret content was preserved and re-applied in `zot-system`.
- A Zot startup issue (`failed to create a new hot reloader`) was mitigated by raising node inotify limits.

## Historical note

This file is kept as a concise migration completion record. Detailed transition steps and Harbor-era references were intentionally removed to keep docs aligned with the current platform state.
