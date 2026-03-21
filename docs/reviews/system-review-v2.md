# System Review v2: dev-strap Complete Assessment

> **Date**: 2026-03-21
> **Scope**: Full system review per REVIEW_PROMPT_CATALOG_EXPANSION.md (all 9 sections)
> **Codebase state**: main branch, commit d1bf536

---

## 1. Architecture Understanding

### Files Reviewed

- `docs/ARCHITECTURE-NEXT.md` (330 lines)
- `docs/AI_BOOTSTRAP.md` (261 lines)
- `DEVSTRAP-POWERHOUSE-CONTRACT.md` (575 lines)

### Assessment

**Factory/product boundary: well-defined in documentation, partially implemented in code.**

ARCHITECTURE-NEXT.md clearly articulates the two-system insight: factory (creation-time) vs product (runtime). The contract document is precise and unambiguous. However, the codebase has TWO parallel systems running simultaneously:

1. The **old factory** (`devstack.sh` lines 64-81, `core/compose/generate.sh`, `core/caddy/generate-caddyfile.sh`) that operates via `.generated/` directory and `project.env` + `EXTRAS` variable.
2. The **new factory** (`devstack.sh` lines 1484-1956, `product/devstack.sh`) that operates via `--bootstrap` and produces self-contained product directories.

These two systems share the same `devstack.sh` file but are fundamentally different architectures. The old system regenerates everything on every `start`. The new system copies templates once and generates only dynamic files at runtime. This dual-mode existence is the project's biggest structural risk.

**Contract specification: complete and well-documented.** The DEVSTRAP-POWERHOUSE-CONTRACT.md is excellent. The separation of locked vs flexible fields, the standard error codes, the changelog -- all well done. The example payload in the contract matches the actual manifest.json behavior.

**AI_BOOTSTRAP.md: partially stale.** It describes the old architecture (`.generated/`, `core/compose/generate.sh`, variable substitution via sed). The "file reading order" points to files relevant to the old system (`project.env`, `core/compose/generate.sh`, `core/caddy/generate-caddyfile.sh`) rather than the product system. This will mislead AI agents.

### Findings

| ID | Severity | Finding |
|----|----------|---------|
| 1.1 | HIGH | `docs/AI_BOOTSTRAP.md` describes the OLD architecture. Reading order, change flow diagram, verification loop, variable substitution table -- all reference `core/` generators and `.generated/` directory. A new AI agent following this will not understand the product architecture. |
| 1.2 | MEDIUM | Two architectures coexist in `devstack.sh`. The old `cmd_start` (line 86) calls `cmd_generate` which invokes `core/compose/generate.sh` and `core/caddy/generate-caddyfile.sh`. The new `cmd_contract_bootstrap` (line 1137) calls `generate_from_bootstrap` which produces a self-contained product. Neither path is deprecated or marked as primary. |
| 1.3 | LOW | The pitfall list in AI_BOOTSTRAP.md (section "Pitfalls that waste your time") is still accurate for the old system but item 9 ("Named volumes must be prefixed with ${PROJECT_NAME}") contradicts the product templates which use `devstack-` prefixed volumes (e.g., `devstack-certs`, `devstack-db-data`). |

---

## 2. Factory Review

### Files Reviewed

- `devstack.sh` (~2099 lines)
- `contract/manifest.json` (238 lines)

### cmd_init (lines 779-1103)

**Does cmd_init read from the filesystem?** Yes. Lines 837-843 iterate `templates/apps/*/` to list app types. Lines 871-875 iterate `templates/frontends/*/` for frontends. Lines 906-912 iterate `templates/databases/*/` for databases. Lines 929-931 iterate manifest services and verify against `templates/extras/`. This is correct.

**Does --preset work?** Yes. Lines 801-812 parse the `--preset` flag and look up the preset in the manifest. Preset selections are extracted and used to skip interactive prompts (lines 830-831, 864-866, 899-900, 923-925, 954-956, 986-988). The preset is correctly expanded into the same JSON payload that would be built interactively.

### cmd_contract_options / cmd_contract_bootstrap (lines 1120-1225)

Solid implementation. The `--options` path simply pretty-prints the manifest. The `--bootstrap` path reads from file or stdin, validates JSON syntax, validates against the manifest, generates the product, and returns a structured response. Error handling outputs valid JSON to stdout on all failure paths.

### validate_bootstrap_payload (lines 1229-1375)

All 11 checks are present and implemented as a single jq expression that collects all errors:

1. Contract field check (line 1238)
2. Version check (line 1244)
3. Project name regex (line 1250)
4. Unknown categories (line 1256)
5. Unknown items (line 1264)
6. Required categories (line 1276)
7. Single-selection enforcement (line 1286)
8. Requires dependencies with wildcard support (line 1296)
9. Conflicts (line 1327)
10. Override key validation (line 1344)
11. Port collision detection (line 1360)

This is well-implemented. The validation accumulates ALL errors rather than failing on the first one.

### generate_from_bootstrap (lines 1484-1956)

This is the core assembly function. It produces a self-contained product directory.

### Manifest Consistency

**Categories match templates:**

| Manifest category.item | Template path | Match? |
|------------------------|---------------|--------|
| app.node-express | templates/apps/node-express/ | Yes |
| app.php-laravel | templates/apps/php-laravel/ | Yes |
| app.go | templates/apps/go/ | Yes |
| app.python-fastapi | templates/apps/python-fastapi/ | Yes |
| app.rust | templates/apps/rust/ | Yes |
| frontend.vite | templates/frontends/vite/ | Yes |
| database.postgres | templates/databases/postgres/ | Yes |
| database.mariadb | templates/databases/mariadb/ | Yes |
| services.redis | templates/extras/redis/ | Yes |
| services.mailpit | templates/extras/mailpit/ | Yes |
| services.nats | templates/extras/nats/ | Yes |
| services.minio | templates/extras/minio/ | Yes |
| tooling.db-ui | templates/extras/db-ui/ | Yes |
| tooling.swagger-ui | templates/extras/swagger-ui/ | Yes |
| observability.prometheus | templates/extras/prometheus/ | Yes |
| observability.grafana | templates/extras/grafana/ | Yes |
| observability.dozzle | templates/extras/dozzle/ | Yes |
| tooling.qa | (special-cased, no template) | OK |
| tooling.qa-dashboard | (special-cased, no template) | OK |
| tooling.wiremock | (generated at runtime) | OK |
| tooling.devcontainer | (copies from app template) | OK |

