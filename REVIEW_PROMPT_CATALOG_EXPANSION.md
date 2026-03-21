# Review Prompt: dev-strap System Review

> **For**: A review team to analyse the complete system as it stands today.
> **Context**: dev-strap is a meta-tool (factory) that generates self-contained Docker development environments (products). This review covers the factory, the product, and everything in between.

---

## Instructions for Reviewers

You are reviewing dev-strap — a tool that generates Docker infrastructure for development environments. The system has two parts:

1. **The Factory** (this repo) — presents a catalog of services, takes selections, and assembles a self-contained project
2. **The Product** (what users get) — a project directory with Docker Compose `include`-based services, a lightweight CLI, and mock management

Read the files in the order below. For each section, assess the quality against the criteria listed.

---

## 1. Understand the Architecture

Read these to understand how the system is structured:

- `docs/ARCHITECTURE-NEXT.md` — Factory/product separation, design principles
- `docs/AI_BOOTSTRAP.md` — System architecture, file reading order, pitfalls
- `DEVSTRAP-POWERHOUSE-CONTRACT.md` — Contract interface with PowerHouse (orchestrator)

**Assessment criteria:**
- Is the factory/product boundary clearly defined?
- Is the contract specification complete and unambiguous?
- Does the documentation accurately describe the current system?

---

## 2. Review the Factory

The factory presents options and assembles projects.

- `devstack.sh` — Focus on:
  - `cmd_init()` — Interactive project scaffolding with `--preset` support
  - `cmd_contract_options()` / `cmd_contract_bootstrap()` — JSON contract interface
  - `validate_bootstrap_payload()` — 11 validation checks including port collision
  - `resolve_wiring()` — Auto-wiring resolution
  - `generate_from_bootstrap()` — Product assembly (file copying, not generation)
  - `build_bootstrap_response()` — Response with resolved services and wiring
- `contract/manifest.json` — The full catalog (categories, items, presets, wiring rules)

**Assessment criteria:**
- Does `cmd_init` read available types from the filesystem (not hardcoded)?
- Does `cmd_init --preset` work correctly?
- Does `generate_from_bootstrap` produce a self-contained product directory?
- Are all categories, items, defaults, requires, and conflicts internally consistent?
- Do preset selections reference valid items and satisfy dependency constraints?
- Are wiring rules well-formed?
- Is the port allocation collision-free in default configuration?
- Is backward compatibility maintained (contract version stays "1")?

---

## 3. Review the Product

The product is what ships to the user's project directory.

- `product/devstack.sh` — Lightweight runtime CLI (~580 lines)
- `product/certs/generate.sh` — Certificate generation with domain change detection
- `product/.gitignore` — What's tracked vs generated

**Assessment criteria:**
- Is the product truly self-contained? (no references back to the factory)
- Does `start` correctly generate only the dynamic files? (caddy.yml, wiremock.yml, Caddyfile, domains.txt)
- Is `stop` non-destructive by default? Does `stop --clean` work?
- Does `validate_config` catch the right things?
- Are mock management commands complete? (new-mock, reload, record, apply-recording, verify)

---

## 4. Review the Templates

Templates define individual services. The factory copies them to the product.

**App templates** (5 backends):
- `templates/apps/node-express/`, `templates/apps/go/`, `templates/apps/php-laravel/`
- `templates/apps/python-fastapi/`, `templates/apps/rust/`

**Frontend templates:**
- `templates/frontends/vite/`

**Database templates:**
- `templates/databases/postgres/`, `templates/databases/mariadb/`

**Service/tooling templates:**
- `templates/extras/redis/`, `templates/extras/nats/`, `templates/extras/minio/`, `templates/extras/mailpit/`
- `templates/extras/db-ui/`, `templates/extras/swagger-ui/`
- `templates/extras/prometheus/`, `templates/extras/grafana/`, `templates/extras/dozzle/`

**Common templates** (ship with every project):
- `templates/common/cert-gen.yml`, `templates/common/tester.yml`, `templates/common/test-dashboard.yml`

