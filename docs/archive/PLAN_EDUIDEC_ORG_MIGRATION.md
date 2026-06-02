# Plan: EduIDE Org Runner Migration

**Status:** Completed (2026-03-18)  
**Date:** 2026-03-09

## Final implemented outcome

- EduIDE is served by one BuildKit runner set per cluster:
  - `arc-buildkit-eduide-amd64` (theia-prod)
  - `arc-buildkit-eduide-arm64` (parma)
- Legacy ls1intum-focused and intermediate EduIDEC split releases were removed from active deployment.
- Dedicated `theia-arc-runners-eduidec` release is no longer used.

## Current naming and ownership

| Resource | theia-prod | parma |
|----------|------------|-------|
| Active runner set | `arc-buildkit-eduide-amd64` | `arc-buildkit-eduide-arm64` |
| BuildKit namespace | `buildkit-exp` | `buildkit` |
| GitHub org URL | `https://github.com/EduIDE` | `https://github.com/EduIDE` |
| Auth secret | `github-arc-secret-eduidec` | `github-arc-secret-eduidec` |

## CI workflow implication

Workflows must target one of these labels explicitly:

```yaml
runs-on: arc-buildkit-eduide-amd64
# or
runs-on: arc-buildkit-eduide-arm64
```

No automatic fallback mode is assumed by this migration record.

## Notes

- This document is retained as historical completion evidence.
- Previous overlay/release strategy sections were intentionally removed to avoid stale guidance.