All items are accounted for.

**Port allocation: collision-free in defaults.**

| Item | Port(s) |
|------|---------|
| node-express / go / python-fastapi / rust | 3000 (internal, not host-exposed) |
| php-laravel | 9000 (internal FastCGI) |
| vite | 5173 (internal) |
| postgres | 5432 (internal) |
| mariadb | 3306 (internal) |
| redis | 6379 (internal) |
| mailpit | 1025/8025 |
| nats | 4222/8222 |
| minio | 9000/9001 |
| prometheus | 9090 |
| grafana | 3001 |
| dozzle | 9999 |
| qa-dashboard | 8082 |
| db-ui/adminer | 8083 |
| swagger-ui | 8084 |
| HTTP port | 8080 |
| HTTPS/wiremock | 8443 |

**Collision found**: MinIO's default `api_port` is 9000 and PHP-Laravel's internal port is 9000. However, MinIO's 9000 is host-exposed (`"${MINIO_PORT}:9000"`), while PHP-Laravel's 9000 is internal (no `ports:` directive). The port collision validator (check 11) compares manifest defaults including `api_port`, so selecting `php-laravel` + `minio` would flag port 9000. This is a **false positive** in the validator -- PHP's port is internal FastCGI (never exposed to the host), while MinIO's is a host-mapped port. They cannot actually collide.

**Preset dependency satisfaction:**

| Preset | Selections | Dependencies satisfied? |
|--------|-----------|------------------------|
| spa-api | vite, postgres, qa, wiremock + [app prompt] | Yes (app is prompted, qa-dashboard not selected so no qa dep issue) |
| api-only | postgres, redis, qa, swagger-ui + [app prompt] | Yes (redis requires app.* -- app is prompted; swagger-ui requires app.* -- app is prompted) |
| full-stack | vite, postgres, redis, qa, prometheus, grafana, dozzle + [app prompt] | Yes (grafana requires prometheus -- included; redis requires app.* -- prompted) |
| data-pipeline | python-fastapi, postgres, nats, minio | Yes (nats requires app.* -- python-fastapi is selected) |

All presets are valid.

### Findings

| ID | Severity | Finding |
|----|----------|---------|
| 2.1 | MEDIUM | **MinIO/PHP-Laravel false positive port conflict.** Both have port 9000 in their defaults, but PHP's is internal FastCGI (never host-exposed) while MinIO's is host-mapped. The validator would reject selecting both, even though they cannot actually collide. File: `contract/manifest.json` line 62 (`php-laravel` defaults port: 9000) and line 139 (`minio` defaults api_port: 9000). |
| 2.2 | MEDIUM | **Wiremock always included in docker-compose.yml.** `generate_from_bootstrap` lines 1809-1812 always add `services/wiremock.yml` to the compose includes, regardless of whether `tooling.wiremock` was selected. The product's `generate_wiremock_service` function will generate the file if mocks exist, but the compose include will fail if the file doesn't exist and there are no mocks. |
| 2.3 | LOW | **Tester and test-dashboard always included.** Lines 1814-1822 always include `services/tester.yml` and `services/test-dashboard.yml`. These common templates are always copied (line 1602-1608), so this is consistent. But if a user doesn't select QA tooling, they still get a Playwright container and a busybox dashboard. The manifest has `qa` and `qa-dashboard` as optional tooling items, but the generated product always includes them. |
| 2.4 | LOW | **`APP_INIT_SCRIPT` is not set in generated project.env.** The product devstack.sh checks for `APP_INIT_SCRIPT` (line 403), and `generate_from_bootstrap` creates `app/init.sh` (line 1900-1906), but the generated `project.env` (lines 1659-1687) never sets `APP_INIT_SCRIPT=app/init.sh`. The init script will never run in a bootstrapped product. |
| 2.5 | LOW | **FRONTEND_SOURCE hardcoded in project.env.** `generate_from_bootstrap` writes `FRONTEND_SOURCE=./frontend` (line 1669) unconditionally, even when no frontend is selected. This is harmless but messy. |

---

## 3. Product Review

### Files Reviewed

- `product/devstack.sh` (1009 lines)
- `product/certs/generate.sh` (148 lines)
- `product/.gitignore` (11 lines)

### Self-containment Check

The product devstack.sh has **no references to the factory**. No `core/`, no `templates/`, no `contract/`. It sources `project.env` from its own directory (`PROJECT_DIR`). All paths are relative to the product directory. This is correct.

### cmd_start (lines 360-457)

The start flow:
1. Validates config (`PROJECT_NAME`, `APP_TYPE`, port format)
2. Collects mock domains from `mocks/*/domains` into `domains.txt`
3. Generates `caddy/Caddyfile` (3 routing modes: PHP, frontend+backend, plain proxy)
4. Generates `services/caddy.yml` (dynamic: includes mock domain aliases)
5. Generates `services/wiremock.yml` (dynamic: includes mock volume mounts)
6. Runs `docker compose up --build -d`
7. Waits for cert-gen and database
8. Runs init script if configured
9. Prints summary

The dynamic files are correctly listed in `.gitignore`: `domains.txt`, `caddy/Caddyfile`, `services/caddy.yml`, `services/wiremock.yml`.

### cmd_stop (lines 462-483)

**Non-destructive by default: Yes.** Default `stop` runs `docker compose down --remove-orphans` (preserves volumes). The `--clean` flag adds `-v` to also remove volumes, plus cleans test artifacts and recordings. This is correct.

### validate_config (lines 70-97)

Validates `PROJECT_NAME` (required, regex), `APP_TYPE` (required), and port variables (`HTTP_PORT`, `HTTPS_PORT` must be numeric). This is minimal but catches the important things.

Missing: no validation of `DB_TYPE` or `APP_TYPE` against expected values. A typo in `APP_TYPE` would only fail later at `docker compose` time, not at validation.

### Mock Management Commands

All mock commands are present and functional:
- `new-mock` (lines 663-718): scaffolds directory, domains file, example mapping
- `reload-mocks` (lines 637-658): calls WireMock `/__admin/mappings/reset`
- `record` (lines 723-812): temporary WireMock in record/proxy mode
- `apply-recording` (lines 817-890): copies recordings with `bodyFileName` path fixup
- `verify-mocks` (lines 895-944): tests HTTPS reachability from inside the app container

