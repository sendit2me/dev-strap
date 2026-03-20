# Catalog Expansion Implementation Plan

> **Generated from**: Research documents 01-10 in `docs/research/`
> **Date**: 2026-03-20 (revised after Caddy research)
> **Contract impact**: All changes are v1-compatible (additive). No breaking changes.

---

## Status

| Phase | Status | Commit |
|-------|--------|--------|
| Phase 1: Foundation | DONE | `4643faa` |
| Phase 2: New Services (NATS, MinIO, Adminer, Swagger UI) | DONE | `4643faa` |
| Phase 3: New Languages (Python/FastAPI, Rust) | DONE | `4643faa` |
| Phase 4: Presets & Auto-Wiring | DONE | `9ea545a` |
| Phase 5a: Caddy Swap (replace nginx) | NEXT | |
| Phase 5b: Frontend/Vite (leveraging Caddy) | NEXT | |
| Phase 6: Documentation | PENDING | |

---

## Decision Log

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Frontend category | Separate `frontend` category | Semantic clarity, cleaner auto-wiring, better PowerHouse UX |
| Frontend template dir | `templates/frontends/vite/` | Reinforces frontend/backend distinction |
| **Reverse proxy** | **Caddy v2 replaces nginx** | Eliminates all protocol branching (FastCGI, WebSocket, gRPC handled natively). Generator shrinks from ~207 to ~130 lines, config from ~80 to ~20 lines. |
| **Vite routing** | **Through Caddy (path-based)** — revised from direct exposure | Caddy handles WebSocket HMR natively, so original reason for direct exposure is gone. Single entry point, no CORS. |
| **PHP-FPM edge case** | **Eliminated by Caddy** | `php_fastcgi` handles protocol translation; Vite wiring doesn't need to know about it |
| **proxy_protocol field** | **Not needed** | With Caddy, there is no protocol branching. One exception (PHP) doesn't justify an abstraction; Caddy handles it natively. Trigger: add the field if/when a second non-HTTP protocol appears that Caddy can't handle. |
| Contract version | Stay v1, all additions are non-breaking | Presets, wiring, port detection, new categories are all additive |
| Auto-wiring approach | Top-level `wiring` array in manifest (Proposal C from research 04) | Keeps `defaults` flat/scalar, declarative, no contract version bump |
| Python package manager | `uv` (by Astral) | 10-100x faster than pip, excellent Docker layer caching |
| Rust build cache | Persistent `cargo-target` volume | Without it, 5-30 min recompile on every restart |
| Beaver / DBeaver | Adminer chosen over CloudBeaver | CloudBeaver: 500MB image, 400MB RAM, complex config. Adminer: 30MB, 10MB RAM, zero config. |
| **Cert restart** | **Acceptable** | New mock domains require cert regen → Caddy restart. Caddy is stateless; lost packets during dev restart are fine. |

---

## Phase 1: Foundation Tightening

*Goal: Harden the base so the catalog can grow safely.*

### 1.1 Port Collision Detection
- **What**: Add validation check 11 to `validate_bootstrap_payload()` in `devstack.sh`
- **How**: Extract ports from all selected items' resolved values (defaults merged with overrides), match keys named `port` or `*_port`, flag duplicates
- **Error code**: `PORT_CONFLICT`
- **Files**: `devstack.sh`, `tests/contract/test-contract.sh`, 5 new fixture files
- **Research**: `04-contract-evolution.md` §1

### 1.2 Volume Accumulator Pattern
- **What**: Add `EXTRAS_VOLUMES` accumulator in `core/compose/generate.sh` so extras can declare named volumes
- **How**: As each extra is processed, append volume declarations to `EXTRAS_VOLUMES`, write them in the `volumes:` footer
- **Why**: NATS and MinIO need persistent data volumes. Current pattern only handles app-type volumes.
- **Files**: `core/compose/generate.sh`
- **Research**: `01-new-services.md`

### 1.3 App Volume Case Statement
- **What**: Convert the Go-only volume `if` (line ~148) to a `case` statement
- **How**: `case "${APP_TYPE}" in go) ... ;; python-fastapi) ... ;; rust) ... ;; esac`
- **Why**: Unblocks Python and Rust templates without more `if` spaghetti
- **Files**: `core/compose/generate.sh`
- **Research**: `02-language-templates.md`

