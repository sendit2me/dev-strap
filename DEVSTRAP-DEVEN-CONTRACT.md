# dev-strap ↔ deven Interaction Contract

> **THIS DOCUMENT IS NOT OWNED BY THIS REPOSITORY.**
>
> This contract is shared between [dev-strap](https://github.com/sendit2me/dev-strap)
> and [deven](https://github.com/sendit2me/deven). An identical copy should
> exist in both repositories. Neither team should edit this file unilaterally.
>
> Changes must be agreed with visibility into both systems and committed to
> both repositories simultaneously.
>
> **Contract version: 1 (DRAFT — bilateral mirror landed 2026-05-08)**

---

## Purpose

This document defines the interface between **deven** (the agentic
development system that turns briefs into product MVPs) and **dev-strap**
(the containerized development environment generator that produces the
infra layer beneath the MVP).

deven does not know how dev-strap builds environments.
dev-strap does not know how deven authors product code.
This contract is the only coupling between them.

The contract has two parts:

1. **Bootstrap-time** — the discover + bootstrap operations dev-strap
   exposes. These mirror the dev-strap ↔ PowerHouse contract v1
   (deven uses the same `--options` and `--bootstrap` flags).
2. **Runtime layer** — the files dev-strap delivers post-bootstrap and
   the conventions deven cycle prompts assume those files follow. This
   is **new** to the deven side and not covered by the PowerHouse
   contract.

---

## Principles

1. **dev-strap describes, deven consumes.** dev-strap publishes what
   it can provide via discover; deven cycles assume only what bootstrap
   actually delivers.
2. **No hardcoded knowledge.** Neither side assumes specific
   categories, presets, keys, or paths beyond what this contract
   names.
3. **Convention over configuration.** When a value is named here as
   canonical (e.g. `APP_SOURCE`, `PRISM_SPEC_PATH`, `mocks/<provider>/domains`),
   both sides MUST treat the convention as authoritative.
4. **Omission is meaningful.** A file dev-strap doesn't deliver is one
   deven cycles MUST author. The contract enumerates which side owns
   each.
5. **Fail loud.** Mismatches between what dev-strap delivers and what
   deven assumes MUST surface as gate failures or container build
   failures, not silent runtime drift.

---

## Operation 1: DISCOVER (bootstrap-time)

deven asks dev-strap what it can provide.

### Invocation

```bash
devstack.sh --options
```

### Response

Exit code `0`. JSON to stdout. Schema, field reference, and rules
are identical to the dev-strap ↔ PowerHouse contract Operation 1.
deven's `scripts/init-bootstrap.sh` invokes this and pipes through
`jq` to confirm the chosen preset is present in the catalog (rule:
abort if `agentic-dev` preset is missing).

deven uses ONLY the `agentic-dev` preset in v0.1. `nuxt-go` is the
deven-side preset name; it maps to dev-strap's `agentic-dev` via
`deven.stack.yaml`'s `infrastructure.dev_strap_preset` key.

---

## Operation 2: BOOTSTRAP (bootstrap-time)

deven sends a configured payload; dev-strap generates a project
directory.

### Invocation

```bash
devstack.sh --bootstrap --config <payload.json>
```

### Input payload

Same shape as the PowerHouse contract. `selections.app.go.overrides.port=8080`
is the only override deven sends in v0.1 (see `deven.stack.yaml`
`infrastructure.bootstrap_overrides`).

### Response

Same shape as the PowerHouse contract: `{ contract: "devstrap-result",
status: "ok", project_dir: "./<sanitized-name>", services: { ... },
commands: { ... } }`.

deven's `init-bootstrap.sh` rsyncs the contents of `${DEV_STRAP_DIR}/${project_dir}/`
into the deven instance directory (the cwd at `/deven:init` time).

---

## Runtime Layer Contract (post-bootstrap)

This section is what makes the deven contract different from the
PowerHouse one. Once dev-strap has bootstrapped, deven cycles assume
specific files are present at specific paths with specific
conventions. This is the bilateral interface that the wire-test
across cycles 1-3 stress-tested and surfaced gaps in.

### A. Directory layout

After bootstrap, the instance directory contains:

| Path | Owner | Notes |
|---|---|---|
| `project.env` | dev-strap | Component env vars: `PROJECT_NAME`, `APP_TYPE`, `APP_SOURCE`, `FRONTEND_SOURCE`, `DB_*`, port assignments. |
| `devstack.sh` | dev-strap | Product-shim runtime CLI. Generates Caddyfile, services/caddy.yml, services/wiremock.yml on `start`. |
| `docker-compose.yml` | dev-strap | Top-level compose with `include:` directives pulling `services/*.yml`. |
| `services/*.yml` | dev-strap | Per-service compose files: `app.yml`, `frontend.yml`, `database.yml`, `prism.yml`, `cert-gen.yml`, `tester.yml`, `test-dashboard.yml`. |
| `caddy/` | dev-strap (generated) | Caddyfile written by `devstack.sh start`. Empty until then. |
| `certs/generate.sh` | dev-strap | TLS cert-gen container's entrypoint. |
| `mocks/` | dev-strap (initial) → deven (per-cycle) | Initial: empty + an `example-api/` stub. Cycles populate `mocks/<provider>/{mappings,__files,domains}` per the discovered third-party set. |
| `app/` | dev-strap (initial scaffold) → deven (per-cycle) | Initial: stub Go scaffold with `main.go`, `go.mod`, `Dockerfile`, `.air.toml`, `init.sh`. **deven cycles relocate code to `backend/`** (see clause C below). |
| `frontend/` | dev-strap (initial scaffold) → deven (per-cycle) | Initial: minimal Nuxt scaffold with `package.json`, `nuxt.config.ts`, `app.vue`, `Dockerfile`. Cycles extend with pages, components, BFF routes, deps. |
| `backend/` | deven (per-cycle) | NOT delivered by dev-strap. deven cycles author the entire Go module here (cmd, internal, migrations, sqlc.yaml, oapi-codegen.yaml, openapi.yaml). |
| `briefs/` | deven (init) | Created by `init-scaffold.sh`. |
| `openspec/` | deven (init + per-cycle) | `specs/` and `changes/` subdirs. |
| `evidence/` | deven (per-cycle) | Gate output, integration evidence, lint evidence. |
| `reports/` | deven (per-cycle) | Re-aligner output. |

### B. `project.env` canonical keys

dev-strap's bootstrap output writes:

```ini
PROJECT_NAME=<sanitized>
COMPOSE_PROJECT_NAME=<sanitized>
NETWORK_SUBNET=172.28.0.0/24
APP_TYPE=go
APP_SOURCE=./app
APP_INIT_SCRIPT=./app/init.sh
FRONTEND_SOURCE=./frontend
HTTP_PORT=8080
HTTPS_PORT=8443
TEST_DASHBOARD_PORT=8082
DB_TYPE=postgres
DB_PORT=5432
DB_NAME=<sanitized>
DB_USER=<sanitized>
DB_PASSWORD=secret
DB_ROOT_PASSWORD=root
FRONTEND_TYPE=nuxt
FRONTEND_PORT=3000
FRONTEND_API_PREFIX=/api
PRISM_PORT=4010
PRISM_SPEC_PATH=openapi.yaml
```

**Required deven-side override** (cycles 1-3 confirmed the gap): the
`agentic-dev` preset's default `APP_SOURCE=./app` does not match
deven's convention of placing Go code at `backend/`. deven's
`init-scaffold.sh` MUST rewrite `APP_SOURCE=./backend` and
`APP_INIT_SCRIPT=./backend/init.sh` after rsync.

**Open contract gap**: dev-strap's `agentic-dev` preset SHOULD accept
this override at bootstrap time via the existing `selections.*.overrides`
mechanism. Today it doesn't — `init-scaffold` patches `project.env` after
the fact.

### C. Per-tier file ownership at the `app/` ↔ `backend/` seam

Because deven repurposes `${APP_SOURCE}` to `./backend`:

| File | dev-strap delivers (at `app/`) | deven keeps (at `backend/`) |
|---|---|---|
| `Dockerfile` | yes (Go scaffold) | yes — deven cycle prompt #7 authors the deven-canonical version (Go 1.25 alpine + air@latest, EXPOSE 8080 — see prompt template). The dev-strap one is left at `app/Dockerfile` and ignored once `APP_SOURCE` is retargeted. |
| `.air.toml` | yes (root entry point: `go build -o ./tmp/main .`) | yes — deven cycle prompt #7 authors a `.air.toml` whose `cmd` builds `./cmd/server` (deven manifest puts Go entry at `backend/cmd/server/main.go`). |
| `init.sh` | yes (placeholder) | yes — deven cycle prompt #7 authors a deven-canonical `init.sh` that runs goose migrations idempotently when `DATABASE_URL` is set. |
| `main.go` | yes (stub) | NO — deven uses `cmd/server/main.go` instead. The stub at `app/main.go` is harmless dead weight. |
| `go.mod` | yes (`module devstack-app`) | YES — deven cycle's own `backend/go.mod` with the real module path. The stub at `app/` is unused. |

**Cleanup recommendation**: dev-strap's `agentic-dev` preset SHOULD
accept an `app_source` override that, when set, suppresses the
`./app/*` scaffold entirely (since deven's `backend/` path
supersedes it). Currently those stub files sit unused.

### D. `frontend/Dockerfile` + `package.json` deps

deven cycle prompt #5 authors the canonical `frontend/Dockerfile`
(`--host 0.0.0.0` is non-negotiable — Caddy bridge network won't
reach localhost-only Nuxt). deven cycle prompts also extend
`frontend/package.json` with all imported deps (cycles 1-3 surfaced
that dev-strap's minimal `nuxt`-only scaffold is not enough — pinia,
@pinia/nuxt, orval, typescript, vue-tsc are all cycle-authored).

**Open contract clarification**: dev-strap's `package.json` baseline
should remain minimal — it doesn't know which Nuxt modules cycles
will use. deven cycle prompts (specifically #5) own dep maintenance
per import.

### E. `mocks/<provider>/` layout

Each third-party-mock provider directory MUST have:

```
mocks/<provider>/
├── domains              # one canonical hostname per line (DNS aliases + cert-gen)
├── mappings/            # WireMock JSON mappings; loaded read-only
└── __files/             # response body files referenced via bodyFileName
```

**dev-strap RESPONSIBILITIES:**

- Read `mocks/<provider>/domains` and add each line as a network
  alias on the `web` (Caddy) container.
- Append each domain to `domains.txt` for `cert-gen` so Caddy issues
  a TLS cert covering it.
- Mount `mocks/<provider>/mappings/` at `/home/wiremock/mappings/<provider>:ro`.
- Mount `mocks/<provider>/__files/` at `/home/wiremock/__files/<provider>:ro`.

**deven cycle RESPONSIBILITIES:**

- Author the per-provider `domains` file (cycle prompt #3).
- Author per-provider `mappings/*.json` (cycle prompt #3).
- Author per-provider `__files/*.json` for any mapping that uses
  `bodyFileName` (cycle prompt #3).

**Open contract gap (filed in deven issue #007 sub-7)**: dev-strap's
product-shim `devstack.sh` `generate_wiremock_service` only mounts
`mappings/`, not `__files/`. Mappings that reference body files
404 at WireMock until this is fixed dev-strap-side. The parent
`core/compose/generate.sh` mounts both correctly; the regression is
in the product shim.

### F. Caddy routing for FE+BFF model

The deven `nuxt-go` preset has Nuxt absorb both FE and BFF: `/api/*`
routes go to the **frontend container** (which holds Nuxt server
routes), and the BFF makes its own internal call to `app:3000` for
BE access.

dev-strap's product-shim Caddyfile generator currently emits:

```caddyfile
handle /api/* { reverse_proxy app:3000 }
```

This assumes the simpler "FE → BE direct" model. For deven's BFF
model the routing should be:

```caddyfile
handle /api/* { reverse_proxy frontend:3000 }
# (frontend container, running Nuxt, owns /api/* via server routes)
```

**Open contract gap (filed in deven issue #007 sub-5)**: dev-strap's
Caddyfile generator should detect "frontend type is FE+BFF" (e.g.,
`FRONTEND_TYPE=nuxt-bff` or a new project.env flag) and route
accordingly, OR provide a hook for deven to override the generator's
output. Today deven's runbook patches the Caddyfile after each
`devstack.sh start`, which is brittle.

### G. `devstack.sh` env sourcing

dev-strap's product-shim `devstack.sh load_config()` does
`source project.env` without `set -a`. Sourced vars stay in the
shell but aren't exported to subprocesses, so `docker compose`
sees them as unset.

**Open contract gap (filed in deven issue #007 sub-4)**:
`devstack.sh load_config` should wrap source with `set -a; source
...; set +a`. One-line dev-strap-side fix.

### H. BE database access

dev-strap's `services/app.yml` sets `DB_HOST`, `DB_PORT`, `DB_NAME`,
`DB_USER`, `DB_PASSWORD` as environment variables on the app
container. It does NOT set a single `DATABASE_URL`.

**deven cycle RESPONSIBILITY**: BE config code (`backend/internal/config`)
MUST read `DATABASE_URL` first and fall back to assembling it from
the components if absent. Cycle prompt #7 carries this rule (with
a worked example) so the BE survives whether dev-strap ships the
DSN or just the components.

Alternative: dev-strap could ship `DATABASE_URL` directly in
`services/app.yml`. Either side fulfilling this clause closes the
gap; today the deven side does it.

### I. `${PROJECT_NAME}.local` Caddy site

Caddy serves the application at:

- `https://localhost:${HTTPS_PORT}` (always)
- `https://${PROJECT_NAME}.local:${HTTPS_PORT}` (if user adds
  `127.0.0.1 ${PROJECT_NAME}.local` to `/etc/hosts`)

Per-mock provider hostnames (`stripe.deven.local`,
`api.stripe.com`, etc., from `mocks/<provider>/domains`) only
resolve **inside** the docker network — the `web` (Caddy) container
has them as network aliases. From the host, they're not routable.
Tests that need to hit these hostnames must run inside the
`tester` container (Playwright) or inside the BE/BFF containers.

---

## Open contract gaps (cross-repo backlog)

Filed under deven issue #007 sub-findings. Each is a dev-strap-side
change to align with this contract:

- **#007-sub-4**: `devstack.sh load_config` needs `set -a` wrap.
- **#007-sub-5**: Caddyfile generator needs to know about FE+BFF model.
- **#007-sub-7**: WireMock service.yml needs `__files/` mount.
- **(new)**: `agentic-dev` preset should accept an `app_source` override
  so deven doesn't have to patch `project.env` post-rsync.

These are all dev-strap-side fixes. Once landed, the corresponding
deven-side workarounds (in `init-scaffold.sh`, in cycle prompt
templates, in playground patches) can be retired.

---

## Versioning

Version 1 is the initial agreement. Both repositories should treat
all clauses above as locked at v1.

**Locked (do not change without a version bump):**

- The `--options` / `--bootstrap` operation contract (mirrors
  PowerHouse contract; same shape).
- The directory layout in clause A.
- The canonical key list in `project.env` (clause B).
- The `mocks/<provider>/{domains,mappings,__files}` layout (clause E).
- The runtime expectation that `mocks/<provider>/__files/` is
  mounted into WireMock (clause E).

**Flexible (can change without a version bump):**

- The exact command-line flags `devstack.sh` accepts beyond the
  contract operations.
- The wording of error messages.
- The order of generated services.
- The choice of base image (alpine vs slim, Nuxt 3 minor, Go minor).

---

## Changelog

### 2026-05-08 — v1 DRAFT (deven side only)

Initial authorship from the deven side, post cycles 1-3 wire-test.
Captures runtime layer clauses A-I that the wire-test surfaced.
Mirrors structure of dev-strap ↔ PowerHouse v1 for the bootstrap
ops; net-new for the runtime layer.

**Open**: not yet committed to dev-strap. Once mirrored,
remove the "DRAFT" tag and bump dev-strap-side `--options` response
to advertise contract version 1 for deven.
