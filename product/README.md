# {{PROJECT_NAME}}

A Docker-based development environment with transparent HTTPS mock interception.

## Quick Start

```bash
./devstack.sh start
```

Open [http://localhost:{{HTTP_PORT}}](http://localhost:{{HTTP_PORT}}) (or [https://localhost:{{HTTPS_PORT}}](https://localhost:{{HTTPS_PORT}}))

## Your Stack

**Application**: {{APP_TYPE}}

{{SERVICES_LIST}}

## Project Structure

```
{{PROJECT_NAME}}/
├── docker-compose.yml       Root compose file (includes from services/)
├── project.env              Central configuration (ports, names, credentials)
├── devstack.sh              CLI for managing the stack
├── services/                Docker Compose fragments (ls = your stack)
│   ├── app.yml              Your application service
│   ├── caddy.yml            Reverse proxy (generated on start)
│   ├── wiremock.yml         Mock server (generated on start)
│   ├── cert-gen.yml         TLS certificate generator
│   └── ...                  Other services you selected
├── app/                     Your application source code
│   ├── Dockerfile
│   └── src/
├── mocks/                   Mock API definitions (ls = your mocked APIs)
│   └── <name>/
│       ├── domains           Intercepted domains (one per line)
│       └── mappings/*.json   WireMock stub responses
├── tests/
│   ├── playwright/           Playwright test specs
│   └── results/              Test output (generated)
├── caddy/
│   └── Caddyfile             Reverse proxy config (generated on start)
├── certs/                    TLS certificates (generated on start)
│   └── generate.sh           Certificate generation script
└── .env -> project.env       Symlink for Docker Compose variable resolution
```

Key principle: **`ls services/`** shows your infrastructure stack, just as **`ls mocks/`** shows your mocked APIs.

## Commands

### Stack Management

| Command | Description |
|---------|-------------|
| `./devstack.sh start` | Build and start all services |
| `./devstack.sh stop` | Stop services (database data and caches preserved) |
| `./devstack.sh stop --clean` | Stop and remove everything (volumes, artifacts) |
| `./devstack.sh restart` | Restart (preserves volumes) |
| `./devstack.sh restart --clean` | Full teardown and rebuild |
| `./devstack.sh status` | Show container status and health |
| `./devstack.sh logs [service]` | Tail logs (all services, or one) |
| `./devstack.sh shell [service]` | Open a shell in a container (default: app) |

### Testing

| Command | Description |
|---------|-------------|
| `./devstack.sh test` | Run all Playwright tests |
| `./devstack.sh test "login"` | Run tests matching a filter |

### Mock Management

| Command | Description |
|---------|-------------|
| `./devstack.sh mocks` | List all configured mocks and their domains |
| `./devstack.sh new-mock <name> <domain>` | Scaffold a new mock service |
| `./devstack.sh reload-mocks` | Hot-reload mock mappings (no restart) |
| `./devstack.sh record <mock>` | Record real API responses |
| `./devstack.sh apply-recording <mock>` | Apply recorded mappings to mock |
| `./devstack.sh verify-mocks` | Check all mocked domains are reachable |

## Architecture

### Mock Interception (How It Works)

Your app makes HTTPS requests to external APIs exactly as it would in production. The stack intercepts these transparently:

```
App requests https://api.stripe.com/v1/charges
  |
  v
Docker DNS resolves api.stripe.com --> Caddy (via network alias)
  |
  v
Caddy terminates TLS, adds X-Original-Host header, forwards to WireMock
  |
  v
WireMock matches the request against mocks/stripe/mappings/*.json
  |
  v
Stub response returned to app
```

No SDK wrappers, no `isDev` flags, no environment conditionals. Your app code is identical to production.

### Caddy (Reverse Proxy)

Caddy serves as the single entry point:

- Routes browser traffic to your app (HTTP/HTTPS)
- Intercepts mocked API domains via Docker DNS aliases
- Terminates TLS using auto-generated certificates
- Adds `X-Original-Host` header so WireMock can distinguish domains sharing the same URL paths

### Certificates

On every start, the cert-gen container checks `domains.txt` (assembled from `mocks/*/domains`) and regenerates certificates only if domains have changed. The CA certificate is mounted into the app container so your app trusts the self-signed certs.

## Configuration

### project.env

Central configuration file. All `${VAR}` references in service YAML files resolve from here at Docker Compose runtime.

| Variable | Purpose |
|----------|---------|
| `PROJECT_NAME` | Container name prefix, network name |
| `APP_TYPE` | Application type (for Caddyfile generation) |
| `HTTP_PORT` | Host port for HTTP traffic |
| `HTTPS_PORT` | Host port for HTTPS traffic |
| `APP_SOURCE` | Path to app source directory |
| `DB_NAME`, `DB_USER`, `DB_PASSWORD` | Database credentials (if applicable) |
| `NETWORK_SUBNET` | Docker network subnet (change to avoid conflicts between projects) |

### Service-specific configuration

Some services have their own env files at `services/*.env` (e.g., `services/database.env`). These are referenced via `env_file` in `docker-compose.yml`.

## Next Steps

- **Add a mock API**: see [docs/MOCKS.md](docs/MOCKS.md)
- **Add or remove a service**: see [docs/SERVICES.md](docs/SERVICES.md)
- **Something broken?**: see [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md)
