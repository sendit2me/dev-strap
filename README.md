# DevStrap

A meta-tool that generates self-contained Docker development environments.

## What it does

DevStrap is a **factory**. It presents a catalog of services, takes your selections, and assembles a self-contained project directory. After bootstrap, your project has no dependency on dev-strap.

```
dev-strap (factory)                      your-project/ (product)
  catalog + templates                      docker-compose.yml
  + your selections                        services/*.yml
  ──────────────────▶                      project.env
  assembly                                 devstack.sh (lightweight runtime)
                                           app/, mocks/, tests/
```

## Quick Start

```bash
# With a preset
./devstack.sh init --preset spa-api

# Interactive wizard
./devstack.sh init

# PowerHouse integration
./devstack.sh --bootstrap '{"project":"myapp","selections":{...}}'
```

The output is a self-contained directory. `cd` into it and run `./devstack.sh start`.

## The Catalog

| Category | Selection | Required | Items |
|----------|-----------|----------|-------|
| **App** | single | yes | `node-express`, `php-laravel`, `go`, `python-fastapi`, `rust` |
| **Frontend** | single | no | `vite` |
| **Database** | single | no | `postgres`, `mariadb` |
| **Services** | multi | no | `redis`, `mailpit`, `nats`, `minio` |
| **Tooling** | multi | no | `qa`, `qa-dashboard`, `wiremock`, `devcontainer`, `db-ui`, `swagger-ui` |
| **Observability** | multi | no | `prometheus`, `grafana`, `dozzle` |

### App templates

| Template | Language | Live Reload | Port |
|----------|----------|-------------|------|
| `node-express` | Node.js 22 | `--watch` (built-in) | 3000 |
| `php-laravel` | PHP 8.3 FPM | Automatic (FPM) | 9000 |
| `go` | Go 1.24 | Air (file watcher) | 3000 |
| `python-fastapi` | Python (FastAPI) | uvicorn hot reload | 3000 |
| `rust` | Rust | cargo-watch | 3000 |

### Databases

| Component | Description | Port |
|-----------|-------------|------|
| `postgres` | PostgreSQL 16 | 5432 |
| `mariadb` | MariaDB 10.11 | 3306 |

### Services

| Component | Description | Ports |
|-----------|-------------|-------|
| `redis` | Cache / queue / session store | 6379 |
| `mailpit` | SMTP catcher with web UI | 1025 (SMTP), 8025 (UI) |
| `nats` | Messaging with JetStream streaming | 4222 (client), 8222 (monitor) |
| `minio` | S3-compatible object storage | 9000 (API), 9001 (console) |

### Tooling

| Component | Description | Port |
|-----------|-------------|------|
| `qa` | Playwright test runner (isolated container) | -- |
| `qa-dashboard` | Web UI for test results | 8082 |
| `wiremock` | API mocking with hot-reload definitions | 8443 |
| `devcontainer` | VS Code dev container config | -- |
| `db-ui` | Adminer database browser | 8083 |
| `swagger-ui` | Live OpenAPI spec viewer | 8084 |

### Observability

| Component | Description | Port |
|-----------|-------------|------|
| `prometheus` | Metrics collection and time-series DB | 9090 |
| `grafana` | Metrics dashboards and visualization | 3001 |
| `dozzle` | Real-time Docker container log viewer | 9999 |

### Preset bundles

| Preset | What you get |
|--------|-------------|
| `spa-api` | Vite frontend + API backend + PostgreSQL + QA + WireMock |
| `api-only` | API backend + PostgreSQL + Redis + QA + Swagger UI |
| `full-stack` | Vite + API + PostgreSQL + Redis + QA + Prometheus + Grafana + Dozzle |
| `data-pipeline` | Python (FastAPI) + PostgreSQL + NATS + MinIO |

### Auto-wiring

When services are co-selected, connection variables are automatically set:

| Condition | Variable set |
|-----------|-------------|
| app + Redis | `REDIS_URL=redis://redis:6379` |
| app + NATS | `NATS_URL=nats://nats:4222` |
| app + MinIO | `S3_ENDPOINT=http://minio:9000` |
| Vite + app | `FRONTEND_API_PREFIX=/api` |
| db-ui + database | `DEFAULT_SERVER=db` |
| swagger-ui + app | `SPEC_URL=http://app:{port}/docs/openapi.json` |

## How It Works

### Factory assembles, product runs

The factory (this repo) does its job at bootstrap time:

1. **Discovery** -- PowerHouse calls `--options`, gets the catalog from `contract/manifest.json`
2. **Selection** -- user picks their stack (interactive, preset, or JSON payload)
3. **Validation** -- payload is validated against the manifest (dependencies, conflicts, port collisions)
4. **Assembly** -- factory copies the right templates into a product directory, writes `project.env`, assembles `docker-compose.yml` with `include` directives
5. **Done** -- the factory's job is complete

The product (user's project) is self-contained:

- `docker-compose.yml` uses `include` to pull in `services/*.yml`
- `ls services/` shows your stack
- `devstack.sh` is a lightweight runtime (start/stop/test/logs/mocks)
- No dependency on the factory after bootstrap

### What you get

```
my-project/
├── docker-compose.yml          # include directives for services/
├── services/
│   ├── cert-gen.yml            # TLS certificate generation
│   ├── app.yml                 # your chosen backend
│   ├── caddy.yml               # generated at runtime (reverse proxy)
│   ├── database.yml            # your chosen database (if selected)
│   ├── frontend.yml            # Vite dev server (if selected)
│   ├── redis.yml               # only if selected
│   └── wiremock.yml            # generated at runtime (if mocks exist)
├── caddy/
│   └── Caddyfile               # generated at runtime from mocks/*/domains
├── certs/
│   └── generate.sh             # certificate generation script
├── app/
│   ├── Dockerfile              # from your chosen template
│   └── src/                    # your application code
├── mocks/                      # mock service definitions
├── tests/
│   └── playwright/             # test specs
├── project.env                 # all configuration
└── devstack.sh                 # runtime CLI (start/stop/test/logs/mocks)
```

### Mock interception

Your app makes real HTTPS requests. Docker DNS + Caddy + WireMock intercept them transparently:

```
App calls https://api.stripe.com/v1/charges
  -> Docker DNS resolves api.stripe.com to Caddy (network alias)
  -> Caddy terminates TLS, proxies to WireMock
  -> WireMock matches against mocks/stripe/mappings/*.json
  -> App receives mock response as if Stripe replied
```

No `isDev` flags. App code is identical in dev and production.

## PowerHouse Integration

DevStrap implements a contract for integration with PowerHouse:

```bash
# Get catalog
./devstack.sh --options

# Bootstrap a project
./devstack.sh --bootstrap '{"project":"myapp","selections":{...}}'
```

See `DEVSTRAP-POWERHOUSE-CONTRACT.md` for the full contract specification.

## Contributing

| Guide | What |
|-------|------|
| [ARCHITECTURE](docs/ARCHITECTURE.md) | System design, assembly pipeline, catalog |
| [ADDING_SERVICES](docs/ADDING_SERVICES.md) | Add a new service to the catalog |
| [CREATING_TEMPLATES](docs/CREATING_TEMPLATES.md) | Create a new app/frontend template |
| [QUICKSTART](docs/QUICKSTART.md) | Getting started with dev-strap |
| [DEVELOPMENT](docs/DEVELOPMENT.md) | Developer guide for factory contributors |
