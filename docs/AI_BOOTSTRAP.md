# AI Agent Bootstrap

This document is written for AI coding agents (Claude Code, Cursor, Copilot, etc.) starting a new session on this codebase. Read this first.

## What this project is

DevStrap is a **meta-tool** — it generates Docker infrastructure, not application code. It's a bootstrap system for containerized development environments with transparent HTTPS mock interception.

It is NOT:
- A web application
- A library or package
- A Docker image

It IS:
- A set of bash scripts that generate `docker-compose.yml`, `Caddyfile`, and TLS certificates from a directory structure
- Templates for different app types (Node, PHP, Go)
- WireMock JSON stubs for mocking external APIs
- A CLI (`devstack.sh`) that orchestrates everything

## Critical: source-of-truth vs generated

```
SOURCE (edit these)                    GENERATED (never edit these)
─────────────────                      ──────────────────────────
project.env                            .generated/docker-compose.yml
mocks/*/domains                        .generated/Caddyfile
mocks/*/mappings/*.json                .generated/domains.txt
mocks/*/__files/*
templates/apps/*/service.yml
templates/apps/*/Dockerfile
templates/databases/*/service.yml
templates/extras/*/service.yml
core/certs/generate.sh
core/caddy/generate-caddyfile.sh
core/compose/generate.sh
devstack.sh
app/                                   tests/results/
tests/playwright/*.spec.ts             tests/playwright/node_modules/
```

`.generated/` is deleted on `./devstack.sh stop` and rebuilt on `./devstack.sh start`. Never edit files there. If you need to change what's generated, edit the generator script in `core/`.

## File reading order

When starting work, read these files in this order:

1. **`project.env`** — current configuration (app type, database, ports, extras)
2. **`devstack.sh`** — the CLI, all commands, the orchestration flow
3. **`core/compose/generate.sh`** — how docker-compose.yml is assembled
4. **`core/caddy/generate-caddyfile.sh`** — how Caddyfile is assembled
5. **`core/certs/generate.sh`** — how certificates are generated
6. **`templates/apps/{APP_TYPE}/service.yml`** — the active app template (check APP_TYPE in project.env)

Only read further if your task requires it. Don't read all docs upfront — they're for humans.

## How changes flow

```
You edit a file
       │
       ├── project.env or templates/*
       │     └── ./devstack.sh restart  (regenerates everything)
       │
       ├── mocks/*/mappings/*.json (existing mock, existing domain)
       │     └── ./devstack.sh reload-mocks  (hot reload, no restart)
       │
       ├── mocks/*/domains (new domain)
       │     └── ./devstack.sh restart  (needs new certs + Caddy config)
       │
       ├── app/src/* (application code)
       │     └── Nothing — file watcher in container picks it up
       │
       ├── core/*.sh (generator scripts)
       │     └── ./devstack.sh restart  (regenerates from changed scripts)
       │
       ├── devstack.sh (CLI itself)
       │     └── Takes effect on next command invocation
       │
       └── tests/playwright/*.spec.ts
              └── ./devstack.sh test  (runs immediately)
```

## How to verify changes

After ANY code change, this is the verification loop:

```bash
# If you changed generators, templates, or project.env:
./devstack.sh stop && ./devstack.sh start

# If you changed mock mappings only:
./devstack.sh reload-mocks

# Always run tests:
./devstack.sh test

# Check specific things:
./devstack.sh status          # container health
./devstack.sh verify-mocks    # mock domain reachability
./devstack.sh mocks           # list what's configured

# Debug:
./devstack.sh logs web        # proxy routing issues
./devstack.sh logs wiremock   # mock matching issues
./devstack.sh logs app        # application errors
./devstack.sh shell app       # interactive debugging
```

Tests must pass. If they don't, the change is broken. Don't skip this.

## Architecture in 30 seconds

```
App makes HTTPS request to api.stripe.com
  → Docker DNS resolves api.stripe.com to Caddy (network alias in docker-compose)
  → Caddy terminates TLS (cert has SAN for api.stripe.com)
  → Caddy adds X-Original-Host: api.stripe.com header
  → Caddy proxies to WireMock (http://wiremock:8080)
  → WireMock matches against mocks/stripe/mappings/*.json
  → Returns stub response
  → App receives it as if Stripe replied
```

The app code is identical in dev and production. No `isDev` flags anywhere.

## Generation pipeline

```
mocks/*/domains  ──→  .generated/domains.txt  ──→  cert-gen container (SANs)
                 ──→  Caddy site blocks
                 ──→  docker-compose network aliases

project.env      ──→  selects templates/apps/{APP_TYPE}/
                 ──→  selects templates/databases/{DB_TYPE}/
                 ──→  derives DB_PORT from DB_TYPE (mariadb=3306, postgres=5432)

templates/       ──→  variable substitution (${PROJECT_NAME}, ${DB_PORT}, etc.)
                 ──→  assembled into .generated/docker-compose.yml
```

## Variable substitution

Templates use `${VARIABLE}` placeholders. The compose generator (`core/compose/generate.sh`) replaces them via `sed`. Available variables:

| Variable | Source | Example |
|----------|--------|---------|
| `${PROJECT_NAME}` | project.env | `myproject` |
| `${APP_SOURCE}` | Resolved to absolute path | `/home/user/devstack/app` |
| `${DB_TYPE}` | project.env | `mariadb` |
| `${DB_PORT}` | Derived from DB_TYPE | `3306` |
| `${DB_NAME}` | project.env | `myproject` |
| `${DB_USER}` | project.env | `myproject` |
| `${DB_PASSWORD}` | project.env | `secret` |
| `${DB_ROOT_PASSWORD}` | project.env | `root` |
| `${MAILPIT_PORT}` | project.env (default 8025) | `8025` |

