# Review Findings — Task List

> **Source**: Three independent code reviews (2026-03-20)
> **Reviews**: `docs/reviews/catalog-expansion-review.md`, `docs/reviews/review-a-cold-start.md`, `docs/reviews/review-b-bootstrapped.md`

---

## Group A: Bugs (fix immediately)

These are broken or will break users.

### A1. `handle_path` strips `/api` prefix — backend routes break
- **Status**: FIXED (changed to `handle` in `core/caddy/generate-caddyfile.sh` line 96)
- **Found by**: Review A, Expansion
- **File**: `core/caddy/generate-caddyfile.sh`

### A2. `--preset` documented but not implemented
- **Found by**: Review A
- **Files**: `devstack.sh` (cmd_init), `docs/QUICKSTART.md`, `README.md`
- **Action**: Either implement `--preset` flag parsing in `cmd_init()` OR remove all preset references from QUICKSTART.md and README.md
- **Recommendation**: Implement it — presets exist in manifest, the UX value is clear

### A3. Python Dockerfile missing build deps for database drivers
- **Found by**: Expansion
- **File**: `templates/apps/python-fastapi/Dockerfile`
- **Action**: Add `gcc`, `libpq-dev`, `pkg-config` to the apt-get install. Without these, `psycopg2` and similar C-extension packages fail to compile.

### A4. PHP-Laravel hardcodes `DB_CONNECTION=mysql` — breaks PostgreSQL
- **Found by**: Review A
- **File**: `templates/apps/php-laravel/service.yml`
- **Action**: Make `DB_CONNECTION` derive from `DB_TYPE`. Add `${DB_CONNECTION}` variable, map `postgres→pgsql`, `mariadb→mysql` in compose generator.

### A5. `EXTRAS_DEPENDS` is dead code
- **Found by**: Review A
- **File**: `core/compose/generate.sh`
- **Action**: Either wire `EXTRAS_DEPENDS` into the app service's `depends_on` block, or remove the dead variable. The intent was that extras (Redis, etc.) should be healthy before the app starts.

### A6. Example app `index.js` references "nginx" instead of "Caddy"
- **Found by**: Review A, B
- **File**: `app/src/index.js` line 73
- **Action**: Change "nginx" to "Caddy". One-line fix.

---

## Group B: Robustness (fix soon)

These won't break immediately but create failure modes.

### B1. No healthcheck on any app service template
- **Found by**: Review A, B, Expansion
- **Files**: All `templates/apps/*/service.yml`
- **Action**: Add healthcheck to each app template. Change web service `depends_on` from `service_started` to `service_healthy`. Without this, Caddy may proxy before the app is ready → 502 errors.

### B2. `init` command only lists 3 of 5 app types
- **Found by**: Review B
- **File**: `devstack.sh` cmd_init(), line ~798
- **Action**: Read available types from `ls templates/apps/` instead of hardcoding. Also add frontend, tooling, and observability prompts to match what `--bootstrap` supports.

### B3. Port collision false positive: internal vs host ports
- **Found by**: Expansion
- **File**: `devstack.sh` validate_bootstrap_payload() check 11
- **Action**: PHP-FPM port 9000 is internal-only, MinIO api_port 9000 is host-exposed. The validator can't distinguish. Consider adding a `host_port` vs `internal_port` distinction in manifest, or document that this is a known false positive.

### B4. Wiring creates keys not in item defaults (un-overridable)
- **Found by**: Expansion
- **File**: `contract/manifest.json` wiring rules
- **Action**: Wiring sets keys like `redis_url`, `nats_url`, `s3_endpoint` on app items, but these keys don't exist in app defaults. This means they can't be overridden via the bootstrap payload's `overrides` field (check 10 would reject them). Either add these keys to app defaults or exempt wiring-generated keys from override validation.

### B5. NATS/MinIO port overrides silently ignored
- **Found by**: Expansion
- **File**: `devstack.sh` generate_from_bootstrap()
- **Action**: The override resolution block handles ports for wiremock, qa-dashboard, mailpit, prometheus, grafana, dozzle, adminer, swagger-ui — but NOT nats or minio. Add override handling for `NATS_PORT`, `NATS_MONITOR_PORT`, `MINIO_PORT`, `MINIO_CONSOLE_PORT`.

### B6. No compose guard for `db-ui` when `DB_TYPE=none`
- **Found by**: Expansion
- **File**: `core/compose/generate.sh`
- **Action**: If db-ui is in EXTRAS but no database is selected, the generated compose will have `db-ui` depending on `db` service that doesn't exist. The manifest `requires: ["database.*"]` prevents this via bootstrap validation, but manual project.env editing could trigger it.

