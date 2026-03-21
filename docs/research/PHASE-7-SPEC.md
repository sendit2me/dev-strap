# Phase 7: Factory/Product Split — Implementation Specification

> **Status**: FIRM — ready to execute
> **Prerequisites**: Phases 1-6 complete. Prototype validated (commit `b0b2f6d`).
> **Research**: docs 14-16, ARCHITECTURE-NEXT.md, prototype/
> **Decisions**: Generated files in `services/` (committed). Non-destructive stop. `project_directory: .` on all includes. Per-service env_file via long-form include. No `add-service` command (deferred).

---

## What This Phase Does

Splits dev-strap into two distinct systems:

1. **Factory** (stays in dev-strap repo) — presents catalog, takes selections, assembles a project
2. **Product** (ships to user's project) — starts, stops, tests, manages mocks. Self-contained.

---

## Task 1: Create Product Templates

New directory `product/` in the dev-strap repo containing files that ship with EVERY bootstrapped project, unchanged.

### 1a: `product/devstack.sh` — lightweight runtime script

The complete product devstack.sh from research doc 15, section 6. ~350 lines. Contains:
- Logging helpers, check_docker, load_config, validate_config
- collect_domains, generate_caddyfile, generate_caddy_service, generate_wiremock_service
- cmd_start (validate → collect domains → generate Caddyfile + dynamic services → compose up → wait → init → summary)
- cmd_stop (non-destructive by default, `--clean` for full teardown)
- cmd_restart (passes `--clean` through)
- cmd_test, cmd_shell, cmd_status, cmd_logs
- cmd_mocks, cmd_new_mock, cmd_reload_mocks, cmd_record, cmd_apply_recording, cmd_verify_mocks
- main (help text + command routing, NO contract/factory commands)

**Source**: `/home/i9user/Projects/DS/dev-strap/docs/research/15-product-devstack-design.md` section 6

### 1b: `product/certs/generate.sh` — cert generation script

Copy of `core/certs/generate.sh`. Ships as-is. Runs inside the cert-gen container.

Add cert domain change detection from research doc 13 section 2:
- Before skipping on existing certs, compare domains.txt against cert SANs
- Regenerate if they differ

### 1c: `product/.gitignore`

```
# Runtime artifacts
domains.txt
caddy/Caddyfile
tests/results/
tests/playwright/node_modules/
tests/playwright/package-lock.json

# Generated service files (regenerated on start from mocks/)
services/caddy.yml
services/wiremock.yml
```

Note: caddy.yml and wiremock.yml ARE gitignored because they're regenerated from `mocks/` on every start. Static service files (app.yml, database.yml, redis.yml, etc.) are NOT gitignored — they're source-of-truth.

---

## Task 2: Create Common Service Templates

New directory `templates/common/` for service files that ship with every project regardless of selections.

### 2a: `templates/common/cert-gen.yml`

```yaml
services:
  cert-gen:
    image: alpine:3
    container_name: ${PROJECT_NAME}-cert-gen
    entrypoint: ["sh", "-c", "apk add --no-cache openssl >/dev/null 2>&1 && sh /scripts/generate.sh"]
    volumes:
      - ./certs/generate.sh:/scripts/generate.sh:ro
      - ./domains.txt:/config/domains.txt:ro
      - devstack-certs:/certs
    environment:
      - PROJECT_NAME=${PROJECT_NAME}
    networks:
      - devstack-internal

volumes:
  devstack-certs:
```

### 2b: `templates/common/tester.yml`

```yaml
services:
  tester:
    image: mcr.microsoft.com/playwright:v1.52.0-noble
    container_name: ${PROJECT_NAME}-tester
    working_dir: /tests
    volumes:
      - ./tests/playwright:/tests
      - ./tests/results:/results
      - devstack-certs:/certs:ro
    environment:
      - BASE_URL=https://web:443
      - NODE_EXTRA_CA_CERTS=/certs/ca.crt
      - PLAYWRIGHT_HTML_REPORT=/results/report
    depends_on:
      web:
        condition: service_healthy
    entrypoint: ["tail", "-f", "/dev/null"]
    networks:
      - devstack-internal
```

### 2c: `templates/common/test-dashboard.yml`

```yaml
services:
  test-dashboard:
    image: busybox:latest
    container_name: ${PROJECT_NAME}-test-dashboard
    ports:
      - "${TEST_DASHBOARD_PORT:-8082}:8080"
    volumes:
      - ./tests/results:/results:ro
    working_dir: /results
    command: httpd -f -p 8080 -h /results
    networks:
      - devstack-internal
```

---

## Task 3: Refactor Existing Service Templates

Existing templates in `templates/apps/`, `templates/databases/`, `templates/extras/`, `templates/frontends/` need adjustments for the product model:

### 3a: Volume and network names → literal (no `${PROJECT_NAME}` prefix in keys)

All service.yml files currently use `${PROJECT_NAME}-certs`, `${PROJECT_NAME}-go-modules`, etc. as volume references. These need to change to literal names since `${VAR}` doesn't work in top-level YAML keys.

**Changes across all templates:**
- `${PROJECT_NAME}-certs` → `devstack-certs` (in volume references)
- `${PROJECT_NAME}-go-modules` → `devstack-go-modules` (in volume references + declarations)
- `${PROJECT_NAME}-db-data` → `devstack-db-data`
- `${PROJECT_NAME}-python-cache` → `devstack-python-cache`
- `${PROJECT_NAME}-cargo-registry` → `devstack-cargo-registry`
- `${PROJECT_NAME}-cargo-target` → `devstack-cargo-target`
- `${PROJECT_NAME}-nats-data` → `devstack-nats-data`
- `${PROJECT_NAME}-minio-data` → `devstack-minio-data`

Docker Compose automatically prefixes volumes with the project name (from `COMPOSE_PROJECT_NAME`), so `devstack-db-data` becomes `myproject_devstack-db-data` at runtime. Scoping is preserved.

Network references: `${PROJECT_NAME}-internal` → `devstack-internal` (same auto-prefix applies).

### 3b: Path references → relative to project root

Templates currently use `${APP_SOURCE}` (resolved to absolute by the factory's sed). In the product model with `project_directory: .`, use simple relative paths:
- `${APP_SOURCE}` → `./app` (or keep `${APP_SOURCE}` since it's in `.env`)
- `${DEVSTACK_DIR}` references → remove (product doesn't know about factory paths)

### 3c: Add per-service volume declarations

Each service that uses named volumes must declare them in its own file (compose include merges them):

For `templates/apps/go/service.yml`, add:
```yaml
volumes:
  devstack-go-modules:
```

For `templates/databases/postgres/service.yml`, add:
```yaml
volumes:
  devstack-db-data:
```

And so on for each template with named volumes.

### 3d: Add healthchecks to app templates (B1 from reviews)

Add healthchecks to all 5 app templates:

| Template | Healthcheck |
|----------|------------|
| node-express | `wget --spider -q http://localhost:3000/ \|\| exit 1` (interval 5s, retries 30) |
| go | `wget --spider -q http://localhost:3000/ \|\| exit 1` (interval 5s, retries 30) |
| php-laravel | `php-fpm -t` (interval 5s, retries 30) |
| python-fastapi | `wget --spider -q http://localhost:3000/ \|\| exit 1` (interval 5s, retries 30) |
| rust | `wget --spider -q http://localhost:3000/ \|\| exit 1` (interval 5s, retries 120) |

Also add to Vite frontend template:
- `wget --spider -q http://localhost:5173/ \|\| exit 1` (interval 5s, retries 30)

---

## Task 4: Refactor Factory (`generate_from_bootstrap`)

Rewrite `generate_from_bootstrap()` in `devstack.sh` to assemble the product instead of generating configs.

### 4a: New assembly flow

```
1. Extract selections from payload (app_type, frontend_type, db_type, extras)
2. Create destination directory
3. Copy product/devstack.sh → dest/devstack.sh
4. Copy product/certs/generate.sh → dest/certs/generate.sh
5. Copy product/.gitignore → dest/.gitignore
6. Copy selected app template → dest/services/app.yml
7. Copy selected app Dockerfile → dest/app/Dockerfile
8. Copy selected frontend template → dest/services/frontend.yml (if selected)
9. Copy selected frontend Dockerfile → dest/frontend/Dockerfile (if selected)
10. Copy selected database template → dest/services/database.yml (if selected)
11. Copy selected extras templates → dest/services/{name}.yml (for each)
12. Copy common templates → dest/services/cert-gen.yml, tester.yml, test-dashboard.yml
13. Assemble dest/docker-compose.yml (include directives for selected services)
14. Assemble dest/project.env (from selections + wiring)
15. Scaffold dest/mocks/ (example mock if wiremock selected)
16. Scaffold dest/tests/ (playwright config)
17. Scaffold dest/app/init.sh
```

### 4b: Root docker-compose.yml assembly

The factory writes this based on selections:

```yaml
include:
  - path: services/cert-gen.yml
    project_directory: .
  - path: services/app.yml
    project_directory: .
  - path: services/caddy.yml       # generated at runtime by devstack.sh
    project_directory: .
  - path: services/database.yml    # only if database selected
    project_directory: .
    env_file: services/database.env
  - path: services/redis.yml       # only if redis selected
    project_directory: .
  - path: services/wiremock.yml    # generated at runtime by devstack.sh
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

Only include lines for services that were selected. Frontend, database, and extras lines are conditional.

### 4c: project.env assembly

```env
# Project configuration
PROJECT_NAME=<from payload>
COMPOSE_PROJECT_NAME=<from payload>
NETWORK_SUBNET=172.28.0.0/24

# Application
APP_TYPE=<selected app type>
APP_SOURCE=./app

# Ports
HTTP_PORT=<resolved>
HTTPS_PORT=<resolved>
TEST_DASHBOARD_PORT=<resolved>

# Frontend (if selected)
FRONTEND_TYPE=<selected or "none">
FRONTEND_PORT=<resolved>
FRONTEND_API_PREFIX=/api

# Wiring (auto-resolved)
REDIS_URL=redis://redis:6379       # only if redis selected
NATS_URL=nats://nats:4222          # only if nats selected
S3_ENDPOINT=http://minio:9000      # only if minio selected
```

### 4d: Per-service env files

For services that need their own env files:

`services/database.env`:
```env
DB_NAME=<project name>
DB_USER=<project name>
DB_PASSWORD=secret
DB_ROOT_PASSWORD=root
```

### 4e: Update build_bootstrap_response

Include the product directory path in the response.

---

## Task 5: Fix Outstanding Bugs in Templates

These bugs don't dissolve with the architecture change. Fix them now in the templates:

### 5a: Python Dockerfile missing build deps (A3)
Add `gcc`, `libpq-dev`, `pkg-config` to `templates/apps/python-fastapi/Dockerfile`

### 5b: PHP-Laravel hardcodes DB_CONNECTION=mysql (A4)
Change to `DB_CONNECTION=${DB_CONNECTION}` in `templates/apps/php-laravel/service.yml`.
Add `DB_CONNECTION` to database.env (factory writes `pgsql` for postgres, `mysql` for mariadb).

### 5c: Example app says "nginx" (A6)
Change to "Caddy" in `app/src/index.js` line 73.

---

## Task 6: Tests

### 6a: Existing contract tests must pass
All 184 tests use `./devstack.sh --bootstrap --config -` which stays in the factory's devstack.sh. These should continue to work, but the output directory structure changes.

### 6b: New product tests
Test the product's devstack.sh in isolation:
- Source product/devstack.sh, verify functions exist
- Test validate_config with good/bad project.env
- Test collect_domains with mock directories
- Test generate_caddyfile output for PHP, non-PHP, frontend
- Test that `docker compose config` validates the assembled project

### 6c: End-to-end test
Bootstrap a project via `--bootstrap`, then verify the product works:
```bash
echo '<payload>' | ./devstack.sh --bootstrap --config -
cd test-project/
./devstack.sh start
./devstack.sh test
./devstack.sh stop
```

---

## Task 7: Clean Up

### 7a: Remove prototype/
The prototype validated the approach. Remove it after implementation.

### 7b: Update ARCHITECTURE-NEXT.md
Mark the factory/product split as implemented. Update open questions with answers.

### 7c: Update AI_BOOTSTRAP.md
Major rewrite — the system architecture has fundamentally changed.

---

## Execution Plan

### Team structure (3 agents, parallel where possible)

**Agent A: Product Runtime** (Tasks 1 + parts of 3)
- Create `product/devstack.sh` (the lightweight script)
- Create `product/certs/generate.sh` (with domain change detection)
- Create `product/.gitignore`
- Create `templates/common/cert-gen.yml`, `tester.yml`, `test-dashboard.yml`
- Add healthchecks to all app templates (3d)
- Files: `product/*`, `templates/common/*`, `templates/apps/*/service.yml`, `templates/frontends/vite/service.yml`

**Agent B: Template Refactor** (Tasks 3a-3c + 5)
- Refactor all service templates: literal volume/network names, relative paths, per-file volume declarations
- Fix Python Dockerfile (5a), PHP DB_CONNECTION (5b), example app nginx ref (5c)
- Files: ALL `templates/*/service.yml` files, `templates/apps/python-fastapi/Dockerfile`, `templates/apps/php-laravel/service.yml`, `app/src/index.js`

**Agent C: Factory Refactor** (Task 4)
- Rewrite `generate_from_bootstrap()` to assemble product structure
- Assemble root docker-compose.yml with includes
- Assemble project.env with selections + wiring
- Write per-service env files
- Update `build_bootstrap_response()`
- Files: `devstack.sh`

**After all 3 complete: Integration testing (Task 6) + cleanup (Task 7)**

### Dependency map

```
Agent A (product runtime) ──┐
Agent B (template refactor) ─┼── Integration tests ── Cleanup
Agent C (factory refactor) ──┘
```

All three are independent — they touch different files. Integration tests run after all complete.
