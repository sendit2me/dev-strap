# Catalog Expansion Implementation Plan

> **Generated from**: Research documents 01-05 in `docs/research/`
> **Date**: 2026-03-20
> **Contract impact**: All changes are v1-compatible (additive). No breaking changes.

---

## Decision Log

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Frontend category | Separate `frontend` category | Semantic clarity, cleaner auto-wiring, better PowerHouse UX |
| Frontend template dir | `templates/frontends/vite/` | Reinforces frontend/backend distinction |
| Vite port exposure | Direct (5173), not proxied through nginx | Avoids HMR/WebSocket complexity, matches standard Vite workflow |
| Contract version | Stay v1, all additions are non-breaking | Presets, wiring, port detection, new categories are all additive |
| Auto-wiring approach | Top-level `wiring` array in manifest (Proposal C from research 04) | Keeps `defaults` flat/scalar, declarative, no contract version bump |
| Python package manager | `uv` (by Astral) | 10-100x faster than pip, excellent Docker layer caching |
| Rust build cache | Persistent `cargo-target` volume | Without it, 5-30 min recompile on every restart |
| Beaver | Deferred — no clear match found | Needs clarification from user |

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

## Phase 5: Multi-App — Vite Frontend

*Goal: Support frontend + backend simultaneously. The capstone.*

### 5.1 Frontend Category in Manifest
- **What**: Add `frontend` category (selection: single, required: false)
- **Items**: `vite` (port 5173, proxy_target default empty)
- **Files**: `contract/manifest.json`

### 5.2 Vite Template
- **Image**: `node:22-alpine`
- **Port**: 5173 (exposed directly to host, NOT through nginx)
- **HMR**: `CHOKIDAR_USEPOLLING=true` for Docker volume watching
- **Proxy**: Vite's `server.proxy` in `vite.config.ts` forwards `/api` to backend
- **Auto-wire**: `VITE_API_URL` injected via wiring rules (Phase 4.2)
- **PHP edge case**: When Vite + PHP-Laravel co-selected, proxy target = `http://web:80` (through nginx, not direct to FPM)
- **Files**: `templates/frontends/vite/Dockerfile`, `service.yml`
- **Research**: `03-vite-multiapp-architecture.md`

### 5.3 Compose Generator Multi-App Support
- **What**: Detect `frontend` category selections, generate a second service named `frontend`
- **Changes to `core/compose/generate.sh`**:
  - New section after app service assembly (~40-60 new lines)
  - Read `templates/frontends/${FRONTEND_TYPE}/service.yml`
  - Variable substitution for `${FRONTEND_PORT}`, `${PROXY_TARGET}`, etc.
  - Add `frontend` to depends_on for tester if present
  - Volume registration for frontend
- **Changes to `devstack.sh`**:
  - `generate_from_bootstrap()`: Extract frontend selections, set `FRONTEND_TYPE` in project.env
  - `project.env`: Add `FRONTEND_TYPE`, `FRONTEND_PORT` variables
- **Backward compatible**: No changes to existing single-app flow
- **Research**: `03-vite-multiapp-architecture.md` §6, §8

### 5.4 Fix Latent `app` Multi-Select Bug
- **What**: `app` category says `selection: multi` but `generate_from_bootstrap()` only uses `keys[0]`
- **Fix**: Change `app` to `selection: single` (backend is singular) since `frontend` is now its own category
- **Research**: `03-vite-multiapp-architecture.md` finding

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

### 6.3 Updated Docs
- `docs/ADDING_SERVICES.md` — update with NATS/MinIO examples
- `docs/CREATING_TEMPLATES.md` — add Python/Rust sections
- `README.md` — update catalog table

---

## Execution Order

```
Phase 1 (Foundation)
├── 1.1 Port collision detection
├── 1.2 Volume accumulator pattern
├── 1.3 App volume case statement
└── 1.4 Manifest new categories
         │
Phase 2 (Services) ──────────────── Phase 3 (Languages)
├── 2.1 NATS                        ├── 3.1 Python/FastAPI
├── 2.2 MinIO                       └── 3.2 Rust
├── 2.3 Adminer                          │
└── 2.4 Swagger UI                       │
         │                               │
         └───────────┬───────────────────┘
                     │
Phase 4 (Presets & Wiring)
├── 4.1 Preset bundles
└── 4.2 Auto-wiring rules
         │
Phase 5 (Multi-App)
├── 5.1 Frontend category
├── 5.2 Vite template
├── 5.3 Compose generator multi-app
└── 5.4 Fix app multi-select
         │
Phase 6 (Docs)
└── Ships incrementally with each phase
```

Phases 2 and 3 can run in parallel. All other phases are sequential.

---

## Port Allocation Map (Final State)

| Service | Port | Category | Variable |
|---------|------|----------|----------|
| App backends (Node/Go/Python/Rust) | 3000 | app | internal only |
| App (PHP-FPM) | 9000 | app | internal only |
| Vite frontend | 5173 | frontend | `FRONTEND_PORT` |
| PostgreSQL | 5432 | database | internal only |
| MariaDB | 3306 | database | internal only |
| Redis | 6379 | services | internal only |
| Mailpit SMTP | 1025 | services | internal only |
| Mailpit UI | 8025 | services | `MAILPIT_PORT` |
| NATS client | 4222 | services | `NATS_PORT` |
| NATS monitor | 8222 | services | `NATS_MONITOR_PORT` |
| MinIO API | 9000 | services | `MINIO_PORT` |
| MinIO Console | 9001 | services | `MINIO_CONSOLE_PORT` |
| HTTP (nginx) | 8080 | core | `HTTP_PORT` |
| HTTPS (nginx) | 8443 | core | `HTTPS_PORT` |
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
