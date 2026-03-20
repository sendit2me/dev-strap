# DevStrap — Open Tasks

## Completed

- [x] Catalog expansion (Phases 1-5): Python, Rust, Vite, NATS, MinIO, Adminer, Swagger UI, Prometheus, Grafana, Dozzle
- [x] Preset bundles: spa-api, api-only, full-stack, data-pipeline
- [x] Service auto-wiring (REDIS_URL, NATS_URL, S3_ENDPOINT, etc.)
- [x] Caddy v2 migration (replaced nginx as reverse proxy)
- [x] manifest.json contract for catalog and wiring rules

## CI/CD Integration

**Priority:** Next major task
**Status:** Deferred — needs real testing, not documentation guesswork

Build and test an actual `.github/workflows/devstack.yml`, then document what worked.

Known issues to solve:
1. **Bind mount paths** — Generated docker-compose uses absolute host paths. CI runner workspace paths differ. Compose generator may need a relative-path mode.
2. **Image caching** — Playwright (~2GB) + database + WireMock + Caddy. Without layer caching, every CI run pulls everything. Need registry caching or pre-baked images.
3. **Docker-in-Docker** — CI runners using Docker executors need DinD or socket mounting. Runner-specific, fragile.
4. **Artifact extraction** — Test results path is dynamic (timestamped run-id). CI needs a predictable path or a `latest` symlink.
5. **Startup race conditions** — `devstack.sh start` waits for healthchecks, but app init scripts may take longer. CI may need a readiness probe before running tests.

Deliverable: working GitHub Actions workflow + `docs/CI_CD.md` based on what actually works, not theory.

## Future Work

- **Caddy PKI replacement** — Replace the shell-based cert-gen with Caddy's built-in PKI module for automatic CA and certificate management.
- **SSR framework support** — Add templates for SSR frameworks (Next.js, Nuxt, SvelteKit) alongside the current Vite SPA frontend.
- **Multi-app stacks** — Support projects with multiple backend services (microservices) in a single dev-strap config.
- **Plugin system** — Allow third-party catalog entries without modifying the core manifest.
