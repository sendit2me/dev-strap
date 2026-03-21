# Architecture

## Factory / Product Separation

DevStrap is two systems sharing one repo:

**Factory** (creation-time) -- presents the catalog, validates selections, assembles a project. Lives in this repo. Runs once at bootstrap.

**Product** (runtime) -- starts, stops, tests, manages mocks. Lives in the user's project directory. Self-contained, no dependency on the factory.

```
FACTORY (this repo)                         PRODUCT (user's project)
  contract/manifest.json  ─┐                  docker-compose.yml
  templates/apps/*/        ├─ assembly ──▶     services/*.yml
  templates/extras/*/      │                   project.env
  devstack.sh              ┘                   devstack.sh (runtime)
```

The boundary is the bootstrap moment. Everything before = factory concern. Everything after = product concern.

### Why this matters

- The product has no unused templates, no catalog logic, no validation code
- `ls services/` shows the user's stack -- same as `ls mocks/` shows what's mocked
- Adding a service to the catalog does not change existing products
- The factory can evolve independently of deployed products

## The Assembly Pipeline

`generate_from_bootstrap()` is the core of the factory. It takes a validated JSON payload and:

```
JSON payload
  │
  ├─ 1. Extract selections (app, database, frontend, extras)
  ├─ 2. Create directory structure
  ├─ 3. Copy product/devstack.sh (runtime CLI)
  ├─ 4. Copy templates/common/*.yml (cert-gen, tester, test-dashboard)
  ├─ 5. Copy selected templates:
  │       templates/apps/{chosen}/service.yml     -> services/app.yml
  │       templates/apps/{chosen}/Dockerfile       -> app/Dockerfile
  │       templates/databases/{chosen}/service.yml -> services/database.yml
  │       templates/frontends/{chosen}/service.yml -> services/frontend.yml
  │       templates/extras/{name}/service.yml      -> services/{name}.yml
  ├─ 6. Write project.env (all config, ports, wiring)
  ├─ 7. Resolve auto-wiring rules -> append to project.env
  ├─ 8. Assemble docker-compose.yml (include directives)
  ├─ 9. Scaffold mocks (if WireMock selected)
  └─ 10. Scaffold test infrastructure
```

## Docker Compose Include Pattern

The product's `docker-compose.yml` uses Compose `include` (v2.20+):

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
  # ... one entry per selected service

networks:
  devstack-internal:
    driver: bridge
