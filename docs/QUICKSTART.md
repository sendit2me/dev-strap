# Getting Started

## Prerequisites

- Docker (with Compose v2.20+)
- jq (for `--options` and `--bootstrap` contract)

That's it. No language runtimes, no package managers.

## Init with a preset

Presets give you a curated stack in one step:

```bash
./devstack.sh init --preset spa-api        # Vite + API + DB + QA + mocking
./devstack.sh init --preset api-only       # API + DB + Redis + Swagger UI
./devstack.sh init --preset full-stack     # Vite + API + DB + Redis + monitoring
./devstack.sh init --preset data-pipeline  # Python + DB + NATS + MinIO
```

The wizard prompts for your app type (Node.js, PHP, Go, Python, or Rust) and project name.

## Init interactively

```bash
./devstack.sh init
```

Walk through each category: app template, frontend, database, services, tooling, and observability.

## What you get

After init, you have a self-contained project directory:

```
my-project/
├── docker-compose.yml          # include directives for services/
├── services/
│   ├── cert-gen.yml            # TLS certificate generation
│   ├── app.yml                 # your chosen backend
│   ├── caddy.yml               # generated at start (reverse proxy)
│   ├── database.yml            # if selected
│   ├── redis.yml               # if selected
│   └── ...                     # one file per selected service
├── app/
│   ├── Dockerfile
│   └── src/                    # your application code goes here
├── mocks/                      # mock service definitions
├── tests/playwright/           # test specs
├── project.env                 # all configuration
└── devstack.sh                 # runtime CLI
```

`ls services/` shows your stack. The project has no dependency on dev-strap.

## Start your project

```bash
cd my-project/
./devstack.sh start
```

Open `http://localhost:8080`. Your stack is running.

## Common commands

```bash
# Stack lifecycle
./devstack.sh start                       # Build and start
./devstack.sh stop                        # Stop (volumes preserved)
./devstack.sh stop --clean                # Stop and remove everything
./devstack.sh restart                     # Restart (volumes preserved)
./devstack.sh status                      # Container health
./devstack.sh logs [service]              # Tail logs
./devstack.sh shell [service]             # Shell into a container

# Testing
./devstack.sh test                        # Run Playwright tests
./devstack.sh test "login"                # Run tests matching a filter

# Mocks
./devstack.sh mocks                       # List configured mocks
./devstack.sh new-mock stripe api.stripe.com  # Scaffold a new mock
./devstack.sh reload-mocks                # Hot-reload mappings (no restart)
./devstack.sh record stripe               # Record real API responses
./devstack.sh apply-recording stripe      # Apply recordings as mocks
./devstack.sh verify-mocks                # Verify mock DNS interception
```

## PowerHouse integration

DevStrap implements the PowerHouse contract:

```bash
# Get catalog (returns manifest.json)
./devstack.sh --options

# Bootstrap from JSON payload
./devstack.sh --bootstrap '{"project":"myapp","selections":{"app":{"go":{}}}}'
```

See `DEVSTRAP-POWERHOUSE-CONTRACT.md` for the full contract specification.

## Next steps

| I want to... | Read |
|---------------|------|
| Add a service to the catalog | [ADDING_SERVICES.md](ADDING_SERVICES.md) |
| Create a new app template | [CREATING_TEMPLATES.md](CREATING_TEMPLATES.md) |
| Understand the architecture | [ARCHITECTURE.md](ARCHITECTURE.md) |
| Contribute to the factory | [DEVELOPMENT.md](DEVELOPMENT.md) |
