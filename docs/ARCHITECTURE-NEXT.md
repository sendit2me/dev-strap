# Architecture: Where We Are and Where We're Going

> **Note**: The architectural concepts from this document have been merged into `docs/ARCHITECTURE.md`. This file is preserved as historical context -- it captures the research journey and reasoning that led to the factory/product split.

> **Date**: 2026-03-20
> **Status**: Hard-earned thinking from a full day of research, implementation, and review.
> **Purpose**: This document captures WHY we're here, WHAT we learned, and WHERE we're going. Read this before doing any architectural work on dev-strap.

---

## The Journey So Far

### What we built (Phases 1-6, all committed and pushed)

We expanded dev-strap's catalog from 3 app templates + 2 extras to a full development platform:

- **5 backends**: Node/Express, Go, PHP/Laravel, Python/FastAPI, Rust
- **1 frontend**: Vite (path-based routing through Caddy)
- **2 databases**: PostgreSQL, MariaDB
- **4 services**: Redis, Mailpit, NATS, MinIO
- **6 tooling**: QA, QA Dashboard, WireMock, DevContainer, Adminer, Swagger UI
- **3 observability**: Prometheus, Grafana, Dozzle
- **4 preset bundles**: spa-api, api-only, full-stack, data-pipeline
- **6 auto-wiring rules**: Vite→backend, Redis URL, NATS URL, S3 endpoint, DB UI, Swagger spec
- **Port collision detection**: Validation check 11 in bootstrap pipeline
- **Caddy v2**: Replaced nginx — zero protocol branching

All v1-contract-compatible. 184 tests passing.

### What we tried to do next

We tried to split `devstack.sh` (1,688 lines) into modules. We designed a 10-module split, mapped all 29 functions, drew dependency graphs. It was clean engineering.

### Why we stopped

We were solving the wrong problem.

The complexity isn't in how functions are organized. It's in the fact that **two fundamentally different systems are tangled into one script**:

1. **The Factory** — presents options, takes selections, generates a project. This is a creation-time concern. Once the project exists, the factory is done.

2. **The Product** — starts, stops, tests, manages mocks. This is a runtime concern. It should be self-contained in the user's project folder.

Currently, `devstack.sh` is both. The product (user's project) reaches back to the factory (dev-strap repo) on every `./devstack.sh start` to regenerate everything from templates. This is why the script is 1,688 lines — it carries the entire catalog, all generators, all templates, at all times.

---

## The Insight: "What is where, and when?"

### The Two Lifecycles

```
FACTORY (dev-strap repo)                    PRODUCT (user's project)
────────────────────────                    ──────────────────────────
Lives in: github.com/sendit2me/dev-strap    Lives in: ~/projects/my-app/
When: before choices are made               When: after choices are made
Job: present options, generate project      Job: start, stop, test, develop

Contains:                                   Contains:
  contract/manifest.json                      docker-compose.yml
  templates/apps/*/                           services/app.yml
  templates/frontends/*/                      services/database.yml
  templates/extras/*/                         services/redis.yml (if chosen)
  templates/databases/*/                      services/caddy.yml
  core/caddy/generate-caddyfile.sh           Caddyfile
  core/compose/generate.sh                    project.env
  core/certs/generate.sh                      app/
  devstack.sh (full, with --options etc)      mocks/
                                              tests/
                                              devstack.sh (lightweight, runtime only)
```

The boundary between factory and product is the **bootstrap/init moment**. Everything before that is potential. Everything after is concrete.

### Why the current approach is wrong

Today, when a user bootstraps a project:
1. The factory generates `project.env` with their choices
2. The factory copies a Dockerfile and init.sh to `app/`
3. BUT — the product still depends on the factory at runtime:
   - `devstack.sh` reaches into `core/caddy/` to regenerate the Caddyfile
   - `devstack.sh` reaches into `core/compose/` to regenerate docker-compose.yml
   - `devstack.sh` reaches into `templates/` for service definitions
   - The entire catalog travels with the product

This means:
- The product isn't portable (needs the factory's directory structure)
- Unused templates ship with every project
- The script has conditional logic for things the user didn't choose
- Every `start` regenerates from scratch instead of using what's already configured
- Complexity grows with the catalog because the product carries all of it

### What the product should look like

```
my-app/
├── docker-compose.yml          ← includes from services/
├── services/
│   ├── app.yml                 ← Go backend (the specific one chosen)
│   ├── database.yml            ← PostgreSQL (the specific one chosen)
│   ├── redis.yml               ← present because it was chosen
│   ├── caddy.yml               ← reverse proxy config
│   ├── wiremock.yml            ← mock server
│   └── cert-gen.yml            ← certificate generation
├── caddy/
│   └── Caddyfile               ← generated from mocks/*/domains at start
├── certs/                      ← generated certificates
├── mocks/
│   ├── stripe/
│   │   ├── domains
│   │   └── mappings/*.json
│   └── sendgrid/
│       ├── domains
│       └── mappings/*.json
├── app/                        ← user's application code
│   ├── Dockerfile
│   └── src/
├── tests/
│   ├── playwright/*.spec.ts
│   └── results/
├── project.env                 ← shared environment variables
└── devstack.sh                 ← LIGHTWEIGHT: start/stop/test/logs/mocks only
```

