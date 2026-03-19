# DevStrap — Open Tasks

## CI/CD Integration

**Priority:** Next major task
**Status:** Deferred — needs real testing, not documentation guesswork

Build and test an actual `.github/workflows/devstack.yml`, then document what worked.

Known issues to solve:
1. **Bind mount paths** — Generated docker-compose uses absolute host paths. CI runner workspace paths differ. Compose generator may need a relative-path mode.
2. **Image caching** — Playwright (~2GB) + MariaDB + WireMock + nginx. Without layer caching, every CI run pulls everything. Need registry caching or pre-baked images.
3. **Docker-in-Docker** — CI runners using Docker executors need DinD or socket mounting. Runner-specific, fragile.
4. **Artifact extraction** — Test results path is dynamic (timestamped run-id). CI needs a predictable path or a `latest` symlink.
5. **Startup race conditions** — `devstack.sh start` waits for healthchecks, but app init scripts may take longer. CI may need a readiness probe before running tests.

Deliverable: working GitHub Actions workflow + `docs/CI_CD.md` based on what actually works, not theory.