```

Each service file is a standalone compose fragment with a `services:` top-level key. The `project_directory: .` directive makes relative paths resolve from the product root, not the service file location.

Key behaviors:
- Volumes declared in included files merge into a global volumes section
- Services in included files can reference each other in `depends_on`
- The shared network `devstack-internal` is declared in the root compose file
- Variables resolve from `.env` (symlinked to `project.env`) in the project root

## Caddy Proxy Layer

Caddy serves as the reverse proxy (`web` container). It handles three concerns:

**App routing** -- proxies to the backend:
- HTTP backends: `reverse_proxy app:3000`
- PHP-FPM: `php_fastcgi app:9000`
- With frontend: path-based routing (`/api/*` to backend, `/*` to Vite)

**Mock interception** -- terminates TLS for mocked domains and proxies to WireMock:
```
mock-domain:443 {
    tls /certs/server.crt /certs/server.key
    reverse_proxy wiremock:8080 {
        header_up X-Original-Host {http.request.host}
    }
}
```

**Test results** -- serves static HTML reports at `/test-results/`.

The Caddyfile is generated at product start time because it depends on `mocks/*/domains`.

## Mock Interception Flow

```
1. App calls https://api.stripe.com/v1/charges
2. Docker DNS resolves api.stripe.com to Caddy (network alias in caddy.yml)
3. Caddy terminates TLS using custom cert (SANs include mock domains)
4. Caddy adds X-Original-Host: api.stripe.com header
5. Caddy proxies to http://wiremock:8080
6. WireMock matches against mocks/stripe/mappings/*.json
7. Mock response flows back through Caddy to app
```

The app code is identical in dev and production. No `isDev` flags.

DNS interception works because the `caddy.yml` service definition includes network aliases for each mocked domain. These aliases are generated at start time from `mocks/*/domains`.

## Certificate Generation

The `cert-gen` service is a one-shot Alpine container that generates a CA + server certificate:

```
cert-gen container (alpine:3 + openssl)
  ├─ Reads: domains.txt (all domains from mocks/*/domains)
  ├─ Generates:
  │   ├─ ca.key + ca.crt (Root CA, 10-year validity)
  │   └─ server.key + server.crt (Server cert, SANs: localhost + mock domains)
  └─ Outputs to: devstack-certs volume (shared with Caddy, app, WireMock)
```

App containers trust the CA via environment variables:
- Node.js: `NODE_EXTRA_CA_CERTS=/certs/ca.crt`
- Go / Rust: `SSL_CERT_FILE=/certs/ca.crt`
- Python: `REQUESTS_CA_BUNDLE`, `SSL_CERT_FILE`, `CURL_CA_BUNDLE`
- PHP: `update-ca-certificates` in init script

## Auto-Wiring System

The `wiring` array in `contract/manifest.json` declares rules that fire when specific items are co-selected:

```json
{
  "when": ["app.*", "services.redis"],
  "set": "app.*.redis_url",
  "template": "redis://redis:6379"
}
```

- `when`: all items must be present in selections (wildcards supported)
- `set`: output variable path; last segment becomes the env var name (uppercased)
- `template`: the value to write to project.env

During assembly, `resolve_wiring()` evaluates each rule against the selections and writes matching variables to `project.env`. For example, selecting Go + Redis writes `REDIS_URL=redis://redis:6379`.

Current wiring rules:

| Condition | Variable | Value |
|-----------|----------|-------|
| Vite + app | `FRONTEND_API_PREFIX` | `/api` |
| app + Redis | `REDIS_URL` | `redis://redis:6379` |
| app + NATS | `NATS_URL` | `nats://nats:4222` |
| app + MinIO | `S3_ENDPOINT` | `http://minio:9000` |
| db-ui + database | `DEFAULT_SERVER` | `db` |
| swagger-ui + app | `SPEC_URL` | `http://app:{port}/docs/openapi.json` |

## Preset Bundles

Presets in the manifest define pre-configured stacks:

| Preset | Selections |
|--------|-----------|
| `spa-api` | Vite + PostgreSQL + QA + WireMock (prompts for app type) |
| `api-only` | PostgreSQL + Redis + QA + Swagger UI (prompts for app type) |
| `full-stack` | Vite + PostgreSQL + Redis + QA + Prometheus + Grafana + Dozzle (prompts for app type) |
| `data-pipeline` | Python FastAPI + PostgreSQL + NATS + MinIO |

Presets are expanded into concrete selections before assembly. The factory never receives a preset identifier directly -- PowerHouse expands them first.

## The Catalog (manifest.json)

`contract/manifest.json` is the single source of truth for the catalog:

```json
{
  "contract": "devstrap-options",
  "version": "1",
  "presets": { ... },
  "categories": {
    "app":           { "selection": "single", "required": true,  "items": { ... } },
    "frontend":      { "selection": "single", "required": false, "items": { ... } },
    "database":      { "selection": "single", "required": false, "items": { ... } },
    "services":      { "selection": "multi",  "required": false, "items": { ... } },
    "tooling":       { "selection": "multi",  "required": false, "items": { ... } },
    "observability": { "selection": "multi",  "required": false, "items": { ... } }
  },
  "wiring": [ ... ]
}
```

Each item can declare:
- `defaults` -- default port(s) and settings
- `requires` -- dependencies (wildcard patterns like `app.*`)
- `conflicts` -- incompatible items

The `--options` command returns this manifest for PowerHouse to present as a UI.

## Current Catalog

| Category | Items |
|----------|-------|
| App (5) | `node-express`, `php-laravel`, `go`, `python-fastapi`, `rust` |
| Frontend (1) | `vite` |
| Database (2) | `postgres`, `mariadb` |
| Services (4) | `redis`, `mailpit`, `nats`, `minio` |
| Tooling (6) | `qa`, `qa-dashboard`, `wiremock`, `devcontainer`, `db-ui`, `swagger-ui` |
| Observability (3) | `prometheus`, `grafana`, `dozzle` |

4 preset bundles. 6 auto-wiring rules. Port collision detection at validation time.

## Contract Validation

The `--bootstrap` flow validates payloads before assembly:

1. Required categories have selections
2. Single-select categories have exactly one item
3. All referenced items exist in the manifest
4. Dependencies (`requires`) are satisfied
5. Conflicts are not violated
6. Default ports don't collide across selected services

Test fixtures in `tests/contract/fixtures/` cover all validation scenarios.

---

*Note: This document supersedes `docs/ARCHITECTURE-NEXT.md`, which contains the original research and reasoning behind the factory/product split. That document is preserved as historical context.*