**Assessment criteria:**
- Does every service.yml have a `services:` top-level key? (required for compose include)
- Do all templates use literal volume/network names (e.g., `devstack-certs` not `${PROJECT_NAME}-certs`)?
- Do services that use named volumes declare them in their own `volumes:` section?
- Do all app templates have healthchecks?
- Are Dockerfiles well-structured? (layer caching, minimal images, correct base images)
- Are CA certificate handling patterns correct per language?
- Is the frontend template's service named `frontend` (not `app`)?

---

## 5. Review the Proxy Layer

- `core/caddy/generate-caddyfile.sh` — Caddyfile generator (used by both factory example and product)

**Assessment criteria:**
- Does it handle all three app routing modes? (PHP FastCGI, frontend+backend path-based, plain reverse proxy)
- Is the mock interception flow correct? (DNS alias → TLS termination → X-Original-Host → WireMock)
- Does `handle` (not `handle_path`) preserve the API prefix for backend routes?
- Is `auto_https off` set globally?
- Does `tls` correctly reference the cert paths?

---

## 6. Review the Compose Integration

Bootstrap a project and examine the output:

```bash
echo '{"contract":"devstrap-bootstrap","version":"1","project":"review-test","selections":{"app":{"go":{}},"frontend":{"vite":{}},"database":{"postgres":{}},"services":{"redis":{},"nats":{}},"tooling":{"wiremock":{}}}}' | ./devstack.sh --bootstrap --config -
```

Then examine `review-test/`:

**Assessment criteria:**
- Does `docker-compose.yml` use `include:` with `project_directory: .`?
- Does `ls services/` match the selections?
- Does `.env` symlink to `project.env`?
- Does `project.env` have `COMPOSE_PROJECT_NAME`?
- Does `docker compose config` validate without errors (after generating dynamic files)?
- Do `${VAR}` references in service files resolve from the root `.env`?
- Do cross-file `depends_on` references work?
- Do network aliases for mock domains appear on the caddy service?

---

## 7. Review the Tests

- `tests/contract/test-contract.sh` — Contract test suite
- `tests/contract/fixtures/` — Test payloads

**Assessment criteria:**
- Do all tests pass? (`bash tests/contract/test-contract.sh`)
- Is there coverage for: port collision, presets, wiring, frontend, product directory structure?
- Do generation tests verify the assembled product (not just exit codes)?
- Are edge cases covered? (empty selections, conflicting items, override validation)

---

## 8. Review the Documentation

- `README.md` — Project overview
- `docs/QUICKSTART.md` — Getting started
- `docs/ARCHITECTURE.md` — System architecture
- `docs/ARCHITECTURE-NEXT.md` — Factory/product design principles
- `docs/ADDING_SERVICES.md` — How to add new services
- `docs/CREATING_TEMPLATES.md` — How to create app/frontend templates
- `docs/DEVELOPMENT.md` — Developer guide
- `DEVSTRAP-POWERHOUSE-CONTRACT.md` — Contract specification

**Assessment criteria:**
- Does the documentation accurately describe the factory/product architecture?
- Are contributor guides actionable? (can someone follow them to add a new service?)
- Are all nginx references updated to Caddy?
- Does the catalog in README match what's in manifest.json?
- Is the contract changelog complete?

---

## 9. Overall Assessment

After reviewing all sections, provide:

1. **Architecture quality** — Is the factory/product separation clean? Are concerns properly divided?
2. **Implementation quality** — Is the code clean, consistent, and maintainable?
3. **Test coverage** — Are the tests sufficient? What's missing?
4. **Documentation quality** — Can a new developer understand and extend the system?
5. **Contract stability** — Is the PowerHouse interface stable and well-documented?
6. **Risk assessment** — What could break? What needs attention?
7. **Recommendations** — What should be done next? What's missing?

---

## Quick Reference

**Factory** (this repo): `devstack.sh` + `contract/manifest.json` + `templates/` + `product/`

**Product** (user's project): `devstack.sh` (lightweight) + `docker-compose.yml` (includes) + `services/` + `mocks/` + `app/` + `project.env`

**Catalog**: 5 backends, 1 frontend, 2 databases, 4 services, 6 tooling, 3 observability, 4 presets, 6 wiring rules
