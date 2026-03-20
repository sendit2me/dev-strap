# DevStack Architecture

## Design Principles

1. **Only Docker required** — No language runtimes, package managers, or tools on the host machine
2. **Directory-driven config** — The filesystem IS the configuration. `ls mocks/` shows what's mocked
3. **Transparent interception** — App code makes real HTTPS requests; DNS + Caddy + WireMock intercept them
4. **Clean slate** — `stop` removes everything. `start` builds from scratch. Deterministic every time
5. **Proof of execution** — Tests produce HTML reports, screenshots, and JSON artifacts

## System Diagram

```
┌─────────────────────────────────────────────────────────────────────┐
│                        Docker Network                               │
│                    (project-internal bridge)                         │
│                                                                     │
│  ┌──────────┐     ┌──────────────────────────────┐                  │
│  │          │     │        Caddy v2 (web)         │                  │
│  │   App    │────▶│  - Path routing:              │◀── localhost:8080│
│  │(backend) │     │    /api/* → app (backend)     │◀── localhost:8443│
│  │          │     │    /*    → frontend (if any)   │                  │
│  └────┬─────┘     │  - Proxies mocked domains     │                  │
│       │           │    to WireMock                 │                  │
│       │           │  - DNS aliases:               │                  │
│  ┌────┴─────┐     │    api.openai.com              │                  │
│  │ Frontend │────▶│    api.stripe.com              │                  │
│  │  (Vite)  │     │    (from mocks/*/domains)      │                  │
│  │(optional)│     └──────────┬───────────────────┘                  │
│  └──────────┘                │                                      │
│                              ▼                                      │
│  ┌──────────┐     ┌──────────────────────┐     ┌──────────────┐    │
│  │    DB    │     │     WireMock          │     │   cert-gen   │    │
│  │(MariaDB/ │     │  - JSON stub mappings │     │  - Root CA   │    │
│  │ Postgres)│     │  - Stateful scenarios │     │  - Server    │    │
│  └──────────┘     │  - Conditional logic  │     │    cert      │    │
│                   └───────────────────────┘     └──────────────┘    │
│  ┌──────────┐                                                       │
│  │  Redis   │     ┌──────────────────────┐                          │
│  │ NATS     │     │   Tester (Playwright)│                          │
│  │ MinIO    │     │  - Runs specs        │                          │
│  │ Mailpit  │     │  - Screenshots/video │                          │
│  │  (extras)│     └──────────────────────┘                          │
│  └──────────┘                                                       │
│                   ┌──────────────────────┐                          │
│  ┌──────────┐     │   Test Dashboard     │◀── localhost:8082        │
│  │Adminer   │     │  - HTTP file server  │                          │
│  │Swagger UI│     │  - Browse reports    │                          │
│  │  (tools) │     └──────────────────────┘                          │
│  └──────────┘                                                       │
└─────────────────────────────────────────────────────────────────────┘
```

## Directory Structure

```
devstack/
├── devstack.sh              # CLI entry point
├── project.env              # Project configuration
├── .generated/              # Auto-generated files (gitignored)
│   ├── docker-compose.yml   # Assembled from templates
│   ├── Caddyfile            # Built from mocks/*/domains
│   └── domains.txt          # All mocked domains (for cert-gen)
│
├── core/                    # Generation scripts
│   ├── certs/
│   │   └── generate.sh     # PKI generation (runs in container)
│   ├── caddy/
│   │   └── generate-caddyfile.sh # Caddyfile from directory structure
│   └── compose/
│       └── generate.sh      # Docker-compose from templates
│
├── contract/
│   └── manifest.json        # Catalog source of truth (presets, categories, wiring)
│
├── templates/               # Composable service definitions
│   ├── apps/
│   │   ├── node-express/    # Dockerfile + service.yml + .devcontainer/
│   │   ├── php-laravel/
│   │   ├── go/              # Includes air (file-watcher) config
│   │   ├── python-fastapi/  # FastAPI with uvicorn + uv package manager
│   │   └── rust/            # Cargo workspace with cargo-watch
│   ├── frontends/
│   │   └── vite/            # Vite dev server with HMR
│   ├── databases/
│   │   ├── mariadb/
│   │   └── postgres/
│   └── extras/
│       ├── redis/
│       ├── mailpit/
│       ├── nats/            # NATS messaging with JetStream
│       ├── minio/           # S3-compatible object storage
│       ├── db-ui/           # Adminer database browser
│       └── swagger-ui/      # OpenAPI spec viewer
│
├── mocks/                   # One directory per mocked service
│   ├── example-api/
│   │   ├── domains          # "api.example-provider.com"
│   │   └── mappings/        # WireMock JSON stubs
│   └── example-payment/
│       ├── domains          # "api.payment-provider.com"
│       └── mappings/        # Stateful + conditional stubs
│
├── app/                     # Your application source code
│   ├── Dockerfile
│   ├── src/
│   └── init.sh             # Project-specific initialization
│
├── tests/
│   ├── playwright/          # Test specs + config
│   └── results/             # Test output (transient)
│
└── docs/
```

## SSL/TLS Certificate Chain

```
cert-gen container (alpine:3)
    │
    ├── Reads: .generated/domains.txt (all domains from mocks/*/domains)
    │
    ├── Generates:
    │   ├── ca.key + ca.crt           Root CA (10-year validity)
    │   └── server.key + server.crt   Server cert signed by Root CA
    │                                  SANs: localhost + all mock domains
    │
    └── Outputs to: project-certs volume (shared with caddy, app, wiremock)
```

