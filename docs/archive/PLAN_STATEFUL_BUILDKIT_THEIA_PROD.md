# Plan: Stateful BuildKit Workers on theia-prod

**Date:** 2026-03-12  
**Status:** Completed (2026-03-18)

## Final implemented outcome

- BuildKit workers are deployed on theia-prod in namespace `buildkit`.
- StatefulSet `buildkitd` runs with:
  - `replicas: 7`
  - storage class `csi-rbd-sc`
  - PVC size `500Gi` per worker
  - preferred pod anti-affinity across hosts
- ARC build runner set used for this path:
  - `arc-buildkit-eduide-theiaprod-amd64`
- Runner env and workflow contract:
  - `BUILDKIT_NAMESPACE=buildkit`
  - `BUILDKIT_NUM_WORKERS=7`
- Docker mirror endpoint aligned to Zot NodePort:
  - `http://131.159.88.117:30081`

## Deployed resources (theia-prod)

- `infra/theia-prod/buildkit/namespace.yaml`
- `infra/theia-prod/buildkit/service.yaml`
- `infra/theia-prod/buildkit/configmap.yaml`
- `infra/theia-prod/buildkit/statefulset.yaml`

## Verification snapshot

- `buildkitd-0..6` Running in namespace `buildkit`
- 7 PVCs Bound on `csi-rbd-sc`
- headless service `buildkitd` present
- autoscaling runner set `arc-buildkit-eduide-theiaprod-amd64` active in `arc-runners`

## Notes

- This document is retained as a completion record.
- Historical experiment naming (`arc-runner-set-buildkit`) has been superseded by `arc-buildkit-eduide-theiaprod-amd64`.
