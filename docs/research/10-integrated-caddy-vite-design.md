# Integrated Design: Caddy + Vite Frontend + Multi-App Support

> **Date**: 2026-03-20
> **Depends on**: Research 03 (Vite multi-app), Research 07 (Traefik/Caddy evaluation), IMPLEMENTATION-PLAN.md (Phase 5)
> **Scope**: Merges the nginx-to-Caddy swap with Phase 5 (multi-app/Vite support) into a single cohesive design.

---

## Table of Contents

1. [Routing Architecture](#1-routing-architecture)
2. [Wiring Implications](#2-wiring-implications)
3. [Compose Generator Changes](#3-compose-generator-changes)
4. [devstack.sh Changes](#4-devstacksh-changes)
5. [Vite Template Design](#5-vite-template-design)
6. [Testing Implications](#6-testing-implications)
7. [Revised Implementation Plan](#7-revised-implementation-plan)
8. [Risk Assessment](#8-risk-assessment)

---

## Executive Summary

The Caddy swap creates an opportunity to simplify Phase 5 (Vite/multi-app). With Caddy handling WebSocket, FastCGI, and gRPC natively, the "everything through Caddy" routing model becomes viable with minimal configuration. This eliminates the CORS problem that originally drove the "direct port exposure" recommendation in Research 03, while preserving simplicity.

**Recommended approach**: Option B (everything through Caddy) as the default, with direct port exposure available as a fallback. This gives developers a single-entry-point experience (one URL for everything) while Caddy transparently handles HMR WebSocket forwarding.

---

## 1. Routing Architecture

### 1.1 Option A: Direct Exposure (Current Plan)

The approach recommended in Research 03: Vite on port 5173 directly, backend through Caddy on 8080/8443.

**Caddyfile**:

```
{
    auto_https off
}

localhost:80, localhost:443 {
    tls /certs/server.crt /certs/server.key
    reverse_proxy app:3000
}

# Mock interception (unchanged)
api.stripe.com:443, api.sendgrid.com:443 {
    tls /certs/server.crt /certs/server.key
    reverse_proxy wiremock:8080 {
        header_up X-Original-Host {http.request.host}
    }
}
```

**Compose service for frontend**:

```yaml
  frontend:
    build:
      context: ${FRONTEND_SOURCE}
    ports:
      - "${FRONTEND_PORT}:5173"    # Direct host exposure
    # ...
```

**How HMR works**: Browser connects directly to `http://localhost:5173`. Vite's WebSocket opens on the same port. No proxying involved. Works out of the box with zero configuration.

**CORS behavior**: Frontend on `localhost:5173` makes API requests to `localhost:8443`. These are cross-origin. The developer must either:
- Configure Vite's `server.proxy` to forward `/api` to the backend (standard Vite pattern, requests go from the Vite container to the app container over Docker networking)
- Set CORS headers on the backend

**Pros**:
- Simplest possible HMR -- no proxy in the WebSocket path
- Proven pattern from Research 03
- Caddy config is unchanged from the no-frontend case
- Zero risk of HMR breakage

**Cons**:
- Two ports for the developer to remember (5173 for frontend, 8080/8443 for backend)
- CORS between frontend and backend unless Vite's `server.proxy` is configured
- Not production-like (production uses one entry point)
- Developer's `vite.config.ts` must include proxy configuration to avoid CORS

---

### 1.2 Option B: Everything Through Caddy (Recommended)

Caddy routes all traffic through a single entry point. The frontend container is not exposed to the host.

**Caddyfile**:

```
{
    auto_https off
}

localhost:80, localhost:443, {$PROJECT_NAME}.local:80, {$PROJECT_NAME}.local:443 {
    tls /certs/server.crt /certs/server.key

    # API routes to backend
    handle /api/* {
        reverse_proxy app:3000
    }

    # Everything else (including HMR WebSocket) to frontend
    handle {
        reverse_proxy frontend:5173
    }
}

# Mock interception (unchanged from non-frontend case)
api.stripe.com:443, api.sendgrid.com:443 {
    tls /certs/server.crt /certs/server.key
    reverse_proxy wiremock:8080 {
        header_up X-Original-Host {http.request.host}
    }
}
```

**Compose service for frontend** (no host port mapping):

```yaml
  frontend:
    build:
      context: ${FRONTEND_SOURCE}
    # No ports: section -- Caddy handles external access
    # ...
```

**How HMR works**: This is the critical question. Vite's HMR relies on a WebSocket connection between the browser and the Vite dev server. Here is the exact flow:

1. Browser loads `https://localhost:8443/` -- Caddy routes to `frontend:5173`
2. Vite serves the page, which includes a `<script>` tag that opens a WebSocket to the HMR endpoint
3. By default, Vite constructs the WebSocket URL from the page's own origin: `wss://localhost:8443/`
4. The browser opens this WebSocket. The request hits Caddy.
5. Caddy's `reverse_proxy` directive **automatically handles WebSocket upgrade** -- it detects the `Upgrade: websocket` header and forwards the connection to `frontend:5173`
6. Vite receives the WebSocket connection and HMR works.

**Why this works with Caddy but was problematic with nginx**: Nginx requires explicit `proxy_http_version 1.1`, `Upgrade $http_upgrade`, and `Connection "upgrade"` directives for WebSocket forwarding. Caddy handles WebSocket upgrades automatically in `reverse_proxy` -- no special configuration needed.

**Vite's HMR client port**: When the page is served through a proxy, the browser's address bar shows port 8443, but Vite's internal HMR tries to connect to the dev server's port (5173 by default). To fix this, the Vite server must be told the external-facing port. This is configured via `server.hmr.clientPort`:

```typescript
// vite.config.ts (generated or documented)
export default defineConfig({
  server: {
    host: '0.0.0.0',
    hmr: {
      clientPort: parseInt(process.env.VITE_HMR_PORT || '443'),
    },
  },
});
```

The environment variable `VITE_HMR_PORT` is set by the compose generator to match `HTTPS_PORT`. If the developer accesses via HTTP (port 8080), they use `clientPort: 80`. In practice, the default HTTPS path is the expected one.

**Alternative: protocol-aware HMR detection**. Vite 5.x and later auto-detect the WebSocket protocol from the page load. When the page loads from `https://localhost:8443`, Vite constructs `wss://localhost:8443` for the WebSocket. Caddy proxies this WebSocket to `ws://frontend:5173` (downgrading TLS at the Caddy boundary, which is the standard reverse proxy pattern). This means:
- If `HTTPS_PORT` is the default 8443, `clientPort: 8443` in the Vite config makes HMR work
- If the user changes `HTTPS_PORT`, the `VITE_HMR_PORT` env var propagates the correct value

**CORS behavior**: No CORS issues. Frontend and backend are both served from `localhost:8443`. All requests are same-origin.

**Pros**:
- Single entry point -- one URL for everything
- No CORS between frontend and backend
- Production-like routing (same path conventions in dev and prod)
- Vite's `server.proxy` is NOT needed -- Caddy handles `/api` routing
- The developer does not need to configure proxy settings in `vite.config.ts`
- WebSocket forwarding is automatic in Caddy

**Cons**:
- Requires `server.hmr.clientPort` in `vite.config.ts` (one line, can be injected via env var)
- Path convention: `/api/*` must be reserved for backend routes. This is nearly universal in SPA architectures but is technically an assumption.
- If Caddy has an issue, both frontend and backend are affected
- Slightly more complex Caddyfile (two `handle` blocks vs one `reverse_proxy`)

---

### 1.3 Option C: Hybrid (Both Entry Points)

Caddy proxies both, but the frontend is also exposed directly on its own port.

**Caddyfile**: Same as Option B.

**Compose service**:

```yaml
  frontend:
    build:
      context: ${FRONTEND_SOURCE}
    ports:
      - "${FRONTEND_PORT}:5173"    # Also directly accessible
    # ...
```

**How HMR works**: Both paths work:
- Through Caddy: same as Option B (WebSocket forwarded automatically)
- Direct: same as Option A (browser connects directly to Vite)

**Pros**:
- Maximum flexibility -- developer chooses either entry point
- If the proxied path has issues, the direct path is a fallback
- No lock-in to either approach

**Cons**:
- Two ways to access the same thing creates confusion ("which URL should I use?")
- HMR clientPort must be configured for the Caddy path, but the direct path does not need it -- they conflict
- Documentation burden: explaining when to use which
- The fallback undermines confidence in the primary approach

---

### 1.4 Recommendation: Option B with Direct Fallback Flag

**Default: Option B (everything through Caddy)**. Reasons:

1. **Single entry point is the better developer experience.** One URL, no CORS, no proxy configuration in `vite.config.ts`. The developer types `https://localhost:8443` and everything works.

2. **Caddy handles WebSocket natively.** The reason Research 03 recommended direct exposure was the WebSocket complexity with nginx. Caddy eliminates that concern.

3. **No Vite proxy configuration needed.** With Option A, the developer must add `server.proxy` to their `vite.config.ts`. With Option B, Caddy handles the routing. This is fewer things for the developer to know.

4. **The PHP-FPM edge case becomes clean.** With Caddy, `php_fastcgi app:9000` replaces the FastCGI boilerplate. When a frontend is present alongside PHP, Caddy routes `/api/*` through `php_fastcgi` and `/` through `reverse_proxy frontend:5173`. No special wiring needed. (See Section 1.5 below.)

**Fallback**: If a developer wants direct port exposure (for debugging HMR issues or testing without the proxy), they can set `FRONTEND_DIRECT_PORT=5173` in `project.env`. The compose generator adds a `ports:` entry only when this variable is set. This is not the default.

---

### 1.5 PHP-FPM with Caddy: The Edge Case That Disappears

With nginx, PHP-FPM + Vite was the hardest combination. Vite cannot proxy to PHP-FPM directly because FPM speaks FastCGI, not HTTP. The workaround was to proxy through nginx: `Vite -> nginx:80 -> fastcgi_pass app:9000`.

With Caddy, this is built in:

```
localhost:80, localhost:443 {
    tls /certs/server.crt /certs/server.key

    # API routes to PHP backend
    handle /api/* {
        root * /var/www/html/public
        php_fastcgi app:9000
    }

    # Static PHP pages (non-API)
    handle /admin/* {
        root * /var/www/html/public
        php_fastcgi app:9000
    }

    # Frontend
    handle {
        reverse_proxy frontend:5173
    }
}
```

The `php_fastcgi` directive is Caddy's first-class FastCGI support. It handles the protocol translation internally. No `fastcgi_params`, no `SCRIPT_FILENAME` configuration -- Caddy infers it all from the `root` directive and the request URI.

**Wiring implication**: With nginx, the frontend wiring rule for PHP was `proxy_target = http://web:80` (going through nginx). With Caddy doing the routing, the frontend does not need a `proxy_target` at all. Caddy routes `/api/*` to the backend directly. The frontend only serves the SPA. This eliminates the special case.

---

### 1.6 Backend-Only (No Frontend): Caddyfile Stays Simple

When no frontend is selected, the Caddyfile is identical to the current nginx replacement:

```
{
    auto_https off
}

localhost:80, localhost:443, {$PROJECT_NAME}.local:80, {$PROJECT_NAME}.local:443 {
    tls /certs/server.crt /certs/server.key

    reverse_proxy app:3000
    # OR for PHP:
    # root * /var/www/html/public
    # php_fastcgi app:9000
    # file_server

    handle_path /test-results/* {
        root * /srv/test-results
        file_server browse
    }
}

# Mock interception blocks (if any mocked domains)
```

This is what Research 07 already proposed. The frontend additions are purely additive.

---

### 1.7 gRPC: Zero Config

If a future Go gRPC template is added, no Caddyfile changes are needed. Caddy's `reverse_proxy` detects HTTP/2 and gRPC automatically:

```
handle /grpc.MyService/* {
    reverse_proxy h2c://app:50051
}
```

The `h2c://` scheme tells Caddy the backend speaks HTTP/2 cleartext (gRPC without TLS). This is the standard pattern for gRPC behind a TLS-terminating reverse proxy.

---

## 2. Wiring Implications

### 2.1 Current Wiring Rule

From `contract/manifest.json`:

```json
{
    "when": ["frontend.vite", "app.*"],
    "set": "frontend.vite.proxy_target",
    "template": "http://{app.*}:{app.*.port}"
}
```

This sets `PROXY_TARGET` in the frontend's environment, which Vite's `server.proxy` uses to forward `/api` requests to the backend.

### 2.2 How Wiring Changes with Option B (Caddy Routes Everything)

**The `proxy_target` wiring rule becomes unnecessary for Caddy routing.** Caddy handles `/api/*` routing in the Caddyfile. The frontend does not need to know where the backend is -- it makes requests to `/api/*` on its own origin, and Caddy routes them.

However, the wiring rule is still useful for one thing: **`VITE_API_URL` as a client-side environment variable**. The Vite dev server exposes variables prefixed with `VITE_` to client-side code via `import.meta.env`. Setting `VITE_API_URL=/api` lets the frontend code reference the API base path without hardcoding it:

```typescript
// In application code
const response = await fetch(`${import.meta.env.VITE_API_URL}/users`);
```

**Recommended change**: Rename the wiring rule from `proxy_target` to `api_base` and set it to the path prefix rather than a full URL:

```json
{
    "when": ["frontend.vite", "app.*"],
    "set": "frontend.vite.api_base",
    "template": "/api"
}
```

This outputs `VITE_API_BASE=/api` in `project.env`, which the frontend service template injects as an environment variable. The Vite dev server passes it to client-side code via `import.meta.env.VITE_API_BASE`.

The Caddy generator uses a separate mechanism (the `FRONTEND_TYPE` variable) to decide whether to add the frontend routing block. The wiring system and the Caddy routing are decoupled -- wiring handles environment variables, Caddy handles network routing.

### 2.3 PHP-FPM Wiring: No Special Case

With nginx + direct exposure, the PHP case needed special handling:
- Vite could not proxy to PHP-FPM directly (wrong protocol)
- The wiring target had to be `http://web:80` (through nginx) instead of `http://app:9000`

With Caddy + Option B:
- The frontend does not proxy anything. It serves the SPA.
- Caddy routes `/api/*` to `php_fastcgi app:9000` in the Caddyfile.
- No wiring rule needed for the protocol translation.
- The Caddyfile generator handles this based on `APP_TYPE`.

**The PHP edge case is eliminated entirely.**

### 2.4 Remaining Wiring Rules

All other wiring rules are unchanged. They operate on backend environment variables (Redis URL, NATS URL, MinIO endpoint, etc.) and are unaffected by the proxy layer:

| Rule | Status |
|------|--------|
| `frontend.vite.proxy_target` | **Changed**: becomes `api_base = /api` |
| `app.*.redis_url` | Unchanged |
| `app.*.nats_url` | Unchanged |
| `app.*.s3_endpoint` | Unchanged |
| `tooling.db-ui.default_server` | Unchanged |
| `tooling.swagger-ui.spec_url` | Unchanged |

### 2.5 New Wiring Rule: HMR Port

Add a new wiring rule for the HMR client port:

```json
{
    "when": ["frontend.vite"],
    "set": "frontend.vite.hmr_port",
    "template": "{HTTPS_PORT}"
}
```

Wait -- `HTTPS_PORT` is a project.env variable, not a selection-derived value. Wiring rules currently resolve against manifest defaults and overrides, not project.env variables. This value should be injected by the compose generator directly, not through the wiring system.

**Decision**: The compose generator sets `VITE_HMR_PORT=${HTTPS_PORT}` in the frontend service's environment. No wiring rule needed.

---

## 3. Compose Generator Changes

### 3.1 Current Flow

The current `core/compose/generate.sh` flow:

```
1. Collect mocked domains + WireMock volumes
2. Build domains.txt for cert-gen
3. Build web container network aliases
4. Resolve APP_SOURCE to absolute path
5. Build extras services
6. Build database service
7. Derive DB_PORT
8. Build app-type-specific volumes
9. Build app service from template
10. Assemble: cert-gen -> app -> web -> wiremock -> db -> extras -> tester -> footer
```

### 3.2 New Flow (with Caddy + Frontend)

```
1.  Collect mocked domains + WireMock volumes          (unchanged)
2.  Build domains.txt for cert-gen                      (unchanged)
3.  Build Caddy container network aliases               (renamed from web)
4.  Resolve APP_SOURCE to absolute path                 (unchanged)
5.  Resolve FRONTEND_SOURCE to absolute path            (NEW)
6.  Build extras services                               (unchanged)
7.  Build database service                              (unchanged)
8.  Derive DB_PORT                                      (unchanged)
9.  Build app-type-specific volumes                     (unchanged)
10. Build app service from template                     (unchanged)
11. Build frontend service from template                (NEW)
12. Build Caddy service                                 (CHANGED: replaces nginx)
13. Build WireMock                                      (unchanged)
14. Build database, extras, tester, footer              (unchanged)
```

### 3.3 New Section: Frontend Service (Step 11)

Insert after the app service build (after current line 201), before the web/Caddy service:

```bash
# ---------------------------------------------------------------------------
# Build frontend service from template (if configured)
# ---------------------------------------------------------------------------
FRONTEND_SERVICE=""
FRONTEND_SOURCE_ABS=""
if [ "${FRONTEND_TYPE:-none}" != "none" ]; then
    FRONTEND_SOURCE_ABS="${DEVSTACK_DIR}/${FRONTEND_SOURCE#./}"
    frontend_template="${DEVSTACK_DIR}/templates/frontends/${FRONTEND_TYPE}/service.yml"
    if [ -f "${frontend_template}" ]; then
        FRONTEND_SERVICE=$(cat "${frontend_template}" | \
            sed "s|\${PROJECT_NAME}|${PROJECT_NAME}|g" | \
            sed "s|\${FRONTEND_SOURCE}|${FRONTEND_SOURCE_ABS}|g" | \
            sed "s|\${FRONTEND_PORT}|${FRONTEND_PORT:-5173}|g" | \
            sed "s|\${HTTPS_PORT}|${HTTPS_PORT}|g" | \
            sed "s|\${API_BASE}|${API_BASE:-/api}|g")
    else
        echo "[compose-gen] WARNING: No frontend template found at ${frontend_template}"
    fi
fi
```

And in the assembly section, after the app service block:

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

### 3.4 Changed Section: Caddy Replaces Nginx (Step 12)

Replace the current `web` service block (lines 237-274 in current `generate.sh`):

```bash
  # ---------------------------------------------------------------------------
  # Web Server (Caddy) -- reverse proxy + mock API interceptor
  # ---------------------------------------------------------------------------
  web:
    image: caddy:2-alpine
    container_name: ${PROJECT_NAME}-web
    ports:
      - "${HTTP_PORT}:80"
      - "${HTTPS_PORT}:443"
    volumes:
      - ${OUTPUT_DIR}/Caddyfile:/etc/caddy/Caddyfile:ro
      - ${PROJECT_NAME}-certs:/certs:ro
      - ${DEVSTACK_DIR}/tests/results:/srv/test-results:ro
```

For PHP, the app source mount is still needed (Caddy needs the PHP files for `php_fastcgi`):

```bash
# Add app source volume mount for web if PHP (serves static files)
if [ "${APP_TYPE}" = "php-laravel" ]; then
    cat >> "${OUTPUT_FILE}" <<COMPOSE_WEB_PHP
      - ${APP_SOURCE_ABS}:/var/www/html:ro
COMPOSE_WEB_PHP
fi
```

The depends_on section changes to include `frontend` when present:

```bash
cat >> "${OUTPUT_FILE}" <<COMPOSE_WEB_DEPS
    depends_on:
      cert-gen:
        condition: service_completed_successfully
      app:
        condition: service_started
COMPOSE_WEB_DEPS

# Add frontend dependency if frontend exists
if [ -n "${FRONTEND_SERVICE}" ]; then
    cat >> "${OUTPUT_FILE}" <<COMPOSE_WEB_FRONTEND_DEP
      frontend:
        condition: service_started
COMPOSE_WEB_FRONTEND_DEP
fi

# Add database dependency if database exists
if [ -n "${DB_SERVICE}" ]; then
    cat >> "${OUTPUT_FILE}" <<COMPOSE_WEB_DB_DEP
      db:
        condition: service_healthy
COMPOSE_WEB_DB_DEP
fi
```

The rest (network aliases, health check) stays the same with one update -- Caddy's health check:

```bash
    healthcheck:
      test: ["CMD", "wget", "--spider", "-q", "http://127.0.0.1:80/"]
      interval: 5s
      timeout: 3s
      retries: 20
```

This is identical to the current nginx health check. Caddy responds to HTTP requests on port 80 the same way.

### 3.5 The Caddyfile Generator: `core/caddy/generate-caddyfile.sh`

This replaces `core/nginx/generate-conf.sh`. The generator is substantially shorter because Caddy's configuration syntax is more concise and protocol-agnostic.

```bash
#!/bin/bash
# =============================================================================
# Caddyfile Generator
# =============================================================================
# Replaces core/nginx/generate-conf.sh
# Reads project.env and mocks/*/domains to produce a Caddyfile.
# Handles:
#   - App reverse proxy (HTTP backends) or php_fastcgi (PHP-FPM)
#   - Frontend proxy (when FRONTEND_TYPE is set)
#   - Mock API interception (DNS alias + TLS termination + WireMock proxy)
#   - Test results static file serving
# Output: .generated/Caddyfile
# =============================================================================

set -euo pipefail

DEVSTACK_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
OUTPUT_DIR="${DEVSTACK_DIR}/.generated"
OUTPUT_FILE="${OUTPUT_DIR}/Caddyfile"

source "${DEVSTACK_DIR}/project.env"
mkdir -p "${OUTPUT_DIR}"

# ---------------------------------------------------------------------------
# Collect all mocked domains
# ---------------------------------------------------------------------------
ALL_MOCK_DOMAINS=()
if [ -d "${DEVSTACK_DIR}/mocks" ]; then
    for mock_dir in "${DEVSTACK_DIR}"/mocks/*/; do
        [ -d "${mock_dir}" ] || continue
        domains_file="${mock_dir}domains"
        [ -f "${domains_file}" ] || continue
        while IFS= read -r domain || [ -n "${domain}" ]; do
            domain=$(echo "${domain}" | tr -d '[:space:]')
            [ -z "${domain}" ] && continue
            [[ "${domain}" == \#* ]] && continue
            ALL_MOCK_DOMAINS+=("${domain}")
        done < "${domains_file}"
    done
fi

echo "[caddy-gen] Found ${#ALL_MOCK_DOMAINS[@]} mocked domains"

# ---------------------------------------------------------------------------
# Global options
# ---------------------------------------------------------------------------
cat > "${OUTPUT_FILE}" <<'CADDY_GLOBAL'
# =============================================================================
# AUTO-GENERATED by devstack -- do not edit manually
# Regenerated on every `devstack.sh start`
# =============================================================================
{
    auto_https off
    log {
        level WARN
    }
}

CADDY_GLOBAL

# ---------------------------------------------------------------------------
# App server block (with or without frontend)
# ---------------------------------------------------------------------------
HAS_FRONTEND="false"
if [ "${FRONTEND_TYPE:-none}" != "none" ]; then
    HAS_FRONTEND="true"
fi

if [ "${HAS_FRONTEND}" = "true" ]; then
    # ── Frontend + Backend: path-based routing ──
    if [ "${APP_TYPE}" = "php-laravel" ]; then
        cat >> "${OUTPUT_FILE}" <<CADDY_APP
# Application server (Frontend + PHP backend)
localhost:80, localhost:443, ${PROJECT_NAME}.local:80, ${PROJECT_NAME}.local:443 {
    tls /certs/server.crt /certs/server.key

    # API and PHP routes to backend
    handle /api/* {
        root * /var/www/html/public
        php_fastcgi app:9000
    }

    # Test results
    handle_path /test-results/* {
        root * /srv/test-results
        file_server browse
    }

    # Everything else to frontend (SPA + HMR WebSocket)
    handle {
        reverse_proxy frontend:5173
    }
}

CADDY_APP
    else
        cat >> "${OUTPUT_FILE}" <<CADDY_APP
# Application server (Frontend + API backend)
localhost:80, localhost:443, ${PROJECT_NAME}.local:80, ${PROJECT_NAME}.local:443 {
    tls /certs/server.crt /certs/server.key

    # API routes to backend
    handle /api/* {
        reverse_proxy app:3000
    }

    # Test results
    handle_path /test-results/* {
        root * /srv/test-results
        file_server browse
    }

    # Everything else to frontend (SPA + HMR WebSocket)
    handle {
        reverse_proxy frontend:5173
    }
}

CADDY_APP
    fi
else
    # ── Backend only: simple reverse proxy ──
    if [ "${APP_TYPE}" = "php-laravel" ]; then
        cat >> "${OUTPUT_FILE}" <<CADDY_APP
# Application server (PHP-FPM)
localhost:80, localhost:443, ${PROJECT_NAME}.local:80, ${PROJECT_NAME}.local:443 {
    tls /certs/server.crt /certs/server.key

    root * /var/www/html/public
    php_fastcgi app:9000
    file_server

    handle_path /test-results/* {
        root * /srv/test-results
        file_server browse
    }
}

CADDY_APP
    else
        cat >> "${OUTPUT_FILE}" <<CADDY_APP
# Application server (reverse proxy)
localhost:80, localhost:443, ${PROJECT_NAME}.local:80, ${PROJECT_NAME}.local:443 {
    tls /certs/server.crt /certs/server.key

    reverse_proxy app:3000

    handle_path /test-results/* {
        root * /srv/test-results
        file_server browse
    }
}

CADDY_APP
    fi
fi

# ---------------------------------------------------------------------------
# Mock proxy -- intercepts HTTPS to mocked external services
# ---------------------------------------------------------------------------
if [ ${#ALL_MOCK_DOMAINS[@]} -gt 0 ]; then
    DOMAIN_LIST=""
    for domain in "${ALL_MOCK_DOMAINS[@]}"; do
        DOMAIN_LIST="${DOMAIN_LIST}${domain}:443, "
    done
    DOMAIN_LIST="${DOMAIN_LIST%, }"

    cat >> "${OUTPUT_FILE}" <<CADDY_MOCK
# Mock API Proxy -- intercepts HTTPS to mocked external services
# All traffic forwarded to WireMock for response generation
${DOMAIN_LIST} {
    tls /certs/server.crt /certs/server.key

    reverse_proxy wiremock:8080 {
        header_up X-Original-Host {http.request.host}
        header_up X-Real-IP {remote_host}
        header_up X-Forwarded-Proto {scheme}
    }
}
CADDY_MOCK
fi

echo "[caddy-gen] Generated ${OUTPUT_FILE}"
echo "[caddy-gen] App: http://localhost:${HTTP_PORT} / https://localhost:${HTTPS_PORT}"
if [ "${FRONTEND_TYPE:-none}" != "none" ]; then
    echo "[caddy-gen] Frontend: proxied through Caddy (${FRONTEND_TYPE})"
fi
if [ ${#ALL_MOCK_DOMAINS[@]} -gt 0 ]; then
    echo "[caddy-gen] Mocked domains (via DNS aliases):"
    for domain in "${ALL_MOCK_DOMAINS[@]}"; do
        echo "  - ${domain}"
    done
fi
```

### 3.6 Comparison: Generator Size

| Generator | Lines | Protocol Branches |
|-----------|-------|-------------------|
| `core/nginx/generate-conf.sh` (current) | 207 | 2 (PHP vs proxy) + WebSocket boilerplate per branch |
| `core/caddy/generate-caddyfile.sh` (proposed) | ~130 | 2 (PHP vs proxy) but each branch is shorter |
| Caddyfile output (no frontend) | ~15 lines | vs ~80 lines nginx.conf |
| Caddyfile output (with frontend) | ~25 lines | vs would-be ~120 lines nginx.conf |

The generator is shorter because:
- No `worker_processes`, `events`, `http`, `log_format` boilerplate
- No `proxy_set_header`, `proxy_http_version`, WebSocket upgrade directives
- `php_fastcgi` replaces 6 lines of `fastcgi_pass` + params
- No `ssl_certificate`, `ssl_protocols`, `ssl_ciphers` block (Caddy uses inline `tls`)

### 3.7 depends_on Chain

The complete dependency chain with the integrated solution:

```
cert-gen  (runs once, produces certs volume)
    |
    +---> app  (backend, needs certs for CA trust)
    |
    +---> frontend  (frontend, needs certs for CA trust)
    |
    +---> web/caddy  (needs certs for TLS termination)
    |         |
    |         +---> depends on app (started)
    |         +---> depends on frontend (started, if present)
    |         +---> depends on db (healthy, if present)
    |
    +---> wiremock  (needs certs volume for reference)
    |
    +---> tester  (depends on web being healthy)
```

No circular dependencies. The tester still waits for `web` (Caddy) to be healthy, which means Caddy is up and the backend and frontend are both reachable.

---

## 4. devstack.sh Changes

### 4.1 `cmd_generate()` Change

Replace the nginx generator call with Caddy:

```bash
cmd_generate() {
    log "Generating configuration from directory structure..."
    mkdir -p "${GENERATED_DIR}"

    # 1. Generate Caddyfile (replaces nginx.conf)
    log "Generating Caddyfile..."
    bash "${DEVSTACK_DIR}/core/caddy/generate-caddyfile.sh"

    # 2. Generate docker-compose.yml
    log "Generating docker-compose.yml..."
    bash "${DEVSTACK_DIR}/core/compose/generate.sh"

    log_ok "Configuration generated in ${GENERATED_DIR}/"
    log "  - Caddyfile"
    log "  - docker-compose.yml"
}
```

### 4.2 `generate_from_bootstrap()` Changes

After the existing extraction of `app_type`, `db_type`, `extras` (around line 1308-1315), add frontend extraction:

```bash
    # Extract frontend type
    local frontend_type
    frontend_type=$(printf '%s\n' "${payload}" | jq -r \
        '.selections.frontend // {} | keys[0] // "none"')

    local frontend_port=5173
    if printf '%s\n' "${payload}" | jq -e \
        '.selections.frontend.vite.overrides.port' &>/dev/null; then
        frontend_port=$(printf '%s\n' "${payload}" | jq -r \
            '.selections.frontend.vite.overrides.port')
    fi
```

In the project.env generation (around line 1362-1392), add the frontend variables after the `EXTRAS=` line:

```bash
FRONTEND_TYPE=${frontend_type}
FRONTEND_SOURCE=./frontend
FRONTEND_PORT=${frontend_port}
```

After the existing app scaffolding section (around line 1440), add frontend scaffolding:

```bash
    # ── 2b. Scaffold frontend directory (if frontend selected) ────────────
    if [ "${frontend_type}" != "none" ]; then
        log "Scaffolding frontend directory..." >&2
        mkdir -p "${DEVSTACK_DIR}/frontend"

        if [ -f "${DEVSTACK_DIR}/templates/frontends/${frontend_type}/Dockerfile" ]; then
            cp "${DEVSTACK_DIR}/templates/frontends/${frontend_type}/Dockerfile" \
               "${DEVSTACK_DIR}/frontend/Dockerfile"
        fi
    fi
```

### 4.3 `cmd_start()` Changes

After the app source directory check (line 96-100), add the frontend check:

```bash
    # Ensure frontend source directory exists (if configured)
    if [ "${FRONTEND_TYPE:-none}" != "none" ]; then
        if [ ! -d "${DEVSTACK_DIR}/${FRONTEND_SOURCE:-frontend}" ]; then
            log_warn "Frontend source directory '${FRONTEND_SOURCE:-frontend}' not found."
            log_warn "Creating it with a placeholder."
            mkdir -p "${DEVSTACK_DIR}/${FRONTEND_SOURCE:-frontend}"
        fi
    fi
```

In the summary output (after line 164), add the frontend URL:

```bash
    if [ "${FRONTEND_TYPE:-none}" != "none" ]; then
        log "Frontend:        https://localhost:${HTTPS_PORT} (via Caddy)"
    fi
```

Note that with Option B, the frontend URL is the same as the application URL. The summary line serves to confirm that the frontend dev server is active behind Caddy.

### 4.4 Log and Debug References

Existing references to `logs web` in the codebase continue to work because the service is still named `web` (just runs Caddy instead of nginx). The only change is the AI Bootstrap doc and help text, which mention `nginx routing issues` -- update to `Caddy routing issues`.

### 4.5 Changes Summary

| Function | Change | Lines |
|----------|--------|-------|
| `cmd_generate()` | Replace `nginx` path with `caddy` path | ~5 lines changed |
| `generate_from_bootstrap()` | Add frontend extraction + project.env vars + scaffolding | ~25 lines added |
| `cmd_start()` | Add frontend directory check + summary line | ~10 lines added |
| `cmd_init()` | Add frontend prompt (for interactive mode) | ~5 lines added |

Total: ~45 lines of changes across `devstack.sh`. No existing logic is modified for the non-frontend case.

---

## 5. Vite Template Design

### 5.1 Directory Structure

```
templates/frontends/vite/
    Dockerfile
    service.yml
```

### 5.2 `templates/frontends/vite/Dockerfile`

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

Notes:
- `node:22-alpine` matches the existing `node-express` template
- `--host 0.0.0.0` is required because Vite defaults to `localhost`, which is unreachable from outside the container
- No `CHOKIDAR_USEPOLLING` in the Dockerfile -- it belongs in the service.yml environment where it can be toggled per platform

### 5.3 `templates/frontends/vite/service.yml`

```yaml
  frontend:
    build:
      context: ${FRONTEND_SOURCE}
      dockerfile: Dockerfile
    container_name: ${PROJECT_NAME}-frontend
    volumes:
      - ${FRONTEND_SOURCE}:/app
      - /app/node_modules
      - ${PROJECT_NAME}-certs:/certs:ro
    working_dir: /app
    environment:
      - NODE_ENV=development
      - CHOKIDAR_USEPOLLING=true
      - NODE_EXTRA_CA_CERTS=/certs/ca.crt
      - VITE_API_BASE=${API_BASE}
      - VITE_HMR_PORT=${HTTPS_PORT}
    depends_on:
      cert-gen:
        condition: service_completed_successfully
    networks:
      - ${PROJECT_NAME}-internal
```

Key design decisions:

1. **No `ports:` section.** With Option B (recommended), Caddy proxies to the frontend. The frontend container is only reachable within the Docker network. If the user sets `FRONTEND_DIRECT_PORT` in `project.env`, the compose generator adds a `ports:` entry dynamically (not in the template).

2. **`/app/node_modules` anonymous volume.** Identical to the `node-express` pattern. Prevents bind mount from overwriting container's `node_modules` with host-platform-specific binaries.

3. **`VITE_API_BASE`** (instead of `VITE_API_URL`). With Caddy routing, the frontend code only needs the path prefix (`/api`), not a full URL. This is injected from the wiring system.

4. **`VITE_HMR_PORT`**. Set to `${HTTPS_PORT}` so the frontend developer can configure `server.hmr.clientPort` in their `vite.config.ts` using `process.env.VITE_HMR_PORT`. Needed when the page is loaded through Caddy's HTTPS port.

5. **`CHOKIDAR_USEPOLLING=true`**. Enables filesystem polling for macOS/Windows Docker Desktop where inotify events do not propagate through the VM boundary. On Linux (native Docker), this is unnecessary but harmless.

6. **`NODE_EXTRA_CA_CERTS=/certs/ca.crt`**. If the Vite dev server makes server-side requests (e.g., SSR, middleware), it trusts the dev-strap CA. Same pattern as the `node-express` template.

### 5.4 What the User Needs in Their `vite.config.ts`

For Option B (Caddy proxies everything), the user needs one line:

```typescript
import { defineConfig } from 'vite';

export default defineConfig({
  server: {
    host: '0.0.0.0',
    hmr: {
      clientPort: parseInt(process.env.VITE_HMR_PORT || '443'),
    },
  },
});
```

The `host: '0.0.0.0'` is also set via the Dockerfile's CMD, so it is technically redundant. But including it in the config makes the requirement visible.

The `server.proxy` configuration is **not needed** because Caddy routes `/api/*` to the backend. This is a simplification over Research 03's recommendation.

### 5.5 Scaffold Output

When a user bootstraps with Vite + Go + PostgreSQL:

```
project-name/
    devstack.sh
    project.env               # APP_TYPE=go, FRONTEND_TYPE=vite
    app/                      # Go backend
        Dockerfile
        init.sh
    frontend/                 # Vite frontend
        Dockerfile
    mocks/
    tests/
    .generated/
        docker-compose.yml    # Services: cert-gen, app, frontend, web(caddy), wiremock, db, tester
        Caddyfile             # Replaces nginx.conf
        domains.txt
```

---

## 6. Testing Implications

### 6.1 Tester Container Dependency

Currently:

```yaml
  tester:
    depends_on:
      web:
        condition: service_healthy
    environment:
      - BASE_URL=https://web:443
```

With Caddy, this is unchanged in structure. The service is still named `web`, it just runs `caddy:2-alpine` instead of `nginx:alpine`. The `BASE_URL` points to the same hostname and port. The tester trusts the same CA certificate.

### 6.2 Health Check for Caddy

```yaml
    healthcheck:
      test: ["CMD", "wget", "--spider", "-q", "http://127.0.0.1:80/"]
      interval: 5s
      timeout: 3s
      retries: 20
```

Caddy responds to HTTP requests on port 80. The `wget --spider` check works identically. The response code will be `200` (from the backend or frontend) or `502` (if the backend is not yet ready). The health check passes on `200`.

With the frontend present, the health check hits `/` which routes to the frontend. Vite responds immediately (it serves the dev page even before the app is compiled). This means Caddy's health check passes faster when a frontend is present, because it does not depend on the backend being fully ready -- only on the frontend container having started.

### 6.3 Test Assertions

Existing API tests that hit `https://web:443/` (which reaches the backend) need adjustment when a frontend is present:

- **Without frontend**: `https://web:443/` reaches the backend's root route. Tests that assert against backend responses at `/` continue to work.
- **With frontend**: `https://web:443/` reaches the frontend. Backend tests must use `https://web:443/api/...` paths.

This is a fundamental routing change. The mitigation:

1. **Existing tests for backend-only projects are unchanged.** The routing only changes when `FRONTEND_TYPE` is set.
2. **New tests for frontend+backend projects should use `/api/` prefixed paths for API assertions.**
3. **The `BASE_URL` environment variable remains `https://web:443`** for both cases. Test code uses relative paths from there.

### 6.4 New Test Scenarios

When a frontend is present, add these test assertions:

1. `GET /` returns HTML (frontend is serving the SPA)
2. `GET /api/health` returns the backend's health check response (path-based routing works)
3. WebSocket connection to `wss://web:443/` is upgradable (HMR path works through Caddy)
4. Mock interception still works (unchanged from current tests)

### 6.5 CA Certificate Trust

No change. The tester container mounts `${PROJECT_NAME}-certs:/certs:ro` and sets `NODE_EXTRA_CA_CERTS=/certs/ca.crt`. The certificates are generated by the same `core/certs/generate.sh` script. Caddy loads them via `tls /certs/server.crt /certs/server.key`. The CA chain is the same.

---

## 7. Revised Implementation Plan

### 7.1 Should Caddy Swap and Frontend Support Be Done Together?

**Yes, but in sub-phases.** The Caddy swap (Phase 5a) must land first because the frontend support (Phase 5b) depends on Caddy's WebSocket handling for Option B. Doing them together in one branch avoids a throwaway nginx-based frontend implementation.

However, each sub-phase is independently testable and can be merged separately.

### 7.2 Revised Phase 5: Caddy + Frontend

**Phase 5a: Caddy Swap (Replace nginx)**

| Step | Description | Files | Risk |
|------|-------------|-------|------|
| 5a.1 | Create `core/caddy/generate-caddyfile.sh` | New file | None |
| 5a.2 | Update `core/compose/generate.sh`: `web` service uses `caddy:2-alpine`, mounts `Caddyfile` | `core/compose/generate.sh` | Low |
| 5a.3 | Update `devstack.sh` `cmd_generate()`: call Caddy generator instead of nginx | `devstack.sh` | Low |
| 5a.4 | Update health check: `wget --spider` on port 80 (same command, same behavior) | `core/compose/generate.sh` | None |
| 5a.5 | Run full test suite with Caddy | Existing tests | Low |
| 5a.6 | Verify mock interception: `X-Original-Host` header, TLS termination, DNS aliases | Manual + tests | Low |
| 5a.7 | Verify PHP-FPM: `php_fastcgi app:9000` replaces `fastcgi_pass` | Manual test with PHP template | Medium |
| 5a.8 | Update docs: `AI_BOOTSTRAP.md` references to nginx | `docs/AI_BOOTSTRAP.md` | None |

**Estimated effort**: 1 day. The Caddyfile generator is the main work item, and it is shorter than the nginx generator it replaces.

**Validation criteria**:
- All 6 existing Playwright tests pass
- `./devstack.sh verify-mocks` passes
- PHP-Laravel template generates valid Caddyfile with `php_fastcgi`
- Node/Go templates generate valid Caddyfile with `reverse_proxy`

**Phase 5b: Frontend/Vite Support (Leveraging Caddy)**

| Step | Description | Files | Risk |
|------|-------------|-------|------|
| 5b.1 | Create `templates/frontends/vite/Dockerfile` + `service.yml` | New files | None |
| 5b.2 | Add frontend section to `core/compose/generate.sh` | `core/compose/generate.sh` | Low |
| 5b.3 | Update Caddyfile generator: conditional frontend routing block | `core/caddy/generate-caddyfile.sh` | Low |
| 5b.4 | Update `devstack.sh` `generate_from_bootstrap()`: extract frontend, write to project.env | `devstack.sh` | Low |
| 5b.5 | Update `devstack.sh` `cmd_start()`: frontend directory check + summary | `devstack.sh` | Low |
| 5b.6 | Update `devstack.sh` `cmd_init()`: frontend prompt | `devstack.sh` | Low |
| 5b.7 | Update `project.env` template: add `FRONTEND_TYPE`, `FRONTEND_SOURCE`, `FRONTEND_PORT` | `devstack.sh` | Low |
| 5b.8 | Update wiring rule: `proxy_target` becomes `api_base` with value `/api` | `contract/manifest.json` | Low |
| 5b.9 | Add frontend tests | New test files | None |

**Estimated effort**: 1-2 days. Most logic is additive and follows existing patterns.

**Validation criteria**:
- Bootstrap with Vite + Go + PostgreSQL generates correct project structure
- Caddy routes `/` to frontend, `/api/*` to backend
- HMR WebSocket works through Caddy (page live-reloads on file change)
- Mock interception is unaffected
- Backend-only projects (no frontend) are completely unchanged

### 7.3 Updated Overall Plan

The revised Phase 5 replaces the original:

```
Phase 1 (Foundation)         -- unchanged
Phase 2 (Services)           -- unchanged
Phase 3 (Languages)          -- unchanged
Phase 4 (Presets & Wiring)   -- unchanged
Phase 5a (Caddy Swap)        -- NEW: replaces nginx with Caddy
Phase 5b (Frontend/Vite)     -- REVISED: leverages Caddy, simpler wiring
Phase 6 (Docs)               -- unchanged
```

Phase 5a can be done at any time -- it has no dependency on Phases 2-4. It could even be done first, because the Caddy swap is a pure infrastructure replacement with no feature dependencies.

Phase 5b depends on:
- Phase 5a (Caddy must be in place for Option B routing)
- Phase 1.4 (manifest structure for `frontend` category -- already done)
- Phase 4.2 (wiring rules -- for the `api_base` wiring)

### 7.4 Files Deleted

| File | Replacement |
|------|-------------|
| `core/nginx/generate-conf.sh` | `core/caddy/generate-caddyfile.sh` |

The nginx generator is deleted after Phase 5a is validated. There is no parallel-run period needed because the Caddy swap is a complete replacement tested by the existing test suite.

### 7.5 Rollback Plan

If Caddy causes unexpected issues after Phase 5a:
1. The nginx generator still exists in git history
2. Revert the three changed files (`devstack.sh`, `core/compose/generate.sh`, and add back `core/nginx/generate-conf.sh`)
3. Delete `core/caddy/generate-caddyfile.sh`

---

## 8. Risk Assessment

### 8.1 Does Caddy's Auto-HTTPS Interfere with Custom Certs?

**No.** The global option `auto_https off` disables Caddy's automatic HTTPS entirely. When this is set:
- Caddy does not attempt to obtain Let's Encrypt certificates
- Caddy does not redirect HTTP to HTTPS
- Caddy does not manage certificates at all
- Custom TLS certs are loaded explicitly via `tls /certs/server.crt /certs/server.key` per site block

This is the correct mode for dev-strap, where certificates are generated by the `cert-gen` container with specific SANs for mocked domains.

### 8.2 Race Condition Between cert-gen and Caddy Starting

**Mitigated by `depends_on`.** The `web` (Caddy) service has:

```yaml
depends_on:
  cert-gen:
    condition: service_completed_successfully
```

Docker Compose guarantees that Caddy does not start until the cert-gen container has exited successfully. The cert files exist in the shared volume before Caddy reads them.

**Edge case**: If `cert-gen` fails (e.g., keytool error), Caddy never starts. This is the correct behavior -- same as current nginx.

### 8.3 Does the Tester Need to Trust Caddy's Certs Differently?

**No.** The certificate chain is unchanged:

```
CA cert (ca.crt) -- generated by cert-gen
    |
    +-- Server cert (server.crt) -- signed by CA, SANs include mocked domains + localhost
```

Caddy loads `server.crt`/`server.key`. The tester trusts `ca.crt` via `NODE_EXTRA_CA_CERTS`. This is identical to the nginx setup. The TLS handshake presents the same certificate regardless of whether nginx or Caddy serves it.

### 8.4 What Happens to Existing Bootstrapped Projects?

Existing projects that were bootstrapped with nginx have:
- `project.env` with no `FRONTEND_TYPE` variable
- `.generated/nginx.conf` (deleted on `stop`, regenerated on `start`)
- No `FRONTEND_SOURCE` or `FRONTEND_PORT` variables

When the user runs `./devstack.sh start` after updating to the Caddy version:

1. `project.env` is sourced. `FRONTEND_TYPE` is unset, which defaults to `none`.
2. The Caddyfile generator is called. It generates a backend-only Caddyfile (no frontend routing).
3. The compose generator produces a `web` service with `caddy:2-alpine` instead of `nginx:alpine`.
4. The `.generated/nginx.conf` file is not created (not needed). The old one was already deleted on the previous `stop`.
5. Everything works. The behavior is identical to the nginx version.

**No migration action required for existing projects.** The only visible change is that `docker ps` shows `caddy:2-alpine` instead of `nginx:alpine`.

The user's `project.env` does not need updating. The new variables (`FRONTEND_TYPE`, etc.) default to values that produce identical behavior.

### 8.5 HMR Through Caddy: What Could Go Wrong?

**Risk**: Vite's HMR WebSocket connection fails through the proxy.

**Mitigation**: Caddy handles WebSocket upgrades automatically. The `reverse_proxy` directive detects the `Upgrade: websocket` header and forwards the connection transparently. No configuration needed.

**Remaining risk**: If the developer's `vite.config.ts` does not set `server.hmr.clientPort`, the browser may try to open the WebSocket on port 5173 (Vite's internal port) instead of 8443 (Caddy's HTTPS port). This would fail because port 5173 is not exposed to the host.

**Mitigation**: The `VITE_HMR_PORT` environment variable is set in the frontend service template. The scaffolded `vite.config.ts` example (or documentation) shows how to use it. If the developer ignores it, they get a clear error in the browser console ("WebSocket connection failed") that points to the port mismatch.

### 8.6 Path Convention: What If `/api` Conflicts?

**Risk**: The backend does not mount its routes at `/api/*`. Some frameworks use `/`, `/graphql`, `/rpc`, etc.

**Mitigation options**:

1. **Configurable API prefix.** Add `API_PREFIX=/api` to `project.env`. The Caddyfile generator uses this value in the `handle` directive. Default is `/api`.

2. **Multiple prefixes.** The Caddyfile can list multiple `handle` blocks:
   ```
   handle /api/* { reverse_proxy app:3000 }
   handle /graphql { reverse_proxy app:3000 }
   ```

3. **Fallback to direct exposure.** If the path convention does not fit, the developer sets `FRONTEND_DIRECT_PORT=5173` to bypass Caddy for the frontend and uses Vite's `server.proxy` instead.

For the initial implementation, a single configurable `API_PREFIX` (default `/api`) covers the vast majority of cases. The fallback to direct exposure handles edge cases.

### 8.7 Caddy Image Size

Caddy's Alpine image is ~40MB vs nginx's ~12MB. For a development tool where database images are 100-400MB and the Playwright image is 2GB, this difference is negligible. The image is pulled once and cached.

### 8.8 Caddy Familiarity

Caddy is less widely known than nginx among developers. However:
- Developers do not edit the Caddyfile -- it is generated and lives in `.generated/`
- The Caddyfile syntax is simpler than nginx.conf, so when developers do read it for debugging, it is easier to understand
- The `./devstack.sh logs web` command works the same way

The unfamiliarity risk is low because the proxy is an implementation detail hidden behind the CLI.

---

## Appendix A: Complete Caddyfile Examples

### A.1 Go Backend Only (No Frontend, No Mocks)

```
{
    auto_https off
    log {
        level WARN
    }
}

localhost:80, localhost:443, myproject.local:80, myproject.local:443 {
    tls /certs/server.crt /certs/server.key

    reverse_proxy app:3000

    handle_path /test-results/* {
        root * /srv/test-results
        file_server browse
    }
}
```

### A.2 Go Backend + Stripe Mock (No Frontend)

```
{
    auto_https off
    log {
        level WARN
    }
}

localhost:80, localhost:443, myproject.local:80, myproject.local:443 {
    tls /certs/server.crt /certs/server.key

    reverse_proxy app:3000

    handle_path /test-results/* {
        root * /srv/test-results
        file_server browse
    }
}

api.stripe.com:443 {
    tls /certs/server.crt /certs/server.key

    reverse_proxy wiremock:8080 {
        header_up X-Original-Host {http.request.host}
        header_up X-Real-IP {remote_host}
        header_up X-Forwarded-Proto {scheme}
    }
}
```

### A.3 Vite + Go Backend + Stripe Mock

```
{
    auto_https off
    log {
        level WARN
    }
}

localhost:80, localhost:443, myproject.local:80, myproject.local:443 {
    tls /certs/server.crt /certs/server.key

    handle /api/* {
        reverse_proxy app:3000
    }

    handle_path /test-results/* {
        root * /srv/test-results
        file_server browse
    }

    handle {
        reverse_proxy frontend:5173
    }
}

api.stripe.com:443 {
    tls /certs/server.crt /certs/server.key

    reverse_proxy wiremock:8080 {
        header_up X-Original-Host {http.request.host}
        header_up X-Real-IP {remote_host}
        header_up X-Forwarded-Proto {scheme}
    }
}
```

### A.4 Vite + PHP-Laravel + Stripe + SendGrid Mocks

```
{
    auto_https off
    log {
        level WARN
    }
}

localhost:80, localhost:443, myproject.local:80, myproject.local:443 {
    tls /certs/server.crt /certs/server.key

    handle /api/* {
        root * /var/www/html/public
        php_fastcgi app:9000
    }

    handle_path /test-results/* {
        root * /srv/test-results
        file_server browse
    }

    handle {
        reverse_proxy frontend:5173
    }
}

api.stripe.com:443, api.sendgrid.com:443 {
    tls /certs/server.crt /certs/server.key

    reverse_proxy wiremock:8080 {
        header_up X-Original-Host {http.request.host}
        header_up X-Real-IP {remote_host}
        header_up X-Forwarded-Proto {scheme}
    }
}
```

### A.5 PHP-Laravel Only (No Frontend, No Mocks)

```
{
    auto_https off
    log {
        level WARN
    }
}

localhost:80, localhost:443, myproject.local:80, myproject.local:443 {
    tls /certs/server.crt /certs/server.key

    root * /var/www/html/public
    php_fastcgi app:9000
    file_server

    handle_path /test-results/* {
        root * /srv/test-results
        file_server browse
    }
}
```

---

## Appendix B: Updated Manifest Wiring Rules

Current wiring rules with proposed changes:

```json
"wiring": [
    {
        "when": ["frontend.vite", "app.*"],
        "set": "frontend.vite.api_base",
        "template": "/api",
        "_note": "Changed from proxy_target. Caddy handles routing; frontend only needs path prefix."
    },
    {
        "when": ["app.*", "services.redis"],
        "set": "app.*.redis_url",
        "template": "redis://redis:6379"
    },
    {
        "when": ["app.*", "services.nats"],
        "set": "app.*.nats_url",
        "template": "nats://nats:4222"
    },
    {
        "when": ["app.*", "services.minio"],
        "set": "app.*.s3_endpoint",
        "template": "http://minio:9000"
    },
    {
        "when": ["tooling.db-ui", "database.*"],
        "set": "tooling.db-ui.default_server",
        "template": "db"
    },
    {
        "when": ["tooling.swagger-ui", "app.*"],
        "set": "tooling.swagger-ui.spec_url",
        "template": "http://app:{app.*.port}/docs/openapi.json"
    }
]
```

The only change is the first rule: `proxy_target` becomes `api_base`, and the template changes from `http://{app.*}:{app.*.port}` to `/api`. This reflects that Caddy handles the network routing -- the frontend only needs to know the path convention.

---

## Appendix C: Decision Log

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Routing architecture | Option B (everything through Caddy) | Single entry point, no CORS, Caddy handles WebSocket natively |
| Direct port fallback | Available via `FRONTEND_DIRECT_PORT` env var, not default | Covers edge cases without complicating the default |
| PHP-FPM handling | Caddy's `php_fastcgi` directive | Eliminates the special-case wiring that nginx required |
| HMR configuration | `VITE_HMR_PORT` env var, user sets `server.hmr.clientPort` | One line in vite.config.ts; env var auto-set by compose generator |
| Wiring rule change | `proxy_target` becomes `api_base = /api` | Caddy handles routing; frontend only needs path convention |
| Implementation order | Phase 5a (Caddy) then Phase 5b (Vite), same branch or sequential PRs | Caddy must land first; Vite routing depends on it |
| Service naming | Keep `web` as service name (runs Caddy instead of nginx) | Zero impact on existing depends_on chains, log commands, test references |
| Nginx removal | Delete after Phase 5a validation, no parallel-run period | Test suite provides sufficient validation |
| API path prefix | Configurable via `API_PREFIX`, default `/api` | Covers most cases; override available for non-standard paths |