Key differences from today:
- **`ls services/` tells you your stack** — same as `ls mocks/` tells you what's mocked
- **Docker Compose `include`** — root compose file just lists includes, no monolithic generation
- **No `core/`, no `templates/`, no `contract/`** — factory concerns stay in the factory
- **No `.generated/` directory** — files ARE the config, not derived from something else
- **No regeneration on start** — compose files are static. Only the Caddyfile needs regeneration (from `mocks/*/domains` for cert SANs and proxy blocks)
- **devstack.sh is tiny** — no catalog logic, no validation, no template substitution

### Docker Compose `include` makes this possible

```yaml
# docker-compose.yml (root)
include:
  - services/cert-gen.yml
  - services/app.yml
  - services/caddy.yml
  - services/database.yml
  - services/redis.yml
  - services/wiremock.yml
```

Each service file is self-contained:

```yaml
# services/redis.yml
services:
  redis:
    image: redis:7-alpine
    container_name: ${PROJECT_NAME}-redis
    networks:
      - ${PROJECT_NAME}-internal
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 5s
      timeout: 3s
      retries: 10
```

Variables like `${PROJECT_NAME}` are resolved from `project.env` via Docker Compose's native `env_file` or `.env` support. No sed, no envsubst, no generation.

**Adding a service** = dropping a YAML file in `services/` and adding an include line.
**Removing a service** = deleting the file and the include line.
**Understanding your stack** = `ls services/`.

---

## What the Factory's Job Becomes

The factory (dev-strap repo with `--options`/`--bootstrap`/`init`) does this:

1. **Discovery**: PowerHouse calls `--options`, gets the manifest
2. **Selection**: User picks their stack (or uses a preset)
3. **Assembly**: Factory copies the RIGHT files to the destination:
   - `services/app.yml` ← from `templates/apps/{chosen}/service.yml`
   - `services/database.yml` ← from `templates/databases/{chosen}/service.yml`
   - `services/redis.yml` ← from `templates/extras/redis/service.yml` (only if chosen)
   - `app/Dockerfile` ← from `templates/apps/{chosen}/Dockerfile`
   - `mocks/` ← scaffold with examples
   - `project.env` ← with chosen values
   - `docker-compose.yml` ← root include file listing the chosen services
   - `devstack.sh` ← the lightweight runtime script (always the same)
4. **Done**: Factory's job is complete. The product is self-contained.

Variable substitution happens ONCE, at assembly time. Not on every start.

---

## Open Questions for Research

### 1. Docker Compose `include` mechanics
- How do variables scope across included files? Does `env_file` in the root apply to all?
- Do networks defined in the root propagate to included services?
- Do volumes declared in included files merge into a global volumes section?
- Can included files reference each other's services in `depends_on`?
- What Docker Compose version is required? (v2.20+ for `include`)

### 2. The Caddyfile problem
The Caddyfile is the ONE thing that still needs generation at runtime, because:
- Mock domains come from `mocks/*/domains` (filesystem-driven)
- The Caddyfile needs a site block for each mock domain
- Cert SANs need to match mock domains
- Adding a new mock = regenerating the Caddyfile

Options:
- **A**: Lightweight generator in the product (reads `mocks/*/domains`, writes Caddyfile)
- **B**: Caddy's built-in file watcher (can it reload when mocks change?)
- **C**: Static Caddyfile with wildcard matching (is this possible?)

### 3. Cert generation in the product
Currently cert-gen is a one-shot container that generates certs from `domains.txt`. In the product:
- Where does `domains.txt` come from? (derived from `mocks/*/domains` at start time)
- The cert-gen container stays — it's a runtime concern
- But it only needs `openssl`, not the full factory

### 4. How lightweight can devstack.sh be?
In the product, devstack.sh needs to:
- Start/stop the stack (`docker compose up/down`)
- Run tests (`docker compose exec tester ...`)
- Show logs/status (`docker compose logs/ps`)
- Manage mocks (new-mock, reload, record, apply-recording, verify)
- Regenerate Caddyfile when mock domains change
- Regenerate certs when mock domains change