### 1.4 Manifest Structure for New Categories
- **What**: Add `frontend` category and `services`/`tooling` items to `contract/manifest.json`
- **How**: Additive — new keys, no existing keys changed
- **Files**: `contract/manifest.json`

---

## Phase 2: Catalog Expansion — New Services

*Goal: Add the four proposed services. Each is independent.*

### 2.1 NATS (Messaging/Streaming)
- **Image**: `nats:2-alpine`
- **Ports**: `client_port: 4222`, `monitor_port: 8222`
- **Config**: JetStream via `--jetstream --store_dir /data`
- **Health**: `wget --spider http://127.0.0.1:8222/healthz`
- **Volume**: `${PROJECT_NAME}-nats-data:/data`
- **Category**: `services`, requires `app.*`
- **Files**: `templates/extras/nats/service.yml`, `contract/manifest.json`, `core/compose/generate.sh` (sed + volume)
- **Research**: `01-new-services.md` §1

### 2.2 MinIO (S3-Compatible Storage)
- **Image**: `minio/minio:latest`
- **Ports**: `api_port: 9000`, `console_port: 9001`
- **Config**: `server /data --console-address ":9001"`
- **Health**: `mc ready local`
- **Volume**: `${PROJECT_NAME}-minio-data:/data`
- **Category**: `services`, no requires (useful standalone)
- **Credentials**: `MINIO_ROOT_USER=minioadmin`, `MINIO_ROOT_PASSWORD=minioadmin`
- **Files**: `templates/extras/minio/service.yml`, `contract/manifest.json`, `core/compose/generate.sh`
- **Research**: `01-new-services.md` §2

### 2.3 Adminer (Database UI)
- **Image**: `adminer:latest`
- **Port**: `port: 8083`
- **Config**: `ADMINER_DEFAULT_SERVER=db` (auto-fills login)
- **Health**: `wget -qO /dev/null http://localhost:8080/`
- **Volume**: None (stateless)
- **Category**: `tooling`, requires `database.*`
- **Guard**: Skip generation when `DB_TYPE=none`
- **Files**: `templates/extras/db-ui/service.yml`, `contract/manifest.json`, `core/compose/generate.sh`
- **Research**: `01-new-services.md` §3

### 2.4 Swagger UI (API Documentation)
- **Image**: `swaggerapi/swagger-ui:latest`
- **Port**: `port: 8084`
- **Config**: Mount spec file via `SWAGGER_JSON=/spec/openapi.json`
- **Health**: `curl -sf http://localhost:8080/`
- **Volume**: None
- **Category**: `tooling`, requires `app.*`
- **Note**: `API_URL` is browser-side, can't use Docker hostnames — use mounted file instead
- **Files**: `templates/extras/swagger-ui/service.yml`, `contract/manifest.json`, `core/compose/generate.sh`
- **Research**: `01-new-services.md` §4

---

## Phase 3: Catalog Expansion — New Language Templates

*Goal: Add Python and Rust app templates. Each is independent.*

### 3.1 Python (FastAPI)
- **Image**: `python:3.12-slim` (NOT Alpine — musl breaks C-extension wheels)
- **Package mgr**: `uv` via `COPY --from=ghcr.io/astral-sh/uv:latest`
- **File watcher**: `uvicorn --reload` (built-in watchfiles)
- **Port**: 3000 (matches nginx default)
- **CA certs**: `REQUESTS_CA_BUNDLE=/certs/ca.crt`, `SSL_CERT_FILE=/certs/ca.crt`, `CURL_CA_BUNDLE=/certs/ca.crt` + `update-ca-certificates` in init.sh
- **Volume**: `${PROJECT_NAME}-python-cache` for pip/uv cache
- **Files**: `templates/apps/python-fastapi/Dockerfile`, `service.yml`, `contract/manifest.json`, `core/compose/generate.sh` (case stmt)
- **Research**: `02-language-templates.md` §1

