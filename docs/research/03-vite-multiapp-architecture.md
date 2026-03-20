# Research: Vite Frontend Support and Multi-App Architecture

> **Date**: 2026-03-20
> **Context**: dev-strap currently assumes one app service named `app`. Adding Vite means supporting a frontend AND a backend simultaneously. This document researches the problem space and recommends a concrete design.

---

## Table of Contents

1. [Vite in Docker](#1-vite-in-docker)
2. [Multi-App Architecture Options](#2-multi-app-architecture-options)
3. [Nginx Routing for Multi-App](#3-nginx-routing-for-multi-app)
4. [Auto-Wiring Between Frontend and Backend](#4-auto-wiring-between-frontend-and-backend)
5. [Common Multi-App Combinations](#5-common-multi-app-combinations)
6. [Impact on Existing Systems](#6-impact-on-existing-systems)
7. [Recommendation](#7-recommendation)
8. [Detailed Design for Recommended Approach](#8-detailed-design-for-recommended-approach)

---

## 1. Vite in Docker

### 1.1 How Vite HMR Works Through Docker

Vite's Hot Module Replacement relies on a WebSocket connection between the browser and the Vite dev server. In a Docker environment, this creates specific challenges:

**The WebSocket path**: Vite opens a WebSocket on `ws://hostname:port/` (or `wss://` for HTTPS). The browser must be able to reach the Vite dev server's WebSocket endpoint. When Vite runs inside Docker but the browser runs on the host, the WebSocket connection URL must resolve to something the host browser can reach.

**File watching**: Docker volume mounts use filesystem events to detect changes. On Linux (native Docker), `inotify` events propagate correctly from the host into the container. On macOS and Windows (Docker Desktop with a VM layer), filesystem events are unreliable or absent because the file changes happen in the host OS but the container watches from inside the VM.

**The polling fallback**: When `inotify` events do not propagate (macOS/Windows), Vite must poll the filesystem instead. This is controlled by Vite's `server.watch.usePolling` option (which passes through to chokidar). The environment variable `CHOKIDAR_USEPOLLING=true` is a legacy mechanism from older tooling (Create React App, webpack); Vite's own configuration is the correct lever.

### 1.2 Required Configuration

**vite.config.ts (inside the user's project)**:

```typescript
export default defineConfig({
  server: {
    host: '0.0.0.0',       // Listen on all interfaces (required for Docker)
    port: 5173,
    strictPort: true,
    watch: {
      usePolling: true,     // Fallback for macOS/Windows Docker Desktop
      interval: 300,        // Polling interval in ms (lower = faster, more CPU)
    },
    hmr: {
      // When proxied through nginx, Vite needs to know the external port
      // so the WebSocket URL in the browser resolves correctly.
      // If exposed directly: clientPort matches the host-mapped port.
      // If proxied through nginx: clientPort matches the nginx HTTPS port.
    },
  },
});
```

**Environment variables for the container**:

| Variable | Purpose | Example |
|----------|---------|---------|
| `CHOKIDAR_USEPOLLING` | Legacy polling toggle (some tools still read this) | `true` |
| `VITE_HMR_HOST` | Not a real Vite env var; use `server.hmr.host` in config | - |

The `CHOKIDAR_USEPOLLING` variable is a convenience for tools that use chokidar directly. Vite uses chokidar internally but reads its own config (`server.watch.usePolling`) rather than this environment variable. However, setting it does no harm and helps if other tools in the same container also watch files.

### 1.3 Volume Mounting Strategy

The user's frontend source code must be bind-mounted into the container for live editing:

```yaml
volumes:
  - ${FRONTEND_SOURCE}:/app          # Source code (read-write)
  - /app/node_modules                # Anonymous volume: isolates node_modules
```

The anonymous volume for `node_modules` is critical. Without it, `npm install` inside the container writes `node_modules` to the bind mount, which:

1. Overwrites any host `node_modules` (which may have different platform-specific binaries)
2. Creates root-owned files on the host
3. Causes performance problems on macOS/Windows (thousands of small files over the VM mount)

The existing `node-express` template already uses this pattern (`- /app/node_modules`). The Vite template should follow the same convention.

### 1.4 Port Strategy: Direct Exposure vs Nginx Proxy

**Option: Expose port 5173 directly**

```yaml
ports:
  - "5173:5173"
```

Pros:
- Simplest possible configuration
- HMR WebSocket works without any special configuration
- No nginx routing complexity
- Browser connects directly to Vite; lowest latency

Cons:
- One more port to manage
- HTTPS mock interception does not apply to the frontend (no TLS termination through nginx)
- Frontend and backend are on separate origins (CORS issues if the frontend fetches from the backend directly)

**Option: Proxy through nginx**

```
Browser -> nginx:443 -> vite:5173 (for frontend routes)
Browser -> nginx:443 -> app:3000  (for /api/* routes)
```

Pros:
- Single entry point (one port for everything)
- Same-origin: no CORS between frontend and backend
- TLS termination works for both frontend and backend
- More production-like (production usually has one entry point)

Cons:
- WebSocket forwarding for HMR requires nginx configuration
- Added latency (extra hop)
- More complex nginx config
- If nginx has a bug, it breaks both frontend and backend

**Recommendation: Direct exposure with optional nginx proxy**

For development, direct exposure is simpler and more reliable. The Vite dev server already handles its own CORS and WebSocket. The user's `vite.config.ts` can use `server.proxy` to forward `/api` requests to the backend container. This is the standard Vite development pattern and does not require nginx involvement at all.

The nginx proxy approach is valuable for production-like testing but is unnecessary complexity for the default dev experience. If a user wants it, they can configure it, but the default should be direct exposure.

### 1.5 Framework Agnosticism

Vite is the build tool, not the framework. A single Vite template handles:

- React (`npm create vite@latest -- --template react-ts`)
- Vue (`npm create vite@latest -- --template vue-ts`)
- Svelte (`npm create vite@latest -- --template svelte-ts`)
- Angular (uses Vite as of Angular 17+ via `@angular/cli`)
- Vanilla JS/TS
- Solid, Preact, Lit, Qwik, etc.

The Dockerfile and service.yml are identical regardless of framework. The framework choice happens when the user scaffolds their project, not when dev-strap generates the container.

### 1.6 Draft Dockerfile

```dockerfile
FROM node:22-alpine

WORKDIR /app

# Install dependencies first (layer caching)
COPY package*.json ./
RUN npm install

# Copy source
COPY . .

# Vite dev server
EXPOSE 5173

# Default: vite dev server with host binding for Docker
CMD ["npx", "vite", "--host", "0.0.0.0"]
```

Notes:
- `node:22-alpine` matches the existing node-express template
- `--host 0.0.0.0` is required for Docker (Vite defaults to localhost which is unreachable from outside the container)
- No `CHOKIDAR_USEPOLLING` in the Dockerfile; it belongs in the service.yml environment section where it can be toggled per-platform

### 1.7 Draft service.yml

```yaml
  frontend:
    build:
      context: ${FRONTEND_SOURCE}
      dockerfile: Dockerfile
    container_name: ${PROJECT_NAME}-frontend
    ports:
      - "${FRONTEND_PORT}:5173"
    volumes:
      - ${FRONTEND_SOURCE}:/app
      - /app/node_modules
      - ${PROJECT_NAME}-certs:/certs:ro
    working_dir: /app
    environment:
      - NODE_ENV=development
      - CHOKIDAR_USEPOLLING=true
      - NODE_EXTRA_CA_CERTS=/certs/ca.crt
    depends_on:
      cert-gen:
        condition: service_completed_successfully
    networks:
      - ${PROJECT_NAME}-internal
```

Key differences from the `node-express` template:
- Service name is `frontend`, not `app`
- Port is 5173, not 3000
- Exposes port directly to host via `${FRONTEND_PORT}`
- `CHOKIDAR_USEPOLLING=true` for cross-platform file watching
- No database environment variables (frontend does not talk to DB directly)

---

## 2. Multi-App Architecture Options

The fundamental challenge: dev-strap's generators, nginx config, project.env, and CLI all assume exactly one service named `app`. Adding a frontend means either changing this assumption or working around it.

### 2.1 Option A: Frontend as a Separate Category

Add a new `frontend` category to the manifest alongside `app`.

**Manifest change**:

```json
{
  "categories": {
    "app": { ... },
    "frontend": {
      "label": "Frontend",
      "description": "Frontend development server",
      "selection": "single",
      "required": false,
      "items": {
        "vite": {
          "label": "Vite Dev Server",
          "description": "Vite with HMR for React/Vue/Svelte/Angular",
          "defaults": { "port": 5173, "proxy_target": "" }
        }
      }
    },
    "database": { ... }
  }
}
```

**project.env change**:

```env
APP_TYPE=go
FRONTEND_TYPE=vite
FRONTEND_SOURCE=./frontend
FRONTEND_PORT=5173
```

**Generator changes**:
- `core/compose/generate.sh`: Add a new section that reads `FRONTEND_TYPE`, loads `templates/frontends/vite/service.yml`, performs variable substitution
- `core/nginx/generate-conf.sh`: Detect if `FRONTEND_TYPE` is set; if so, route `/` to frontend and `/api` to backend; if not, route everything to `app` (backward compatible)
- `devstack.sh`: `generate_from_bootstrap()` extracts `frontend` category from payload, maps to `FRONTEND_TYPE`

**Pros**:
- Clean semantic separation: "frontend" is a fundamentally different thing from "backend"
- `selection: single` makes sense (you have one frontend framework)
- Cannot accidentally select two frontends
- Backward compatible: if `frontend` category is absent from selections, nothing changes
- Easy for PowerHouse to present: separate section in the UI

**Cons**:
- New category in the contract (but the contract explicitly says categories are flexible and do not require a version bump)
- New template directory (`templates/frontends/`) rather than reusing `templates/apps/`
- Two separate code paths in generators for "app" and "frontend"
- If someone wants Vite standalone (no backend), the `app` category is still required in the current manifest

### 2.2 Option B: Frontend as a Special App Type

Vite is another item in the existing `app` category. When both Vite and a backend are selected, the compose generator detects the multi-app scenario and generates two services.

**Manifest change**:

```json
{
  "app": {
    "selection": "multi",
    "items": {
      "node-express": { "defaults": { "port": 3000 } },
      "go": { "defaults": { "port": 3000 } },
      "vite": { "defaults": { "port": 5173, "proxy_target": "" } }
    }
  }
}
```

**Generator changes**:
- The compose generator detects when `vite` is one of the selected apps
- If Vite is present alongside another app: Vite becomes service `frontend`, the other becomes service `app`
- If Vite is the only app: it becomes service `app` (or `frontend` -- this ambiguity is a problem)
- Nginx generator detects whether a `frontend` service exists in the compose

**Pros**:
- No new categories; stays within existing contract structure
- `app` category already has `selection: multi`, so multiple selections are supported
- Vite items live in `templates/apps/vite/` like all other app templates

**Cons**:
- The `app` category now contains two fundamentally different types of thing (frontend dev servers vs backend servers)
- Special-casing in the generator: "if the app is named `vite`, use service name `frontend` instead of `app`" -- this is fragile
- What happens when someone selects two backends? Currently the manifest says `selection: multi` but the generator only handles one. This is already a latent bug that Option B would expose.
- The mapping from "which item is `app` and which is `frontend`" is implicit and fragile
- Naming conventions become confusing: is `vite` an "app"?

### 2.3 Option C: Frontend as Tooling

Vite goes in the `tooling` category, similar to how `wiremock` and `qa` are tooling.

**Manifest change**:

```json
{
  "tooling": {
    "items": {
      "vite": {
        "label": "Frontend Dev Server",
        "description": "Vite dev server that proxies API calls to the app container",
        "defaults": { "port": 5173 },
        "requires": ["app.*"]
      }
    }
  }
}
```

**Generator changes**:
- Vite would be generated like other extras/tooling: read from `templates/extras/vite/service.yml` or `templates/tooling/vite/service.yml`
- No changes to the `app` service generation
- Nginx unchanged (Vite is exposed directly on its own port)

**Pros**:
- Simplest implementation: Vite is "just another container" alongside Redis, Mailpit, etc.
- No changes to the app service architecture
- `requires: ["app.*"]` makes the dependency explicit
- Template goes in `templates/extras/` which already has a well-understood pattern

**Cons**:
- Semantically wrong: Vite is not "tooling." It is a primary part of the application that developers interact with constantly.
- `requires: ["app.*"]` means you cannot use Vite standalone (e.g., for a static site or SPA with a third-party API). This is a real use case.
- The user's source code mount needs a different path (`FRONTEND_SOURCE` vs `APP_SOURCE`), which extras do not currently support -- all extras use the same simple variable substitution
- Extras are treated as optional addons, but for an SPA project the frontend is THE application
- Confusing for users: "to add my frontend, I go to the tooling section?"

### 2.4 Option D: Composable Service Naming

Each app category item defines its own service name. Vite generates `frontend`, Node generates `app`, Go generates `app`.

**Manifest change**:

```json
{
  "app": {
    "items": {
      "vite": {
        "defaults": { "port": 5173, "service_name": "frontend" }
      },
      "node-express": {
        "defaults": { "port": 3000, "service_name": "app" }
      }
    }
  }
}
```

**Generator changes**:
- The compose generator reads `service_name` from the item's defaults
- Templates use `${SERVICE_NAME}` instead of hardcoding `app:`
- Nginx detects which services exist and routes accordingly

**Pros**:
- Flexible: any future template can define its own service name
- No new categories needed
- Works naturally with multi-select in the `app` category

**Cons**:
- Breaks every existing template (service name changes from hardcoded `app` to `${SERVICE_NAME}`)
- The nginx generator must dynamically discover what services exist and how to route
- The `web` service in compose currently hardcodes `depends_on: app:` -- must become dynamic
- `devstack.sh` hardcodes `app` in many places (shell, logs, init script execution)
- Most complex implementation of all four options
- `service_name` as a "default" that the user could theoretically "override" is dangerous -- changing service names breaks inter-service references

### 2.5 Analysis Matrix

| Criterion | A (Separate Category) | B (Special App Type) | C (Tooling) | D (Composable Names) |
|-----------|----------------------|---------------------|-------------|---------------------|
| Semantic clarity | Excellent | Poor | Poor | Good |
| Backward compatibility | Full | Partial | Full | Breaking |
| Implementation complexity | Medium | Medium-high | Low | Very high |
| Standalone frontend | Possible (make app not-required, or add exception) | Awkward | Impossible | Possible |
| Contract impact | None (categories are flexible) | None | None | Medium (new variable) |
| Generator changes | Medium | High (special-casing) | Low | Very high |
| User comprehension | Clear | Confusing | Confusing | Clear |
| Future extensibility | Good (new frontends added to category) | Poor (more special cases) | Poor | Excellent |

---

## 3. Nginx Routing for Multi-App

### 3.1 Path-Based Routing

The most common pattern for SPA + API:

```nginx
# Frontend (SPA)
location / {
    proxy_pass http://frontend:5173;
    # WebSocket for HMR
    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection "upgrade";
}

# Backend API
location /api/ {
    proxy_pass http://app:3000;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
}
```

**The path prefix problem**: This assumes the backend API is mounted at `/api/`. Some backends use `/api/v1/`, others use `/graphql`, others have no prefix at all. Making this configurable adds complexity.

**Interaction with mock interception**: Mock interception is based on DNS (the domain name resolves to nginx). Path-based routing and mock interception are orthogonal -- they operate on different server blocks (mocked domains vs `localhost`/`project.local`). No conflict.

### 3.2 Separate Ports

Simpler alternative: frontend and backend each get their own host-mapped port.

```
http://localhost:5173  -> frontend (Vite direct)
http://localhost:8080  -> backend (nginx -> app:3000)
```

The frontend uses Vite's built-in `server.proxy` to forward API requests:

```typescript
// vite.config.ts
export default defineConfig({
  server: {
    proxy: {
      '/api': {
        target: 'http://app:3000',  // Docker service name
        changeOrigin: true,
      },
    },
  },
});
```

This is the standard Vite development pattern and avoids all nginx routing complexity for the frontend.

**Interaction with mock interception**: The Vite container, like the `app` container, is on the same Docker network. If the Vite container (or more precisely, the app running inside it) needs to make server-side requests to mocked APIs, it would go through the same DNS interception path. However, Vite's proxy runs inside the Vite container -- it forwards browser requests to the backend. The browser itself is on the host, not in Docker, so browser-originated requests to mocked domains would NOT be intercepted. This is correct behavior: the browser should not be hitting mocked APIs directly; only the backend should.

### 3.3 How Other Tools Handle This

**Traefik pattern**: Traefik uses labels on Docker containers to configure routing dynamically. Each service declares its own routing rules:

```yaml
labels:
  - "traefik.http.routers.frontend.rule=PathPrefix(`/`)"
  - "traefik.http.routers.api.rule=PathPrefix(`/api`)"
```

This is overkill for dev-strap's use case. Traefik solves dynamic service discovery in production; dev-strap generates static configuration.

**docker-compose + nginx pattern**: The most common community pattern is exactly what dev-strap already does: nginx as a reverse proxy, configured statically. For multi-service, the pattern is two upstream blocks and path-based location blocks.

**Recommendation for dev-strap**: Separate ports with Vite's built-in proxy is the best default. It requires zero nginx changes for the common case and matches how Vite developers already work. The nginx proxy-all-through-one-port approach can be documented as an advanced option.

---

## 4. Auto-Wiring Between Frontend and Backend

### 4.1 The Wiring Problem

When a user selects Vite + Go + PostgreSQL, these connections need to be established:

```
Vite (frontend) --proxy /api--> Go (backend) --db connection--> PostgreSQL
```

Currently, the Go template's service.yml hardcodes `DB_HOST=db` because the database service is always named `db`. The same approach can work for frontend-to-backend wiring: the backend service is always named `app`, so the frontend can always proxy to `http://app:3000`.

### 4.2 Vite Proxy Configuration

The user's `vite.config.ts` controls the proxy. Dev-strap does not generate this file (it is application code, not infrastructure). However, dev-strap can:

1. **Document the convention**: In the generated project, include a comment or example config showing the proxy setup
2. **Set environment variables**: Provide `VITE_API_URL=http://app:3000` so the user can reference it in their Vite config

The Vite container's service.yml should include:

```yaml
environment:
  - VITE_API_URL=http://app:${BACKEND_PORT}
```

Where `${BACKEND_PORT}` is derived from the co-selected backend's defaults (3000 for Node/Go, 9000 for PHP).

### 4.3 Environment Variable Injection

Vite exposes environment variables prefixed with `VITE_` to client-side code. This is a Vite convention, not a Docker one. Setting `VITE_API_URL` in the Docker environment makes it available in the Vite dev server process, and Vite passes it through to the browser bundle via `import.meta.env.VITE_API_URL`.

However, for the `server.proxy` configuration in `vite.config.ts`, the proxy target is read at server start time (Node.js), not at browser runtime. So `process.env.VITE_API_URL` (available in Node.js via the Docker environment) is the correct mechanism:

```typescript
export default defineConfig({
  server: {
    proxy: {
      '/api': {
        target: process.env.VITE_API_URL || 'http://app:3000',
        changeOrigin: true,
      },
    },
  },
});
```

### 4.4 Draft $ref Syntax for Auto-Wiring

The proposal doc suggests a `$ref` syntax in manifest defaults:

```json
{
  "defaults": {
    "port": 5173,
    "proxy_target": { "$ref": "app.*.port", "template": "http://{key}:{value}" }
  }
}
```

This is a v2 contract change. For v1, a simpler approach works: the `generate_from_bootstrap()` function in `devstack.sh` already has access to all selections. It can compute the proxy target programmatically:

```bash
# In generate_from_bootstrap():
if [ "${frontend_type}" != "none" ] && [ "${app_type}" != "none" ]; then
    # Auto-wire: frontend proxies to backend
    backend_port=$(printf '%s\n' "${payload}" | jq -r \
        ".selections.app.\"${app_type}\".overrides.port //
         \$m[0].categories.app.items.\"${app_type}\".defaults.port // 3000" \
        --slurpfile m "${manifest_file}")
    PROXY_TARGET="http://app:${backend_port}"
fi
```

This is simpler than a contract-level `$ref` syntax and handles the 90% case. The `$ref` syntax can be added later when more complex wiring scenarios emerge.

---

## 5. Common Multi-App Combinations

### 5.1 Vite + Go API + PostgreSQL

```
Browser -> localhost:5173 -> Vite container (HMR, static assets)
                |
                +-- /api proxy -> Go container:3000 -> PostgreSQL container:5432
```

Wiring needed:
- Vite service.yml: `VITE_API_URL=http://app:3000`
- Go service.yml: `DB_HOST=db`, `DB_PORT=5432` (already handled)
- User's vite.config.ts: `server.proxy = { '/api': process.env.VITE_API_URL }`

### 5.2 Vite + Node/Express + PostgreSQL

```
Browser -> localhost:5173 -> Vite container
                |
                +-- /api proxy -> Node container:3000 -> PostgreSQL:5432
```

Identical wiring to Go. The backend port is the same (3000). The only difference is the backend Dockerfile and service.yml template.

### 5.3 Vite + Python/FastAPI + PostgreSQL

```
Browser -> localhost:5173 -> Vite container
                |
                +-- /api proxy -> FastAPI container:8000 -> PostgreSQL:5432
```

Different backend port (8000 vs 3000). This is why `VITE_API_URL` should use the backend's port from the manifest defaults, not hardcode 3000.

### 5.4 Vite + Any Backend + Redis + NATS (Event-Driven)

```
Browser -> localhost:5173 -> Vite container
                |
                +-- /api proxy -> Backend:3000 -> PostgreSQL
                                      |
                                      +-> Redis (cache/sessions)
                                      +-> NATS (pub/sub messaging)
```

No additional wiring for the frontend. Redis and NATS are backend concerns. The frontend only talks to the backend via its API proxy. The backend's service.yml includes Redis and NATS connection details.

### 5.5 Vite Standalone (Static Site / SPA with External API)

```
Browser -> localhost:5173 -> Vite container (no backend)
```

No proxy needed. The SPA talks to an external API (which might be mocked via WireMock if the user configures mocks). This use case requires that the `app` category is not `required: true` when a `frontend` is selected, OR that the `frontend` category is independent.

### 5.6 Wiring Summary

| Combination | Frontend Env Vars | Proxy Config | Backend Env Vars |
|-------------|-------------------|--------------|------------------|
| Vite + Go | `VITE_API_URL=http://app:3000` | `/api -> $VITE_API_URL` | `DB_HOST=db` |
| Vite + Node | `VITE_API_URL=http://app:3000` | `/api -> $VITE_API_URL` | `DB_HOST=db` |
| Vite + FastAPI | `VITE_API_URL=http://app:8000` | `/api -> $VITE_API_URL` | `DB_HOST=db` |
| Vite + Any + Redis | Same as above | Same | Add `REDIS_URL=redis://redis:6379` |
| Vite standalone | None | None | N/A |

The pattern is uniform: `VITE_API_URL` points to the backend service by Docker hostname and port. The port comes from the backend's manifest defaults.

---

## 6. Impact on Existing Systems

### 6.1 Changes to `core/compose/generate.sh`

**Required changes (for Option A)**:

1. **New section**: Read `FRONTEND_TYPE` from project.env. If set and not "none", load `templates/frontends/${FRONTEND_TYPE}/service.yml`, perform variable substitution, and append to the compose file.

2. **New variable substitution**: Add `${FRONTEND_SOURCE}`, `${FRONTEND_PORT}`, `${PROXY_TARGET}` to the sed pipeline for frontend templates.

3. **Web service depends_on**: Currently hardcodes `app:`. When a frontend exists AND nginx is configured to proxy to it, add `frontend:` to depends_on. If using direct port exposure (recommended), the `web` service does not need to depend on `frontend`.

4. **Volume registration**: If the frontend template uses named volumes, register them in the COMPOSE_FOOTER.

**Lines affected**: Approximately 40-60 new lines, zero existing lines modified (the new section is additive).

**Backward compatibility**: Full. If `FRONTEND_TYPE` is unset or "none", the new section produces no output.

### 6.2 Changes to `core/nginx/generate-conf.sh`

**For the recommended approach (direct port exposure)**: No changes required. The Vite dev server is exposed directly on its own port. Nginx only handles the backend and mock interception, as it does today.

**If path-based routing is ever needed**: Add a conditional block that detects `FRONTEND_TYPE` and generates:

```nginx
location / {
    proxy_pass http://frontend:5173;
    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection "upgrade";
}

location /api/ {
    proxy_pass http://app:3000;
    # ... existing proxy headers
}
```

This would replace the current unconditional `location / { proxy_pass http://app:3000; }` block. This is a medium-risk change because it alters existing behavior when a frontend is present.

**Recommendation**: Do NOT change nginx for v1. Use direct port exposure. This eliminates risk.

### 6.3 Changes to `devstack.sh` CLI

**`generate_from_bootstrap()`** (line 1179):

1. Extract `frontend_type` from payload: `frontend_type=$(printf '%s\n' "${payload}" | jq -r '.selections.frontend // {} | keys[0] // "none"')`
2. Add `FRONTEND_TYPE`, `FRONTEND_SOURCE`, `FRONTEND_PORT` to the generated project.env
3. If a frontend is selected alongside a backend, compute and write `PROXY_TARGET`

**`cmd_start()`** (line 86):

1. After ensuring `APP_SOURCE` exists, also check `FRONTEND_SOURCE` (if `FRONTEND_TYPE` is set)
2. In the summary output, add a line for the frontend URL: `log "Frontend: http://localhost:${FRONTEND_PORT}"`

**`cmd_init()`** (line 779):

1. Add a prompt: `"Frontend (vite, none) [none]: "`
2. Write `FRONTEND_TYPE`, `FRONTEND_SOURCE`, `FRONTEND_PORT` to project.env
3. Create the frontend source directory if needed

**`cmd_shell()`** (line 284):

1. Default service remains `app`. User can already pass `frontend` as argument: `./devstack.sh shell frontend`

**Contract functions**:

1. `cmd_contract_options()`: No changes; it reads the manifest file directly
2. `validate_bootstrap_payload()`: No changes; it validates against whatever categories exist in the manifest
3. `build_bootstrap_response()`: No changes; it dynamically builds the response from selections

**Estimated changes**: ~30 lines modified, ~20 lines added.

### 6.4 Changes to Test Infrastructure

**Playwright tests**: The tester container's `BASE_URL` currently points to `https://web:443`. For frontend testing:

- If Vite is exposed directly: tests can target `http://frontend:5173` instead
- If proxied through nginx: no change needed

For API testing (which is what the existing tests do), no change is needed.

**New test scenarios to add**:

1. Frontend is reachable at `http://localhost:${FRONTEND_PORT}`
2. Frontend HMR WebSocket connects
3. Frontend can proxy to backend (if both selected)

### 6.5 Backward Compatibility

**No breaking changes** if Option A is implemented with direct port exposure:

- Existing projects that do not use `frontend` see zero behavioral changes
- `FRONTEND_TYPE` defaults to nothing or "none"
- All generators skip the frontend section when no frontend is configured
- The nginx generator is unchanged
- The contract version stays at "1" (adding a category is explicitly listed as non-breaking)

---

## 7. Recommendation

**Option A (Frontend as a Separate Category)** is the recommended approach, implemented with direct port exposure (not nginx proxy).

### Why Option A

1. **Semantic correctness**: A frontend dev server is a different concept from a backend server. Separate categories communicate this clearly to both human users and the PowerHouse orchestrator.

2. **No special-casing**: Unlike Option B, there is no "if the app is named vite, treat it differently" logic. Every item in the `app` category behaves the same way (generates a service named `app`). Every item in the `frontend` category behaves the same way (generates a service named `frontend`).

3. **Backward compatible**: Adding a category does not break the contract. The contract document explicitly states: "Categories -- dev-strap adds or removes freely" under "What is flexible (no version bump needed)."

4. **Standalone frontends are possible**: The `frontend` category has `required: false`. A user can select Vite without a backend. The `app` category has `required: true`, but this can be relaxed to `required: false` when a `frontend` is selected (or unconditionally -- the user might want to run only a database + observability).

5. **Natural extension point**: When SSR frameworks (Next.js, Nuxt, SvelteKit) are added later, they might need to go in the `app` category (because they serve both frontend and backend) or in the `frontend` category with different routing. Having the categories separate makes this decision clean.

### Why Direct Port Exposure

1. **Simplest correct behavior**: HMR works out of the box. No WebSocket forwarding through nginx.
2. **Zero nginx changes**: The biggest source of risk (modifying nginx config generation) is eliminated entirely.
3. **Matches standard Vite workflow**: Every Vite tutorial accesses the dev server directly on port 5173.
4. **Vite's built-in proxy handles API forwarding**: No need for nginx to do path-based routing. Vite already has this feature and developers already use it.

---

## 8. Detailed Design for Recommended Approach

### 8.1 New Files

**`templates/frontends/vite/Dockerfile`**:

```dockerfile
FROM node:22-alpine

WORKDIR /app

# Install dependencies first (layer caching)
COPY package*.json ./
RUN npm install

# Copy source
COPY . .

# Vite dev server
EXPOSE 5173

# --host 0.0.0.0: required for Docker (listen on all interfaces)
CMD ["npx", "vite", "--host", "0.0.0.0"]
```

**`templates/frontends/vite/service.yml`**:

```yaml
  frontend:
    build:
      context: ${FRONTEND_SOURCE}
      dockerfile: Dockerfile
    container_name: ${PROJECT_NAME}-frontend
    ports:
      - "${FRONTEND_PORT}:5173"
    volumes:
      - ${FRONTEND_SOURCE}:/app
      - /app/node_modules
      - ${PROJECT_NAME}-certs:/certs:ro
    working_dir: /app
    environment:
      - NODE_ENV=development
      - CHOKIDAR_USEPOLLING=true
      - NODE_EXTRA_CA_CERTS=/certs/ca.crt
      - VITE_API_URL=${PROXY_TARGET}
    depends_on:
      cert-gen:
        condition: service_completed_successfully
    networks:
      - ${PROJECT_NAME}-internal
```

### 8.2 Manifest Changes

Add to `contract/manifest.json`:

```json
{
  "frontend": {
    "label": "Frontend",
    "description": "Frontend development server with hot module replacement",
    "selection": "single",
    "required": false,
    "items": {
      "vite": {
        "label": "Vite Dev Server",
        "description": "Framework-agnostic frontend dev server with HMR (React, Vue, Svelte, Angular)",
        "defaults": { "port": 5173 }
      }
    }
  }
}
```

Note: `selection: single` because you run one frontend dev server. `required: false` because backend-only projects are valid.

### 8.3 project.env Changes

Add new variables (with defaults for backward compatibility):

```env
# Frontend configuration (leave empty or "none" for backend-only projects)
FRONTEND_TYPE=none
FRONTEND_SOURCE=./frontend
FRONTEND_PORT=5173
```

### 8.4 Generator Changes: `core/compose/generate.sh`

Add a new section after the app service generation (around line 173) and before the web service block:

```bash
# ---------------------------------------------------------------------------
# Build frontend service from template (if configured)
# ---------------------------------------------------------------------------
FRONTEND_SERVICE=""
FRONTEND_DEPENDS=""
FRONTEND_SOURCE_ABS=""
if [ "${FRONTEND_TYPE:-none}" != "none" ]; then
    FRONTEND_SOURCE_ABS="${DEVSTACK_DIR}/${FRONTEND_SOURCE#./}"
    frontend_template="${DEVSTACK_DIR}/templates/frontends/${FRONTEND_TYPE}/service.yml"
    if [ -f "${frontend_template}" ]; then
        # Compute proxy target: if backend exists, point to it
        PROXY_TARGET=""
        if [ -n "${APP_TYPE:-}" ] && [ "${APP_TYPE}" != "none" ]; then
            case "${APP_TYPE}" in
                php-laravel) PROXY_TARGET="http://app:9000" ;;
                *)           PROXY_TARGET="http://app:3000" ;;
            esac
        fi

        FRONTEND_SERVICE=$(cat "${frontend_template}" | \
            sed "s|\${PROJECT_NAME}|${PROJECT_NAME}|g" | \
            sed "s|\${FRONTEND_SOURCE}|${FRONTEND_SOURCE_ABS}|g" | \
            sed "s|\${FRONTEND_PORT}|${FRONTEND_PORT:-5173}|g" | \
            sed "s|\${PROXY_TARGET}|${PROXY_TARGET}|g")
    else
        echo "[compose-gen] WARNING: No frontend template found at ${frontend_template}"
    fi
fi
```

Then add the frontend service block to the output (after the app block, before the web block):

```bash
# ---------------------------------------------------------------------------
# Frontend (if configured)
# ---------------------------------------------------------------------------
if [ -n "${FRONTEND_SERVICE}" ]; then
    cat >> "${OUTPUT_FILE}" <<COMPOSE_FRONTEND

  # ---------------------------------------------------------------------------
  # Frontend Dev Server
  # ---------------------------------------------------------------------------
${FRONTEND_SERVICE}

COMPOSE_FRONTEND
fi
```

### 8.5 `devstack.sh` Changes

In `generate_from_bootstrap()`, add frontend extraction:

```bash
# Extract frontend type
local frontend_type
frontend_type=$(printf '%s\n' "${payload}" | jq -r '.selections.frontend // {} | keys[0] // "none"')

local frontend_port=5173
if printf '%s\n' "${payload}" | jq -e '.selections.frontend.vite.overrides.port' &>/dev/null; then
    frontend_port=$(printf '%s\n' "${payload}" | jq -r '.selections.frontend.vite.overrides.port')
fi
```

And add to the project.env generation:

```bash
FRONTEND_TYPE=${frontend_type}
FRONTEND_SOURCE=./frontend
FRONTEND_PORT=${frontend_port}
```

In `cmd_start()`, add after the app source directory check:

```bash
# Ensure frontend source directory exists (if frontend configured)
if [ "${FRONTEND_TYPE:-none}" != "none" ]; then
    if [ ! -d "${DEVSTACK_DIR}/${FRONTEND_SOURCE:-frontend}" ]; then
        log_warn "Frontend source directory '${FRONTEND_SOURCE:-frontend}' not found."
        log_warn "Creating it with a placeholder."
        mkdir -p "${DEVSTACK_DIR}/${FRONTEND_SOURCE:-frontend}"
    fi
fi
```

In the summary output, add:

```bash
if [ "${FRONTEND_TYPE:-none}" != "none" ]; then
    log "Frontend:        http://localhost:${FRONTEND_PORT:-5173}"
fi
```

In `cmd_init()`, add a prompt:

```bash
echo -n "  Frontend (vite, none) [none]: "
read -r input_frontend
local frontend_type="${input_frontend:-none}"
```

### 8.6 Scaffold Output

When a user bootstraps with Vite + Go + PostgreSQL, the generated structure is:

```
project-name/
├── devstack.sh
├── project.env               # APP_TYPE=go, FRONTEND_TYPE=vite
├── app/                      # Go backend source
│   ├── Dockerfile            # Copied from templates/apps/go/
│   ├── init.sh
│   └── (user's Go code)
├── frontend/                 # Vite frontend source
│   ├── Dockerfile            # Copied from templates/frontends/vite/
│   └── (user's Vite project: vite.config.ts, src/, etc.)
├── mocks/
├── tests/
├── .generated/
│   ├── docker-compose.yml    # Services: cert-gen, app, frontend, web, wiremock, tester
│   ├── nginx.conf
│   └── domains.txt
```

### 8.7 Required Behavior Changes Summary

| Component | Change | Risk |
|-----------|--------|------|
| `contract/manifest.json` | Add `frontend` category with `vite` item | None (additive) |
| `templates/frontends/vite/` | New directory with Dockerfile + service.yml | None (new files) |
| `core/compose/generate.sh` | Add frontend service section (~40 lines) | Low (additive) |
| `core/nginx/generate-conf.sh` | No changes | None |
| `devstack.sh` cmd_start | Add frontend directory check + summary line | Low |
| `devstack.sh` cmd_init | Add frontend prompt | Low |
| `devstack.sh` generate_from_bootstrap | Extract frontend from payload, write to project.env | Low |
| `project.env` | Add FRONTEND_TYPE, FRONTEND_SOURCE, FRONTEND_PORT | None (backward compatible) |

### 8.8 Open Questions for Implementation

1. **Should `app.required` change to `false`?** Currently `true`. If a user wants Vite standalone (static site, no backend), they cannot because `app` requires at least one selection. Recommendation: keep `required: true` for now, revisit when the standalone frontend use case is validated.

2. **PHP-FPM + Vite**: PHP-FPM (port 9000) is a special case in the nginx generator. Vite proxying to PHP-FPM does not work via HTTP proxy -- FPM uses the FastCGI protocol, not HTTP. If someone selects Vite + PHP-Laravel, the frontend's `VITE_API_URL` should point to `http://web:80` (going through nginx which handles FastCGI), not directly to `app:9000`. This edge case needs specific handling.

3. **HMR through HTTPS**: If the user accesses the app through the nginx HTTPS port (8443), HMR WebSocket connections from the browser target the Vite dev server directly on port 5173. The browser makes a cross-origin WebSocket connection. This works in development but could trigger browser security warnings if the Vite server is HTTP and the page was loaded via HTTPS. Mitigation: access the frontend directly via `http://localhost:5173` during development, use the nginx HTTPS endpoint only for testing the backend.

4. **CI/CD implications**: The same CI/CD challenges listed in `docs/TODO.md` apply, with the added complexity of two application source directories. The `FRONTEND_SOURCE` bind mount path needs the same absolute-path treatment as `APP_SOURCE`.

5. **Template directory: `templates/frontends/` vs `templates/apps/`?** Using a separate `templates/frontends/` directory reinforces the semantic separation. Using `templates/apps/` would be more consistent with the existing structure but blurs the frontend/backend distinction. Recommendation: `templates/frontends/` for clarity.
