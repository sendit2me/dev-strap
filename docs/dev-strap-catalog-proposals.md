# dev-strap Catalog Expansion Proposals

> **From**: Field usage during project bootstrapping (simply-test — Vue+Go+PostgreSQL stack)
> **Date**: 2026-03-20
> **Context**: First-hand experience hitting gaps while configuring a modern SPA + API + database project with full testing and mocking.

---

## Executive Summary

dev-strap's current catalog covers backend APIs and databases well, but has significant gaps for frontend development, modern messaging, storage, and developer tooling. The most impactful addition would be a **Vite frontend dev server** template — without it, every SPA project has to break out of the containerized model for its frontend.

Below are prioritized proposals for new templates, services, tooling, preset bundles, and infrastructure improvements.

---

## 1. New App Templates

### 1.1 Vite Frontend Dev Server — **HIGH PRIORITY**

The single biggest gap. Every modern SPA (React, Vue, Svelte, Angular) uses Vite. Without this, frontend developers run outside the container stack, fragmenting the dev experience.

| Field           | Value                                                                  |
| --------------- | ---------------------------------------------------------------------- |
| **Key**         | `vite`                                                                 |
| **Label**       | Frontend Dev Server (Vite)                                             |
| **Description** | Vite dev server with HMR, configurable API proxy to backend containers |
| **Category**    | `app`                                                                  |
| **Defaults**    | `port: 5173`, `proxy_target: ""`                                       |
| **Requires**    | None (can serve static sites standalone)                               |
| **Conflicts**   | None                                                                   |

**Implementation notes**:

- One generic template — Vite handles React/Vue/Svelte/Angular. The framework choice happens at `npm create vite@latest`, not at the container level.
- Mount `src/frontend/` (or configurable path) with watch mode.
- When a backend app is co-selected, auto-populate `proxy_target` with the backend's container hostname and port (e.g., `http://go:8080`). This eliminates the most common manual wiring step.
- WebSocket forwarding for HMR must work through the container network.

### 1.2 Python (FastAPI)

| Field           | Value                           |
| --------------- | ------------------------------- |
| **Key**         | `python-fastapi`                |
| **Label**       | Python (FastAPI)                |
| **Description** | FastAPI with uvicorn hot reload |
| **Category**    | `app`                           |
| **Defaults**    | `port: 8000`                    |
| **Requires**    | None                            |
| **Conflicts**   | None                            |

**Rationale**: Dominant in data, ML, and API development. FastAPI + uvicorn with `--reload` is the Python equivalent of Express or Go + Air.

### 1.3 Rust

| Field           | Value                             |
| --------------- | --------------------------------- |
| **Key**         | `rust`                            |
| **Label**       | Rust                              |
| **Description** | Rust with cargo-watch live reload |
| **Category**    | `app`                             |
| **Defaults**    | `port: 8080`                      |
| **Requires**    | None                              |
| **Conflicts**   | None                              |

**Rationale**: Growing adoption for API backends, CLI tools, and systems programming. Similar profile to the existing Go template.

---

## 2. New Services

### 2.1 NATS

| Field           | Value                                                                      |
| --------------- | -------------------------------------------------------------------------- |
| **Key**         | `nats`                                                                     |
| **Label**       | NATS                                                                       |
| **Description** | High-performance messaging — pub/sub, request/reply, streaming (JetStream) |
| **Category**    | `services`                                                                 |
| **Defaults**    | `client_port: 4222`, `monitor_port: 8222`                                  |
| **Requires**    | `app.*`                                                                    |
| **Conflicts**   | None                                                                       |

**Rationale**: NATS has been gaining significant traction over RabbitMQ for several reasons:

- Single binary, zero dependencies, sub-millisecond latency
- JetStream provides persistence/streaming without a separate system (replaces Kafka for many use cases)
- Built-in monitoring UI on the monitor port
- Native support in Go, Rust, Node, Python — aligns with all current and proposed app templates
- Much simpler operational model than RabbitMQ (no Erlang runtime, no management plugin)

### 2.2 MinIO (S3-Compatible Object Storage)

| Field           | Value                                              |
| --------------- | -------------------------------------------------- |
| **Key**         | `minio`                                            |
| **Label**       | MinIO                                              |
| **Description** | S3-compatible object storage for local development |
| **Category**    | `services`                                         |
| **Defaults**    | `api_port: 9000`, `console_port: 9001`             |
| **Requires**    | None                                               |
| **Conflicts**   | None                                               |

**Rationale**: Nearly every application eventually handles file uploads or blob storage. MinIO lets teams develop against the S3 API locally without AWS credentials or network dependency. Console UI included for browsing buckets during development.

**Note**: Default `api_port: 9000` conflicts with the current PHP (Laravel) default. If both are selected, one should auto-shift. See Section 5 (Port Allocation) for a broader solution.

---

## 3. New Tooling

### 3.1 Database UI (pgAdmin / Adminer)

| Field           | Value                                                                                 |
| --------------- | ------------------------------------------------------------------------------------- |
| **Key**         | `db-ui`                                                                               |
| **Label**       | Database UI                                                                           |
| **Description** | Web-based database browser and query tool (Adminer — supports PostgreSQL and MariaDB) |
| **Category**    | `tooling`                                                                             |
| **Defaults**    | `port: 8083`                                                                          |
| **Requires**    | `database.*`                                                                          |
| **Conflicts**   | None                                                                                  |

**Rationale**: When you select a database, you almost always want a UI for development — inspecting schema, running queries, checking data. Currently every developer installs one separately.

**Implementation note**: Adminer is recommended over pgAdmin because it supports both PostgreSQL and MariaDB with a single lightweight container, matching dev-strap's existing database options.

### 3.2 OpenAPI / Swagger UI

