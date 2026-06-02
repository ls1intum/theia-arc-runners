# Plan: Migrate Zot from theia-prod to parma

**Date:** 2026-03-12
**Status:** Completed (2026-03-18)

## Final state

- Zot now runs as a standalone Helm release on parma:
  - release: `theia-zot`
  - namespace: `zot-system`
  - storage class: `longhorn`
  - service: `NodePort 30081`
- ARC runner sets now use the parma Zot endpoint:
  - `http://131.159.88.117:30081`
- Zot is no longer deployed via `theia-arc-bundle` in `arc-systems`.

## Notes

- Migration retained the existing `zot-dockerhub-credentials` secret content and re-created it in `zot-system`.
- During rollout, Zot initially crash-looped due to low `fs.inotify.max_user_instances` on parma node.
  Temporary node-level tuning to `1024` resolved startup.
- Keep this file as historical migration record.