### 3.2 Rust
- **Image**: `rust:1.83-slim` (NOT Alpine — glibc avoids openssl/ring issues)
- **File watcher**: `cargo-watch`
- **Port**: 3000
- **CA certs**: `SSL_CERT_FILE=/certs/ca.crt` (works with rustls + native-tls)
- **Volumes**: `${PROJECT_NAME}-cargo-registry`, `${PROJECT_NAME}-cargo-target` (critical: 1-10 GB build cache)
- **Files**: `templates/apps/rust/Dockerfile`, `service.yml`, `contract/manifest.json`, `core/compose/generate.sh` (case stmt)
- **Research**: `02-language-templates.md` §2

---

## Phase 4: Enhanced UX — Presets & Wiring

*Goal: Make the catalog faster to use. Additive contract extensions.*

### 4.1 Preset Bundles
- **What**: Add top-level `presets` key to manifest/options response
- **How**: Each preset defines `selections` (pre-filled items) and `prompts` (categories requiring user input)
- **Contract**: Presets are UI-only. `--bootstrap` never receives a preset identifier — PowerHouse expands before sending.
- **Presets**:
  | Key | Label | Pre-selects | User chooses |
  |-----|-------|-------------|--------------|
  | `spa-api` | SPA + API | vite, postgres, qa, wiremock | backend language |
  | `api-only` | API Service | postgres, redis, qa, swagger-ui | backend language |
  | `full-stack` | Full Stack + Observability | vite, postgres, redis, qa, prometheus, grafana, dozzle | backend language |
  | `data-pipeline` | Data Pipeline | python-fastapi, postgres, nats, minio | — |
- **Files**: `contract/manifest.json`, `devstack.sh` (options output), test fixtures
- **Research**: `04-contract-evolution.md` §2, `05-stack-combinations.md` §3

### 4.2 Auto-Wiring Rules
- **What**: Add top-level `wiring` array to manifest — declarative rules that fire when items are co-selected
- **How**: Each rule has a `when` condition (items present) and `set` actions (env vars injected into target service)
- **Example rules**:
  ```
  when: frontend.vite + app.* → set VITE_API_URL=http://app:{app.port}
  when: tooling.db-ui + database.* → set ADMINER_DEFAULT_SERVER=db
  when: app.* + services.nats → set NATS_URL=nats://nats:4222
  when: app.* + services.minio → set AWS_ENDPOINT_URL=http://minio:9000
  ```
- **Contract**: Non-breaking addition (new top-level key, consumers can ignore it)
- **Files**: `contract/manifest.json`, `core/compose/generate.sh` (apply wiring during generation)
- **Research**: `04-contract-evolution.md` §4, `05-stack-combinations.md` §2

---

## Phase 5a: Caddy Swap (replace nginx)

*Goal: Replace nginx with Caddy v2. Eliminates all protocol branching.*

> **Why the swap**: nginx requires separate directives for HTTP (`proxy_pass`), FastCGI (`fastcgi_pass`), gRPC (`grpc_pass`), and WebSocket (manual upgrade headers). This creates protocol special-casing in the generator. Caddy's `reverse_proxy` handles HTTP, WebSocket, and gRPC automatically. `php_fastcgi` handles PHP-FPM. Zero branching.
>
> **Research**: `07-traefik-v3-evaluation.md` (Traefik rejected), `08-caddy-deep-dive.md`, `09-caddy-generator-design.md`

