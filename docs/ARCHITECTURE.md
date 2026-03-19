# DevStack Architecture

## Design Principles

1. **Only Docker required** — No language runtimes, package managers, or tools on the host machine
2. **Directory-driven config** — The filesystem IS the configuration. `ls mocks/` shows what's mocked
3. **Transparent interception** — App code makes real HTTPS requests; DNS + nginx + WireMock intercept them
4. **Clean slate** — `stop` removes everything. `start` builds from scratch. Deterministic every time
5. **Proof of execution** — Tests produce HTML reports, screenshots, and JSON artifacts

## System Diagram

```
┌─────────────────────────────────────────────────────────────────────┐
│                        Docker Network                               │
│                    (project-internal bridge)                         │
│                                                                     │
│  ┌──────────┐     ┌──────────────────────────────┐                  │
│  │          │     │         Nginx (web)           │                  │
│  │   App    │────▶│  - Serves app on :80/:443     │◀── localhost:8080│
│  │Container │     │  - Proxies mocked domains     │◀── localhost:8443│
│  │          │     │    to WireMock                 │                  │
│  └────┬─────┘     │  - DNS aliases:               │                  │
│       │           │    api.openai.com              │                  │
│       │           │    api.stripe.com              │                  │
│       │           │    (from mocks/*/domains)      │                  │
│       │           └──────────┬───────────────────┘                  │
│       │                      │                                      │
│       ▼                      ▼                                      │
│  ┌──────────┐     ┌──────────────────────┐     ┌──────────────┐    │
│  │    DB    │     │     WireMock          │     │   cert-gen   │    │
│  │(MariaDB/ │     │  - JSON stub mappings │     │  - Root CA   │    │
│  │ Postgres)│     │  - Stateful scenarios │     │  - Server    │    │
│  └──────────┘     │  - Conditional logic  │     │    cert      │    │
│                   └───────────────────────┘     │  - JKS store │    │
│  ┌──────────┐                                   └──────────────┘    │
│  │  Redis   │     ┌──────────────────────┐                          │
│  │ Mailpit  │     │   Tester (Playwright)│                          │
│  │  (extras)│     │  - Runs specs        │                          │
│  └──────────┘     │  - Screenshots/video │                          │
│                   └──────────────────────┘                          │
│                                                                     │
│                   ┌──────────────────────┐                          │
│                   │   Test Dashboard     │◀── localhost:8082        │
│                   │  - HTTP file server  │                          │
│                   │  - Browse reports    │                          │
│                   └──────────────────────┘                          │
└─────────────────────────────────────────────────────────────────────┘
```

## Directory Structure

```
devstack/
├── devstack.sh              # CLI entry point
├── project.env              # Project configuration
├── .generated/              # Auto-generated files (gitignored)
│   ├── docker-compose.yml   # Assembled from templates
│   ├── nginx.conf           # Built from mocks/*/domains
│   └── domains.txt          # All mocked domains (for cert-gen)
│
├── core/                    # Generation scripts
│   ├── certs/
│   │   └── generate.sh     # PKI generation (runs in container)
│   ├── nginx/
│   │   └── generate-conf.sh # Nginx config from directory structure
│   └── compose/
│       └── generate.sh      # Docker-compose from templates
│
├── templates/               # Composable service definitions
│   ├── apps/
│   │   ├── node-express/    # Dockerfile + service.yml + .devcontainer/
│   │   ├── php-laravel/
│   │   └── go/              # Includes air (file-watcher) config
│   ├── databases/
│   │   ├── mariadb/
│   │   └── postgres/
│   └── extras/
│       ├── redis/
│       └── mailpit/
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
cert-gen container (eclipse-temurin:17-alpine)
    │
    ├── Reads: .generated/domains.txt (all domains from mocks/*/domains)
    │
    ├── Generates:
    │   ├── ca.key + ca.crt           Root CA (10-year validity)
    │   ├── server.key + server.crt   Server cert signed by Root CA
    │   │                              SANs: localhost + all mock domains
    │   └── wiremock.jks              Java keystore for WireMock
    │
    └── Outputs to: project-certs volume (shared with nginx, app, wiremock)
```

The app container trusts the Root CA via `NODE_EXTRA_CA_CERTS` (Node.js), `SSL_CERT_FILE` (Go), or OS trust store update (PHP). This means `https.request('api.openai.com')` succeeds with our self-signed cert.

## Mock Interception Flow (detailed)

1. App code calls `https://api.stripe.com/v1/charges`
2. Docker's internal DNS resolves `api.stripe.com` to the nginx container (configured via `networks.aliases` in docker-compose)
3. Nginx receives the TLS connection, performs SNI matching, serves our custom cert
4. Nginx's `server` block for `api.stripe.com` proxies the decrypted request to `http://wiremock:8080`
5. Nginx adds `X-Original-Host: api.stripe.com` header so WireMock knows the original target
6. WireMock matches the request against `mocks/stripe/mappings/*.json`
7. WireMock returns the mock response (may be stateful or conditional)
8. Response flows back through nginx → app, as if Stripe responded

## Generation Pipeline

```
project.env + mocks/*/domains
         │
         ├──▶ core/nginx/generate-conf.sh ──▶ .generated/nginx.conf
         │
         ├──▶ core/compose/generate.sh ──▶ .generated/docker-compose.yml
         │     │
         │     ├── reads templates/apps/{APP_TYPE}/service.yml
         │     ├── reads templates/databases/{DB_TYPE}/service.yml
         │     ├── reads templates/extras/{name}/service.yml
         │     ├── mounts mocks/*/mappings/ into WireMock (for request matching)
         │     └── mounts mocks/*/__files/ into WireMock (for response bodies)
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

The service.yml must define a service named `app` that exposes port 3000 (for proxied languages) or 9000 (for PHP-FPM). See [CREATING_TEMPLATES.md](CREATING_TEMPLATES.md) for a full walkthrough.
