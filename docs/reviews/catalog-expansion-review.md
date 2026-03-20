# Catalog Expansion Review Report

> **Reviewer**: Claude Opus 4.6 (code review, not runtime)
> **Date**: 2026-03-20
> **Scope**: All 6 phases of the catalog expansion initiative
> **Commits reviewed**: `4643faa`, `9ea545a`, `0c4efc4`, `d4dd7bc`

---

## 1. Starting Point Assessment

**Files reviewed:**
- `docs/AI_BOOTSTRAP.md`
- `DEVSTRAP-POWERHOUSE-CONTRACT.md`

### Architecture documentation

The `AI_BOOTSTRAP.md` is excellent. It provides:
- Clear source-of-truth vs generated distinction (line 22-39)
- Correct file reading order (line 43-54)
- Actionable verification loop (line 86-109)
- Ten well-documented pitfalls (lines 157-203)
- Variable substitution table (lines 143-156)

The document has been updated to reflect the Caddy swap (line 15: "A set of bash scripts that generate `docker-compose.yml`, `Caddyfile`..." and line 118: "Caddy adds `X-Original-Host` automatically"). No stale nginx references remain.

**Minor issue:** Pitfall #4 (line 172-176) lists CA cert handling for Node.js, Go, and PHP but omits Python and Rust. The research (`02-language-templates.md`) documents these thoroughly, but the bootstrap doc was not updated. This means an AI agent starting a session on a Python or Rust project will not find the CA cert pattern in the primary bootstrap document.

### Contract specification

The contract is well-structured with clear principles (lines 29-42) and explicit "locked" vs "flexible" boundaries (lines 514-538). The changelog section (lines 541-575) is comprehensive and accurately reflects all changes.

**Positive:** The changelog correctly notes that `app.selection` changed from `multi` to `single` (line 556), which is a potentially breaking change that was handled carefully.

**Minor concern:** The contract example (lines 250-402) shows `presets` with `"app": ["vite"]` in the `spa-api` selections (line 259). But `vite` is in the `frontend` category, not `app`. This is inconsistent with the actual manifest. The example in the contract doc appears to be a draft that was not updated to match the final implementation where Vite moved to a separate `frontend` category.

**Verdict:** Architecture is clearly documented. Contract is complete. Two minor documentation gaps identified.

---

## 2. Research Quality Assessment

**Files reviewed:**
- `docs/dev-strap-catalog-proposals.md`
- `docs/research/IMPLEMENTATION-PLAN.md`
- `docs/research/01-new-services.md` through `10-integrated-caddy-vite-design.md`

### Alternatives evaluated

Research quality is high. Key evaluations:

| Decision | Alternatives Evaluated | Depth |
|----------|----------------------|-------|
| Database UI | pgAdmin, Adminer, CloudBeaver, DbGate | Full comparison with image sizes, RAM, features (doc 06) |
| Reverse proxy | nginx (status quo), Traefik v3, Caddy v2 | 3-doc investigation (07, 08, 09) with line-count analysis |
| Python base image | `python:3.12-alpine` vs `python:3.12-slim` | Detailed musl vs glibc analysis (doc 02, section 1.1) |
| Rust base image | `rust:1.83-alpine` vs `rust:1.83-slim` | Same pattern (doc 02, section 2.1) |
| Auto-wiring | Three proposals (A, B, C) | Contract impact analysis for each (doc 04, section 4) |
| Frontend category | Four architecture options (A-D) | Full comparison matrix (doc 03, section 2.5) |

### Decision rationale quality

Decisions are clearly documented with rationale. The decision log in `IMPLEMENTATION-PLAN.md` (lines 25-38) is a strong artifact. Particularly good:

- Caddy decision (line 29): quantified the improvement ("Generator shrinks from ~207 to ~130 lines, config from ~80 to ~20 lines")
- `proxy_protocol` field decision (line 32): included a trigger for when to revisit ("add the field if/when a second non-HTTP protocol appears that Caddy can't handle")
- Beaver/DBeaver decision (line 37): quantified the size difference ("CloudBeaver: 500MB image, 400MB RAM. Adminer: 30MB, 10MB RAM")

### Research actionability

All research documents led directly to implementation. The implementation plan references specific research sections for each task. No research was theoretical only.

**One gap:** The Vite architecture research (doc 03) originally recommended "direct port exposure" (section 7), but the integrated design (doc 10) reversed this to "everything through Caddy" after the Caddy swap made WebSocket forwarding trivial. The original doc 03 was not updated to reflect this reversal. A reader following the docs in order would get confused. The `IMPLEMENTATION-PLAN.md` captures the updated decision (line 30-31), but the research doc itself is stale.

### Risk identification

Risks are well-identified:
- Port collision risk (doc 04, section 1) -- led to validation check 11
- Rust compile cache risk (doc 02, section 2.4) -- led to named volume strategy
- PHP-FPM + Vite edge case (doc 03, section 8.8 Q2) -- resolved by Caddy
- `SSL_CERT_FILE` replacement behavior differences across languages (doc 02, Appendix C)