## Pitfalls that waste your time

### 1. Editing .generated/ files
They get deleted on stop and overwritten on start. Edit the generators or templates instead.

### 2. Docker build context paths
The compose file lives in `.generated/` but references files elsewhere. All paths in the generated compose are absolute. If you add a new volume mount in a template, use `${APP_SOURCE}` (absolute) not `./app` (relative to compose file location).

### 3. Root-owned files from containers
Containers write files as root. `tests/results/`, `tests/playwright/node_modules/`, and recorded mock files are root-owned. `./devstack.sh stop` handles cleanup using a Docker container (`alpine rm -rf`). If you need to clean manually:
```bash
docker run --rm -v $(pwd)/tests:/data alpine rm -rf /data/results/* /data/playwright/node_modules
```

### 4. CA certificate trust differs by language
The mock interception requires the app to trust a self-signed CA at `/certs/ca.crt`. Each language handles this differently:
- **Node.js**: `NODE_EXTRA_CA_CERTS=/certs/ca.crt` env var (set in service.yml)
- **Go**: `SSL_CERT_FILE=/certs/ca.crt` env var (set in service.yml)
- **PHP**: Entrypoint wrapper in Dockerfile runs `update-ca-certificates` at container start
- **CLI tools** (wget, curl inside containers): Must use `--no-check-certificate` or `-k`

### 5. Playwright version must match container image
`tests/playwright/package.json` pins `@playwright/test` to `1.52.0`. The compose generator uses `mcr.microsoft.com/playwright:v1.52.0-noble`. If you change one, change both. Mismatch = "Executable doesn't exist" error.

### 6. WireMock shares all mocks in one instance
All `mocks/*/mappings/` directories are mounted into a single WireMock. If two APIs use the same path (e.g., both have `POST /v1/tokens`), WireMock can't distinguish them unless mappings include:
```json
"headers": { "X-Original-Host": { "equalTo": "api.stripe.com" } }
```
Caddy adds `X-Original-Host` automatically. Only needed when paths collide across different mocked services.

### 7. New domains require restart, mapping changes don't
- Changed a JSON mapping → `./devstack.sh reload-mocks`
- Added a new `mocks/<name>/domains` file → `./devstack.sh restart` (needs new cert SANs + Caddy config + DNS alias)

### 8. The init script runs via stdin pipe
`devstack.sh` pipes the init script into the container: `exec -T app sh < init.sh`. This means:
- The script runs in the container's working directory (not the host)
- It works regardless of where the app is mounted (`/app`, `/var/www/html`, etc.)
- Interactive commands won't work (no TTY)

### 9. Named volumes must be prefixed with ${PROJECT_NAME}
Docker Compose scopes volume cleanup to the project. Unprefixed volumes (like `go-modules`) won't be cleaned up on `./devstack.sh stop`. Always use `${PROJECT_NAME}-go-modules`.

### 10. Don't "improve" the test-dashboard
It's intentionally a `busybox httpd` — the simplest possible static file server. Don't replace it with something "better". Its job is serving HTML test reports, nothing more.

## Commands reference

```bash
# Lifecycle
./devstack.sh start                       # Generate + build + start
./devstack.sh stop                        # Tear down everything
./devstack.sh restart                     # stop + start

# Observability
./devstack.sh status                      # Container health
./devstack.sh logs [service]              # Tail logs
./devstack.sh shell [service]             # Shell into container
./devstack.sh verify-mocks                # Check mock domains reachable

# Testing
./devstack.sh test [grep-filter]          # Run Playwright in container

# Mocks
./devstack.sh mocks                       # List configured mocks
./devstack.sh new-mock <name> <domain>    # Scaffold mock directory
./devstack.sh reload-mocks                # Hot-reload WireMock mappings
./devstack.sh record <mock-name>          # Proxy real API, capture responses
./devstack.sh apply-recording <mock-name> # Copy recordings into mock

# Setup
./devstack.sh init                        # Interactive project scaffold
./devstack.sh generate                    # Regenerate config (dry run)
```

## When adding a new feature to devstack.sh

1. Add the function (`cmd_your_feature`)
2. Add to the `case` statement in `main()`
3. Add to the help text (keep the category grouping)
4. Update `README.md` commands table
5. Update `docs/QUICKSTART.md` CLI reference
6. Run `./devstack.sh help` to verify formatting
7. Run `./devstack.sh test` to verify nothing broke

## When modifying a generator script

1. Make the change in `core/*/generate.sh`
2. Run `./devstack.sh generate` to inspect output in `.generated/`
3. Run `docker compose -f .generated/docker-compose.yml config --quiet` to validate YAML
4. Run `./devstack.sh stop && ./devstack.sh start` to test the full flow
5. Run `./devstack.sh test` — all 6 tests must pass

## When adding a new template variable

1. Add it to `project.env` with a default value
2. Add a `sed` substitution in `core/compose/generate.sh` (in the relevant template section)
3. Use `${VARIABLE}` in the template file
4. Document it in the variable table in `docs/CREATING_TEMPLATES.md`

## Open tasks

See `docs/TODO.md` for deferred work items (CI/CD integration, etc.).
