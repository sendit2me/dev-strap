# AI Agent Bootstrap (Factory)

This document is for AI agents working on the dev-strap **factory** -- the tool that generates Docker development environments.

## What this project is

DevStrap is a factory. It takes a catalog of services and user selections, then assembles a self-contained project directory with Docker Compose, templates, and a lightweight runtime CLI.

It is NOT:
- A web application
- A Docker image
- Something users run directly after bootstrap

It IS:
- A set of bash scripts that assemble Docker infrastructure from templates
- A catalog of service definitions (`contract/manifest.json`)
- A CLI (`devstack.sh`) that handles discovery, validation, and assembly

## The two systems

```
FACTORY (this repo)                    PRODUCT (user's project)
-----------------------                -------------------------
When: before choices are made          When: after choices are made
Job: present catalog, assemble         Job: start, stop, test, develop

Contains:                              Contains:
  contract/manifest.json                 docker-compose.yml (include directives)
  templates/apps/*/                      services/app.yml (the chosen one)
  templates/frontends/*/                 services/database.yml (if chosen)
  templates/databases/*/                 services/redis.yml (if chosen)
  templates/extras/*/                    services/caddy.yml (generated at start)
  templates/common/*/                    services/wiremock.yml (generated at start)
  product/devstack.sh                    devstack.sh (lightweight runtime)
  product/certs/generate.sh              certs/generate.sh
  core/caddy/generate-caddyfile.sh       caddy/Caddyfile (generated at start)
  devstack.sh (full factory CLI)         project.env
```

The boundary is the **bootstrap moment**. Everything before = factory. Everything after = product.

## Critical: source-of-truth

```
SOURCE (edit these):                   PRODUCT (generated output):
  contract/manifest.json                 <project>/docker-compose.yml
  templates/apps/*/service.yml           <project>/services/app.yml
  templates/frontends/*/service.yml      <project>/services/frontend.yml
  templates/databases/*/service.yml      <project>/services/database.yml
  templates/extras/*/service.yml         <project>/services/<extra>.yml
  templates/common/*.yml                 <project>/services/cert-gen.yml etc
  product/devstack.sh                    <project>/devstack.sh
  product/certs/generate.sh              <project>/certs/generate.sh
  core/caddy/generate-caddyfile.sh       (logic reused in product's devstack.sh)
  devstack.sh                            (factory CLI, not shipped)
```

## File reading order

When starting work, read in this order:

1. `contract/manifest.json` -- the catalog (categories, items, presets, wiring rules)
2. `devstack.sh` -- the factory CLI, focus on `generate_from_bootstrap()` and `cmd_init()`
3. `product/devstack.sh` -- the product runtime CLI (start/stop/test/mocks)
4. `templates/` -- service definitions (standalone compose fragments with `services:` key)
5. `core/caddy/generate-caddyfile.sh` -- Caddyfile generation logic

Only read further if your task requires it.

## How assembly works

`generate_from_bootstrap()` takes a validated JSON payload and:

1. Extracts selections (app, database, frontend, extras)
2. Creates the product directory structure (`services/`, `caddy/`, `certs/`, `app/`, `mocks/`, `tests/`)
3. Copies `product/devstack.sh` (the runtime CLI)
4. Copies common templates (`cert-gen.yml`, `tester.yml`, `test-dashboard.yml`)
5. Copies selected templates (app, database, frontend, extras)
6. Writes `project.env` with all configuration and port assignments
7. Resolves auto-wiring rules and appends to `project.env`
8. Assembles `docker-compose.yml` with `include` directives for each service
9. Scaffolds mock examples (if WireMock selected) and test infrastructure

## How the product works

The product uses Docker Compose `include` -- the root `docker-compose.yml` lists service files:

```yaml
include:
  - path: services/cert-gen.yml
    project_directory: .
  - path: services/app.yml
    project_directory: .
  - path: services/caddy.yml
    project_directory: .
  # ... one entry per selected service
```