**Verdict:** Research is thorough, well-structured, and actionable. One stale research doc (03) after the Caddy pivot.

---

## 3. Contract (Manifest) Review

**File reviewed:** `contract/manifest.json`

### Internal consistency

**Categories and items:** All 6 categories present (`app`, `frontend`, `database`, `services`, `tooling`, `observability`). All items within each category have required fields (`label`, `description`).

**Preset validity check:**

| Preset | Selection References | Valid? |
|--------|---------------------|--------|
| `spa-api` | `frontend.vite`, `database.postgres`, `tooling.qa`, `tooling.wiremock` | Yes -- all exist |
| `api-only` | `database.postgres`, `services.redis`, `tooling.qa`, `tooling.swagger-ui` | Yes -- all exist |
| `full-stack` | `frontend.vite`, `database.postgres`, `services.redis`, `tooling.qa`, `observability.prometheus`, `observability.grafana`, `observability.dozzle` | Yes -- all exist |
| `data-pipeline` | `app.python-fastapi`, `database.postgres`, `services.nats`, `services.minio` | Yes -- all exist |

**Preset dependency satisfaction:**

| Preset | Dependency Concern | Satisfied? |
|--------|-------------------|------------|
| `full-stack` | `grafana` requires `observability.prometheus` | Yes -- both selected |
| `full-stack` | `redis` requires `app.*` | **Partially** -- `prompts: ["app"]` means user must select an app, but it is not guaranteed |
| `api-only` | `redis` requires `app.*` | **Same issue** -- depends on user selecting from `prompts` |
| `api-only` | `swagger-ui` requires `app.*` | Same issue |

This is by design (presets are UI hints, validation happens at bootstrap), but the `full-stack` preset includes `redis` which requires `app.*`, yet `app` is only in `prompts`. If the user somehow skips the app selection, bootstrap validation will catch it. This is acceptable but worth noting.

**ISSUE: `spa-api` preset references `frontend.vite` but does NOT have `frontend` in its `prompts`.** Looking at the manifest (line 8-13), the spa-api preset selects from `frontend`, `database`, and `tooling` but only prompts for `app`. This is correct -- Vite is pre-selected, not prompted for.

### Port allocation collision analysis

Default port map for all items:

| Item | Port Key | Default Value |
|------|----------|---------------|
| node-express | port | 3000 |
| php-laravel | port | 9000 |
| go | port | 3000 |
| python-fastapi | port | 3000 |
| rust | port | 3000 |
| vite | port | 5173 |
| postgres | port | 5432 |
| mariadb | port | 3306 |
| redis | port | 6379 |
| mailpit | smtp_port | 1025 |
| mailpit | ui_port | 8025 |
| nats | client_port | 4222 |
| nats | monitor_port | 8222 |
| minio | api_port | 9000 |
| minio | console_port | 9001 |
| qa-dashboard | port | 8082 |
| wiremock | port | 8443 |
| db-ui | port | 8083 |
| swagger-ui | port | 8084 |
| prometheus | port | 9090 |
| grafana | port | 3001 |
| dozzle | port | 9999 |

**Potential collision:** `php-laravel` (port 9000) and `minio` (api_port 9000). However, `php-laravel` port 9000 is the FastCGI internal port and is NOT exposed to the host. The manifest lists it as a default for documentation purposes, but the PHP service.yml does not have a `ports:` mapping. So no actual host-port collision exists. The port collision validator would still flag this because it compares manifest defaults. This is a **false positive in the port collision logic** -- the validator does not distinguish between internal and host-exposed ports.

**ISSUE:** The port collision detection at `devstack.sh` line 1175-1189 treats all `port` and `*_port` keys as host-port bindings. But `php-laravel`'s `port: 9000` is an internal FastCGI port, never mapped to the host. Selecting `php-laravel` + `minio` together would trigger a `PORT_CONFLICT` error that is technically a false positive. Since the `app` category is `single` selection, you cannot select both php-laravel and another app, so the php-laravel + minio collision is the only scenario where this matters. It IS a valid co-selection (php-laravel from app + minio from services).

**Recommendation:** Either rename php-laravel's default to something like `fastcgi_port` to avoid the `_port` suffix pattern, or add an exception in the validator for internal-only ports. Alternatively, since `php-laravel` port 9000 appears in the manifest, and MinIO `api_port` is 9000, a user selecting both WILL get a false-positive `PORT_CONFLICT`. This should be documented or fixed.

### Wiring rules

Six wiring rules are defined (lines 206-237). Each is well-formed:

| Rule | When | Set | Template | Valid? |
|------|------|-----|----------|--------|
| 1 | `frontend.vite` + `app.*` | `frontend.vite.api_base` | `/api` | Yes |
| 2 | `app.*` + `services.redis` | `app.*.redis_url` | `redis://redis:6379` | Yes |
| 3 | `app.*` + `services.nats` | `app.*.nats_url` | `nats://nats:4222` | Yes |
| 4 | `app.*` + `services.minio` | `app.*.s3_endpoint` | `http://minio:9000` | Yes |
| 5 | `tooling.db-ui` + `database.*` | `tooling.db-ui.default_server` | `db` | Yes |
| 6 | `tooling.swagger-ui` + `app.*` | `tooling.swagger-ui.spec_url` | `http://app:{app.*.port}/docs/openapi.json` | Yes |

