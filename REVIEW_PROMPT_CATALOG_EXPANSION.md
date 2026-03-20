# Review Prompt: dev-strap Catalog Expansion

> **For**: A review team to analyse the end product of the catalog expansion initiative.
> **Context**: This review covers 6 phases of work implementing a major expansion to dev-strap's catalog, proxy layer, and developer experience.

---

## Instructions for Reviewers

You are reviewing a significant expansion to dev-strap — a meta-tool that generates Docker infrastructure for development environments. The work spans new services, languages, a proxy swap, frontend support, preset bundles, and auto-wiring.

Read the files in the order below. For each section, assess the quality of implementation against the criteria listed.

---

## 1. Understand the Starting Point

Read these first to understand what existed before the expansion:

- `docs/AI_BOOTSTRAP.md` — System architecture, file reading order, pitfalls
- `DEVSTRAP-POWERHOUSE-CONTRACT.md` — The contract interface with PowerHouse (orchestrator)

**Assessment criteria:**
- Is the architecture clearly documented?
- Is the contract specification complete and unambiguous?

---

## 2. Review the Research

The expansion was driven by field feedback and researched before implementation. Evaluate the research quality:

- `docs/dev-strap-catalog-proposals.md` — Original user proposals
- `docs/research/IMPLEMENTATION-PLAN.md` — Master plan with decision log
- `docs/research/01-new-services.md` — NATS, MinIO, Adminer, Swagger UI evaluation
- `docs/research/02-language-templates.md` — Python/FastAPI, Rust template design
- `docs/research/03-vite-multiapp-architecture.md` — Multi-app architecture options
- `docs/research/04-contract-evolution.md` — Contract changes, presets, auto-wiring
- `docs/research/05-stack-combinations.md` — Stack patterns, wiring maps, resource estimates
- `docs/research/06-dbeaver-cloudbeaver.md` — DBeaver evaluation (decided against)
- `docs/research/07-traefik-v3-evaluation.md` — Traefik v3 evaluation (rejected)
- `docs/research/08-caddy-deep-dive.md` — Caddy v2 capabilities research
- `docs/research/09-caddy-generator-design.md` — Caddy generator design
- `docs/research/10-integrated-caddy-vite-design.md` — Integrated Caddy + Vite design

**Assessment criteria:**
- Were alternatives properly evaluated before decisions were made?
- Are decision rationales clearly documented?
- Is the research actionable (did it lead to implementation, not just theory)?
- Were risks identified and mitigated?

---

## 3. Review the Contract (Manifest)

The contract is the interface between dev-strap and PowerHouse. Review it for completeness and consistency:

- `contract/manifest.json` — The full catalog definition

**Assessment criteria:**
- Are all categories, items, defaults, requires, and conflicts internally consistent?
- Do preset selections reference valid items?
- Do preset dependencies satisfy requires constraints (e.g., grafana needs prometheus)?
- Are wiring rules well-formed? Do `when` conditions reference valid categories?
- Is the port allocation collision-free in default configuration?
- Is backward compatibility maintained (version stays "1")?

---

## 4. Review the Generators

These are the core of dev-strap — they produce the infrastructure:

- `core/caddy/generate-caddyfile.sh` — Caddyfile generator (replaced nginx)
- `core/compose/generate.sh` — Docker Compose generator
- `core/certs/generate.sh` — Certificate generator

**Assessment criteria:**
- Does the Caddyfile generator handle all app types correctly? (HTTP proxy, PHP FastCGI, frontend routing)
- Is the mock interception flow preserved? (DNS alias → TLS termination → X-Original-Host → WireMock)
- Is the compose generator backward compatible? (existing projects without FRONTEND_TYPE work)
- Is the cert-gen script clean after JKS removal?
- Are variable substitutions complete? (no unreplaced `${VAR}` in output)
- Is the frontend section properly guarded? (only generated when FRONTEND_TYPE is set)

---

## 5. Review the Templates

Templates define individual services. Check consistency and quality:

**App templates** (backends):
- `templates/apps/node-express/` — Existing
- `templates/apps/go/` — Existing
- `templates/apps/php-laravel/` — Existing
- `templates/apps/python-fastapi/` — NEW: Dockerfile + service.yml
- `templates/apps/rust/` — NEW: Dockerfile + service.yml