| Field           | Value                                            |
| --------------- | ------------------------------------------------ |
| **Key**         | `swagger-ui`                                     |
| **Label**       | API Documentation (Swagger UI)                   |
| **Description** | Live OpenAPI spec viewer against running backend |
| **Category**    | `tooling`                                        |
| **Defaults**    | `port: 8084`, `spec_path: "./openapi.yaml"`      |
| **Requires**    | `app.*`                                          |
| **Conflicts**   | None                                             |

**Rationale**: API-first development benefits enormously from a live Swagger UI that reflects the running backend. Useful for both developers and QA.

---

## 4. Preset Bundles

Rather than always walking categories item by item, offer preset bundles as a fast-start option in the `--options` contract. Users select a preset, then customize from there.

| Preset Key      | Label                          | Expands To                                                               | Target User                        |
| --------------- | ------------------------------ | ------------------------------------------------------------------------ | ---------------------------------- |
| `spa-api`       | **SPA + API**                  | Vite + one backend + PostgreSQL + QA + WireMock                          | Most common modern web app         |
| `api-only`      | **API Service**                | One backend + PostgreSQL + Redis + QA + Swagger UI                       | Microservice / headless API        |
| `full-stack`    | **Full Stack + Observability** | Vite + backend + PostgreSQL + Redis + QA + Prometheus + Grafana + Dozzle | Production-like dev environment    |
| `data-pipeline` | **Data Pipeline**              | Python (FastAPI) + PostgreSQL + NATS + MinIO                             | ETL / event processing / data work |

**Contract extension**: Add a top-level `presets` key to the `devstrap-options` response:

```json
{
  "presets": {
    "spa-api": {
      "label": "SPA + API",
      "description": "Frontend SPA with API backend, database, testing, and mocking",
      "selections": {
        "app": ["vite"],
        "database": ["postgres"],
        "tooling": ["qa", "wiremock"]
      },
      "prompts": ["app (pick one backend)"]
    }
  }
}
```

The `prompts` array lists categories where the user must still make a choice (e.g., which backend language). The orchestrator fills in preset selections first, then walks only the prompted categories.

---

## 5. Infrastructure Improvements

### 5.1 Port Allocation Strategy

As the catalog grows, port collisions become a real problem. We already hit Go vs Node.js both defaulting to 3000 during our session.

**Proposal**: Assign default port ranges by category:

| Category        | Range                | Rationale                                    |
| --------------- | -------------------- | -------------------------------------------- |
| App (backends)  | 3000–3999            | Convention for dev servers                   |
| App (frontends) | 5100–5199            | Vite defaults to 5173                        |
| Databases       | 5400–5499            | PostgreSQL is 5432, MariaDB 3306 (exception) |
| Services        | 4200–4299, 6300–6399 | NATS 4222, Redis 6379                        |
| Tooling         | 8000–8499            | WireMock, Swagger, DB UI, QA Dashboard       |
| Observability   | 9000–9999            | Prometheus, Grafana, Dozzle                  |

**Additionally**: Add collision detection to `--bootstrap`. When two selected items share a default port, return a validation error with both items named rather than silently generating a broken compose file.

### 5.2 Auto-Wiring Between Selections

When items are co-selected, certain configuration can be inferred:

| If selected together         | Auto-wire                                                    |
| ---------------------------- | ------------------------------------------------------------ |
| Vite + any backend app       | Set Vite's `proxy_target` to the backend's hostname:port     |
| Swagger UI + any backend app | Set `spec_url` to the backend's OpenAPI endpoint             |
| QA Container + any app       | Pre-configure QA's `BASE_URL` to point at the app under test |
| Grafana + Prometheus         | Pre-configure Grafana's datasource to Prometheus             |

This already happens for Grafana → Prometheus (via the `requires` dependency), but making it explicit for cross-category wiring would reduce post-bootstrap manual configuration.

### 5.3 Template Composability

App templates that support a `proxy_target` default (like the proposed Vite template) should have a way to express "fill this from a co-selected item's port." This could be a reference syntax in defaults:

```json
{
  "defaults": {
    "port": 5173,
    "proxy_target": { "$ref": "app.*.port", "template": "http://{key}:{value}" }
  }
}
```

This is a larger contract change, but it eliminates the single most common source of post-bootstrap configuration errors.

---

## 6. Dependency & Conflict Matrix for All Proposals

| Item                  | Requires     | Conflicts With |
| --------------------- | ------------ | -------------- |
| Vite (frontend)       | —            | —              |
| Python (FastAPI)      | —            | —              |
| Rust                  | —            | —              |
| NATS                  | `app.*`      | —              |
| MinIO                 | —            | —              |
| Database UI (Adminer) | `database.*` | —              |
| Swagger UI            | `app.*`      | —              |

No new conflicts introduced. All proposals are additive.

---

## Priority Ranking

| Priority | Item                          | Impact                                                 |
| -------- | ----------------------------- | ------------------------------------------------------ |
| 1        | **Vite frontend template**    | Unlocks every SPA project — currently the biggest gap  |
| 2        | **Port collision detection**  | Prevents broken compose files as catalog grows         |
| 3        | **Database UI**               | Near-universal need when a database is selected        |
| 4        | **NATS**                      | Modern messaging for event-driven architectures        |
| 5        | **Preset bundles**            | Faster onboarding, fewer questions for common patterns |
| 6        | **Python (FastAPI)**          | Expands language coverage to a major ecosystem         |
| 7        | **MinIO**                     | Common need, easy to implement                         |
| 8        | **Swagger UI**                | API development quality of life                        |
| 9        | **Rust**                      | Growing but still niche — lower urgency                |
| 10       | **Auto-wiring / $ref syntax** | High value but larger contract change — plan carefully |
