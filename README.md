# DevStrap

A container-first development environment where external APIs are transparently mocked at the network layer. No `isDev` flags. No code changes between dev and production. Just Docker.

## The Problem

Your app calls Stripe, OpenAI, Twilio, SendGrid. In development, you need:
- Mock responses without real API keys or costs
- Every team member to get identical, reproducible results
- Tests that prove the integration works, with screenshots
- Zero setup beyond `git clone` and `docker`

The usual approach — `if (process.env.NODE_ENV === 'development')` — litters your codebase with conditional paths that don't exist in production. When you go live, you're running code paths that were never tested.

## The Solution

DevStrap intercepts HTTPS at the network layer:

```
Your app → HTTPS to api.stripe.com
         → Docker DNS resolves to nginx (network alias)
         → Nginx terminates TLS with auto-generated cert
         → Nginx proxies to WireMock
         → WireMock returns mock response
         → Your app gets a response as if Stripe replied
```

Your application code is byte-for-byte identical in dev and production. The interception happens in infrastructure, not in code.

## Quick Start

```bash
git clone https://github.com/sendit2me/dev-strap.git
cd dev-strap
./devstack.sh start
```

Open http://localhost:8080 — the example app calls two mocked APIs demonstrating simple, stateful, and conditional mock patterns.

```bash
./devstack.sh test       # Run Playwright tests in container (6/6 pass)
./devstack.sh mocks      # List what's mocked
./devstack.sh shell      # Drop into the app container
./devstack.sh stop       # Tear down everything (clean slate)
```

## How Mocking Works

Mock services are directories:

```
mocks/
├── stripe/
│   ├── domains              # "api.stripe.com" — one domain per line
│   └── mappings/
│       └── create-charge.json   # WireMock JSON stub
└── openai/
    ├── domains              # "api.openai.com"
    └── mappings/
        ├── chat.json
        └── chat-stream.json
```

`ls mocks/` shows what's mocked. Adding a mock:

```bash
mkdir -p mocks/twilio/mappings
echo "api.twilio.com" > mocks/twilio/domains
# Add WireMock JSON mappings, then:
./devstack.sh restart
```

Certificates, nginx routing, and DNS aliases are auto-generated from the directory structure.

## Architecture

```
┌─── Docker Network ────────────────────────────────────────┐
│                                                           │
│  [App] ──HTTPS──▶ [Nginx] ──proxy──▶ [WireMock]         │
│    │              (DNS aliases:       (JSON stubs,        │
│    │               api.stripe.com     stateful scenarios, │
│    │               api.openai.com)    conditional logic)  │
│    │                                                      │
│    ├──▶ [DB] (MariaDB / Postgres)                        │
│    ├──▶ [Redis]                                          │
│    └──▶ [Mailpit]                                        │
│                                                           │
│  [Tester] ─── Playwright in container                    │
│  [Dashboard] ─── Test reports at localhost:8082           │
│  [Cert-gen] ─── Auto-generates CA + server certs         │
└───────────────────────────────────────────────────────────┘
```

## What You Need

- Docker (with Compose v2)
- That's it. No language runtimes. No package managers. No tools.

## Configuration

Everything is in `project.env`:

```env
PROJECT_NAME=my-app
APP_TYPE=node-express    # or php-laravel, go
APP_SOURCE=./app
DB_TYPE=mariadb          # or postgres, none
EXTRAS=redis,mailpit
HTTP_PORT=8080
```

## Mock Patterns

DevStrap includes working examples of three WireMock patterns:

- **Simple** — fixed request/response pairs
- **Stateful** — responses change across sequential calls (pending → processing → complete)
- **Conditional** — different responses based on request body (amount >= 10000 → requires_review)

## App Templates

| Template | Language | Live Reload | Port |
|----------|----------|-------------|------|
| `node-express` | Node.js 22 | `--watch` (built-in) | 3000 |
| `php-laravel` | PHP 8.3 FPM | Automatic (FPM) | 9000 |
| `go` | Go 1.24 | Air (file watcher) | 3000 |

All templates include `.devcontainer/` config for VS Code.

## Commands

```
./devstack.sh start              Build and start the full stack
./devstack.sh stop               Tear down everything (clean slate)
./devstack.sh restart             Stop and start (clean rebuild)
./devstack.sh test [filter]      Run Playwright tests in container
./devstack.sh shell [service]    Shell into a container
./devstack.sh status             Show container health
./devstack.sh logs [service]     Tail logs
./devstack.sh mocks              List configured mock services
./devstack.sh reload-mocks       Hot-reload mock mappings (no restart)
./devstack.sh new-mock <name> <domain>  Scaffold a new mock service
./devstack.sh record <mock>      Record real API responses as mock mappings
./devstack.sh apply-recording <mock>  Apply recorded mappings (with path fixup)
./devstack.sh generate           Regenerate config without starting
```

## Documentation

| Guide | What |
|-------|------|
| [QUICKSTART](docs/QUICKSTART.md) | Try the example, CLI reference |
| [PROJECT_SETUP](docs/PROJECT_SETUP.md) | Set up your own project from scratch |
| [ADDING_MOCKS](docs/ADDING_MOCKS.md) | Mock patterns, WireMock mappings |
| [ADDING_SERVICES](docs/ADDING_SERVICES.md) | Custom services with port forwarding |
| [DEVELOPMENT](docs/DEVELOPMENT.md) | Dev workflow, devcontainers, database |
| [TESTING](docs/TESTING.md) | Writing and running tests |
| [CREATING_TEMPLATES](docs/CREATING_TEMPLATES.md) | New app templates (Rust, Python, etc.) |
| [ARCHITECTURE](docs/ARCHITECTURE.md) | System design and internals |
| [TROUBLESHOOTING](docs/TROUBLESHOOTING.md) | Common issues and fixes |

## Design Principles

1. **Only Docker required** — Nothing else installed on the developer's machine
2. **Directory-driven config** — The filesystem IS the configuration
3. **Transparent interception** — App code is identical in dev and production
4. **Clean slate** — `stop` removes everything. `start` builds from scratch. Deterministic.
5. **Proof of execution** — Tests produce HTML reports with screenshots, not just exit codes
