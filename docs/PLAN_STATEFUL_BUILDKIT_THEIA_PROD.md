# Plan: Stateful BuildKit Workers on theia-prod

**Date:** 2026-03-12  
**Status:** Completed (2026-03-18)

## Final implemented outcome

- BuildKit workers are deployed on theia-prod in namespace `buildkit-exp`.
- StatefulSet `buildkitd` runs with:
  - `replicas: 7`
  - storage class `csi-rbd-sc`
  - PVC size `100Gi` per worker
  - preferred pod anti-affinity across hosts
- ARC build runner set used for this path:
  - `arc-buildkit-eduide-amd64`
- Runner env and workflow contract:
  - `BUILDKIT_NAMESPACE=buildkit-exp`
  - `BUILDKIT_NUM_WORKERS=7`
- Docker mirror endpoint aligned to Zot NodePort:
  - `http://131.159.88.117:30081`

## Deployed resources (theia-prod)

- `infra/theia-prod/buildkit-exp/namespace.yaml`
- `infra/theia-prod/buildkit-exp/service.yaml`
- `infra/theia-prod/buildkit-exp/configmap.yaml`
- `infra/theia-prod/buildkit-exp/statefulset.yaml`

## Verification snapshot

- `buildkitd-0..6` Running in namespace `buildkit-exp`
- 7 PVCs Bound on `csi-rbd-sc`
- headless service `buildkitd` present
- autoscaling runner set `arc-buildkit-eduide-amd64` active in `arc-runners`

## Notes

- This document is retained as a completion record.
- Historical experiment naming (`arc-runner-set-buildkit-exp`) has been superseded by `arc-buildkit-eduide-amd64`.