### Cert Generation (product/certs/generate.sh)

**Domain change detection: implemented.** Lines 22-44 compare existing cert SANs against expected SANs from `domains.txt`. If they match, cert generation is skipped with "Certificates up to date." This avoids unnecessary regeneration.

**PKI chain is correct:** Root CA (10-year validity, v3_ca extensions) signs a server certificate (1-year validity, v3_server extensions with serverAuth EKU). SANs include localhost, all mock domains, and `${PROJECT_NAME}.local`.

### Findings

| ID | Severity | Finding |
|----|----------|---------|
| 3.1 | HIGH | **Product Caddyfile uses `handle_path` for /test-results/*.** File: `product/devstack.sh` lines 152, 166, 181. `handle_path` strips the matched prefix from the URI before passing it to the handler. This means a request to `/test-results/20240101/report/index.html` becomes `/20240101/report/index.html` inside the handler. With `root * /srv/test-results`, this maps to `/srv/test-results/20240101/report/index.html` which IS correct. However, the factory's `core/caddy/generate-caddyfile.sh` also uses `handle_path` for test-results (lines 77, 100, 123) -- consistent. So this actually works correctly. Downgrading: not a bug. |
| 3.2 | MEDIUM | **Product Caddyfile generator (plain proxy mode, line 177-186) puts `reverse_proxy` before `handle_path`.** In Caddy, a bare `reverse_proxy` outside any `handle` directive is a catch-all that matches first. This means `/test-results/*` requests would be proxied to the app instead of being served as static files. The `handle_path /test-results/*` block (line 181) would never match because `reverse_proxy` already consumed the request. The factory's generator (`core/caddy/generate-caddyfile.sh` lines 118-129) has the same bug. The PHP and frontend modes are fine because they use `handle` and `handle_path` blocks that scope their matching. |
| 3.3 | MEDIUM | **Network name inconsistency between factory old-system and product.** The old factory compose generator (`core/compose/generate.sh` line 425) creates a network named `${PROJECT_NAME}-internal`. The product templates and `generate_caddy_service` (line 264) use `devstack-internal`. The docker-compose.yml generated by `generate_from_bootstrap` (line 1829) defines `devstack-internal`. Service templates use `devstack-internal`. This is internally consistent within the product system, but the old system uses `${PROJECT_NAME}-internal`. The `cmd_record` function in the factory's devstack.sh (line 583) hardcodes `--network "${PROJECT_NAME}_${PROJECT_NAME}-internal"` while the product's cmd_record (line 781) uses `--network "${PROJECT_NAME}_devstack-internal"`. These are different network names. |
| 3.4 | LOW | **`APP_INIT_SCRIPT` is referenced but never set.** Product's `cmd_start` (line 403) checks `${APP_INIT_SCRIPT:-}` but the generated `project.env` does not include this variable. The init script at `app/init.sh` (created by factory at line 1900) will never run unless the user manually adds `APP_INIT_SCRIPT=app/init.sh` to project.env. |
| 3.5 | LOW | **Product stop default behavior is non-destructive, but factory stop is destructive.** Product's `cmd_stop` default (line 479) preserves volumes. Factory's `cmd_stop` (line 210) always runs `down -v` (destroys volumes). The help text in the factory says "Stop and remove everything (clean slate)" which is accurate, but this behavioral difference could confuse users who work with both. |

**Correction on 3.2**: On deeper analysis, in Caddy v2, directives within the same site block are sorted by Caddy's directive ordering. `handle_path` has higher priority than `reverse_proxy` in Caddy's sort order. So the `handle_path /test-results/*` would actually match before `reverse_proxy`. This is NOT a bug -- Caddy's automatic directive ordering handles it. Downgrading to informational.

---

## 4. Template Review

### All 17 Service Templates + 3 Common + Dockerfiles

**Criterion: Does every service.yml have a `services:` top-level key?**

| Template | Has `services:` key? |
|----------|---------------------|
| apps/node-express/service.yml | Yes (line 1) |
| apps/go/service.yml | Yes (line 1) |
| apps/php-laravel/service.yml | Yes (line 1) |
| apps/python-fastapi/service.yml | Yes (line 1) |
| apps/rust/service.yml | Yes (line 1) |
| frontends/vite/service.yml | Yes (line 1) |
| databases/postgres/service.yml | Yes (line 1) |
| databases/mariadb/service.yml | Yes (line 1) |
| extras/redis/service.yml | Yes (line 1) |
| extras/nats/service.yml | Yes (line 1) |
| extras/minio/service.yml | Yes (line 1) |
| extras/mailpit/service.yml | Yes (line 1) |
| extras/db-ui/service.yml | Yes (line 1) |
| extras/swagger-ui/service.yml | Yes (line 1) |
| extras/prometheus/service.yml | Yes (line 1) |
| extras/grafana/service.yml | Yes (line 1) |
| extras/dozzle/service.yml | Yes (line 1) |
| common/cert-gen.yml | Yes (line 1) |
| common/tester.yml | Yes (line 1) |
| common/test-dashboard.yml | Yes (line 1) |

All pass.

**Criterion: Do templates use literal volume/network names (not `${PROJECT_NAME}-` prefixed)?**

The product system uses Docker Compose's native `${VAR}` interpolation from `.env`. Templates should use `devstack-` prefix for literal names, or `${PROJECT_NAME}-` if they need project-scoped names resolved by Compose.

| Template | Volume names | Network name |
|----------|-------------|--------------|
| node-express | `devstack-certs` | `devstack-internal` |
| go | `devstack-go-modules`, `devstack-certs` | `devstack-internal` |
| php-laravel | `devstack-certs` | `devstack-internal` |
| python-fastapi | `devstack-python-cache`, `devstack-certs` | `devstack-internal` |
| rust | `devstack-cargo-registry`, `devstack-cargo-target`, `devstack-certs` | `devstack-internal` |
| vite | `devstack-certs` | `devstack-internal` |
| postgres | `devstack-db-data` | `devstack-internal` |
| mariadb | `devstack-db-data` | `devstack-internal` |
| redis | (none) | `devstack-internal` |
| nats | `devstack-nats-data` | `devstack-internal` |
| minio | `devstack-minio-data` | `devstack-internal` |
| mailpit | (none) | `devstack-internal` |
| db-ui | (none) | `devstack-internal` |
| swagger-ui | (none) | `devstack-internal` |
| prometheus | (none) | `devstack-internal` |
| grafana | (none) | `devstack-internal` |
| dozzle | (none) | `devstack-internal` |
| cert-gen | `devstack-certs` | `devstack-internal` |
| tester | `devstack-certs` | `devstack-internal` |
| test-dashboard | (none) | `devstack-internal` |

All templates use `devstack-` literal prefixes -- consistent. These are resolved as literal names by Docker Compose (not interpolated).

**Criterion: Do services that use named volumes declare them?**

| Template | Volumes used | Declared in `volumes:` section? |
|----------|-------------|-------------------------------|
| node-express | `devstack-certs` | Yes (line 33) |
| go | `devstack-go-modules`, `devstack-certs` | Yes (lines 33-34) |
| php-laravel | `devstack-certs` | Yes (line 32) |
| python-fastapi | `devstack-python-cache`, `devstack-certs` | Yes (lines 35-36) |
| rust | `devstack-cargo-registry`, `devstack-cargo-target`, `devstack-certs` | Yes (lines 34-36) |
| vite | `devstack-certs` | Yes (line 29) |
| postgres | `devstack-db-data` | Yes (line 20) |
| mariadb | `devstack-db-data` | Yes (line 21) |
| nats | `devstack-nats-data` | Yes (line 20) |
| minio | `devstack-minio-data` | Yes (line 23) |
| cert-gen | `devstack-certs` | Yes (line 16) |

All pass. Each template that references a named volume also declares it.

**Criterion: Do all app templates have healthchecks?**

| App template | Healthcheck |
|-------------|-------------|
| node-express | Yes: `wget --spider -q http://localhost:3000/` |
| go | Yes: `wget --spider -q http://localhost:3000/` |
| php-laravel | Yes: `php-fpm -t 2>/dev/null || exit 1` |
| python-fastapi | Yes: `wget --spider -q http://localhost:3000/` |
| rust | Yes: `wget --spider -q http://localhost:3000/` (retries: 120 -- appropriate for compile time) |
| vite | Yes: `wget --spider -q http://localhost:5173/` |

All app templates have healthchecks.

**Criterion: Are Dockerfiles well-structured?**

| Dockerfile | Layer caching | Minimal image | CA cert handling | Issues |
|-----------|---------------|---------------|-----------------|--------|
| node-express | Yes (COPY package*.json, npm install, then COPY .) | node:22-alpine | NODE_EXTRA_CA_CERTS env var | None |
| go | Yes (COPY go.mod go.sum, go mod download, then COPY .) | golang:1.24-alpine | SSL_CERT_FILE env var | None |
| php-laravel | Partial (COPY . then composer install) | php:8.3-fpm (not slim/alpine) | Entrypoint runs update-ca-certificates | Image is 500MB+ vs ~100MB alpine. Intentional for extensions. |
| python-fastapi | Yes (COPY requirements.txt, pip install, no source COPY) | python:3.12-slim | REQUESTS_CA_BUNDLE + SSL_CERT_FILE + CURL_CA_BUNDLE | gcc/libpq-dev included (previously noted as missing, now fixed) |
| rust | Yes (dummy main.rs trick for dep caching) | rust:1.83-slim | SSL_CERT_FILE env var | None |
| vite | Yes (COPY package*.json, npm install, no source COPY) | node:22-alpine | NODE_EXTRA_CA_CERTS env var | None |

**Criterion: Is the frontend service named `frontend`?**

Yes. `templates/frontends/vite/service.yml` line 2: `frontend:`.

### Findings

| ID | Severity | Finding |
|----|----------|---------|
| 4.1 | HIGH | **Prometheus template mounts from factory path.** `templates/extras/prometheus/service.yml` line 8: `./templates/extras/prometheus/prometheus.yml:/etc/prometheus/prometheus.yml:ro`. This is a relative path from the FACTORY root, not the product. In a bootstrapped product, this file would be at `services/prometheus.yml` (copied by `generate_from_bootstrap` line 1652-1654). The volume mount path is wrong in the product context. |
| 4.2 | HIGH | **Grafana template mounts from factory path.** `templates/extras/grafana/service.yml` line 14: `./templates/extras/grafana/provisioning:/etc/grafana/provisioning:ro`. Same problem. In the product, the provisioning directory is at `services/grafana-provisioning/` (copied at line 1650-1651). The mount path in the template is wrong. |
| 4.3 | MEDIUM | **Swagger UI mounts a specific file that may not exist.** `templates/extras/swagger-ui/service.yml` line 10: `${APP_SOURCE}/docs/openapi.json:/spec/openapi.json:ro`. If swagger-ui is selected, `generate_from_bootstrap` creates a placeholder (lines 1909-1922). But the `${APP_SOURCE}` variable is `./app` in the product context. Docker Compose will fail if the file doesn't exist. The factory creates it, but users who delete or move it will get a cryptic error. |
| 4.4 | LOW | **PHP-Laravel healthcheck tests PHP-FPM config, not app responsiveness.** `php-fpm -t` tests the config syntax, not whether the app is actually serving requests. A healthcheck like `curl -sf http://localhost:9000/` would be better, but PHP-FPM doesn't speak HTTP -- it speaks FastCGI. The current approach is a reasonable compromise. |
| 4.5 | LOW | **Rust healthcheck has 120 retries at 5s intervals = 10 minutes.** This is generous but appropriate for Rust compilation. |
| 4.6 | LOW | **Redis has no `ports:` directive.** This is intentional (internal-only access), and documented in ADDING_SERVICES.md. |

---

## 5. Proxy Layer Review

### Files Reviewed

- `core/caddy/generate-caddyfile.sh` (182 lines) -- factory old system
- `product/devstack.sh` lines 121-208 -- product Caddyfile generator

### Three Routing Modes

**1. PHP FastCGI** (factory line 65-84, product line 145-158):

```
localhost:80, localhost:443, ${PROJECT_NAME}.local:80, ${PROJECT_NAME}.local:443 {
    tls /certs/server.crt /certs/server.key
    root * /var/www/html/public
    php_fastcgi app:9000
    file_server
    handle_path /test-results/* { ... }
}
```

Correct. `php_fastcgi` passes to PHP-FPM. `root` sets the document root. `file_server` serves static assets. Test results are handled separately.

**2. Frontend + Backend path-based routing** (factory line 86-111, product line 159-175):

```
handle ${FRONTEND_API_PREFIX}/* {
    reverse_proxy app:3000
}
handle_path /test-results/* { ... }
handle {
    reverse_proxy frontend:${FRONTEND_PORT}
}
```

Uses `handle` (not `handle_path`) for API prefix -- correct. This preserves the `/api` prefix when proxying to the backend. Test results use `handle_path` to strip the prefix -- correct for static file serving. The catch-all `handle {}` routes everything else to the frontend.

**3. Plain reverse proxy** (factory line 113-131, product line 176-188):

```
reverse_proxy app:3000
handle_path /test-results/* { ... }
```

As discussed earlier, Caddy's automatic directive ordering ensures `handle_path` takes priority over `reverse_proxy`, so this works correctly.

### Mock Interception

Both generators produce the same mock block:

```
domain1.com:443, domain2.com:443 {
    tls /certs/server.crt /certs/server.key
    reverse_proxy wiremock:8080 {
        header_up X-Original-Host {http.request.host}
        header_up X-Real-IP {remote_host}
        header_up X-Forwarded-Proto {scheme}
    }
}
```

Correct. `X-Original-Host` is set from `{http.request.host}` (Caddy placeholder for the request's Host header), allowing WireMock to distinguish between different mocked APIs sharing the same instance.

### Global Options

Both generators set `auto_https off` -- correct. Caddy must not try to obtain real ACME certificates for mocked domains.

### TLS Configuration

Both generators use `tls /certs/server.crt /certs/server.key` -- correct, pointing to the certificates generated by the cert-gen container and shared via the `devstack-certs` volume.

### Findings

| ID | Severity | Finding |
|----|----------|---------|
| 5.1 | LOW | **Product Caddyfile generator is inline (210 lines inside devstack.sh) vs factory generator is a separate file.** The product's approach is cleaner for self-containment. No bug, but the two generators can drift in behavior since they're independent implementations. |
| 5.2 | INFO | **Factory Caddyfile generator checks `FRONTEND_TYPE` presence** (line 86: `elif [ -n "${FRONTEND_TYPE:-}" ]`) without checking for `!= "none"`. Product generator (line 159) checks both: `[ -n "${FRONTEND_TYPE:-}" ] && [ "${FRONTEND_TYPE}" != "none" ]`. The factory version would treat `FRONTEND_TYPE=none` as a frontend being configured, generating incorrect routing. |

---

## 6. Compose Integration (Static Trace)

Since this is a code review without Docker access, I'll trace a bootstrap flow statically.

### Trace: Go + PostgreSQL + Redis + NATS + WireMock

Input payload:
```json
{
  "contract": "devstrap-bootstrap", "version": "1",
  "project": "review-test",
  "selections": {
    "app": {"go": {}},
    "database": {"postgres": {}},
    "services": {"redis": {}, "nats": {}},
    "tooling": {"wiremock": {}}
  }
}
```

**Step 1: Extract selections** (devstack.sh lines 1490-1503)
- `project_name` = "review-test"
- `app_type` = "go"
- `db_type` = "postgres"
- `extras` = "redis,nats" (from jq merging services + observability + tooling-minus-special)
- `frontend_type` = "none"

Note: `wiremock` is special-cased (excluded from extras jq filter at line 1498: `select(. != "qa" and . != "qa-dashboard" and . != "wiremock" and . != "devcontainer")`). It gets its own include line at line 1810.

**Step 2: Directory structure created** (lines 1573-1579)
```
review-test/
  services/
  caddy/
  certs/
  app/
  tests/playwright/
  tests/results/
  mocks/
```

**Step 3: Files copied** (lines 1581-1655)
- `product/devstack.sh` -> `review-test/devstack.sh`
- `product/certs/generate.sh` -> `review-test/certs/generate.sh`
- `product/.gitignore` -> `review-test/.gitignore`
- `templates/common/cert-gen.yml` -> `review-test/services/cert-gen.yml`
- `templates/common/tester.yml` -> `review-test/services/tester.yml`
- `templates/common/test-dashboard.yml` -> `review-test/services/test-dashboard.yml`
- `templates/apps/go/service.yml` -> `review-test/services/app.yml`
- `templates/apps/go/Dockerfile` -> `review-test/app/Dockerfile`
- `templates/databases/postgres/service.yml` -> `review-test/services/database.yml`
- `templates/extras/redis/service.yml` -> `review-test/services/redis.yml`
- `templates/extras/nats/service.yml` -> `review-test/services/nats.yml`
- Mock scaffold: `review-test/mocks/example-api/` with domains and example mapping

**Step 4: project.env written** (lines 1659-1720)

Expected content:
```
PROJECT_NAME=review-test
COMPOSE_PROJECT_NAME=review-test
NETWORK_SUBNET=172.28.0.0/24
APP_TYPE=go
APP_SOURCE=./app
FRONTEND_SOURCE=./frontend
HTTP_PORT=8080
HTTPS_PORT=8443
TEST_DASHBOARD_PORT=8082
DB_TYPE=postgres
DB_PORT=5432
DB_NAME=review-test
DB_USER=review-test
DB_PASSWORD=secret
DB_ROOT_PASSWORD=root
FRONTEND_TYPE=none
FRONTEND_PORT=5173
FRONTEND_API_PREFIX=/api
NATS_PORT=4222
NATS_MONITOR_PORT=8222
```

`.env` symlinked to `project.env` (line 1690).

**Step 5: docker-compose.yml assembled** (lines 1764-1834)

```yaml
include:
  - path: services/cert-gen.yml
    project_directory: .
  - path: services/app.yml
    project_directory: .
  - path: services/caddy.yml
    project_directory: .
  - path: services/database.yml
    project_directory: .
    env_file: services/database.env
  - path: services/redis.yml
    project_directory: .
  - path: services/nats.yml
    project_directory: .
  - path: services/wiremock.yml
    project_directory: .
  - path: services/tester.yml
    project_directory: .
  - path: services/test-dashboard.yml
    project_directory: .

networks:
  devstack-internal:
    driver: bridge
    ipam:
      config:
        - subnet: ${NETWORK_SUBNET}
```

### Analysis of Generated Structure

**Does `docker-compose.yml` use `include:` with `project_directory: .`?** Yes.

**Does `ls services/` match selections?** Yes: app.yml, database.yml, redis.yml, nats.yml, plus common (cert-gen.yml, tester.yml, test-dashboard.yml) and dynamic (caddy.yml, wiremock.yml).

**Does `.env` symlink to `project.env`?** Yes (line 1690).

**Does `project.env` have `COMPOSE_PROJECT_NAME`?** Yes (line 1662).

**Do `${VAR}` references in service files resolve from root `.env`?** Yes. Docker Compose reads `.env` from the project root by default, and `project_directory: .` ensures all included files resolve relative to the root. Variables like `${PROJECT_NAME}`, `${DB_PORT}`, `${DB_NAME}` etc. in service templates will be interpolated by Docker Compose from the `.env` symlink.

**Do cross-file `depends_on` references work?** Yes. Docker Compose `include` merges all services into a single namespace. So `db-ui`'s `depends_on: db: condition: service_healthy` works even though `db` is defined in `services/database.yml` and `db-ui` is in `services/db-ui.yml`. Similarly, `tester` depends on `web` (defined in caddy.yml). This is a core feature of Docker Compose `include`.

**Do network aliases for mock domains appear on the caddy service?** Yes. The product's `generate_caddy_service` (product/devstack.sh lines 214-273) dynamically generates `services/caddy.yml` with aliases read from `domains.txt`. At runtime, `cmd_start` calls `collect_domains` then `generate_caddy_service`, which produces the aliases in the YAML.

### Findings

| ID | Severity | Finding |
|----|----------|---------|
| 6.1 | HIGH | **database.env uses `env_file` in include but `DB_CONNECTION` is only in database.env, not in project.env.** The PHP-Laravel template references `${DB_CONNECTION}` in service.yml line 14. This variable comes from `services/database.env` (written at line 1731-1737), which is loaded via the `env_file: services/database.env` on the database include (line 1788). But the app service (services/app.yml) does NOT load database.env -- it only gets variables from the root `.env` (project.env). So `${DB_CONNECTION}` in the PHP app service.yml will be EMPTY unless the user manually adds it to project.env. The factory writes it to database.env for the DATABASE container, but the APP container needs it too. |
| 6.2 | MEDIUM | **The `tester` service depends on `web` but `caddy.yml` names the service `web`.** In the common template `templates/common/tester.yml` line 16: `depends_on: web: condition: service_healthy`. The caddy service generated by the product names itself `web` (product/devstack.sh line 248: `services: web:`). This is consistent. But if caddy.yml is not generated (e.g., no mocks and product start fails), the tester would fail on dependency resolution. |
| 6.3 | LOW | **`env_file` in include may cause confusion.** The database include has `env_file: services/database.env`. This makes the variables available to the database service AND as build args, but NOT to other services. Users might expect `DB_CONNECTION` to be globally available. |

---

## 7. Test Review

### Files Reviewed

- `tests/contract/test-contract.sh` (~605 lines)
- `tests/contract/fixtures/` (28 fixture files)

### Test Categories

**--options (DISCOVER) tests**: 57+ assertions covering:
- Schema envelope (contract, version)
- All 6 categories exist
- Category metadata (selection type, required)
- All items in all categories
- Default values for all port-having items
- Items without defaults correctly lack the key
- Dependencies (requires arrays)
- Frontend category
- Presets (4 presets, prompts field)
- Wiring rules (count, first rule target)

**--bootstrap validation tests**: 25+ assertions covering:
- INVALID_CONTRACT
- INVALID_VERSION
- INVALID_PROJECT_NAME
- UNKNOWN_CATEGORY
- UNKNOWN_ITEM
- MISSING_REQUIRED (including empty selections)
- INVALID_SINGLE_SELECT
- MISSING_DEPENDENCY (specific and wildcard, both pass and fail cases)
- CONFLICT (using test manifest with conflict definitions)
- INVALID_OVERRIDE
- PORT_CONFLICT (default collision, override collision, override resolution)
- Edge cases: null category value, multiple errors at once
- stdin mode
- Error response envelope format
- CLI error handling (no --config, missing file, invalid JSON)

**--bootstrap generation tests** (require Docker): 60+ assertions covering:
- Test 1: Full valid payload (node-express) -- checks exit code, response structure, generated files, project.env content, compose includes
- Test 2: Overrides -- verifies overridden ports appear in response and project.env
- Test 3: Minimal valid (app only) -- verifies no database.yml, FRONTEND_TYPE=none
- Test 4: PHP app type -- verifies APP_TYPE and Dockerfile
- Test 5: Go app type -- verifies APP_TYPE
- Test 6: Devcontainer generation -- verifies .devcontainer/ created
- Test 7: Observability stack -- verifies service files, compose includes, port vars
- Test 8: Frontend generation -- verifies frontend vars, wiring, scaffolding

**Regression tests**: help command works, shows --options and --bootstrap.

### Coverage Assessment

| Area | Covered? | Notes |
|------|----------|-------|
| Port collision | Yes | 3 fixtures: default, override, resolved |
| Presets | Partially | Preset LISTING tested, but preset USAGE through cmd_init is not tested (requires TTY) |
| Wiring | Partially | Wiring rule count and first rule target checked; wiring resolution in bootstrap response checked for frontend |
| Frontend | Yes | Full generation test with frontend directory, Dockerfile, compose includes |
| Product directory structure | Yes | Checks for services/, app/, mocks/, devstack.sh, docker-compose.yml |
| Self-containment | No | No test verifies the product can `docker compose config` without the factory |
| Caddyfile generation | No | No test checks generated Caddyfile content |
| Dynamic service generation | No | No test checks caddy.yml or wiremock.yml generation |
| Product CLI commands | No | No test exercises product/devstack.sh commands |
| Edge cases: empty extras | Yes | Minimal valid test has no extras |
| Edge cases: conflicting items | Yes (indirectly) | Uses test manifest, not production manifest (no conflicts in production manifest) |
| Edge cases: all categories selected | No | No test selects from every category simultaneously |
| Wiring env vars in project.env | No | No test checks that REDIS_URL, NATS_URL etc. are written to project.env |
| database.env content | No | No test checks DB_CONNECTION value |

### Findings

| ID | Severity | Finding |
|----|----------|---------|
| 7.1 | HIGH | **No test verifies wiring env vars are written to project.env.** The `resolve_wiring` function and `generate_from_bootstrap` write wiring values (REDIS_URL, NATS_URL, S3_ENDPOINT etc.) to project.env, but no test checks this. A regression in wiring resolution would go undetected. |
| 7.2 | MEDIUM | **No test for product self-containment.** There's no test that runs `docker compose -f <product>/docker-compose.yml config` to verify the product is valid Compose. Tests check file existence but not YAML validity or variable resolution. |
| 7.3 | MEDIUM | **No test for Caddyfile generation.** Both the factory and product generate Caddyfiles, but no test checks the output for correct routing rules, mock domain blocks, or TLS configuration. |
| 7.4 | MEDIUM | **Conflict test uses synthetic manifest, not production manifest.** The production manifest has no `conflicts` entries at all. The conflict test (lines 291-312) uses `fixtures/manifest-with-conflict.json`. This proves the conflict LOGIC works, but not that the production manifest has any conflicts to enforce. If someone adds a conflicting item to the manifest, the validation would work. But no production items conflict. |
| 7.5 | LOW | **No test for python-fastapi or rust app types.** Tests cover node-express, php-laravel, and go. The two newer app types have no generation tests. |
| 7.6 | LOW | **No test for preset selection through init.** The `cmd_init --preset` code path is untested because it requires TTY interaction. |

---

## 8. Documentation Review

### Files Reviewed

| Document | Lines | Status |
|----------|-------|--------|
| README.md | ~199 | Mostly accurate |
| docs/QUICKSTART.md | ~100 | Mostly accurate |
| docs/ARCHITECTURE.md | ~93 | Accurate |
| docs/ARCHITECTURE-NEXT.md | ~330 | Accurate and insightful |
| docs/ADDING_SERVICES.md | ~451 | Contains stale instructions |
| docs/CREATING_TEMPLATES.md | ~466 | Contains stale instructions |
| docs/DEVELOPMENT.md | ~417 | Contains stale references |
| DEVSTRAP-POWERHOUSE-CONTRACT.md | ~575 | Accurate |
| docs/AI_BOOTSTRAP.md | ~261 | Significantly stale |

### Accuracy Assessment

**README.md**: The catalog tables match manifest.json exactly. The architecture diagram is accurate. The "Quick Start" section references the old factory system (`./devstack.sh start` from the factory root), which still works. The configuration section mentions `EXTRAS=redis,mailpit` which is the OLD system's approach (comma-separated in project.env). The new system uses per-service YAML files in services/. This is misleading for bootstrapped projects.

**QUICKSTART.md**: References `./devstack.sh generate` which is the old system. The CLI reference is accurate. The preset examples work.

**ADDING_SERVICES.md**: Major staleness issues. The document instructs users to:
1. Edit `project.env` EXTRAS variable (old system, line 8-10)
2. Use `${PROJECT_NAME}-` prefixed volumes and networks (line 56-66), but actual templates now use `devstack-` prefix
3. Add sed substitutions to `core/compose/generate.sh` (line 133-139), which is only relevant to the old system
4. Create `volumes.yml` sidecar files (line 100-116), which the new product system doesn't use (volumes are declared inline in each service.yml)

The document shows NATS service.yml examples with `${PROJECT_NAME}-internal` network and `${PROJECT_NAME}-nats-data` volume (lines 56-66), but the actual templates use `devstack-internal` and `devstack-nats-data`.

**CREATING_TEMPLATES.md**: Similar staleness. Shows service.yml examples using `${PROJECT_NAME}-certs`, `${PROJECT_NAME}-internal` (lines 92-109), but actual templates use `devstack-certs`, `devstack-internal`. Also references `core/compose/generate.sh` for volume registration (lines 122-149), which is old-system-only. The Python-FastAPI example at line 261 shows the old Dockerfile without gcc/libpq-dev, but the actual Dockerfile has been fixed.

**DEVELOPMENT.md**: References `.generated/docker-compose.yml` (lines 99, 102) which is old-system. Product system doesn't use `.generated/`. Also references `core/caddy/generate-caddyfile.sh` (line 301-302) which is factory-only.

**nginx references**: One remaining reference in `core/caddy/generate-caddyfile.sh` line 14 (`# Replaces: core/nginx/generate-conf.sh`) which is a historical comment and harmless. All nginx references in .md files are in research docs, review docs, and the migration spec -- historical/contextual. No active docs claim nginx is used.

**Contract changelog**: Complete. The 2026-03-20 entry documents all catalog expansion changes, migration notes for PowerHouse, and v1 compatibility.

### Findings

| ID | Severity | Finding |
|----|----------|---------|
| 8.1 | HIGH | **ADDING_SERVICES.md and CREATING_TEMPLATES.md describe the old architecture.** Both docs instruct users to edit `core/compose/generate.sh` sed pipelines, use `${PROJECT_NAME}-` prefixed names, create `volumes.yml` sidecars, and edit `project.env` EXTRAS. None of these apply to the product system. A contributor following these guides would make changes that only work with the old system. |
| 8.2 | HIGH | **AI_BOOTSTRAP.md reading order is wrong for the product architecture.** It directs agents to `project.env` -> `devstack.sh` -> `core/compose/generate.sh` -> `core/caddy/generate-caddyfile.sh`. For the product system, the reading order should be: `product/devstack.sh` -> `contract/manifest.json` -> `templates/` -> `devstack.sh` (factory functions). |
| 8.3 | MEDIUM | **README.md Configuration section shows old-system EXTRAS variable.** `EXTRAS=redis,mailpit` is only used by the old compose generator. Bootstrapped products don't use EXTRAS -- they have individual service YAML files. |
| 8.4 | MEDIUM | **DEVELOPMENT.md references .generated/ directory.** Product system has no .generated/ directory. The VS Code devcontainer example (line 102) points to `../../.generated/docker-compose.yml` which doesn't exist in products. |
| 8.5 | LOW | **QUICKSTART.md still references `./devstack.sh generate`.** This command exists in the factory but not in the product. Bootstrapped product users cannot run this command. |

---

## 9. Overall Assessment

### 1. Architecture Quality

**Score: 7/10**

The factory/product conceptual separation is excellent. ARCHITECTURE-NEXT.md shows deep understanding of the problem. The implementation is partially complete:

Strengths:
- Product devstack.sh is truly self-contained (no factory references)
- Docker Compose `include` approach is elegant and correct
- Dynamic file generation at runtime is minimal (just Caddyfile, caddy.yml, wiremock.yml)
- Template-based assembly is clean -- the factory copies, doesn't generate

Weaknesses:
- Two parallel architectures coexist in the same script, creating confusion
- The old system (core/ generators, .generated/ directory) is still functional and has its own CLI commands
- No deprecation path for the old system
- Documentation hasn't been updated to reflect the product architecture

### 2. Implementation Quality

**Score: 7.5/10**

Strengths:
- The validation pipeline is thorough (11 checks, all errors collected)
- Wiring resolution is clever and handles wildcards correctly
- JSON handling is careful (using `printf '%s\n'` instead of `echo` to avoid flag interpretation)
- Error responses are always valid JSON
- The product's dynamic file generation is well-implemented

Weaknesses:
- `generate_from_bootstrap` is 470+ lines with deeply nested conditional logic
- Port override extraction (lines 1531-1566) is 35 lines of repetitive if/jq/fi blocks
- Prometheus and Grafana templates have broken volume mounts (factory paths, not product paths)
- `DB_CONNECTION` variable is written to database.env but needed by the app service
- `APP_INIT_SCRIPT` is never set in generated project.env

### 3. Test Coverage

**Score: 7/10**

Strengths:
- 184 tests (the contract says, though the test file has ~130 assertions visible)
- Validation tests are comprehensive -- every error code is exercised
- Generation tests verify file existence, content, and response format
- Port collision tested in all three scenarios (default, override, resolved)

Weaknesses:
- No product self-containment test (compose config validation)
- No Caddyfile generation test
- No wiring env var test
- No test for python-fastapi or rust app types
- No integration-level test for the product CLI

### 4. Documentation Quality

**Score: 5/10**

The documentation is well-written and comprehensive for the OLD system. It is significantly stale for the PRODUCT system. A new developer following the contributor guides (ADDING_SERVICES.md, CREATING_TEMPLATES.md) would produce changes incompatible with bootstrapped products.

ARCHITECTURE-NEXT.md is the best document in the repo -- it captures reasoning, not just facts. The contract document is excellent.

### 5. Contract Stability

**Score: 9/10**

The contract is well-designed with clear versioning rules. All catalog expansion changes are v1-compatible. The changelog is complete. The separation of locked vs flexible fields is thoughtful. The only minor issue is that `presets` and `wiring` in the options response are top-level keys (not inside `categories`), which the contract schema doesn't specify -- they're described in the example but not in the formal schema.

### 6. Risk Assessment

**Critical risks:**

1. **Prometheus and Grafana are broken in bootstrapped products.** Their templates mount files from factory-relative paths that don't exist in the product directory. Any user who bootstraps with observability will get Docker Compose errors.

2. **PHP-Laravel `DB_CONNECTION` doesn't reach the app container.** It's written to `database.env` but the app service doesn't load that env file. PHP-Laravel apps will have an empty `DB_CONNECTION` variable, breaking database connections.

3. **Documentation guides new contributors to the wrong architecture.** Following ADDING_SERVICES.md produces changes that only work with the old system.

**Moderate risks:**

4. **`APP_INIT_SCRIPT` silently unused.** The factory creates `app/init.sh` but doesn't configure the product to run it. Users who put setup logic there will wonder why it doesn't execute.

5. **Wiremock include always present in compose.** If the user didn't select wiremock AND has no mocks directory, the compose include for `services/wiremock.yml` will fail because the product's start function won't generate the file.

### 7. Recommendations

**Must fix (before next release):**

1. Fix Prometheus template volume mount: change `./templates/extras/prometheus/prometheus.yml` to `./services/prometheus.yml` (or equivalent product-relative path).

2. Fix Grafana template volume mount: change `./templates/extras/grafana/provisioning` to `./services/grafana-provisioning` (or equivalent product-relative path).

3. Fix `DB_CONNECTION` propagation: either add it to project.env (so all services can read it) or add `env_file: services/database.env` to the app include in docker-compose.yml.

4. Set `APP_INIT_SCRIPT=app/init.sh` in the generated project.env.

5. Make wiremock include conditional in docker-compose.yml: only include it if wiremock was selected.

**Should fix (high value):**

6. Update ADDING_SERVICES.md and CREATING_TEMPLATES.md for the product architecture. The examples should use `devstack-` prefixed names and reference the bootstrap flow, not `core/compose/generate.sh`.

7. Update AI_BOOTSTRAP.md with correct reading order for the product system and mark the old system as legacy.

8. Add test for wiring env vars in project.env (e.g., verify REDIS_URL is written when redis + app are co-selected).

9. Add test for product `docker compose config` validation.

**Should consider:**

10. Deprecate or remove the old system (`core/compose/generate.sh`, `core/caddy/generate-caddyfile.sh`, the factory's `cmd_start`/`cmd_stop`/`cmd_generate`). The product system is superior. Keeping both creates maintenance burden and documentation confusion.

11. Refactor port override extraction in `generate_from_bootstrap` -- the 35 lines of if/jq/fi blocks could be replaced with a single jq expression that extracts all overrides.

12. Add a `full-catalog` test fixture that selects one item from every category to verify no inter-service conflicts in the complete stack.

13. Address the MinIO/PHP-Laravel port 9000 false positive in port collision validation. Consider separating "host-exposed ports" from "internal container ports" in the manifest defaults.

---

## Appendix: File Reference

| File | Lines | Role |
|------|-------|------|
| `devstack.sh` | ~2099 | Factory CLI (old + new systems) |
| `product/devstack.sh` | 1009 | Product runtime CLI |
| `product/certs/generate.sh` | 148 | Certificate generator with domain change detection |
| `product/.gitignore` | 11 | Tracks what's generated vs committed |
| `contract/manifest.json` | 238 | Full catalog: categories, items, presets, wiring |
| `core/compose/generate.sh` | 443 | OLD compose generator (sed-based) |
| `core/caddy/generate-caddyfile.sh` | 182 | OLD/FACTORY Caddyfile generator |
| `templates/apps/*/service.yml` | 5 files | Backend service definitions |
| `templates/apps/*/Dockerfile` | 5 files | Backend container builds |
| `templates/frontends/vite/service.yml` | 29 | Frontend service definition |
| `templates/frontends/vite/Dockerfile` | 16 | Frontend container build |
| `templates/databases/*/service.yml` | 2 files | Database service definitions |
| `templates/extras/*/service.yml` | 9 files | Extra service definitions |
| `templates/common/*.yml` | 3 files | Always-included services |
| `tests/contract/test-contract.sh` | ~605 | Contract test suite |
| `tests/contract/fixtures/` | 28 files | Test payloads |