**ISSUE with rule 6:** The `set` target is `tooling.swagger-ui.spec_url`, but `swagger-ui`'s defaults only contain `port: 8084`. There is no `spec_url` key in the defaults. The wiring `set` target references a key that does not exist in the item's defaults. The `resolve_wiring()` function does not validate that the target key exists in defaults -- it just sets it. This means the wired value will appear in the response but has no corresponding manifest default. This is inconsistent but functionally harmless because the wiring result is informational.

**ISSUE with rule 5:** Same problem. `db-ui` defaults only have `port: 8083`. There is no `default_server` key. The wiring sets a key that does not exist in the item's defaults.

**ISSUE with rules 2-4:** The `set` targets (`app.*.redis_url`, `app.*.nats_url`, `app.*.s3_endpoint`) reference keys that do not exist in any app item's defaults. Again, wiring creates keys that have no default counterpart.

These are not bugs per se -- the wiring system creates new derived configuration values. But it is architecturally inconsistent: the manifest says `defaults` values are scalars and `overrides` keys must exist in defaults. Wiring creates keys outside this system. The contract should document this semantic difference.

### Backward compatibility

Version stays at `"1"` (line 3). All additions are non-breaking per the contract's flexibility rules. Verified.

**Verdict:** Manifest is internally consistent for preset references. Port collision false positive with php-laravel + minio. Wiring rules set keys that do not exist in defaults, creating an architectural inconsistency.

---

## 4. Generator Review

### Caddyfile Generator (`core/caddy/generate-caddyfile.sh`)

**Correctness:**

The generator has three code paths (lines 65-132):
1. PHP-FPM: `php_fastcgi app:9000` + `file_server` (correct)
2. Frontend + backend: path-based routing with `handle_path` (correct)
3. Default: `reverse_proxy app:3000` (correct)

**ISSUE (line 96-98):** The frontend + backend path uses `handle_path` for the API prefix:
```
handle_path ${FRONTEND_API_PREFIX}/* {
    reverse_proxy app:3000
}
```
`handle_path` strips the matched prefix before forwarding. So a request to `/api/users` arrives at the backend as `/users`. This is often desired for API gateways but may surprise developers whose backend expects requests at `/api/users`. This behavior is different from how Vite's built-in `server.proxy` works (which does NOT strip the prefix by default). If the intent is path-forwarding without stripping, `handle` should be used instead of `handle_path`.

**ISSUE (line 97):** The app port is hardcoded to `3000`. PHP-FPM is handled separately (line 65), but if a future backend template uses a non-3000 port, this path-based routing block would break. The port should come from a variable.

**Mock interception flow (lines 134-166):** Correct. The mock proxy block:
- Uses `{http.request.host}` for `X-Original-Host` (correct Caddy placeholder)
- Adds `X-Real-IP` and `X-Forwarded-Proto` headers
- Lists all domains with `:443` suffix
- Uses the same TLS cert as the app block

**Variable substitution completeness:**
- `${PROJECT_NAME}` -- used in site blocks, correctly expanded via bash string interpolation (not sed)
- `${FRONTEND_TYPE}` -- checked at line 86
- `${FRONTEND_API_PREFIX}` -- defaulted to `/api` at line 88
- `${FRONTEND_PORT}` -- defaulted to 5173 at line 108
- `${HTTP_PORT}`, `${HTTPS_PORT}` -- used in summary output only (lines 172-173), not in Caddyfile itself. The Caddyfile uses `localhost:80` and `localhost:443` (correct -- Caddy binds to container ports, Docker maps host ports)

**Frontend guard:** Properly guarded with `elif [ -n "${FRONTEND_TYPE:-}" ]` (line 86). When `FRONTEND_TYPE` is unset or empty, the default reverse proxy path is used. Backward compatible.

### Compose Generator (`core/compose/generate.sh`)

**Overall structure:** Well-organized with clear section comments. The extras processing loop (lines 93-132) handles variable substitution, volume registration, and dependency collection.

**ISSUE (line 115-116):** Variable naming inconsistency between manifest and generator:
- Manifest: `minio.defaults.api_port` (manifest.json line 138)
- Generator sed: `${MINIO_PORT}` (generate.sh line 115)
- Template: `${MINIO_PORT}` (minio/service.yml line 6)
- Research doc: `MINIO_API_PORT` (01-new-services.md line 204)

The manifest calls it `api_port`, the template/generator call it `MINIO_PORT`. These are in different namespaces (manifest defaults vs env vars), so there is no functional bug. But the naming inconsistency is confusing. The manifest says the user can override `api_port`, but the port collision validator extracts keys ending in `_port`, and `api_port` does match. The env var `MINIO_PORT` is what the template uses. This works but is a naming convention gap.

**Frontend section (lines 210-223):** Correctly guarded behind `FRONTEND_TYPE` check. Variable substitution includes `${FRONTEND_SOURCE}`, `${FRONTEND_API_PREFIX}`, and `${HTTPS_PORT}`.

