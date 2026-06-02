# Zot Mirror vs Docker Hub Subscription

## Current State

The current setup runs Zot as a Docker Hub pull-through cache on parma. Runner clusters use it through the shared NodePort `131.159.88.117:30081`; parma BuildKit can also use the in-cluster service.

Zot exists mainly to avoid Docker Hub pull rate limits for CI image pulls. GitHub Container Registry does not create the same pull-rate pressure in this setup, so this tradeoff is primarily about `docker.io` traffic.

The Docker Hub credentials used for Zot are currently treated as burner credentials. Do not commit them to this repository.

## Why Keep Zot

- Central Docker Hub cache for all runner clusters.
- Avoids repeating Docker Hub credentials across all runner pods or BuildKit workers.
- Reduces external Docker Hub pulls on cache hits.
- Keeps pull-through behavior transparent for workflows through `--registry-mirror`.

## Why Consider Docker Hub Team

If the setup scales to many more image pulls, a paid Docker Hub Team plan may be simpler than operating a self-hosted mirror. Docker currently lists Team at $15/user/month on annual billing and $16/user/month on monthly billing.

With a dedicated Docker Hub CI user, the token could be injected directly into the BuildKit runner environment or BuildKit configuration. Because BuildKit workers are stateful, repeated image pulls should still be less frequent than with fully ephemeral builders.

The operational upside would be less infrastructure to maintain:

- no standalone Zot release;
- no Zot PVC lifecycle;
- no Zot NodePort dependency;
- no mirror-specific troubleshooting;
- fewer moving parts during cluster reinstall.

## Tradeoff

Zot is cheaper in direct subscription cost and gives a shared cache, but it adds infrastructure that has to be maintained and tested. A Docker Hub Team account adds recurring cost, but may be operationally cleaner if CI usage grows and one dedicated CI user is enough.

## Recommendation

Keep Zot for now. It is already installed, documented, and working.

Revisit the Docker Hub Team option if either of these becomes true:

- Zot becomes a recurring maintenance burden.
- Docker Hub pull volume grows enough that a paid CI user is cheaper than maintaining the mirror.

If the team moves to Docker Hub Team later, make it a deliberate migration: update BuildKit/runner credentials, remove Zot from the install path, and validate a fresh reinstall without `zot-system`.