**Frontend templates:**
- `templates/frontends/vite/` — NEW: Dockerfile + service.yml

**Service templates** (extras):
- `templates/extras/nats/` — NEW: service.yml + volumes.yml
- `templates/extras/minio/` — NEW: service.yml + volumes.yml
- `templates/extras/db-ui/` — NEW: service.yml
- `templates/extras/swagger-ui/` — NEW: service.yml

**Assessment criteria:**
- Do new templates follow the same patterns as existing ones? (indentation, variable usage, service naming)
- Are Dockerfiles well-structured? (layer caching, minimal images, appropriate base images)
- Are CA certificate handling patterns correct per language?
- Are named volumes properly prefixed with `${PROJECT_NAME}`?
- Do service.yml files use correct `depends_on` conditions?
- Is the frontend template's service named `frontend` (not `app`)?
- Do volume sidecar files (volumes.yml) have correct indentation?

---

## 6. Review the Bootstrap Pipeline

The bootstrap flow: PowerHouse sends selections → dev-strap validates → generates project:

- `devstack.sh` — Focus on:
  - `validate_bootstrap_payload()` — 11 validation checks including port collision
  - `resolve_wiring()` — Auto-wiring resolution
  - `generate_from_bootstrap()` — Project generation including frontend extraction
  - `build_bootstrap_response()` — Response with wiring results

**Assessment criteria:**
- Does port collision detection catch all cases? (defaults, overrides, multi-port items)
- Does wiring resolution handle wildcards correctly? (`app.*` matches any app item)
- Do user overrides take precedence over wiring?
- Is frontend extraction correct? (FRONTEND_TYPE, FRONTEND_SOURCE, FRONTEND_PORT in project.env)
- Is the frontend directory scaffolded properly? (Dockerfile copied, package.json created)
- Does the bootstrap response include resolved wiring?

---

## 7. Review the Tests

- `tests/contract/test-contract.sh` — 184 test assertions
- `tests/contract/fixtures/` — Test payloads

**Assessment criteria:**
- Is there test coverage for every new feature? (port collision, presets, wiring, frontend)
- Do test fixtures cover edge cases? (override-resolved conflicts, frontend-only, multi-service combos)
- Are error codes tested? (PORT_CONFLICT, MISSING_DEPENDENCY, etc.)
- Do generation tests verify the actual output? (Caddyfile content, compose content, project.env)

---

## 8. Review the Documentation

- `README.md` — Project overview
- `docs/QUICKSTART.md` — Getting started
- `docs/ARCHITECTURE.md` — System architecture
- `docs/ADDING_SERVICES.md` — How to add new services
- `docs/CREATING_TEMPLATES.md` — How to create app/frontend templates
- `docs/DEVELOPMENT.md` — Developer guide
- `DEVSTRAP-POWERHOUSE-CONTRACT.md` — Contract specification with changelog

**Assessment criteria:**
- Is the catalog accurately represented? (all 5 backends, frontend, 4 services, 6 tooling, 3 observability)
- Are contributor guides actionable? (can someone follow them to add a new service?)
- Are architectural decisions documented with rationale?
- Are all nginx references updated to Caddy?
- Is the contract changelog complete and accurate?

---

## 9. Overall Assessment

After reviewing all sections, provide:

1. **Architecture quality** — Is the system well-structured? Are concerns properly separated?
2. **Implementation quality** — Is the code clean, consistent, and maintainable?
3. **Test coverage** — Are the tests sufficient? What's missing?
4. **Documentation quality** — Can a new developer understand and extend the system?
5. **Contract stability** — Is the PowerHouse interface stable and well-documented?
6. **Risk assessment** — What could break? What needs attention?
7. **Recommendations** — What should be done next? What's missing?

---

## Quick Reference: What Changed

| Commit | Phase | Summary |
|--------|-------|---------|
| `4643faa` | 1-3 | Foundation (port collision, volumes), services (NATS, MinIO, Adminer, Swagger UI), languages (Python, Rust) |
| `9ea545a` | 4 | Preset bundles (4), auto-wiring rules (6), resolve_wiring() |
| `0c4efc4` | 5a | nginx → Caddy v2, cert-gen slimming |
| `d4dd7bc` | 5b | Vite frontend, path-based routing, frontend scaffolding |