**ISSUE (line 219):** The frontend template sed replaces `${HTTPS_PORT}` but this variable is set in `project.env` and sourced at line 22. However, `HTTPS_PORT` is not sourced until `project.env` is loaded. If `HTTPS_PORT` is not defined in `project.env`, the sed will replace `${HTTPS_PORT}` with an empty string. Looking at the Vite service.yml (line 15), it uses `VITE_HMR_PORT=${HTTPS_PORT}`. If `HTTPS_PORT` is empty, the HMR port will be empty in the container environment. The `generate_from_bootstrap()` function at `devstack.sh` line 1385 always writes `HTTPS_PORT`, so this is safe for bootstrap-generated projects. But for manually configured projects, `HTTPS_PORT` must be in `project.env`.

**Volume accumulator (lines 95, 124-128):** The `EXTRAS_VOLUMES` pattern works correctly. Each extra with a `volumes.yml` sidecar file gets its volumes appended. NATS and MinIO both have `volumes.yml` files. The final footer (line 435) includes all accumulated volumes.

**App volume case statement (lines 171-186):** Correctly handles go, python-fastapi, and rust with their respective named volumes. Clean structure.

**Backward compatibility:** Tested by checking that existing projects without `FRONTEND_TYPE` work. Line 86-88 uses `${FRONTEND_TYPE:-}` with default empty string, and line 212 checks for both non-empty and non-"none". Projects without `FRONTEND_TYPE` in `project.env` will skip the frontend section entirely.

### Cert Generator (`core/certs/generate.sh`)

Clean after JKS removal. The comment at line 8 documents the removal: "(JKS removed -- WireMock runs HTTP-only behind the proxy)".

The script:
- Generates a root CA (lines 91-99)
- Generates a server certificate with SANs from domains.txt (lines 104-120)
- Uses `alpine:3` base (confirmed in compose generator line 241)
- Skips if certs exist (line 22-26) unless `FORCE_REGEN=1`

No issues found. The cert-gen is clean and minimal.

**Verdict:** Generators are functional. `handle_path` prefix stripping may surprise developers. Backend port hardcoded to 3000 in the frontend routing path. Variable naming inconsistency between manifest and generator for MinIO ports.

---

## 5. Template Review

### Python/FastAPI (`templates/apps/python-fastapi/`)

**Dockerfile:**
- Base image: `python:3.12-slim` (correct per research, not Alpine)
- Package manager: `uv` installed via multi-stage copy (line 4). Only `/uv` is copied, not `/uvx` as the research recommended. This is minor -- `uvx` is for running tools, not installing packages.
- Layer caching: dependency files copied first (line 14), conditional install (lines 15-16)
- Port: 3000 (matches convention)
- CMD: `uvicorn main:app` with `--reload` (correct for dev)

**ISSUE (Dockerfile line 14):** `COPY requirements.txt* pyproject.toml* ./` -- the glob syntax in COPY will fail if neither file exists. Docker COPY requires at least one file to match. In practice, when the source is bind-mounted at runtime, the Dockerfile COPY is for the initial build only, and a fresh project will have neither file. The `RUN` on line 15-16 guards against this (`if [ -f ... ]`), but the COPY itself could fail during `docker build`. The research Dockerfile (doc 02, section 1.7) had the same issue. This should use `COPY requirements.txt* pyproject.toml* uv.lock* ./` or a `.dockerignore`-based approach.

**ISSUE (Dockerfile line 7-9):** Only `ca-certificates` is installed as a system dependency. The research (doc 02, section 1.7) recommended also installing `gcc`, `libpq-dev`, `default-libmysqlclient-dev`, and `pkg-config` for database driver compilation. The shipped Dockerfile omits these, meaning `psycopg2` (PostgreSQL driver) and `mysqlclient` will fail to compile. Users will hit this immediately when connecting to a database. This is a significant gap.

**service.yml:**
- Service name: `app` (correct)
- Volumes: source mount, certs, python-cache (correct)
- Environment: `PYTHONUNBUFFERED=1`, `REQUESTS_CA_BUNDLE`, `SSL_CERT_FILE`, `CURL_CA_BUNDLE` (matches research)
- `depends_on`: cert-gen (correct)

**ISSUE (service.yml line 13):** Missing `PYTHONDONTWRITEBYTECODE=1` which the research explicitly recommended (doc 02, section 1.5). Without it, `__pycache__` directories will be created in the bind-mounted source, cluttering the host filesystem.

### Rust (`templates/apps/rust/`)

**Dockerfile:**
- Base image: `rust:1.83-slim` (correct per research)
- System deps: `pkg-config`, `libssl-dev`, `ca-certificates`, `wget` (correct)
- Missing: `libpq-dev`, `default-libmysqlclient-dev` (research recommended these in doc 02, section 5.3). Unlike Python, Rust crates like `diesel` will fail to compile without these. Less critical because `sqlx` in pure-Rust mode does not need them, but still a gap.
- `cargo-watch` installed (correct)
- Dummy `main.rs` trick for dependency caching (correct)