Each service file is a standalone compose fragment with a `services:` top-level key. `ls services/` shows the stack.

At start time, the product's `devstack.sh`:
1. Collects mock domains from `mocks/*/domains`
2. Generates `caddy/Caddyfile` and `services/caddy.yml` (dynamic, depends on mock domains)
3. Generates `services/wiremock.yml` (dynamic, depends on mock mappings)
4. Runs `docker compose up`

## Variable substitution

Templates use `${VAR}` placeholders. Docker Compose resolves these from `project.env` (symlinked as `.env`) at runtime. This is native compose interpolation -- no sed, no envsubst.

**Exception**: top-level YAML keys like volume names and network names must be **literal** (e.g., `devstack-certs`, not `${PROJECT_NAME}-certs`). Docker Compose does not interpolate variables in top-level key positions.

Common variables:

| Variable | Source | Example |
|----------|--------|---------|
| `${PROJECT_NAME}` | project.env | `myproject` |
| `${APP_SOURCE}` | project.env | `./app` |
| `${DB_TYPE}` | project.env | `postgres` |
| `${DB_PORT}` | Derived from DB_TYPE | `5432` |
| `${DB_NAME}` | project.env | `myproject` |
| `${HTTP_PORT}` | project.env | `8080` |
| `${HTTPS_PORT}` | project.env | `8443` |

## Pitfalls

### 1. Factory vs product confusion
The factory (`devstack.sh` at repo root) and product (`product/devstack.sh`) are different scripts. Do not edit the product to test factory logic -- bootstrap a test project instead.

### 2. Templates must have `services:` wrapper
Every template in `templates/` must have a `services:` top-level key. Docker Compose `include` requires this.

### 3. Volume and network names are literal
In templates, volume and network names must be literal strings like `devstack-certs` and `devstack-internal`. Docker Compose does not interpolate variables in YAML key positions.

### 4. CA certificate trust differs by language
Mock interception requires the app to trust the self-signed CA at `/certs/ca.crt`:
- **Node.js**: `NODE_EXTRA_CA_CERTS=/certs/ca.crt`
- **Go / Rust**: `SSL_CERT_FILE=/certs/ca.crt`
- **Python**: `REQUESTS_CA_BUNDLE`, `SSL_CERT_FILE`, `CURL_CA_BUNDLE`
- **PHP**: `update-ca-certificates` in init script

### 5. Caddy and WireMock service files are generated at runtime
`services/caddy.yml` and `services/wiremock.yml` are generated by the product's `devstack.sh` at start time because they depend on mock domain configuration. Do not include static versions of these in templates.

### 6. Root-owned files from containers
Containers write files as root. Test results, node_modules, and recorded mock files may be root-owned. The product's `devstack.sh stop --clean` handles cleanup.

### 7. Playwright version must match container image
`tests/playwright/package.json` pins `@playwright/test` to a specific version. The tester template uses a matching Playwright Docker image. Mismatched versions cause "Executable doesn't exist" errors.

### 8. Port convention
Caddy routes to `app:3000` for all app types except PHP-FPM, which uses `php_fastcgi app:9000`. Make new templates listen on port 3000.

## How to verify changes

```bash
# Run contract tests (fast, no Docker needed for most)
bash tests/contract/test-contract.sh

# Test a template change: bootstrap a project and inspect
./devstack.sh --bootstrap '{"project":"test","selections":{"app":{"go":{}}}}'
ls test/services/

# Full integration: bootstrap + start + test
cd test/ && ./devstack.sh start && ./devstack.sh test
```

## When adding a factory feature

1. Add logic in `devstack.sh`
2. Add to the `case` statement in `main()`
3. Update help text
4. Run `bash tests/contract/test-contract.sh`
5. Bootstrap a test project to verify output

## When modifying a template

1. Edit the template in `templates/`
2. Bootstrap a test project: `./devstack.sh --bootstrap '...'`
3. Inspect the product output in the test project directory
4. Start the test project and verify: `cd test/ && ./devstack.sh start`