### B7. Swagger UI mounts file that likely doesn't exist
- **Found by**: Review A
- **File**: `templates/extras/swagger-ui/service.yml`
- **Action**: `${APP_SOURCE}/docs/openapi.json` is mounted but doesn't exist in scaffolded apps. Docker creates an empty directory at the mount point. Either make the mount conditional or create a placeholder during scaffolding.

### B8. `FRONTEND_SOURCE` has no default protection
- **Found by**: Review A
- **File**: `core/compose/generate.sh` line ~87
- **Action**: If FRONTEND_TYPE is set but FRONTEND_SOURCE is empty, the path resolution produces the project root. Add a guard: `FRONTEND_SOURCE="${FRONTEND_SOURCE:-./frontend}"`.

---

## Group C: Documentation (update)

### C1. AI_BOOTSTRAP.md needs major update
- **Found by**: Review B (accuracy 88%, completeness 72%)
- **File**: `docs/AI_BOOTSTRAP.md`
- **Action items**:
  - Add Python and Rust to CA cert trust table (Pitfall #4)
  - Expand variable table from 9 to 20+ variables
  - Add source-of-truth entries: `contract/manifest.json`, `templates/frontends/`, `templates/extras/*/volumes.yml`
  - Add PowerHouse contract section (`--options`, `--bootstrap`, wiring, presets)
  - Add frontend system section (FRONTEND_TYPE, path-based routing)
  - Add Pitfall #11: init command missing app types
  - Add Pitfall #12: manual `docker compose stop` leaves cert volumes
  - Mark `mocks/*/__files/*` as optional in source-of-truth table
  - Add `DEVSTACK_DIR` and `APP_INIT_SCRIPT` to variable table

### C2. Contract example shows Vite in app category
- **Found by**: Expansion
- **File**: `DEVSTRAP-POWERHOUSE-CONTRACT.md`
- **Action**: The `spa-api` preset example shows `"app": ["vite"]` but vite is in `frontend` category. Fix to `"frontend": ["vite"]`.

### C3. ARCHITECTURE.md missing `handle_path` warning
- **Found by**: Review A
- **File**: `docs/ARCHITECTURE.md`
- **Action**: Now that we changed to `handle` (not `handle_path`), document that the `/api` prefix is preserved when forwarding to the backend.

### C4. README WireMock port misleading
- **Found by**: Review A
- **File**: `README.md`
- **Action**: WireMock port listed as 8443. That's the HTTPS proxy port, not WireMock's port. WireMock is internal on 8080. Clarify or remove.

### C5. Research doc 03 is stale after Caddy pivot
- **Found by**: Expansion
- **File**: `docs/research/03-vite-multiapp-architecture.md`
- **Action**: Add a note at the top: "Superseded by `10-integrated-caddy-vite-design.md` — the Caddy swap changed the frontend routing approach from direct exposure to path-based routing through Caddy."

---

## Group D: Architecture improvements (future)

### D1. Non-destructive restart
- **Found by**: Review A
- **Action**: `./devstack.sh restart` runs `docker compose down -v` (deletes database volumes). Add `restart --keep-volumes` or make non-destructive the default.

### D2. Cert domain change detection
- **Found by**: Review A
- **Action**: Before skipping cert generation, compare `domains.txt` with existing cert SANs. Regenerate if they differ.

### D3. Split devstack.sh
- **Found by**: Review A
- **Action**: Extract contract code (~650 lines) into `core/contract/bootstrap.sh`. Source it from main script.

### D4. Replace sed templating with envsubst
- **Found by**: Review A, B
- **Action**: 17+ chained sed commands are fragile. envsubst handles all variables in one pass.

### D5. Add project.env validation
- **Found by**: Review A
- **Action**: After sourcing, verify APP_TYPE matches a template dir, DB_TYPE is valid, NETWORK_SUBNET is well-formed.

### D6. Clean `mocks/*/recordings/` on stop
- **Found by**: Review B
- **Action**: Root-owned recording directories aren't cleaned by `cmd_stop`.

---

## Suggested Team Grouping

### Team 1: Bug fixes (Group A) — fast, isolated changes
Files: `devstack.sh`, `templates/apps/python-fastapi/Dockerfile`, `templates/apps/php-laravel/service.yml`, `core/compose/generate.sh`, `app/src/index.js`

### Team 2: Robustness (Group B) — needs some design
Files: `templates/apps/*/service.yml` (healthchecks), `devstack.sh` (init, overrides), `core/compose/generate.sh` (guards), `contract/manifest.json` (wiring defaults)

### Team 3: Documentation (Group C) — thorough but mechanical
Files: `docs/AI_BOOTSTRAP.md`, `DEVSTRAP-POWERHOUSE-CONTRACT.md`, `docs/ARCHITECTURE.md`, `README.md`, `docs/research/03-*.md`

### Team 4: Architecture (Group D) — plan separately
Bigger changes that need design decisions before implementation.