**service.yml:**
- Volumes: source, certs, cargo-registry, cargo-target (correct)
- Environment: `RUST_LOG=debug`, `SSL_CERT_FILE=/certs/ca.crt` (correct)
- Missing: `RUST_BACKTRACE=1` which the research recommended (doc 02, section 2.7). This makes panic backtraces silent in dev.

### Vite Frontend (`templates/frontends/vite/`)

**Dockerfile:**
- Base image: `node:22-alpine` (matches node-express)
- Simple and clean: install deps, expose 5173, CMD with `--host 0.0.0.0`
- No source COPY (comment: "volume-mounted in dev") -- correct

**service.yml:**
- Service name: `frontend` (correct, not `app`)
- No `ports:` mapping (correct -- everything goes through Caddy)
- Anonymous volume for `node_modules` (line 8, correct)
- `VITE_API_BASE=${FRONTEND_API_PREFIX}` (line 14, correct)
- `VITE_HMR_PORT=${HTTPS_PORT}` (line 15, needed for HMR through Caddy)
- `CHOKIDAR_USEPOLLING=true` for macOS/Windows compat (correct)

### New extras (NATS, MinIO, db-ui, swagger-ui)

**NATS (`templates/extras/nats/`):**
- Follows existing patterns (redis/mailpit): indentation, variable usage, networks
- Health check uses `wget --spider` (consistent with Alpine-based images)
- JetStream enabled with `--store_dir /data` (correct)
- `volumes.yml` sidecar file with correct `${PROJECT_NAME}-nats-data:` (correct)

**MinIO (`templates/extras/minio/`):**
- Health check uses `mc ready local` (correct, `mc` is included in MinIO image)
- Credentials hardcoded as `minioadmin/minioadmin` (appropriate for dev)
- Console address explicitly set to `:9001` (required for deterministic port mapping)

**db-ui (`templates/extras/db-ui/`):**
- `depends_on: db: condition: service_healthy` (correct -- matches research recommendation)
- `ADMINER_DEFAULT_SERVER: db` pre-fills the login server field (correct)
- `ADMINER_DESIGN: pepa-linha-dark` -- the research (doc 01, section 8.3) recommended NOT setting a theme. This is a minor deviation.
- Health check uses `wget` (correct for Alpine-based Adminer image)

**ISSUE:** There is no guard in the compose generator to skip `db-ui` when `DB_TYPE=none`. The research (doc 01, section 6) explicitly called for this guard. The manifest's `requires: ["database.*"]` prevents this at the contract level during bootstrap, but if someone manually adds `db-ui` to `EXTRAS` in `project.env` without a database, the generated compose will reference a non-existent `db` service and fail. The guard should be added to the compose generator.

**swagger-ui (`templates/extras/swagger-ui/`):**
- Volume mounts `${APP_SOURCE}/docs/openapi.json` (line 9) -- uses `${APP_SOURCE}` which gets replaced by the sed pipeline in the compose generator (line 120)
- Health check uses `curl` instead of `wget` (correct -- swagger-ui image is nginx-based, not Alpine)
- `depends_on: app: condition: service_started` (reasonable)

**ISSUE (swagger-ui service.yml line 9):** The volume mount `${APP_SOURCE}/docs/openapi.json:/spec/openapi.json:ro` will fail with an error if the file does not exist on the host. Docker will create it as a directory, which will cause the swagger-ui container to start but show no spec. This should either be documented clearly or the volume mount should be conditional.

### Pattern consistency

| Aspect | node-express | go | python-fastapi | rust | vite |
|--------|-------------|-----|----------------|------|------|
| Indentation | 2-space | 2-space | 2-space | 2-space | 2-space |
| `${PROJECT_NAME}` prefix | Yes | Yes | Yes | Yes | Yes |
| `depends_on: cert-gen` | Yes | Yes | Yes | Yes | Yes |
| Networks | Yes | Yes | Yes | Yes | Yes |
| CA cert handling | `NODE_EXTRA_CA_CERTS` | `SSL_CERT_FILE` | 3 vars | `SSL_CERT_FILE` | `NODE_EXTRA_CA_CERTS` |

Templates are consistent. CA cert handling correctly differs per language.

**Verdict:** Templates follow consistent patterns. Python Dockerfile missing database system dependencies (significant). Rust missing `RUST_BACKTRACE=1`. No compose-level guard for db-ui without database.

---

## 6. Bootstrap Pipeline Review

**File reviewed:** `devstack.sh` (functions: `validate_bootstrap_payload`, `resolve_wiring`, `generate_from_bootstrap`, `build_bootstrap_response`)

### Port collision detection (check 11, lines 1175-1189)

The implementation correctly:
- Extracts all keys named `port` or ending in `_port` (line 1183)
- Merges defaults with overrides before checking (`$defaults * $overrides`, line 1181)
- Groups by port value and flags groups with >1 entry (line 1185)
- Uses `tostring` for normalization (line 1184)

**Issue already noted in Section 3:** False positive for php-laravel (port 9000 internal) + minio (api_port 9000 host-mapped).