It does NOT need to:
- Know about the catalog
- Parse --options/--bootstrap
- Validate bootstrap payloads
- Resolve wiring rules
- Generate docker-compose.yml (it's static)
- Substitute template variables (done once by the factory)

Estimate: ~300-400 lines (down from 1,688).

### 5. What about the Caddyfile generator?
The product needs a small Caddyfile generator that reads:
- `project.env` (app type, ports)
- `services/` (what services exist)
- `mocks/*/domains` (what to intercept)

And produces a Caddyfile. This is simpler than the current generator because:
- No template substitution (values are already resolved)
- No conditionals for unused services (they're not in `services/`)
- The app type is known (just read `services/app.yml` to determine PHP vs HTTP)

### 6. Does the mock DNS approach work with compose include?
Network aliases are set on the caddy service. In the current system, the compose generator builds alias entries from `mocks/*/domains`. With compose include:
- Can the caddy service in `services/caddy.yml` have dynamic aliases?
- Or does the root compose need to specify them?
- Or does a small startup script generate the caddy service's network config?

---

## Outstanding Issues (from reviews)

These bugs/issues were found during three code reviews. Some may dissolve in the new architecture. Some won't. They're tracked here so nothing falls through the cracks.

### Group A: Bugs (must verify after architecture change)

| # | Issue | Current file | May dissolve? | Why |
|---|-------|-------------|---------------|-----|
| A1 | `handle_path` strips /api prefix | `core/caddy/generate-caddyfile.sh` | **FIXED** | Changed to `handle` |
| A2 | `--preset` documented but not implemented | `devstack.sh` cmd_init | Partially | `init` stays in the factory; but product's docs might still reference it |
| A3 | Python Dockerfile missing gcc/libpq-dev | `templates/apps/python-fastapi/Dockerfile` | **No** | Template file, ships to product as-is |
| A4 | PHP-Laravel hardcodes DB_CONNECTION=mysql | `templates/apps/php-laravel/service.yml` | **No** | Template file, ships to product. Factory must set the right value at assembly. |
| A5 | EXTRAS_DEPENDS dead code | `core/compose/generate.sh` | **Yes** | Compose generator goes away. Individual service YAMLs handle their own deps. |
| A6 | Example app index.js says "nginx" | `app/src/index.js` | **No** | App code, not architecture |

### Group B: Robustness (must verify)

| # | Issue | May dissolve? | Why |
|---|-------|---------------|-----|
| B1 | No app healthchecks | **No** | Still need healthchecks in service YAMLs |
| B2 | init only lists 3 app types | Partially | Factory concern, but still needs fixing |
| B3 | Port collision internal vs host | Partially | Factory validates at assembly time, but the distinction still matters |
| B4 | Wiring keys not in defaults | Partially | Wiring is a factory concern; may be simpler with static compose files |
| B5 | NATS/MinIO port overrides ignored | Partially | Factory concern, needs fixing in assembly logic |
| B6 | No db-ui guard when DB_TYPE=none | **Yes** | If db-ui isn't selected, it's not in services/ |
| B7 | Swagger UI mounts nonexistent file | **No** | File still needs to exist or mount needs to be conditional |
| B8 | FRONTEND_SOURCE no default | Partially | Factory sets it at assembly time |

### Group C: Documentation (do LAST)

All documentation should be rewritten AFTER the architecture settles. Updating docs now would be wasted effort.

### Group D: Architecture (subsumed by the factory/product split)

| # | Issue | Status |
|---|-------|--------|
| D1 | Non-destructive restart | **Still relevant** — product's devstack.sh needs this |
| D2 | Cert domain change detection | **Still relevant** — product's cert-gen needs this |
| D3 | Split devstack.sh | **Subsumed** — the split is now factory vs product, not modular within one script |
| D4 | Replace sed with envsubst | **Partially subsumed** — factory does one-time substitution; product doesn't substitute at all |
| D5 | project.env validation | **Still relevant** — product's devstack.sh should validate on start |
| D6 | Clean recordings on stop | **Still relevant** — product concern |

---

## Principles We Learned

These came from hitting walls and stepping back. They should guide the next phase.

### 1. "What is where, and when?"
Every file, every function, every variable — ask which lifecycle it belongs to. Factory or product? Creation-time or runtime? If it's factory, it doesn't ship with the product.

### 2. "We shouldn't fight the system, we should work with it"
Docker Compose has `include`. Use it. Mocks are filesystem-driven. Services should be too. Don't build custom machinery when the platform already provides the mechanism.

### 3. "When things get too complicated, we're probably overcomplicating it"
17 sed commands, 10 proposed modules, growing if/else chains — these are symptoms of solving the wrong problem. Step back for a third-person perspective. The complexity was in GENERATING infrastructure that should just BE infrastructure.

### 4. "Research before building"
Every major decision in this project was researched first. The Caddy swap came from questioning assumptions about nginx. The factory/product split came from questioning assumptions about the module split. The cost of research is low. The cost of building the wrong thing is high.

### 5. "Knowledge hard-earned should be treasured"
Document why, not just what. Future sessions need to understand the reasoning, not just the code. This document exists because we learned things the hard way and don't want to relearn them.

---

## Next Steps

1. **Research Docker Compose `include`** — answer the 6 open questions above
2. **Design the factory's assembly output** — exact files, exact content, exact substitution
3. **Design the product's devstack.sh** — what commands, how lightweight
4. **Prototype** — build a minimal factory→product flow for one stack (e.g., Go + PostgreSQL + Redis)
5. **Validate** — do all 184 tests still pass concept? What changes?
6. **Execute** — implement the factory/product split
7. **Fix remaining bugs** — the ones that didn't dissolve
8. **Documentation** — one final pass, everything stable