### 5a.1 Caddyfile Generator
- **What**: Create `core/caddy/generate-caddyfile.sh` (~130 lines, replacing nginx's ~207)
- **How**: Same input pattern (reads project.env + mocks/*/domains), outputs `.generated/Caddyfile`
- **App routing**: `php_fastcgi app:9000` for PHP, `reverse_proxy app:3000` for all others. No protocol branching — just a simple app-type check for the Caddy directive name.
- **Mock interception**: Same flow — TLS termination, `header_up X-Original-Host {http.request.host}`, proxy to WireMock
- **TLS**: `tls /certs/server.crt /certs/server.key` + `auto_https off` (use our certs, not ACME)
- **Output**: ~20 lines of Caddyfile vs ~80 lines of nginx.conf
- **Files**: `core/caddy/generate-caddyfile.sh` (new)

### 5a.2 Compose Generator Update
- **What**: Change `web` service from nginx to Caddy
- **Image**: `caddy:2-alpine` (replaces `nginx:alpine`)
- **Config mount**: `.generated/Caddyfile:/etc/caddy/Caddyfile:ro` (replaces nginx.conf mount)
- **Cert mount**: `/certs` (same path — Caddy reads from there)
- **Health check**: `wget --spider http://localhost:2019/config/` (Caddy admin API)
- **Service name stays `web`**: Zero template changes needed
- **Files**: `core/compose/generate.sh` (modify web service block)

### 5a.3 devstack.sh Updates
- **What**: Point `cmd_generate()` to new Caddy generator (~4 lines changed)
- **Cert-gen stays**: Caddy refuses to start without certs; existing depends_on handles ordering
- **Cert-gen slimming** (optional): Drop JKS generation, switch from `eclipse-temurin:17-alpine` (~200MB) to `alpine:3` (~7MB)
- **Operational note**: New mock domains require cert regen → `./devstack.sh restart` (same as nginx). Caddy is stateless; restart is clean.
- **Files**: `devstack.sh`

### 5a.4 Retire nginx Generator
- **What**: Remove or archive `core/nginx/generate-conf.sh`
- **Keep tests**: All existing tests should pass with Caddy (same service names, same ports)

---

## Phase 5b: Frontend/Vite (leveraging Caddy)

*Goal: Support frontend + backend simultaneously. Caddy makes this clean.*

> **Key change from original plan**: Everything routes through Caddy (not direct port exposure). Caddy handles WebSocket HMR natively, so the original reason for direct exposure is gone. Single entry point on `localhost:8080`.
>
> **Research**: `03-vite-multiapp-architecture.md` (original), `10-integrated-caddy-vite-design.md` (revised)

### 5b.1 Vite Template
- **Dir**: `templates/frontends/vite/`
- **Dockerfile**: `node:22-alpine`, `npm install`, `CMD ["npx", "vite", "--host", "0.0.0.0"]`
- **service.yml**: Service named `frontend`, NO host port exposure (Caddy proxies), `node_modules` anonymous volume, `VITE_API_BASE=/api` env var
- **HMR**: Caddy forwards WebSocket upgrade automatically; set `VITE_HMR_PORT=${HTTPS_PORT}` for client-side connection
- **Files**: `templates/frontends/vite/Dockerfile`, `service.yml`

### 5b.2 Compose Generator Frontend Section
- **What**: Add frontend service block (~20 new lines in compose generator)
- **How**: Conditional on `FRONTEND_TYPE != none` — read template, substitute vars, write to compose
- **Caddy depends_on**: Add `frontend` to Caddy's depends_on when present
- **Files**: `core/compose/generate.sh`

### 5b.3 Caddyfile Path-Based Routing
- **What**: When frontend is configured, Caddy routes: `/api/*` → backend, `/*` → frontend
- **How**: Add conditional block in Caddyfile generator
- **HMR**: Caddy's `reverse_proxy` forwards WebSocket upgrade headers automatically
- **PHP-FPM edge case**: Gone — Caddy handles `php_fastcgi` transparently, Vite doesn't need to know about it
- **Files**: `core/caddy/generate-caddyfile.sh`

### 5b.4 devstack.sh Frontend Support
- **What**: Extract frontend from bootstrap payload, scaffold frontend directory
- **generate_from_bootstrap()**: Extract `frontend_type`, write `FRONTEND_TYPE`, `FRONTEND_SOURCE`, `FRONTEND_PORT` to project.env, copy Dockerfile from template
- **cmd_start()**: Frontend directory existence check + summary output
- **Files**: `devstack.sh`

### 5b.5 Wiring Rule Updates
- **What**: Update Vite wiring rule — `proxy_target` becomes `api_base = /api`
- **Why**: Since Caddy handles routing, Vite doesn't need a full URL to the backend. It just needs the path prefix.
- **PHP edge case wiring**: Not needed — Caddy handles FastCGI natively
- **Files**: `contract/manifest.json`

### 5b.6 Tests
- **Fixtures**: Frontend bootstrap payloads
- **Assertions**: Verify compose output includes `frontend` service, Caddyfile has path-based routing, wiring resolves correctly
- **Files**: `tests/contract/test-contract.sh`, `tests/contract/fixtures/`

### 5b.7 Fix app Multi-Select (DONE in Phase 1.4)
- Already changed `app` to `selection: single` in manifest

---

## Phase 6: Documentation & Communication

*Goal: Keep the PowerHouse team informed. Ship docs with each phase.*

### 6.1 Contract Changelog
- Add `## Changelog` section to `DEVSTRAP-POWERHOUSE-CONTRACT.md`
- Document every addition per phase with date

### 6.2 Migration Notes
- All changes are additive (v1 compatible)
- PowerHouse can ignore new keys (`presets`, `wiring`, `frontend` category) until ready
- Port collision errors are new but follow existing error format
- nginx → Caddy is an internal change, no contract impact

### 6.3 Updated Docs
- `docs/ADDING_SERVICES.md` — update with NATS/MinIO examples
- `docs/CREATING_TEMPLATES.md` — add Python/Rust sections
- `README.md` — update catalog table, note Caddy as reverse proxy

---

## Execution Order

```
Phase 1 (Foundation) ✅
├── 1.1 Port collision detection
├── 1.2 Volume accumulator pattern
├── 1.3 App volume case statement
└── 1.4 Manifest new categories
         │
Phase 2 (Services) ✅ ──────────── Phase 3 (Languages) ✅
├── 2.1 NATS                        ├── 3.1 Python/FastAPI
├── 2.2 MinIO                       └── 3.2 Rust
├── 2.3 Adminer                          │
└── 2.4 Swagger UI                       │
         │                               │
         └───────────┬───────────────────┘
                     │
Phase 4 (Presets & Wiring) ✅
├── 4.1 Preset bundles
└── 4.2 Auto-wiring rules
         │
Phase 5a (Caddy Swap) ← NEXT
├── 5a.1 Caddyfile generator
├── 5a.2 Compose generator update
├── 5a.3 devstack.sh updates
└── 5a.4 Retire nginx generator
         │
Phase 5b (Frontend/Vite)
├── 5b.1 Vite template
├── 5b.2 Compose frontend section
├── 5b.3 Caddyfile path-based routing
├── 5b.4 devstack.sh frontend support
├── 5b.5 Wiring rule updates
└── 5b.6 Tests
         │
Phase 6 (Docs)
└── Ships incrementally with each phase
```

Phases 2 and 3 ran in parallel. 5a → 5b is sequential (Caddy first, then frontend on top).

---

## Port Allocation Map (Final State)

| Service | Port | Category | Variable |
|---------|------|----------|----------|
| App backends (Node/Go/Python/Rust) | 3000 | app | internal only |
| App (PHP-FPM) | 9000 | app | internal only |
| Vite frontend | 5173 | frontend | internal (Caddy proxies) |
| PostgreSQL | 5432 | database | internal only |
| MariaDB | 3306 | database | internal only |
| Redis | 6379 | services | internal only |
| Mailpit SMTP | 1025 | services | internal only |
| Mailpit UI | 8025 | services | `MAILPIT_PORT` |
| NATS client | 4222 | services | `NATS_PORT` |
| NATS monitor | 8222 | services | `NATS_MONITOR_PORT` |
| MinIO API | 9000 | services | `MINIO_PORT` |
| MinIO Console | 9001 | services | `MINIO_CONSOLE_PORT` |
| HTTP (Caddy) | 8080 | core | `HTTP_PORT` |
| HTTPS (Caddy) | 8443 | core | `HTTPS_PORT` |
| Caddy Admin API | 2019 | core | internal only |
| WireMock | — | tooling | internal only |
| QA Dashboard | 8082 | tooling | `TEST_DASHBOARD_PORT` |
| Adminer | 8083 | tooling | `ADMINER_PORT` |
| Swagger UI | 8084 | tooling | `SWAGGER_PORT` |
| Prometheus | 9090 | observability | `PROMETHEUS_PORT` |
| Grafana | 3001 | observability | `GRAFANA_PORT` |
| Dozzle | 9999 | observability | `DOZZLE_PORT` |

No collisions in the default configuration.

---

## Resource Estimates (from research 05)

| Preset | Services | Idle RAM | Recommended System RAM |
|--------|----------|----------|----------------------|
| minimal | 3-4 | ~200 MB | 8 GB |
| spa-api | 7-8 | ~500 MB | 8 GB |
| api-only | 6-7 | ~400 MB | 8 GB |
| full-stack | 10-12 | ~1.1 GB | 16 GB |
| data-pipeline | 6-7 | ~500 MB | 8 GB |