**ISSUE:** Multi-port items like `mailpit` (smtp_port 1025, ui_port 8025) and `nats` (client_port 4222, monitor_port 8222) are correctly checked for inter-item collisions. But there is no check against the "core" ports that are not in the manifest: `HTTP_PORT` (8080), `HTTPS_PORT` (8443), `TEST_DASHBOARD_PORT` (8082). If a user overrides `db-ui.port` to 8080, it would collide with the Caddy HTTP port, but this is not detected. These core ports are not manifest items, so the validator does not see them.

### Wiring resolution (lines 1197-1296)

The `resolve_wiring()` function is sophisticated:
- Checks all `when` conditions (AND logic, line 1236)
- Handles wildcards in both conditions and targets (lines 1226-1229, 1245-1247)
- User overrides take precedence (lines 1253-1257)
- Template placeholder resolution handles `{category.*}` and `{category.*.key}` patterns (lines 1262-1287)

**Wildcard resolution:** When `category.*` matches multiple items, it uses `sort | .[0]` (alphabetical first, line 1246). This is deterministic and documented.

**Override precedence:** Correctly checked at lines 1253-1256. If the user provides a non-empty override for the wiring target key, the wiring rule is skipped. This is correct.

**ISSUE (line 1253):** The override check looks at `($sel[$tgt_cat][$tgt_item].overrides // {})[$tgt_key]`. But the wiring keys (`redis_url`, `nats_url`, `s3_endpoint`, `default_server`, `spec_url`, `api_base`) do not exist in any item's `defaults`. So `overrides` for these keys would fail validation at check 10 (INVALID_OVERRIDE) before wiring is even called. This means the user can NEVER override a wiring-set value through the bootstrap payload. The only way to override wiring is if the key also exists in defaults, which currently only `api_base` does (it exists in `vite.defaults`). For the other 5 rules, wiring values are not overridable.

### Frontend extraction (lines 1317-1324)

Correctly extracts `frontend_type` and `frontend_port` from the payload. The jq expression uses `// "none"` for graceful absence handling.

### Project generation (lines 1369-1550)

The `generate_from_bootstrap()` function:
1. Writes `project.env` with all settings (lines 1370-1406)
2. Appends wiring env vars to `project.env` (lines 1408-1434)
3. Scaffolds app directory with Dockerfile and init.sh (lines 1436-1453)
4. Scaffolds frontend directory with Dockerfile and `package.json` (lines 1455-1486)
5. Creates mocks directory if wiremock selected (lines 1488-1492)
6. Sets up test infrastructure if QA selected (lines 1504-1543)
7. Runs generators (line 1547)

**ISSUE (line 1400):** The EXTRAS line concatenates services, observability, and non-special tooling items:
```bash
extras=$(printf '%s\n' "${payload}" | jq -r '
    [(.selections.services // {} | keys[]),
     (.selections.observability // {} | keys[]),
     (.selections.tooling // {} | keys[] | select(. != "qa" and . != "qa-dashboard" and . != "wiremock" and . != "devcontainer"))] | join(",")')
```
This correctly maps `db-ui` and `swagger-ui` from `tooling` into `EXTRAS` (since they are backed by templates in `templates/extras/`). However, if a new tooling item is added that is NOT backed by an extras template (similar to qa, qa-dashboard, wiremock, devcontainer), it will be incorrectly added to `EXTRAS` and cause a "No template found for extra" warning. The filter is fragile -- it should use an allow-list rather than a deny-list.

**ISSUE (line 1400):** NATS port override is not extracted. Looking at lines 1333-1367, there are override extractions for most services but NOT for NATS (`client_port`, `monitor_port`) or MinIO (`api_port`, `console_port`). The project.env will use default values for these services even if the user provides overrides. The NATS and MinIO port variables are used by the compose generator with defaults (`${NATS_PORT:-4222}`), so it works when defaults are used, but user overrides would be silently ignored.

### Bootstrap response (lines 1554-1598)

The response correctly:
- Merges defaults with overrides for the `services` object
- Includes `wiring` in the response when present
- Provides standard `commands` object

**Verdict:** Bootstrap pipeline is functional. Port collision has a false-positive edge case. Wiring-set keys are not overridable through the bootstrap payload. NATS/MinIO port overrides are silently ignored.

---

## 7. Test Review

**File reviewed:** `tests/contract/test-contract.sh` (184 assertions across 28 fixture files)

### Coverage by feature

| Feature | Test Coverage | Assessment |
|---------|--------------|------------|
| --options schema | Lines 112-217 (50+ assertions) | Thorough |
| Envelope validation | Lines 224-239 | Complete |
| Category/item validation | Lines 241-261 | Complete |
| Dependency checks | Lines 263-278 | Good |
| Conflict checks | Lines 280-304 | Uses test-only manifest (creative approach) |
| Override validation | Lines 306-310 | Minimal (1 test) |
| Port collision | Lines 312-330 | Good (3 scenarios) |
| Edge cases | Lines 332-369 | Good (null, multiple errors, stdin, CLI errors) |
| Generation: valid payload | Lines 384-431 | Thorough |
| Generation: overrides | Lines 433-446 | Good |
| Generation: minimal | Lines 448-459 | Good |
| Generation: PHP | Lines 461-471 | Basic |
| Generation: Go | Lines 473-483 | Basic |
| Generation: devcontainer | Lines 484-493 | Basic |
| Generation: observability | Lines 495-545 | Thorough |
| Generation: frontend | Lines 547-573 | Good |
| Regression | Lines 578-587 | Basic |

