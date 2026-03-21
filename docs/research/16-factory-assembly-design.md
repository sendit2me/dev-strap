# Factory Assembly Design

> **Date**: 2026-03-21
> **Covers**: Complete file manifest of factory output, variable substitution strategy, caddy.yml dynamic generation, wiring output to project.env, root docker-compose.yml assembly, factory implementation changes, migration path for existing projects
> **Source files studied**: `devstack.sh` (generate_from_bootstrap, resolve_wiring), `core/compose/generate.sh`, `core/caddy/generate-caddyfile.sh`, all templates, `contract/manifest.json`
> **Depends on**: [14-compose-include-patterns.md](14-compose-include-patterns.md) for include mechanics, [15-product-devstack-design.md](15-product-devstack-design.md) for product structure, [ARCHITECTURE-NEXT.md](../ARCHITECTURE-NEXT.md) for factory/product separation

---

## Table of Contents

1. [File Manifest](#1-file-manifest)
2. [Variable Substitution Strategy](#2-variable-substitution-strategy)
3. [The caddy.yml Problem](#3-the-caddyyml-problem)
4. [Wiring Output](#4-wiring-output)
5. [Root docker-compose.yml Assembly](#5-root-docker-composeyml-assembly)
6. [Factory Implementation](#6-factory-implementation)
7. [Migration Path](#7-migration-path)

---

## 1. File Manifest

### 1.1 Complete output for Go + Vite + PostgreSQL + Redis + WireMock

This is the maximal common case. The factory produces exactly these files when a user selects Go backend, Vite frontend, PostgreSQL database, Redis, and WireMock (API mocking).

```
my-app/                                  Source in factory
├── devstack.sh                          product/devstack.sh (always same)
├── docker-compose.yml                   ASSEMBLED (include list + networks + volumes)
├── project.env                          ASSEMBLED (from selections + wiring)
├── services/
│   ├── cert-gen.yml                     templates/common/cert-gen.yml (always same)
│   ├── app.yml                          templates/apps/go/service.yml
│   ├── frontend.yml                     templates/frontends/vite/service.yml
│   ├── database.yml                     templates/databases/postgres/service.yml
│   ├── redis.yml                        templates/extras/redis/service.yml
│   ├── tester.yml                       templates/common/tester.yml (always same)
│   └── test-dashboard.yml               templates/common/test-dashboard.yml (always same)
├── caddy/
│   └── (empty — generated at start time by product devstack.sh)
├── certs/
│   └── generate.sh                      core/certs/generate.sh (always same)
├── app/
│   ├── Dockerfile                       templates/apps/go/Dockerfile
│   ├── .air.toml                        templates/apps/go/.air.toml
│   └── init.sh                          GENERATED (scaffold)
├── frontend/
│   ├── Dockerfile                       templates/frontends/vite/Dockerfile
│   └── package.json                     GENERATED (project-name-specific)
├── mocks/                               GENERATED (empty scaffold)
└── tests/
    ├── playwright/
    │   ├── package.json                 GENERATED (always same)
    │   └── playwright.config.ts         GENERATED (always same)
    └── results/                         (empty dir)
```

### 1.2 Files by category

#### Always produced (every project)

| File | Source | Notes |
|------|--------|-------|
| `devstack.sh` | `product/devstack.sh` | Identical for every project. ~350-600 lines. |
| `docker-compose.yml` | Assembled by factory | Include list varies by selections |
| `project.env` | Assembled by factory | Values from selections + wiring rules |
| `services/cert-gen.yml` | `templates/common/cert-gen.yml` | Always present (TLS certs) |
| `certs/generate.sh` | `core/certs/generate.sh` | OpenSSL cert generation script |
| `app/Dockerfile` | `templates/apps/{type}/Dockerfile` | App-type-specific |
| `app/init.sh` | Generated scaffold | User edits after creation |

#### Produced based on selections

| File | When produced | Source |
|------|---------------|--------|
| `services/app.yml` | Always (app is required) | `templates/apps/{type}/service.yml` |
| `services/frontend.yml` | If frontend selected | `templates/frontends/{type}/service.yml` |
| `services/database.yml` | If database selected | `templates/databases/{type}/service.yml` |
| `services/redis.yml` | If redis selected | `templates/extras/redis/service.yml` |
| `services/mailpit.yml` | If mailpit selected | `templates/extras/mailpit/service.yml` |
| `services/nats.yml` | If nats selected | `templates/extras/nats/service.yml` |
| `services/minio.yml` | If minio selected | `templates/extras/minio/service.yml` |
| `services/prometheus.yml` | If prometheus selected | `templates/extras/prometheus/service.yml` |
| `services/grafana.yml` | If grafana selected | `templates/extras/grafana/service.yml` |
| `services/dozzle.yml` | If dozzle selected | `templates/extras/dozzle/service.yml` |
| `services/db-ui.yml` | If db-ui selected | `templates/extras/db-ui/service.yml` |
| `services/swagger-ui.yml` | If swagger-ui selected | `templates/extras/swagger-ui/service.yml` |
| `services/tester.yml` | If qa selected | `templates/common/tester.yml` |
| `services/test-dashboard.yml` | If qa-dashboard selected | `templates/common/test-dashboard.yml` |
| `frontend/Dockerfile` | If frontend selected | `templates/frontends/{type}/Dockerfile` |
| `frontend/package.json` | If frontend selected | Generated with project name |
| `.devcontainer/` | If devcontainer selected | `templates/apps/{type}/.devcontainer/` |
| `mocks/` | If wiremock selected | Empty scaffold directory |
| `tests/playwright/` | If qa selected | Config scaffold |
| `app/.air.toml` | If Go selected | `templates/apps/go/.air.toml` |

#### Produced by supporting services with extra files

| Service | Extra file(s) | Source |
|---------|---------------|--------|
| Prometheus | `config/prometheus.yml` | `templates/extras/prometheus/prometheus.yml` |
| Grafana | `config/grafana/provisioning/datasources/prometheus.yml` | `templates/extras/grafana/provisioning/...` |

These config files need to be copied alongside the service YAML. The service template references them via volume mounts. In the current system, the mount points to the factory's template directory (e.g., `${DEVSTACK_DIR}/templates/extras/prometheus/prometheus.yml`). In the product, they must be local.

#### NOT produced (stay in factory)

| File | Why stays in factory |
|------|---------------------|
| `contract/manifest.json` | Catalog of options |
| `templates/*/` | Template library |
| `core/compose/generate.sh` | Replaced by static includes |
| `core/caddy/generate-caddyfile.sh` | Product has inline Caddyfile gen |
| `docs/` | Factory documentation |
| Factory `devstack.sh` | Factory CLI (contract, init, bootstrap) |
| Factory tests | Test the factory, not the product |

### 1.3 File count summary

| Scenario | Service files | Total files (approx) |
|----------|---------------|---------------------|
| Minimal (app + no extras) | 2 (cert-gen, app) | ~10 |
| Common (app + db + redis + qa + wiremock) | 7 | ~20 |
| Full (app + frontend + db + redis + all extras + all obs) | 14 | ~30 |
| Maximal (Go + Vite + PostgreSQL + everything) | 15 | ~35 |

---

## 2. Variable Substitution Strategy

### 2.1 The key insight: no substitution needed

The current `core/compose/generate.sh` runs **17+ sed commands** per service file to replace `${VAR}` with concrete values:

```bash
# Current: 17 sed commands per extra service
cat "${extra_file}" | \
    sed "s|\${PROJECT_NAME}|${PROJECT_NAME}|g" | \
    sed "s|\${DB_NAME}|${DB_NAME}|g" | \
    sed "s|\${DB_USER}|${DB_USER}|g" | \
    sed "s|\${DB_PASSWORD}|${DB_PASSWORD}|g" | \
    sed "s|\${MAILPIT_PORT}|${MAILPIT_PORT:-8025}|g" | \
    ...etc...
```

This is unnecessary. Docker Compose natively resolves `${VAR}` from the project's `.env` file. The service template files already use `${VAR}` syntax. The factory should copy them verbatim.

### 2.2 What changes in service file templates

**Nothing.** The templates are already correct. For example, `templates/extras/redis/service.yml`:

```yaml
  redis:
    image: redis:alpine
    container_name: ${PROJECT_NAME}-redis
    networks:
      - ${PROJECT_NAME}-internal
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 5s
      timeout: 3s
      retries: 10
```

This file is copied as-is to `services/redis.yml`. Docker Compose resolves `${PROJECT_NAME}` from `project.env` at runtime.

### 2.3 Templates that need modification

Some templates currently reference factory-specific paths that need fixing:

| Template | Current issue | Fix |
|----------|---------------|-----|
| `templates/apps/go/service.yml` | Uses `${APP_SOURCE}` (absolute path via sed) | Change to `./app` relative path |
| `templates/extras/prometheus/service.yml` | Mounts `${DEVSTACK_DIR}/templates/extras/prometheus/prometheus.yml` | Change to `./config/prometheus.yml` |
| `templates/extras/grafana/service.yml` | Mounts `${DEVSTACK_DIR}/templates/extras/grafana/provisioning` | Change to `./config/grafana/provisioning` |
| `templates/extras/swagger-ui/service.yml` | Mounts `${APP_SOURCE}/docs/openapi.json` | Change to `./app/docs/openapi.json` |
| `templates/extras/dozzle/service.yml` | Mounts `/var/run/docker.sock` | Fine as-is (host path) |

### 2.4 The path resolution change

In the current system, templates use `${APP_SOURCE}` and the compose generator resolves it to an absolute path via sed:

```bash
# Current generator
APP_SOURCE_ABS="${DEVSTACK_DIR}/${APP_SOURCE#./}"
# ... then sed replaces ${APP_SOURCE} with the absolute path
```

In the new system, service files use relative paths from the project root. Docker Compose resolves relative paths from the project directory (or `project_directory` if set in the include).

**Before** (template, sed-substituted):
```yaml
  app:
    build:
      context: ${APP_SOURCE}           # sed replaces with /home/user/my-app/app
    volumes:
      - ${APP_SOURCE}:/app             # sed replaces with /home/user/my-app/app:/app
```

**After** (product, no substitution):
```yaml
  app:
    build:
      context: ./app
    volumes:
      - ./app:/app
```

Wait -- the problem is that different app types use different source paths. Actually, they don't. `APP_SOURCE` is always `./app` (set by the factory in `project.env`). The factory could hardcode `./app` in the service file, or keep using `${APP_SOURCE}` and let Compose resolve it.

**Decision**: Keep `${APP_SOURCE}` in the templates. It is already in `project.env`, Compose resolves it, and it gives users the flexibility to change their source directory by editing `project.env`. This is the zero-change approach.

Similarly, `${FRONTEND_SOURCE}` stays as `./frontend` in `project.env` and is resolved by Compose.

### 2.5 Variables that are NOT in project.env

Some variables used in templates are not user-facing configuration -- they are internal constants or derived values. These need attention:

| Variable | Current value | Strategy |
|----------|---------------|----------|
| `${DB_PORT}` | Derived from DB_TYPE (5432 or 3306) | Write to project.env at assembly |
| `${DB_ROOT_PASSWORD}` | Hardcoded "root" | Already in project.env |
| `${DEVSTACK_DIR}` | Factory directory path | **Eliminate** -- use relative paths |

For `${DB_PORT}`: The factory writes `DB_PORT=5432` to `project.env` at assembly time. The template already uses `${DB_PORT}`, Compose resolves it.

For `${DEVSTACK_DIR}`: Templates that use this variable need to be updated to use relative paths. See section 2.3 above.

### 2.6 Summary of substitution strategy

| Phase | Who | What | How |
|-------|-----|------|-----|
| Assembly (factory) | `generate_from_bootstrap` | Writes `project.env` | jq extracts values from payload |
| Assembly (factory) | `generate_from_bootstrap` | Writes wiring values | `resolve_wiring` appends to project.env |
| Assembly (factory) | `generate_from_bootstrap` | Copies service files | `cp` -- no sed, no envsubst |
| Runtime (product) | Docker Compose | Resolves `${VAR}` in service files | Reads `project.env` as env file |
| Runtime (product) | `devstack.sh` | Generates Caddyfile | Reads `project.env` via `source`, writes static file |

**Zero sed. Zero envsubst. Zero generation of compose files.**

---

## 3. The caddy.yml Problem

### 3.1 Why caddy.yml is different

Every other service file is completely static -- it never changes after assembly. The caddy service file is different because it contains network aliases for DNS interception:

```yaml
services:
  web:
    networks:
      ${PROJECT_NAME}-internal:
        aliases:
          - ${PROJECT_NAME}.local
          - api.stripe.com        # from mocks/stripe/domains
          - api.sendgrid.com      # from mocks/sendgrid/domains
```

The alias list depends on what mock directories exist at runtime. Adding a new mock (`./devstack.sh new-mock twilio api.twilio.com`) adds a directory and a domains file. The next `start` or `restart` must pick up the new domain as an alias.

### 3.2 Solution: generate at start time

The product's `devstack.sh` generates `services/caddy.yml` on every start. This is the ONE dynamic service file.

Content of a generated `services/caddy.yml`:

```yaml
# GENERATED by devstack.sh -- do not edit manually
# Regenerated from mocks/*/domains on every start

services:
  web:
    image: caddy:2-alpine
    container_name: ${PROJECT_NAME}-web
    ports:
      - "${HTTP_PORT}:80"
      - "${HTTPS_PORT}:443"
    volumes:
      - ./caddy/Caddyfile:/etc/caddy/Caddyfile:ro
      - ${PROJECT_NAME}-certs:/certs:ro
      - ./tests/results:/srv/test-results:ro
    depends_on:
      cert-gen:
        condition: service_completed_successfully
      app:
        condition: service_started
    networks:
      ${PROJECT_NAME}-internal:
        aliases:
          - ${PROJECT_NAME}.local
          - api.stripe.com
          - api.sendgrid.com
    healthcheck:
      test: ["CMD", "wget", "--spider", "-q", "http://127.0.0.1/"]
      interval: 5s
      timeout: 3s
      retries: 20
```

### 3.3 Generation logic in product devstack.sh

```bash
generate_caddy_yml() {
    local -a domains=("$@")
    local output="${PROJECT_DIR}/services/caddy.yml"

    # Build aliases YAML
    local aliases_yaml="          - \${PROJECT_NAME}.local"
    for domain in "${domains[@]}"; do
        aliases_yaml="${aliases_yaml}
          - ${domain}"
    done

    # Build depends_on (add frontend if it exists)
    local frontend_depends=""
    if [ -f "${PROJECT_DIR}/services/frontend.yml" ]; then
        frontend_depends="
      frontend:
        condition: service_started"
    fi

    # Add PHP volume mount if PHP app
    local php_volume=""
    if [ "${APP_TYPE:-}" = "php-laravel" ]; then
        php_volume="
      - ./app:/var/www/html:ro"
    fi

    cat > "${output}" <<CADDY_YML
# GENERATED by devstack.sh -- do not edit manually
# Regenerated from mocks/*/domains on every start

services:
  web:
    image: caddy:2-alpine
    container_name: \${PROJECT_NAME}-web
    ports:
      - "\${HTTP_PORT}:80"
      - "\${HTTPS_PORT}:443"
    volumes:
      - ./caddy/Caddyfile:/etc/caddy/Caddyfile:ro
      - \${PROJECT_NAME}-certs:/certs:ro
      - ./tests/results:/srv/test-results:ro${php_volume}
    depends_on:
      cert-gen:
        condition: service_completed_successfully
      app:
        condition: service_started${frontend_depends}
    networks:
      \${PROJECT_NAME}-internal:
        aliases:
${aliases_yaml}
    healthcheck:
      test: ["CMD", "wget", "--spider", "-q", "http://127.0.0.1/"]
      interval: 5s
      timeout: 3s
      retries: 20
CADDY_YML
}
```

### 3.4 What about the factory's assembly?

At assembly time, the factory does NOT generate `caddy.yml`. It does not exist yet in the product. The factory creates the `docker-compose.yml` with the include line for `services/caddy.yml`, but the file itself is created by the product's first `start`.

This means:
- The factory includes `services/caddy.yml` in `docker-compose.yml`
- The file does not exist until `./devstack.sh start` is run
- Docker Compose will error if you run `docker compose config` before `start` (missing include)
- This is acceptable -- `devstack.sh start` is the entry point, not raw compose commands

### 3.5 WireMock service: also dynamic

Like caddy.yml, the WireMock service file has dynamic volume mounts that depend on which mock directories exist:

```yaml
services:
  wiremock:
    volumes:
      - ./mocks/stripe/mappings:/home/wiremock/mappings/stripe:ro
      - ./mocks/sendgrid/mappings:/home/wiremock/mappings/sendgrid:ro
```

The product generates `services/wiremock.yml` alongside `services/caddy.yml` at start time.

If no mocks exist (wiremock not selected, or mocks directory empty), neither `caddy.yml` nor `wiremock.yml` contain mock-specific content.

---

## 4. Wiring Output

### 4.1 What wiring does

The factory's `resolve_wiring` function reads wiring rules from `manifest.json` and resolves them against the user's selections. The output is key-value pairs appended to `project.env`.

Example: if the user selects Go + Redis, the wiring rule fires:
```json
{
  "when": ["app.*", "services.redis"],
  "set": "app.*.redis_url",
  "template": "redis://redis:6379"
}
```

This produces `REDIS_URL=redis://redis:6379` in `project.env`.

### 4.2 Current wiring output

The current `generate_from_bootstrap` appends wiring to project.env:

```bash
# Current code (lines 1408-1434 of devstack.sh)
wiring_json=$(resolve_wiring "${payload}" "${manifest_file}")
wiring_envs=$(printf '%s\n' "${wiring_json}" | jq -r '
    to_entries[] |
    (.key | split(".") | last | ascii_upcase) as $var |
    "\($var)=\(.value)"
')
echo "${wiring_envs}" >> "${DEVSTACK_DIR}/project.env"
```

### 4.3 New wiring output: same approach, cleaner

The wiring logic stays in the factory. The output format stays the same -- env vars appended to `project.env`. No changes needed to the wiring resolution itself.

Complete `project.env` for Go + Vite + PostgreSQL + Redis + WireMock:

```bash
# =============================================================================
# DevStack Project Configuration
# Generated by: dev-strap factory (./devstack.sh --bootstrap)
# =============================================================================

# ── Project identity ─────────────────────────────────────────────────────
PROJECT_NAME=myapp
NETWORK_SUBNET=172.28.0.0/24

# ── Application ──────────────────────────────────────────────────────────
APP_TYPE=go
APP_SOURCE=./app
APP_INIT_SCRIPT=./app/init.sh

# ── Frontend ─────────────────────────────────────────────────────────────
FRONTEND_TYPE=vite
FRONTEND_SOURCE=./frontend
FRONTEND_PORT=5173
FRONTEND_API_PREFIX=/api

# ── Ports ────────────────────────────────────────────────────────────────
HTTP_PORT=8080
HTTPS_PORT=8443
TEST_DASHBOARD_PORT=8082

# ── Database ─────────────────────────────────────────────────────────────
DB_TYPE=postgres
DB_PORT=5432
DB_NAME=myapp
DB_USER=myapp
DB_PASSWORD=secret
DB_ROOT_PASSWORD=root

# ── Auto-wiring (resolved from manifest rules) ──────────────────────────
REDIS_URL=redis://redis:6379
API_BASE=/api
```

### 4.4 What wiring values are possible

From the current `manifest.json` wiring rules:

| Rule | When | Variable | Value |
|------|------|----------|-------|
| Vite API base | frontend.vite + app.* | `API_BASE` | `/api` |
| Redis URL | app.* + services.redis | `REDIS_URL` | `redis://redis:6379` |
| NATS URL | app.* + services.nats | `NATS_URL` | `nats://nats:4222` |
| S3 endpoint | app.* + services.minio | `S3_ENDPOINT` | `http://minio:9000` |
| DB UI server | tooling.db-ui + database.* | `DEFAULT_SERVER` | `db` |
| Swagger spec | tooling.swagger-ui + app.* | `SPEC_URL` | `http://app:{port}/docs/openapi.json` |

These are all internal Docker network addresses -- they are the correct hostnames because the services are on the same Docker network.

### 4.5 Wiring in the new architecture: same, simpler

The wiring mechanism does not change. The factory resolves rules and writes values to `project.env`. The product reads `project.env` and passes values to containers.

The only improvement: service templates that need wired values should reference them from `project.env` via Compose interpolation, not via the template's hardcoded environment block. For example, the Go app template can use:

```yaml
environment:
  - REDIS_URL=${REDIS_URL:-}
```

If `REDIS_URL` is not set (Redis not selected), it defaults to empty. If set (wiring fired), the container gets the value. No conditional logic needed.

---

## 5. Root docker-compose.yml Assembly

### 5.1 Structure

The root `docker-compose.yml` is assembled by the factory at bootstrap time. It contains:

1. `include` directives for each selected service
2. A `networks` section defining the shared network
3. A `volumes` section declaring all named volumes

### 5.2 Assembly logic

```bash
assemble_compose() {
    local project_dir="$1"
    local payload="$2"
    local output="${project_dir}/docker-compose.yml"

    # Start with header
    cat > "${output}" <<'HEADER'
# Docker Compose configuration
# Generated by dev-strap. Edit the include list to add/remove services.
# Service files in services/ contain the actual service definitions.

HEADER

    # Build include list
    echo "include:" >> "${output}"

    # Always included
    echo '  - path: services/cert-gen.yml' >> "${output}"
    echo '    project_directory: .' >> "${output}"

    # App (always present)
    echo '  - path: services/app.yml' >> "${output}"
    echo '    project_directory: .' >> "${output}"

    # Frontend (if selected)
    if has_selection "${payload}" "frontend"; then
        echo '  - path: services/frontend.yml' >> "${output}"
        echo '    project_directory: .' >> "${output}"
    fi

    # Database (if selected)
    if has_selection "${payload}" "database"; then
        echo '  - path: services/database.yml' >> "${output}"
        echo '    project_directory: .' >> "${output}"
    fi

    # Extras: each selected extra gets its own include
    for extra in $(get_extras "${payload}"); do
        echo "  - path: services/${extra}.yml" >> "${output}"
        echo '    project_directory: .' >> "${output}"
    done

    # Caddy (always present -- generated at start time)
    echo '  - path: services/caddy.yml' >> "${output}"
    echo '    project_directory: .' >> "${output}"

    # WireMock (only if wiremock selected)
    if has_selection_item "${payload}" "tooling" "wiremock"; then
        echo '  - path: services/wiremock.yml' >> "${output}"
        echo '    project_directory: .' >> "${output}"
    fi

    # Tester (if qa selected)
    if has_selection_item "${payload}" "tooling" "qa"; then
        echo '  - path: services/tester.yml' >> "${output}"
        echo '    project_directory: .' >> "${output}"
    fi

    # Test dashboard (if qa-dashboard selected, or if qa selected)
    if has_selection_item "${payload}" "tooling" "qa-dashboard" || \
       has_selection_item "${payload}" "tooling" "qa"; then
        echo '  - path: services/test-dashboard.yml' >> "${output}"
        echo '    project_directory: .' >> "${output}"
    fi

    # Network
    cat >> "${output}" <<'NETWORK'

networks:
  ${PROJECT_NAME}-internal:
    driver: bridge
    ipam:
      config:
        - subnet: ${NETWORK_SUBNET}
NETWORK

    # Volumes
    echo "" >> "${output}"
    echo "volumes:" >> "${output}"
    echo '  ${PROJECT_NAME}-certs:' >> "${output}"

    # Database volume
    if has_selection "${payload}" "database"; then
        echo '  ${PROJECT_NAME}-db-data:' >> "${output}"
    fi

    # App-type-specific volumes
    local app_type
    app_type=$(printf '%s\n' "${payload}" | jq -r '.selections.app | keys[0]')
    case "${app_type}" in
        go)
            echo '  ${PROJECT_NAME}-go-modules:' >> "${output}"
            ;;
        python-fastapi)
            echo '  ${PROJECT_NAME}-python-cache:' >> "${output}"
            ;;
        rust)
            echo '  ${PROJECT_NAME}-cargo-registry:' >> "${output}"
            echo '  ${PROJECT_NAME}-cargo-target:' >> "${output}"
            ;;
    esac

    # Extra volumes
    for extra in $(get_extras "${payload}"); do
        case "${extra}" in
            nats) echo '  ${PROJECT_NAME}-nats-data:' >> "${output}" ;;
            minio) echo '  ${PROJECT_NAME}-minio-data:' >> "${output}" ;;
        esac
    done
}
```

### 5.3 Example output: Go + Vite + PostgreSQL + Redis + WireMock

```yaml
# Docker Compose configuration
# Generated by dev-strap. Edit the include list to add/remove services.
# Service files in services/ contain the actual service definitions.

include:
  - path: services/cert-gen.yml
    project_directory: .
  - path: services/app.yml
    project_directory: .
  - path: services/frontend.yml
    project_directory: .
  - path: services/database.yml
    project_directory: .
  - path: services/redis.yml
    project_directory: .
  - path: services/caddy.yml
    project_directory: .
  - path: services/wiremock.yml
    project_directory: .
  - path: services/tester.yml
    project_directory: .
  - path: services/test-dashboard.yml
    project_directory: .

networks:
  ${PROJECT_NAME}-internal:
    driver: bridge
    ipam:
      config:
        - subnet: ${NETWORK_SUBNET}

volumes:
  ${PROJECT_NAME}-certs:
  ${PROJECT_NAME}-db-data:
  ${PROJECT_NAME}-go-modules:
```

### 5.4 Example output: Python-FastAPI + MariaDB + NATS + MinIO (data-pipeline preset)

```yaml
# Docker Compose configuration
# Generated by dev-strap. Edit the include list to add/remove services.
# Service files in services/ contain the actual service definitions.

include:
  - path: services/cert-gen.yml
    project_directory: .
  - path: services/app.yml
    project_directory: .
  - path: services/database.yml
    project_directory: .
  - path: services/nats.yml
    project_directory: .
  - path: services/minio.yml
    project_directory: .
  - path: services/caddy.yml
    project_directory: .

networks:
  ${PROJECT_NAME}-internal:
    driver: bridge
    ipam:
      config:
        - subnet: ${NETWORK_SUBNET}

volumes:
  ${PROJECT_NAME}-certs:
  ${PROJECT_NAME}-db-data:
  ${PROJECT_NAME}-python-cache:
  ${PROJECT_NAME}-nats-data:
  ${PROJECT_NAME}-minio-data:
```

Note: no wiremock, no tester, no test-dashboard -- those were not selected in the data-pipeline preset.

---

## 6. Factory Implementation

### 6.1 How generate_from_bootstrap changes

The current `generate_from_bootstrap` function (lines 1300-1551, ~250 lines) does:

1. Extract settings from payload (project name, app type, db type, extras, ports)
2. Write `project.env`
3. Resolve and append wiring
4. Scaffold `app/` directory (copy Dockerfile, create init.sh)
5. Scaffold `frontend/` directory (if selected)
6. Create `mocks/` directory (if wiremock selected)
7. Copy devcontainer config (if selected)
8. Set up test infrastructure (if qa selected)
9. **Call `cmd_generate`** -- this generates the compose file and Caddyfile

In the new architecture, step 9 is replaced by assembly. Steps 1-8 are similar but restructured.

### 6.2 New generate_from_bootstrap

```bash
generate_from_bootstrap() {
    local payload="$1"
    local manifest_file="$2"
    local project_name
    project_name=$(printf '%s\n' "${payload}" | jq -r '.project')
    local project_dir="${DEVSTACK_DIR}/${project_name}"

    # ── Create project directory ──────────────────────────────────────────
    mkdir -p "${project_dir}/services"
    mkdir -p "${project_dir}/caddy"
    mkdir -p "${project_dir}/certs"

    # ── 1. Write project.env ──────────────────────────────────────────────
    log "Writing project.env..." >&2
    write_project_env "${payload}" "${manifest_file}" "${project_dir}"

    # ── 2. Resolve and append wiring ──────────────────────────────────────
    local wiring_json
    wiring_json=$(resolve_wiring "${payload}" "${manifest_file}")
    append_wiring "${wiring_json}" "${project_dir}/project.env"

    # ── 3. Copy service files ─────────────────────────────────────────────
    log "Copying service files..." >&2
    copy_service_files "${payload}" "${project_dir}"

    # ── 4. Copy cert generation script ────────────────────────────────────
    cp "${DEVSTACK_DIR}/core/certs/generate.sh" "${project_dir}/certs/generate.sh"

    # ── 5. Copy product devstack.sh ───────────────────────────────────────
    cp "${DEVSTACK_DIR}/product/devstack.sh" "${project_dir}/devstack.sh"
    chmod +x "${project_dir}/devstack.sh"

    # ── 6. Assemble docker-compose.yml ────────────────────────────────────
    log "Assembling docker-compose.yml..." >&2
    assemble_compose "${project_dir}" "${payload}"

    # ── 7. Scaffold app directory ─────────────────────────────────────────
    scaffold_app "${payload}" "${project_dir}"

    # ── 8. Scaffold frontend (if selected) ────────────────────────────────
    scaffold_frontend "${payload}" "${project_dir}"

    # ── 9. Scaffold mocks (if wiremock selected) ──────────────────────────
    scaffold_mocks "${payload}" "${project_dir}"

    # ── 10. Scaffold tests (if qa selected) ───────────────────────────────
    scaffold_tests "${payload}" "${project_dir}"

    # ── 11. Copy devcontainer (if selected) ───────────────────────────────
    scaffold_devcontainer "${payload}" "${project_dir}"

    # ── 12. Copy supporting config files ──────────────────────────────────
    copy_support_configs "${payload}" "${project_dir}"

    log_ok "Project assembled at ${project_dir}/" >&2
    return 0
}
```

### 6.3 copy_service_files: the core change

This replaces the monolithic compose generator. Instead of building one huge YAML file, it copies individual service files:

```bash
copy_service_files() {
    local payload="$1"
    local project_dir="$2"

    # cert-gen (always)
    cp "${DEVSTACK_DIR}/templates/common/cert-gen.yml" \
       "${project_dir}/services/cert-gen.yml"

    # App service
    local app_type
    app_type=$(printf '%s\n' "${payload}" | jq -r '.selections.app | keys[0]')
    cp "${DEVSTACK_DIR}/templates/apps/${app_type}/service.yml" \
       "${project_dir}/services/app.yml"

    # Frontend service (if selected)
    local frontend_type
    frontend_type=$(printf '%s\n' "${payload}" | jq -r '.selections.frontend // {} | keys[0] // "none"')
    if [ "${frontend_type}" != "none" ]; then
        cp "${DEVSTACK_DIR}/templates/frontends/${frontend_type}/service.yml" \
           "${project_dir}/services/frontend.yml"
    fi

    # Database service (if selected)
    local db_type
    db_type=$(printf '%s\n' "${payload}" | jq -r '.selections.database // {} | keys[0] // "none"')
    if [ "${db_type}" != "none" ]; then
        cp "${DEVSTACK_DIR}/templates/databases/${db_type}/service.yml" \
           "${project_dir}/services/database.yml"
    fi

    # Extra services
    local extras
    extras=$(printf '%s\n' "${payload}" | jq -r '
        [(.selections.services // {} | keys[]),
         (.selections.observability // {} | keys[]),
         (.selections.tooling // {} | keys[]
            | select(. != "qa" and . != "qa-dashboard" and
                     . != "wiremock" and . != "devcontainer"))] | .[]')

    for extra in ${extras}; do
        local src="${DEVSTACK_DIR}/templates/extras/${extra}/service.yml"
        if [ -f "${src}" ]; then
            cp "${src}" "${project_dir}/services/${extra}.yml"
        fi
    done

    # Tester (if qa selected)
    if printf '%s\n' "${payload}" | jq -e '.selections.tooling.qa' &>/dev/null; then
        cp "${DEVSTACK_DIR}/templates/common/tester.yml" \
           "${project_dir}/services/tester.yml"
    fi

    # Test dashboard
    if printf '%s\n' "${payload}" | jq -e '.selections.tooling["qa-dashboard"] // .selections.tooling.qa' &>/dev/null; then
        cp "${DEVSTACK_DIR}/templates/common/test-dashboard.yml" \
           "${project_dir}/services/test-dashboard.yml"
    fi
}
```

### 6.4 copy_support_configs: handling extra files

Some services need supporting config files beyond their service YAML:

```bash
copy_support_configs() {
    local payload="$1"
    local project_dir="$2"

    # Prometheus config
    if printf '%s\n' "${payload}" | jq -e '.selections.observability.prometheus' &>/dev/null; then
        mkdir -p "${project_dir}/config"
        cp "${DEVSTACK_DIR}/templates/extras/prometheus/prometheus.yml" \
           "${project_dir}/config/prometheus.yml"
    fi

    # Grafana provisioning
    if printf '%s\n' "${payload}" | jq -e '.selections.observability.grafana' &>/dev/null; then
        mkdir -p "${project_dir}/config/grafana/provisioning/datasources"
        cp -r "${DEVSTACK_DIR}/templates/extras/grafana/provisioning/." \
           "${project_dir}/config/grafana/provisioning/"
    fi

    # Go-specific: .air.toml for live reload
    local app_type
    app_type=$(printf '%s\n' "${payload}" | jq -r '.selections.app | keys[0]')
    if [ "${app_type}" = "go" ] && [ -f "${DEVSTACK_DIR}/templates/apps/go/.air.toml" ]; then
        cp "${DEVSTACK_DIR}/templates/apps/go/.air.toml" \
           "${project_dir}/app/.air.toml"
    fi
}
```

### 6.5 New templates needed

The factory needs new template files that don't exist yet:

| New file | Content | Purpose |
|----------|---------|---------|
| `templates/common/cert-gen.yml` | cert-gen service definition | Currently inline in compose generator |
| `templates/common/tester.yml` | Playwright tester service | Currently inline in compose generator |
| `templates/common/test-dashboard.yml` | Test results dashboard | Currently inline in compose generator |
| `product/devstack.sh` | Product runtime script | Currently does not exist separately |

The cert-gen, tester, and test-dashboard are currently hardcoded in `core/compose/generate.sh`. They need to be extracted into standalone service YAML files.

**cert-gen.yml**:
```yaml
services:
  cert-gen:
    image: alpine:3
    container_name: ${PROJECT_NAME}-cert-gen
    volumes:
      - ${PROJECT_NAME}-certs:/certs
      - ./certs/generate.sh:/scripts/generate.sh:ro
      - ./caddy/domains.txt:/config/domains.txt:ro
    environment:
      - PROJECT_NAME=${PROJECT_NAME}
    entrypoint: ["sh", "-c", "apk add --no-cache openssl >/dev/null 2>&1 && sh /scripts/generate.sh"]
    networks:
      - ${PROJECT_NAME}-internal
```

**tester.yml**:
```yaml
services:
  tester:
    image: mcr.microsoft.com/playwright:v1.52.0-noble
    container_name: ${PROJECT_NAME}-tester
    working_dir: /tests
    volumes:
      - ./tests/playwright:/tests
      - ./tests/results:/results
      - ${PROJECT_NAME}-certs:/certs:ro
    environment:
      - BASE_URL=https://web:443
      - NODE_EXTRA_CA_CERTS=/certs/ca.crt
      - PLAYWRIGHT_HTML_REPORT=/results/report
    depends_on:
      web:
        condition: service_healthy
    entrypoint: ["tail", "-f", "/dev/null"]
    networks:
      - ${PROJECT_NAME}-internal
```

**test-dashboard.yml**:
```yaml
services:
  test-dashboard:
    image: busybox:latest
    container_name: ${PROJECT_NAME}-test-dashboard
    ports:
      - "${TEST_DASHBOARD_PORT}:8080"
    volumes:
      - ./tests/results:/results:ro
    working_dir: /results
    command: httpd -f -p 8080 -h /results
    networks:
      - ${PROJECT_NAME}-internal
```

### 6.6 Template modifications needed

Existing templates need their `${DEVSTACK_DIR}` references changed to relative paths. Affected files:

**templates/apps/go/service.yml** -- change `${APP_SOURCE}` to `./app`:
```yaml
# Before
  app:
    build:
      context: ${APP_SOURCE}
    volumes:
      - ${APP_SOURCE}:/app

# After (keep ${APP_SOURCE} -- it's in project.env as ./app)
# No change needed! Compose resolves ${APP_SOURCE} from project.env
```

Actually, `${APP_SOURCE}` is fine because it is already set to `./app` in `project.env`. Docker Compose resolves it. The only templates that need changes are those referencing `${DEVSTACK_DIR}`:

**templates/extras/prometheus/service.yml**:
```yaml
# Before
    volumes:
      - ${DEVSTACK_DIR}/templates/extras/prometheus/prometheus.yml:/etc/prometheus/prometheus.yml:ro

# After
    volumes:
      - ./config/prometheus.yml:/etc/prometheus/prometheus.yml:ro
```

**templates/extras/grafana/service.yml**:
```yaml
# Before
    volumes:
      - ${DEVSTACK_DIR}/templates/extras/grafana/provisioning:/etc/grafana/provisioning:ro

# After
    volumes:
      - ./config/grafana/provisioning:/etc/grafana/provisioning:ro
```

These are the ONLY template changes required. All other templates use `${VAR}` references that Compose resolves natively.

---

## 7. Migration Path

### 7.1 Existing projects (pre-split)

Projects created before the factory/product split have this structure:

```
my-old-project/
├── devstack.sh                  ← 1,688-line monolith
├── project.env
├── core/                        ← factory code (shouldn't be here)
├── templates/                   ← factory templates (shouldn't be here)
├── contract/                    ← factory contract (shouldn't be here)
├── .generated/
│   ├── docker-compose.yml       ← regenerated monolith
│   ├── Caddyfile
│   └── domains.txt
├── app/
├── mocks/
└── tests/
```

### 7.2 Migration script

A one-time migration script converts existing projects to the new structure:

```bash
#!/bin/bash
# migrate-to-product.sh
# Converts an existing dev-strap project to the new product structure.
# Run from the project directory.

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "Migrating to product structure..."

source "${PROJECT_DIR}/project.env"

# 1. Create services/ directory
mkdir -p "${PROJECT_DIR}/services"

# 2. Copy service files from templates
TEMPLATE_DIR="${PROJECT_DIR}/templates"  # Still available in old projects

# App
cp "${TEMPLATE_DIR}/apps/${APP_TYPE}/service.yml" \
   "${PROJECT_DIR}/services/app.yml"

# Database
if [ "${DB_TYPE}" != "none" ]; then
    cp "${TEMPLATE_DIR}/databases/${DB_TYPE}/service.yml" \
       "${PROJECT_DIR}/services/database.yml"
fi

# Extras
IFS=',' read -ra EXTRAS_LIST <<< "${EXTRAS:-}"
for extra in "${EXTRAS_LIST[@]}"; do
    extra=$(echo "${extra}" | tr -d '[:space:]')
    [ -z "${extra}" ] && continue
    if [ -f "${TEMPLATE_DIR}/extras/${extra}/service.yml" ]; then
        cp "${TEMPLATE_DIR}/extras/${extra}/service.yml" \
           "${PROJECT_DIR}/services/${extra}.yml"
    fi
done

# Frontend
if [ "${FRONTEND_TYPE:-none}" != "none" ]; then
    cp "${TEMPLATE_DIR}/frontends/${FRONTEND_TYPE}/service.yml" \
       "${PROJECT_DIR}/services/frontend.yml"
fi

# Common services (extract from .generated/docker-compose.yml or use defaults)
# cert-gen, tester, test-dashboard are currently inline in the generated compose
# Use the new templates if available, otherwise create from defaults
# ... (extract from generated compose or create fresh)

# 3. Create caddy/ directory
mkdir -p "${PROJECT_DIR}/caddy"

# 4. Copy certs script
mkdir -p "${PROJECT_DIR}/certs"
cp "${PROJECT_DIR}/core/certs/generate.sh" "${PROJECT_DIR}/certs/generate.sh"

# 5. Copy support configs
if [ -d "${TEMPLATE_DIR}/extras/prometheus" ] && echo "${EXTRAS}" | grep -q "prometheus"; then
    mkdir -p "${PROJECT_DIR}/config"
    cp "${TEMPLATE_DIR}/extras/prometheus/prometheus.yml" \
       "${PROJECT_DIR}/config/prometheus.yml"
fi
if echo "${EXTRAS}" | grep -q "grafana"; then
    mkdir -p "${PROJECT_DIR}/config/grafana/provisioning/datasources"
    cp -r "${TEMPLATE_DIR}/extras/grafana/provisioning/." \
       "${PROJECT_DIR}/config/grafana/provisioning/"
fi

# 6. Generate docker-compose.yml
echo "Generating docker-compose.yml..."
# Build include list from what exists in services/
cat > "${PROJECT_DIR}/docker-compose.yml" <<'HEADER'
# Docker Compose configuration (migrated from dev-strap monolith)

HEADER
echo "include:" >> "${PROJECT_DIR}/docker-compose.yml"
for svc_file in "${PROJECT_DIR}"/services/*.yml; do
    [ -f "${svc_file}" ] || continue
    local name
    name=$(basename "${svc_file}")
    echo "  - path: services/${name}" >> "${PROJECT_DIR}/docker-compose.yml"
    echo "    project_directory: ." >> "${PROJECT_DIR}/docker-compose.yml"
done

# Add network and volumes
cat >> "${PROJECT_DIR}/docker-compose.yml" <<FOOTER

networks:
  \${PROJECT_NAME}-internal:
    driver: bridge
    ipam:
      config:
        - subnet: \${NETWORK_SUBNET}

volumes:
  \${PROJECT_NAME}-certs:
FOOTER

[ "${DB_TYPE}" != "none" ] && \
    echo '  ${PROJECT_NAME}-db-data:' >> "${PROJECT_DIR}/docker-compose.yml"

case "${APP_TYPE}" in
    go)             echo '  ${PROJECT_NAME}-go-modules:' >> "${PROJECT_DIR}/docker-compose.yml" ;;
    python-fastapi) echo '  ${PROJECT_NAME}-python-cache:' >> "${PROJECT_DIR}/docker-compose.yml" ;;
    rust)           echo '  ${PROJECT_NAME}-cargo-registry:' >> "${PROJECT_DIR}/docker-compose.yml"
                    echo '  ${PROJECT_NAME}-cargo-target:' >> "${PROJECT_DIR}/docker-compose.yml" ;;
esac

# 7. Add DB_PORT to project.env if missing
if ! grep -q "^DB_PORT=" "${PROJECT_DIR}/project.env"; then
    case "${DB_TYPE}" in
        postgres) echo "DB_PORT=5432" >> "${PROJECT_DIR}/project.env" ;;
        mariadb)  echo "DB_PORT=3306" >> "${PROJECT_DIR}/project.env" ;;
    esac
fi

# 8. Replace devstack.sh with product version
# (Back up the old one first)
cp "${PROJECT_DIR}/devstack.sh" "${PROJECT_DIR}/devstack.sh.factory-backup"
cp "${NEW_PRODUCT_DEVSTACK}" "${PROJECT_DIR}/devstack.sh"  # From factory or download
chmod +x "${PROJECT_DIR}/devstack.sh"

# 9. Clean up factory artifacts
echo ""
echo "Migration complete. You can now remove factory directories:"
echo "  rm -rf core/ templates/ contract/ .generated/"
echo ""
echo "But keep the backup: devstack.sh.factory-backup"
echo ""
echo "Test with: ./devstack.sh start"
```

### 7.3 Migration checklist

1. Run `./devstack.sh stop` with the OLD script first (cleans .generated/)
2. Run the migration script
3. Verify: `ls services/` shows the expected service files
4. Verify: `cat docker-compose.yml` shows correct includes
5. Verify: `cat project.env` has all required variables
6. Run `./devstack.sh start` with the NEW product script
7. Run `./devstack.sh verify-mocks` to confirm mock DNS works
8. If everything works, remove factory directories: `rm -rf core/ templates/ contract/ .generated/`

### 7.4 Backward compatibility

The migration is one-way. Once a project is converted to the product structure, it cannot use the old monolithic devstack.sh. This is intentional -- the old structure is the problem being solved.

The factory (dev-strap repo) continues to support `--bootstrap` for creating new projects. Old projects are migrated manually with the script above.

### 7.5 Risk areas

| Risk | Mitigation |
|------|------------|
| Service files reference `${DEVSTACK_DIR}` | Migration script checks and warns; only Prometheus/Grafana affected |
| project.env missing DB_PORT | Migration script adds it |
| Volume names change | They don't -- same `${PROJECT_NAME}-*` pattern |
| Network name changes | It doesn't -- same `${PROJECT_NAME}-internal` |
| cert-gen script path changes | `core/certs/generate.sh` -> `certs/generate.sh`; migration copies it |
| WireMock volume mounts | Generated at start time by new devstack.sh |

---

## Summary

### What the factory produces

The factory is a **file copier with assembly logic**. It:

1. **Copies** service templates as-is (no sed, no envsubst)
2. **Assembles** `docker-compose.yml` with the right include list
3. **Assembles** `project.env` with selections + wiring
4. **Copies** supporting files (Dockerfiles, configs, scripts)
5. **Scaffolds** directories (app/, mocks/, tests/)

It does NOT generate Docker Compose YAML content. It copies pre-authored YAML files and writes a list of includes.

### What changes from current architecture

| Aspect | Current | New |
|--------|---------|-----|
| Compose file | Generated monolith (443 lines of generator code) | Assembled include list (~10 lines) |
| Service files | Templates, sed-substituted | Templates, copied verbatim |
| Variable resolution | 17+ sed commands at generation | Docker Compose native interpolation |
| Factory output | project.env + .generated/ | project.env + services/*.yml + docker-compose.yml |
| Product dependency | Reaches back to factory on every start | Fully standalone |
| Adding a service post-bootstrap | Edit project.env, factory regenerates | Edit docker-compose.yml, drop a .yml in services/ |

### Implementation order

1. Create `templates/common/` with cert-gen.yml, tester.yml, test-dashboard.yml
2. Fix Prometheus and Grafana templates to use relative paths
3. Create `product/devstack.sh` (see research 15)
4. Modify `generate_from_bootstrap` to use the new assembly logic
5. Update `build_bootstrap_response` if response format changes
6. Write the migration script
7. Update factory tests
8. Test with all presets (spa-api, api-only, full-stack, data-pipeline)