The app container trusts the Root CA via `NODE_EXTRA_CA_CERTS` (Node.js), `SSL_CERT_FILE` (Go), or OS trust store update (PHP). This means `https.request('api.openai.com')` succeeds with our self-signed cert.

## Mock Interception Flow (detailed)

1. App code calls `https://api.stripe.com/v1/charges`
2. Docker's internal DNS resolves `api.stripe.com` to the Caddy container (configured via `networks.aliases` in docker-compose)
3. Caddy receives the TLS connection, terminates it using our custom cert
4. Caddy's site block for `api.stripe.com` proxies the decrypted request to `http://wiremock:8080`
5. Caddy adds `X-Original-Host: api.stripe.com` header so WireMock knows the original target
6. WireMock matches the request against `mocks/stripe/mappings/*.json`
7. WireMock returns the mock response (may be stateful or conditional)
8. Response flows back through Caddy → app, as if Stripe responded

## Generation Pipeline

```
project.env + mocks/*/domains
         │
         ├──▶ core/caddy/generate-caddyfile.sh ──▶ .generated/Caddyfile
         │
         ├──▶ core/compose/generate.sh ──▶ .generated/docker-compose.yml
         │     │
         │     ├── reads templates/apps/{APP_TYPE}/service.yml
         │     ├── reads templates/frontends/{FRONTEND_TYPE}/service.yml (if configured)
         │     ├── reads templates/databases/{DB_TYPE}/service.yml
         │     ├── reads templates/extras/{name}/service.yml
         │     ├── mounts mocks/*/mappings/ into WireMock (for request matching)
         │     ├── mounts mocks/*/__files/ into WireMock (for response bodies)
         │     └── applies wiring rules from contract/manifest.json
         │
         └──▶ .generated/domains.txt ──▶ core/certs/generate.sh (in container)
                                              │
                                              └──▶ project-certs volume
```

Everything in `.generated/` is ephemeral — deleted on `devstack.sh stop`, regenerated on `devstack.sh start`.

## Mock Recording Pipeline

```
./devstack.sh record <name>
         │
         ├── Reads mocks/<name>/domains for the target API hostname
         ├── Runs temporary WireMock in proxy mode (--proxy-all --record-mappings)
         ├── Captures request/response pairs to mocks/<name>/recordings/
         │
         └── ./devstack.sh apply-recording <name>
              │
              ├── Copies mappings to mocks/<name>/mappings/
              ├── Copies response bodies to mocks/<name>/__files/
              ├── Rewrites bodyFileName paths for WireMock subdirectory mounting
              ├── Fixes file ownership (container writes as root)
              ├── Cleans up recordings/
              └── Calls reload-mocks (WireMock /__admin/mappings/reset)
```

## Adding a New App Template

1. Create `templates/apps/my-language/`
2. Add `service.yml` (docker-compose service definition with `${VAR}` placeholders)
3. Add `Dockerfile` (language toolchain + file-watcher for live reload)
4. Optionally add `.devcontainer/devcontainer.json` for VS Code
5. Set `APP_TYPE=my-language` in `project.env`

The service.yml must define a service named `app` that exposes port 3000 (for most languages) or 9000 (for PHP-FPM). Caddy handles both via `reverse_proxy` and `php_fastcgi` respectively — no protocol branching is needed in the template. See [CREATING_TEMPLATES.md](CREATING_TEMPLATES.md) for a full walkthrough.

## Path-Based Routing (Caddy)

When a frontend is configured alongside a backend, Caddy provides path-based routing through a single entry point (`localhost:8080` / `localhost:8443`):

```
Request ──▶ Caddy (web)
              │
              ├── /api/*  ──▶ reverse_proxy app:3000   (backend)
              └── /*      ──▶ reverse_proxy frontend:5173 (frontend / Vite)
```

Caddy's `reverse_proxy` handles WebSocket upgrade headers automatically, so Vite's HMR works without special configuration. For PHP backends, Caddy uses `php_fastcgi app:9000` instead of `reverse_proxy` — this is transparent to the frontend and requires no protocol branching in the generator.

When no frontend is configured, all requests route directly to the backend.

## Auto-Wiring

The `wiring` array in `contract/manifest.json` declares rules that fire when specific items are co-selected. During generation, `resolve_wiring()` evaluates each rule's `when` condition against the current selections and injects environment variables into the target service.

Example: when both `app.*` and `services.redis` are selected, the rule sets `REDIS_URL=redis://redis:6379` on the app container — no manual configuration needed.

Wiring rules are informational in the contract. PowerHouse can display them as hints or ignore the key entirely.

## Presets

The `presets` key in the manifest defines pre-configured stack bundles for common use cases (e.g., `spa-api`, `api-only`, `full-stack`, `data-pipeline`). Each preset specifies pre-selected items and optionally lists categories that still require user input via `prompts`.

Presets are a UI-only concept. PowerHouse expands a preset into concrete selections before sending the `--bootstrap` payload. dev-strap never receives a preset identifier.

## Current Catalog

| Category | Selection | Required | Items |
|----------|-----------|----------|-------|
| `app` | single | yes | `node-express`, `php-laravel`, `go`, `python-fastapi`, `rust` |
| `frontend` | single | no | `vite` |
| `database` | single | no | `postgres`, `mariadb` |
| `services` | multi | no | `redis`, `mailpit`, `nats`, `minio` |
| `tooling` | multi | no | `qa`, `qa-dashboard`, `wiremock`, `devcontainer`, `db-ui`, `swagger-ui` |
| `observability` | multi | no | `prometheus`, `grafana`, `dozzle` |

The full catalog with defaults, dependencies, and conflicts is defined in `contract/manifest.json`.