### Test gaps identified

**Missing: New service generation tests.** There are no generation tests for payloads that include NATS, MinIO, db-ui, or swagger-ui. The observability test (Test 7) verifies that prometheus/grafana/dozzle appear in the compose output, but no equivalent test exists for the Phase 2 services.

**Missing: Python/FastAPI generation test.** There is a Go test (Test 5) and PHP test (Test 4), but no test that bootstraps with `python-fastapi` and verifies the Dockerfile and compose output.

**Missing: Rust generation test.** Same gap as Python.

**Missing: Multi-port item in port collision.** The port-collision tests use node-express + go (both single-port items). There is no test that triggers a collision on a multi-port item (e.g., `mailpit.ui_port` colliding with something).

**Missing: Wiring resolution tests.** There are no explicit tests that verify `resolve_wiring()` output. The frontend test (Test 8) checks that `wiring["frontend.vite.api_base"]` exists in the response, but there are no tests for Redis wiring, NATS wiring, MinIO wiring, db-ui wiring, or swagger-ui wiring.

**Missing: Frontend-only payload.** All frontend tests include a backend app. There is no test for a frontend-only bootstrap (which should work since `app` is `required: true` -- it should fail with `MISSING_REQUIRED`).

**Missing: Caddyfile content verification.** The generation tests verify that `docker-compose.yml` and `Caddyfile` are created (line 415), but do not verify Caddyfile content. There is no test asserting that the frontend path-based routing (`handle_path /api/*`) appears in the Caddyfile when a frontend is selected.

**Missing: `db-ui` without database guard.** No test verifies that selecting `db-ui` without a database produces a `MISSING_DEPENDENCY` error.

**Positive:** The test infrastructure itself is solid. The `save_state`/`restore_state` pattern (lines 80-103) properly backs up and restores `project.env` and cleans generated artifacts. The assertion helpers (`assert_eq`, `assert_json`, `assert_json_eq`) are clean and produce good output.

**Verdict:** Good foundational coverage (184 assertions). Significant gaps in testing new services, new languages, wiring resolution, and generated file content verification.

---

## 8. Documentation Review

**Files reviewed:**
- `README.md`
- `docs/QUICKSTART.md`
- `docs/ARCHITECTURE.md`
- `docs/ADDING_SERVICES.md`
- `docs/CREATING_TEMPLATES.md`
- `docs/DEVELOPMENT.md`
- `DEVSTRAP-POWERHOUSE-CONTRACT.md`

### Catalog representation

The README (lines 76-97) accurately lists all services including the new additions (NATS, MinIO, Adminer, Swagger UI, Frontend/Vite). The architecture diagram includes all components.

`ADDING_SERVICES.md` has been updated with NATS and MinIO as real examples (lines 46-80). The built-in extras table (lines 20-31) is complete with all 9 services.

`CREATING_TEMPLATES.md` uses Rust as the example template (lines 40-73), which demonstrates the new template patterns.

### Contributor guide actionability

`ADDING_SERVICES.md` provides a complete step-by-step guide:
1. Create directory
2. Write service.yml
3. Write volumes.yml (if needed)
4. Add sed substitutions to compose generator
5. Add to manifest.json
6. Add to project.env comments
7. Test

This is actionable. Someone could follow it to add a new service.

`CREATING_TEMPLATES.md` covers:
1. Directory structure
2. Dockerfile creation with specific patterns
3. service.yml creation with variable substitution table
4. Compose generator changes
5. Manifest registration
6. CA cert handling per language

The CA cert table in `CREATING_TEMPLATES.md` should include Python and Rust (currently only confirmed for Node, Go, PHP). This was flagged in Section 1 as well.

### nginx reference audit

Checked all main documentation files for stale nginx references:
- `README.md`: No nginx references (uses "Caddy" throughout)
- `docs/AI_BOOTSTRAP.md`: No nginx references
- `docs/ARCHITECTURE.md`: No nginx references
- `docs/ADDING_SERVICES.md`: No nginx references
- `docs/CREATING_TEMPLATES.md`: No nginx references
- `docs/DEVELOPMENT.md`: No nginx references
- `DEVSTRAP-POWERHOUSE-CONTRACT.md`: No nginx references

Research documents still reference nginx (expected -- they document the historical evaluation). No issues in user-facing docs.

### Contract changelog completeness

The changelog in `DEVSTRAP-POWERHOUSE-CONTRACT.md` (lines 541-575) covers:
- New categories (frontend)
- New items (python-fastapi, rust, nats, minio, db-ui, swagger-ui)
- Category changes (app.selection: multi -> single)
- New top-level keys (presets, wiring)
- New validation (PORT_CONFLICT)
- Internal changes (nginx -> Caddy, cert-gen slimming)
- Migration notes for PowerHouse

This is comprehensive. No missing changes.

### IMPLEMENTATION-PLAN.md status accuracy

The status table (lines 10-19) shows:
- Phases 1-4: DONE with commits
- Phase 5a: NEXT (no commit listed)
- Phase 5b: NEXT (no commit listed)
- Phase 6: PENDING

**ISSUE:** The review prompt says Phase 5a committed as `0c4efc4` and Phase 5b as `d4dd7bc`, but the implementation plan does not reflect these. The status table is stale -- it was not updated after the Caddy swap and Vite frontend were implemented.

**Verdict:** Documentation is accurate and well-maintained. nginx references successfully purged from user-facing docs. Implementation plan status table is stale. CA cert table incomplete for new languages.

---

## 9. Overall Assessment

### 1. Architecture quality

**Strong.** The system has clean separation of concerns:
- Contract (manifest.json) defines the interface
- Generators (core/) produce infrastructure from templates
- Templates (templates/) define individual services
- CLI (devstack.sh) orchestrates everything

The Caddy swap reduced the generator from ~207 to ~130 lines and eliminated all protocol branching. The frontend support was added without modifying any existing template. The volume accumulator pattern for extras is extensible.

The decision to use a separate `frontend` category (rather than cramming Vite into `app`) was architecturally sound and paid dividends in cleaner generator logic.

### 2. Implementation quality

**Good with minor gaps.** The code is clean and consistent. Key findings:

- **Positive:** 11-check validation pipeline is comprehensive and well-structured
- **Positive:** Wiring resolution handles wildcards, overrides, and template variables correctly
- **Positive:** Backward compatibility is maintained throughout
- **Issue:** Python Dockerfile missing database driver system dependencies
- **Issue:** `handle_path` prefix stripping may surprise developers
- **Issue:** Port collision false positive for php-laravel + minio
- **Issue:** NATS/MinIO port overrides silently ignored in bootstrap
- **Issue:** No compose generator guard for db-ui without database

### 3. Test coverage

**Adequate for validation, weak for generation.** The 184 assertions cover the contract interface well. The gaps are:

- No generation tests for new services (NATS, MinIO, db-ui, swagger-ui)
- No generation tests for new languages (Python, Rust)
- No wiring resolution tests beyond the frontend api_base check
- No Caddyfile content verification tests
- No multi-port collision test

Estimated additional tests needed: ~30-40 assertions across 5-6 new fixture files.

### 4. Documentation quality

**High.** All user-facing documentation is accurate and updated. The nginx-to-Caddy transition is cleanly reflected. Contributor guides are actionable. Two gaps: AI bootstrap doc missing Python/Rust CA cert patterns; implementation plan status table stale.

### 5. Contract stability

**Stable.** Version remains "1". All changes are additive. The changelog is comprehensive with clear migration notes. The wiring system is the riskiest addition architecturally (it creates keys outside the defaults system), but it is correctly marked as optional and informational for PowerHouse.

### 6. Risk assessment

| Risk | Severity | Likelihood | Mitigation |
|------|----------|------------|------------|
| Python projects fail on `psycopg2` install | Medium | High | Add `libpq-dev` to Python Dockerfile |
| `handle_path` strips API prefix unexpectedly | Medium | Medium | Document behavior or switch to `handle` |
| php-laravel + minio false-positive port conflict | Low | Low | Single-select app prevents most cases; fix naming |
| db-ui without database produces broken compose | Low | Low | Manifest prevents via contract; add generator guard |
| Swagger-ui breaks if `docs/openapi.json` missing | Low | Medium | Document requirement or make mount conditional |
| NATS/MinIO port overrides ignored | Low | Low | Add override extraction to `generate_from_bootstrap` |
| Implementation plan status table misleads contributors | Low | Medium | Update status entries |

### 7. Recommendations

**High priority (should fix before merging):**
1. Add `gcc`, `libpq-dev`, `default-libmysqlclient-dev`, `pkg-config` to Python Dockerfile -- without these, database connectivity will fail out of the box
2. Add `PYTHONDONTWRITEBYTECODE=1` to Python service.yml
3. Add `RUST_BACKTRACE=1` to Rust service.yml

**Medium priority (should fix soon):**
4. Add generation tests for Python, Rust, NATS, MinIO, db-ui, swagger-ui
5. Add wiring resolution tests
6. Update `docs/AI_BOOTSTRAP.md` pitfall #4 with Python and Rust CA cert patterns
7. Update `IMPLEMENTATION-PLAN.md` status table with Phase 5a/5b commits
8. Add NATS/MinIO port override extraction to `generate_from_bootstrap()`
9. Add compose generator guard for db-ui when `DB_TYPE=none`

**Low priority (should fix eventually):**
10. Evaluate `handle_path` vs `handle` for API prefix routing (document decision)
11. Address php-laravel + minio false-positive port collision
12. Make swagger-ui spec file mount conditional (or document the requirement clearly)
13. Clean up EXTRAS filter in `generate_from_bootstrap()` to use an allow-list

---

*Review completed 2026-03-20. All 9 sections assessed per the review prompt.*
