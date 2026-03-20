# Design: Caddy Generator and Compose Integration

> **Date**: 2026-03-20
> **Predecessor**: `docs/research/07-traefik-v3-evaluation.md` (established Caddy as the recommended proxy)
> **Scope**: Complete design for replacing the nginx generator with a Caddy-based equivalent

---

## Table of Contents

1. [Caddyfile Generator Design](#1-caddyfile-generator-design)
2. [Compose Service Definition](#2-compose-service-definition)
3. [Cert-Gen Replacement Analysis](#3-cert-gen-replacement-analysis)
4. [Template Impact](#4-template-impact)
5. [devstack.sh Impact](#5-devstacksh-impact)
6. [Complete Generator Draft](#6-complete-generator-draft)
7. [Migration Checklist](#7-migration-checklist)

---

## 1. Caddyfile Generator Design

### 1.1 App Server Block

#### The protocol problem Caddy solves

With nginx, the generator must branch on `APP_TYPE` to choose between entirely different directive families:

| APP_TYPE | nginx directive | Lines of config |
|----------|----------------|-----------------|
| php-laravel | `fastcgi_pass app:9000` + `fastcgi_params` + `SCRIPT_FILENAME` + `try_files` + `location ~ \.php$` | ~18 lines |
| everything else | `proxy_pass http://app:3000` + `proxy_set_header` (x4) + `proxy_http_version` + WebSocket `Upgrade`/`Connection` | ~12 lines |

With Caddy, the branching still exists but collapses to a single-directive difference:

| APP_TYPE | Caddy directive | Lines of config |
|----------|----------------|-----------------|
| php-laravel | `php_fastcgi app:9000` + `root * /var/www/html/public` + `file_server` | 3 lines |
| everything else | `reverse_proxy app:3000` | 1 line |

#### Can `reverse_proxy` alone handle everything?

No. `reverse_proxy` speaks HTTP to an upstream. PHP-FPM speaks the FastCGI protocol, which is a binary protocol distinct from HTTP. Caddy's `php_fastcgi` is a convenience directive that internally wraps the `reverse_proxy` transport with FastCGI framing, sets `root`, `try_files`, and `file_server`. There is no way to make a plain `reverse_proxy` talk FastCGI.

However, the key simplification is that `reverse_proxy` handles HTTP/1.1, HTTP/2, WebSocket, and gRPC transparently without any protocol-specific directives. No `proxy_http_version 1.1`, no `Upgrade`/`Connection` headers, no `grpc_pass`. The only branch point is PHP-FPM vs everything else, and that branch is inherent to the protocol difference -- not proxy boilerplate.

**Decision**: Two-branch generator. PHP-Laravel uses `php_fastcgi`; all other app types use `reverse_proxy`. Future app types (Go gRPC, Rust with WebSockets, etc.) fall into the `reverse_proxy` branch with zero changes.

#### App server block structure

```
# Non-PHP:
localhost:80, localhost:443, ${PROJECT_NAME}.local:80, ${PROJECT_NAME}.local:443 {
    tls /certs/server.crt /certs/server.key
    reverse_proxy app:3000
    # test-results handled separately (see 1.5)
}

# PHP-Laravel:
localhost:80, localhost:443, ${PROJECT_NAME}.local:80, ${PROJECT_NAME}.local:443 {
    tls /certs/server.crt /certs/server.key
    root * /var/www/html/public
    php_fastcgi app:9000
    file_server
    # test-results handled separately (see 1.5)
}
```

The `tls` directive with explicit cert paths disables Caddy's automatic HTTPS/ACME for that site block. No separate `auto_https off` is needed per block.

### 1.2 Frontend Server Block

FRONTEND_TYPE does not exist in `project.env` today. No Vite template exists yet. This is a planned future feature (see `docs/dev-strap-catalog-proposals.md` and `docs/research/03-vite-multiapp-architecture.md`). The design must accommodate it without implementing it.

#### Option A: Separate port exposure (frontend container exposes its own port)

```yaml
# In compose: frontend container exposes 5173 directly to the host
frontend:
  ports:
    - "${FRONTEND_PORT}:5173"
```

Caddy does not proxy to the frontend at all. The browser connects to `localhost:5173` for the frontend and `localhost:8443` for the API. The frontend's Vite dev server handles its own HMR WebSocket. Caddy is not involved.

**Pros**: Simplest. Vite's built-in dev server handles everything (HMR, WebSocket, module serving). No proxy in the hot path for frontend assets. This is what most developers already do.

**Cons**: Two URLs for one app (`localhost:5173` for UI, `localhost:8443` for API). CORS configuration needed. The developer experience is split.

#### Option B: Caddy proxies to the frontend (path-based routing)

```
localhost:80, localhost:443 {
    tls /certs/server.crt /certs/server.key

    handle /api/* {
        reverse_proxy app:3000
    }

    handle {
        reverse_proxy frontend:5173
    }
}
```

The browser connects to a single URL. Caddy routes `/api/*` to the backend and everything else to the Vite dev server. Vite's HMR WebSocket (`/_vite/ws` or `/__vite_hmr`) is proxied transparently by Caddy's `reverse_proxy` (WebSocket upgrade is automatic).

**Pros**: Single URL. No CORS. Matches production routing. Better developer experience.

**Cons**: Caddy is in the hot path for every frontend asset request (minor perf hit, irrelevant for dev). Path-based routing assumes `/api/*` prefix convention (reasonable but must be configurable or documented). HMR WebSocket must work through the proxy (it does -- Caddy handles WebSocket upgrade automatically).

#### Recommendation: Option B when FRONTEND_TYPE is set

When `FRONTEND_TYPE` is set in `project.env`, the generator should produce a path-based routing block. The API prefix should default to `/api` but be configurable via a `FRONTEND_API_PREFIX` variable. When `FRONTEND_TYPE` is not set (the current default), the generator produces the simple app block from section 1.1.

The generator draft in section 6 includes a conditional block for this. The compose changes for the frontend container are deferred to the Vite template implementation.

### 1.3 Mock Interception Blocks

The current nginx generator creates a single `server` block with all mocked domains in `server_name`. Caddy uses the same pattern: a single site block with a comma-separated list of domain addresses.

```
# One block for all mocked domains
api.stripe.com:443, api.sendgrid.com:443, api.example.com:443 {
    tls /certs/server.crt /certs/server.key

    reverse_proxy wiremock:8080 {
        header_up X-Original-Host {http.request.host}
    }
}
```

Key details:

**Port suffix on domains**: Each mocked domain must include `:443` in the site address. Without the port, Caddy would attempt to serve on its default HTTPS port (443) AND try to obtain a certificate via ACME for that domain. With an explicit `:443`, Caddy uses the provided TLS cert and does not attempt ACME.

**`{http.request.host}` placeholder**: This is Caddy's runtime placeholder for the incoming request's Host header value. When the app sends a request to `api.stripe.com`, Caddy captures that as `{http.request.host}` and injects it as the `X-Original-Host` upstream header. This is the exact equivalent of nginx's `$host` variable.

**`header_up`**: This is Caddy's directive for modifying headers sent to the upstream (proxied request). `header_up X-Original-Host {http.request.host}` adds the header to requests sent to WireMock. This preserves compatibility with existing WireMock mappings that match on `X-Original-Host`.

**Single cert for all mock domains**: The cert-gen container produces a single `server.crt` with SANs for all mocked domains. All mock domains share this cert via the single `tls` directive. This works identically to the nginx approach.

**No per-domain blocks needed**: Unlike an approach where each mock domain gets its own block, a single block with a comma-separated address list is sufficient. All mocked domains route to the same upstream (WireMock). The only differentiator is the `X-Original-Host` header, which WireMock uses to dispatch.

### 1.4 TLS Configuration

#### Disabling auto-HTTPS/ACME globally

Caddy's global options block controls ACME behavior:

```
{
    auto_https off
}
```

This is the nuclear option -- it disables all automatic HTTPS behavior globally. However, it also prevents Caddy from automatically redirecting HTTP to HTTPS, which may or may not be desired.

A more targeted approach: providing explicit `tls` directives with cert file paths on every site block. When Caddy sees `tls /path/to/cert /path/to/key`, it uses those certs and does not attempt ACME for that site.

**Decision**: Use `auto_https off` in the global block. dev-strap's proxy serves a local development environment. There is no ACME server to talk to. Any attempt to reach one would cause startup delays or errors. The global disable is appropriate and defensive.

#### Cert file paths

Caddy cert paths:
- Certificate: `/certs/server.crt`
- Private key: `/certs/server.key`

These are mounted from the `${PROJECT_NAME}-certs` Docker volume, same as the current nginx setup. The volume mount path changes from `/etc/nginx/certs/` to `/certs/` (simpler, and matches what the cert-gen container writes to).

#### Multiple mock domains sharing one cert

The cert-gen container already produces a single certificate with SANs for all mocked domains plus `localhost` and `${PROJECT_NAME}.local`. Every Caddy site block references the same cert files. Caddy matches the incoming SNI against the cert's SANs automatically. No special configuration is needed.

### 1.5 Test Results Serving

The current nginx config serves test results as a static directory at `/test-results/`:

```nginx
location /test-results/ {
    alias /var/www/html/public/test-results/;
    autoindex on;
    autoindex_format html;
}
```

In Caddy, this is handled with `handle_path` and `file_server`:

```
handle_path /test-results/* {
    root * /srv/test-results
    file_server browse
}
```

`handle_path` strips the `/test-results/` prefix from the URI before passing it to inner directives. `file_server browse` serves static files with directory listing (equivalent to nginx's `autoindex on`).

The mount point changes from `/var/www/html/public/test-results` (nginx's convention) to `/srv/test-results` (a simpler, more conventional path for non-app static content).

Note: Test results are also served by the `test-dashboard` container (busybox httpd on port 8082). The `/test-results/` path on the main web server is a convenience alias. Both paths continue to work.

---

## 2. Compose Service Definition

### 2.1 Current nginx service

```yaml
web:
    image: nginx:alpine
    container_name: ${PROJECT_NAME}-web
    ports:
      - "${HTTP_PORT}:80"
      - "${HTTPS_PORT}:443"
    volumes:
      - ${OUTPUT_DIR}/nginx.conf:/etc/nginx/nginx.conf:ro
      - ${PROJECT_NAME}-certs:/etc/nginx/certs:ro
      - ${DEVSTACK_DIR}/tests/results:/var/www/html/public/test-results:ro
      # (PHP only): - ${APP_SOURCE_ABS}:/var/www/html:ro
    depends_on:
      cert-gen:
        condition: service_completed_successfully
      app:
        condition: service_started
    networks:
      ${PROJECT_NAME}-internal:
        aliases:
          - ${PROJECT_NAME}.local
          - api.stripe.com      # one per mocked domain
          - api.sendgrid.com
    healthcheck:
      test: ["CMD", "wget", "--spider", "-q", "http://127.0.0.1/"]
      interval: 5s
      timeout: 3s
      retries: 20
```

### 2.2 Caddy service (proposed)

```yaml
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
      # (PHP only): - ${APP_SOURCE_ABS}:/var/www/html:ro
    depends_on:
      cert-gen:
        condition: service_completed_successfully
      app:
        condition: service_started
    networks:
      ${PROJECT_NAME}-internal:
        aliases:
          - ${PROJECT_NAME}.local
          # ... all mocked domain aliases (unchanged)
    healthcheck:
      test: ["CMD", "wget", "--spider", "-q", "http://127.0.0.1:80/"]
      interval: 5s
      timeout: 3s
      retries: 20
```

### 2.3 Change summary

| Aspect | nginx | Caddy | Notes |
|--------|-------|-------|-------|
| Image | `nginx:alpine` (~12MB) | `caddy:2-alpine` (~40MB) | One-time download difference |
| Config mount | `nginx.conf:/etc/nginx/nginx.conf:ro` | `Caddyfile:/etc/caddy/Caddyfile:ro` | Caddy's default config location |
| Cert mount | `certs:/etc/nginx/certs:ro` | `certs:/certs:ro` | Simpler path, matches cert-gen output |
| Test results mount | `results:/var/www/html/public/test-results:ro` | `results:/srv/test-results:ro` | Cleaner path |
| Ports | `80`, `443` | `80`, `443` | Unchanged |
| Service name | `web` | `web` | **Unchanged** -- see section 4 |
| Health check | `wget --spider http://127.0.0.1/` | `wget --spider http://127.0.0.1:80/` | Explicit port for clarity |
| Admin API | N/A | Port 2019 (internal only) | Not exposed to host -- see below |

### 2.4 Caddy admin API

Caddy runs an admin API on port 2019 by default. This API allows runtime config reloads, metrics, and inspection. For dev-strap:

- **Do NOT expose port 2019 to the host**. It is only useful inside the container for health checks and config reloads.
- The admin API is accessible from inside the Docker network at `http://web:2019`.
- It could be used for a health check alternative: `curl -f http://localhost:2019/config/` instead of `wget --spider http://127.0.0.1:80/`. However, the wget approach is simpler and does not require curl to be in the container. `caddy:2-alpine` includes `wget` via BusyBox.
- For config reloads (see section 5), the admin API is the preferred mechanism over container restart.

**Decision**: Keep the admin API enabled (it's on by default) but do not expose the port. Use `wget` for health checks against port 80, same as nginx. The admin API is available for future enhancements (hot reload, metrics).

### 2.5 PHP static file mount

For `php-laravel`, nginx needs the app source mounted to serve static files (CSS, JS, images) directly without passing through PHP-FPM. Caddy's `php_fastcgi` directive includes `file_server` behavior -- it serves static files itself and only passes `.php` requests to FastCGI. The app source mount is still needed for Caddy to access those static files.

The compose generator must still include the conditional mount:

```yaml
# (PHP only)
      - ${APP_SOURCE_ABS}:/var/www/html:ro
```

This is unchanged from the nginx approach.

---

## 3. Cert-Gen Replacement Analysis

### 3.1 Current cert-gen architecture

The `cert-gen` container:
- Image: `eclipse-temurin:17-alpine` (~200MB compressed, ~330MB uncompressed)
- Runs once at startup, then exits
- Produces:
  1. `ca.key` + `ca.crt` -- Root CA (self-signed, 10-year validity)
  2. `server.key` + `server.crt` -- Server cert signed by the CA (1-year validity, SANs from domains.txt)
  3. `server.p12` -- PKCS12 bundle (intermediate for JKS conversion)
  4. `wiremock.jks` -- Java KeyStore for WireMock
- Java (keytool) is required solely for the JKS conversion. OpenSSL handles everything else.
- The CA cert (`ca.crt`) is mounted into app containers so they trust the proxy's TLS.

### 3.2 Caddy's internal PKI capabilities

Caddy has a built-in PKI system accessible via the `tls internal` directive and the `pki` app in its JSON config:

**What it can do**:
- Generate a local root CA automatically on first start
- Issue server certificates signed by that CA
- Include arbitrary SANs on issued certificates
- Store the CA cert at a known path (`/data/caddy/pki/authorities/local/root.crt` inside the container)
- The CA cert persists across container restarts if the `/data` volume is preserved

**What it cannot do natively**:
- Generate a JKS keystore (Java-specific format)
- Export certs to arbitrary paths (they go to Caddy's internal data directory)
- Run as a one-shot container that exits after generating certs (Caddy is a long-running server)

### 3.3 The JKS problem

WireMock is a Java application. When running in HTTPS mode, it requires a JKS or PKCS12 keystore. The current cert-gen container uses `keytool` (from the Java JDK image) to convert the PEM cert into JKS format.

However, dev-strap's WireMock does NOT run in HTTPS mode. Looking at the compose generator:

```yaml
wiremock:
    command: >
      --port 8080
      --verbose
      --global-response-templating
```

WireMock listens on plain HTTP port 8080. The proxy (nginx/Caddy) terminates TLS and forwards plain HTTP to WireMock. The JKS keystore is generated but **never used** by WireMock in the current architecture.

Wait -- the JKS is generated and the certs volume is mounted into the WireMock container (`${PROJECT_NAME}-certs:/home/wiremock/certs:ro`), but WireMock is not configured with `--https-port` or `--keystore-path`. The JKS generation is either vestigial (from an earlier design where WireMock did TLS) or precautionary (in case recording mode needs it).

Checking the recording flow in `devstack.sh`: the `record` command starts WireMock with `--record-mappings` and `--proxy-all=https://${target_domain}`. When WireMock proxies to the real API, it acts as an HTTP client making outbound HTTPS connections. It does NOT need a server keystore for this -- it needs to trust the target's CA (which is the public internet CA, not our self-signed one). The JKS is truly unused.

### 3.4 Can Caddy replace cert-gen entirely?

**Yes, with caveats.**

#### Approach: Use Caddy's `tls internal` for mock domain certs

```
# Caddyfile
{
    auto_https off
    pki {
        ca local {
            name "DevStack Internal CA"
        }
    }
}

api.stripe.com:443, api.sendgrid.com:443 {
    tls internal
    reverse_proxy wiremock:8080 {
        header_up X-Original-Host {http.request.host}
    }
}
```

When Caddy sees `tls internal`, it:
1. Creates a root CA (if one does not exist) at `/data/caddy/pki/authorities/local/root.crt`
2. Generates a server cert for the site's domain names, signed by that CA
3. Stores the server cert internally (not as files on disk in a predictable path)
4. Serves TLS using the generated cert

The root CA cert can be extracted from the Caddy data volume and mounted into app containers for trust.

#### The extraction problem

App containers need the CA cert at a known path (e.g., `/certs/ca.crt`) to trust the proxy. With the current cert-gen approach, the CA cert is written to the `certs` volume and every container mounts that volume.

With Caddy's internal PKI, the CA cert lives inside Caddy's data directory (`/data/caddy/pki/authorities/local/root.crt`). To make it available to other containers:

**Option A**: Mount a shared volume for Caddy's `/data` directory and have app containers read from it. Problem: the path is deeply nested and Caddy-specific. App container entrypoints would need to know the Caddy data layout.

**Option B**: Add an entrypoint wrapper to the Caddy container that copies the CA cert to a shared volume after Caddy starts. This reintroduces the "wait for cert generation" problem that the current cert-gen container solves with `service_completed_successfully`.

**Option C**: Run a sidecar init container that extracts the cert from the Caddy data volume. This is equivalent to the current cert-gen container but depends on Caddy having already generated the cert.

#### Timing problem

Caddy generates certs when it starts serving, not as a separate step. The current architecture has a clean dependency chain:

```
cert-gen (runs, exits) -> web (starts with certs ready) -> app (starts with CA cert available)
```

With Caddy as the cert generator:

```
caddy (starts, generates certs during startup) -> ??? how do app containers wait for this?
```

The app containers need the CA cert before they start (Node.js reads `NODE_EXTRA_CA_CERTS` at process startup, Go reads `SSL_CERT_FILE` at startup, PHP runs `update-ca-certificates` in its entrypoint). If Caddy has not generated the cert yet when the app starts, TLS verification will fail.

Docker Compose `depends_on` with `condition: service_healthy` could work -- Caddy's health check would pass once it is serving, which means certs are generated. But this creates a circular dependency: the app depends on Caddy being healthy, and Caddy depends on the app being started (for reverse proxying).

The current architecture avoids this by separating cert generation (cert-gen container) from proxying (web container). This separation is intentional and sound.

### 3.5 Decision: Keep cert-gen, remove JKS generation

**Do NOT replace the cert-gen container with Caddy's internal PKI.** The reasons:

1. **Clean dependency chain**: cert-gen runs and exits before anything else starts. No timing issues.
2. **Cert files at predictable paths**: `/certs/ca.crt`, `/certs/server.crt`, `/certs/server.key`. Every container knows where to find them.
3. **Caddy uses the pre-generated certs**: `tls /certs/server.crt /certs/server.key` -- simple, explicit, no magic.
4. **Debuggable**: `openssl x509 -in /certs/server.crt -text` works. Caddy's internal cert storage is opaque.

**However, eliminate the JKS generation.** It is unused. This removes the Java/keytool dependency and allows the cert-gen image to change from `eclipse-temurin:17-alpine` (~200MB) to `alpine:3` (~7MB) with only `openssl` installed.

Updated cert-gen container:

```yaml
cert-gen:
    image: alpine:3
    container_name: ${PROJECT_NAME}-cert-gen
    command: sh /scripts/generate.sh
    volumes:
      - ${PROJECT_NAME}-certs:/certs
      - ${DEVSTACK_DIR}/core/certs/generate.sh:/scripts/generate.sh:ro
      - ${OUTPUT_DIR}/domains.txt:/config/domains.txt:ro
    environment:
      - PROJECT_NAME=${PROJECT_NAME}
    networks:
      - ${PROJECT_NAME}-internal
```

The `generate.sh` script removes the PKCS12 and keytool steps (lines 126-140 of the current script). The `apk add openssl` command runs in the entrypoint (or a minimal Dockerfile).

This is a separate change from the Caddy migration but is a natural companion: the nginx-to-Caddy migration is the right moment to audit the cert pipeline.

### 3.6 Future: Caddy as CA (long-term option)

If a future version of dev-strap wants Caddy to manage the entire PKI:

1. Use a two-phase startup: Caddy starts first with just the PKI config, generates certs, exports CA cert to a shared volume, then signals readiness.
2. App containers wait for the CA cert file to appear (health check or init container).
3. Caddy serves using `tls internal` instead of explicit cert files.

This eliminates the cert-gen container entirely but adds startup complexity. File as a TODO for a future research doc, not for the initial Caddy migration.

---

## 4. Template Impact

### 4.1 Service name: `web` stays `web`

The docker-compose service name remains `web`, not `caddy`. Reasons:

- `web` is a role name (the web-facing proxy), not an implementation name
- Other services reference `web` in `depends_on`, `BASE_URL=https://web:443`, health checks
- The tester container uses `BASE_URL=https://web:443` -- changing the service name would require changing every template
- If we ever swap proxies again, `web` still works

**Decision**: Service name is `web`. Container name changes from `${PROJECT_NAME}-web` to... `${PROJECT_NAME}-web` (unchanged).

### 4.2 `depends_on` references

No changes needed. The dependency chain is:

```
cert-gen -> web (depends_on cert-gen: service_completed_successfully)
cert-gen -> app (depends_on cert-gen: service_completed_successfully)
app -> web (depends_on app: service_started)
```

All templates (`templates/apps/*/service.yml`) depend on `cert-gen`, not on `web`. The `web` service depends on `app` and `cert-gen`. None of these references change.

### 4.3 Volumes

The `${PROJECT_NAME}-certs` volume is unchanged. All templates mount it at `/certs:ro`. The cert-gen container writes to `/certs`. The web (Caddy) container reads from `/certs`. No template changes.

### 4.4 Network aliases

Unchanged. The `web` service still gets network aliases for all mocked domains. This is how Docker DNS resolution routes `api.stripe.com` to the proxy container. The compose generator builds these aliases from `mocks/*/domains` -- same mechanism, same output.

### 4.5 Template files: zero changes

No changes to any file in `templates/`. The proxy swap is entirely contained within `core/` and `devstack.sh`.

---

## 5. devstack.sh Impact

### 5.1 `cmd_generate` function

Current (lines 64-81):

```bash
cmd_generate() {
    log "Generating configuration from directory structure..."
    mkdir -p "${GENERATED_DIR}"

    # 1. Generate nginx.conf
    log "Generating nginx.conf..."
    bash "${DEVSTACK_DIR}/core/nginx/generate-conf.sh"

    # 2. Generate docker-compose.yml
    log "Generating docker-compose.yml..."
    bash "${DEVSTACK_DIR}/core/compose/generate.sh"

    log_ok "Configuration generated in ${GENERATED_DIR}/"
    log "  - nginx.conf"
    log "  - docker-compose.yml"
    log "  - domains.txt"
}
```

Changes:
- Replace `core/nginx/generate-conf.sh` with `core/caddy/generate-caddyfile.sh`
- Change log messages from "nginx.conf" to "Caddyfile"

```bash
cmd_generate() {
    log "Generating configuration from directory structure..."
    mkdir -p "${GENERATED_DIR}"

    # 1. Generate Caddyfile
    log "Generating Caddyfile..."
    bash "${DEVSTACK_DIR}/core/caddy/generate-caddyfile.sh"

    # 2. Generate docker-compose.yml
    log "Generating docker-compose.yml..."
    bash "${DEVSTACK_DIR}/core/compose/generate.sh"

    log_ok "Configuration generated in ${GENERATED_DIR}/"
    log "  - Caddyfile"
    log "  - docker-compose.yml"
    log "  - domains.txt"
}
```

### 5.2 `cmd_reload_mocks` function

Unchanged. This function interacts with WireMock (`/__admin/mappings/reset`), not with the proxy. The proxy does not need to reload for mapping changes -- it only needs to reload if domains change (which requires a full restart anyway).

### 5.3 `cmd_verify_mocks` function

One cosmetic change. Line 770:

```bash
log "Check: ./devstack.sh logs web (nginx routing)"
```

Changes to:

```bash
log "Check: ./devstack.sh logs web (proxy routing)"
```

### 5.4 New Caddy-specific commands

No new commands needed for the initial migration. Potential future additions:

**`./devstack.sh reload-proxy`**: Hot-reload the Caddyfile without restarting the container. Uses the admin API:

```bash
docker compose exec web caddy reload --config /etc/caddy/Caddyfile
```

This is useful if someone modifies the Caddyfile manually for debugging. However, in normal dev-strap usage, the Caddyfile is regenerated on `start` and the container is recreated. A hot-reload command would only be useful during proxy debugging.

**Decision**: Do not add `reload-proxy` in the initial migration. File as a future enhancement if needed. The `restart` command handles all Caddyfile changes.

### 5.5 Help text

No changes to the help text. The commands are the same. The word "nginx" does not appear in the help text.

### 5.6 Log references

Search `devstack.sh` for "nginx" references:

| Location | Current text | New text |
|----------|-------------|----------|
| `cmd_generate` (line 70) | `"Generating nginx.conf..."` | `"Generating Caddyfile..."` |
| `cmd_generate` (line 71) | `bash "...core/nginx/generate-conf.sh"` | `bash "...core/caddy/generate-caddyfile.sh"` |
| `cmd_generate` (line 78) | `"  - nginx.conf"` | `"  - Caddyfile"` |
| `cmd_verify_mocks` (line 770) | `"(nginx routing)"` | `"(proxy routing)"` |

---

## 6. Complete Generator Draft

### `core/caddy/generate-caddyfile.sh`

```bash
#!/bin/bash
# =============================================================================
# Caddyfile Generator
# =============================================================================
# Reads mocks/*/domains and project.env to produce a complete Caddyfile.
# Output: .generated/Caddyfile
#
# Architecture:
#   - Main app site block → PHP-FPM / app container reverse proxy
#   - One shared site block for all mocked domains → WireMock
#   - Test results static file serving at /test-results/
#   - Optional frontend site block (if FRONTEND_TYPE is set)
#
# Replaces: core/nginx/generate-conf.sh
# =============================================================================

set -euo pipefail

DEVSTACK_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
OUTPUT_DIR="${DEVSTACK_DIR}/.generated"
OUTPUT_FILE="${OUTPUT_DIR}/Caddyfile"

# Source project config
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
# AUTO-GENERATED by devstack — do not edit manually
# Regenerated on every `devstack.sh start`
# =============================================================================
{
    auto_https off
}

CADDY_GLOBAL

# ---------------------------------------------------------------------------
# App server block
# ---------------------------------------------------------------------------
if [ "${APP_TYPE}" = "php-laravel" ]; then
    cat >> "${OUTPUT_FILE}" <<CADDY_APP
# ==========================================================================
# Application server (PHP-FPM)
# ==========================================================================
localhost:80, localhost:443, ${PROJECT_NAME}.local:80, ${PROJECT_NAME}.local:443 {
    tls /certs/server.crt /certs/server.key

    root * /var/www/html/public
    php_fastcgi app:9000
    file_server

    handle_path /test-results/* {
        root * /srv/test-results
        file_server browse
        header Access-Control-Allow-Origin *
        header Cache-Control "no-cache, no-store"
    }
}

CADDY_APP
elif [ -n "${FRONTEND_TYPE:-}" ]; then
    # Frontend + backend: path-based routing
    FRONTEND_API_PREFIX="${FRONTEND_API_PREFIX:-/api}"
    cat >> "${OUTPUT_FILE}" <<CADDY_APP
# ==========================================================================
# Application server (frontend + backend, path-based routing)
# ==========================================================================
localhost:80, localhost:443, ${PROJECT_NAME}.local:80, ${PROJECT_NAME}.local:443 {
    tls /certs/server.crt /certs/server.key

    handle_path ${FRONTEND_API_PREFIX}/* {
        reverse_proxy app:3000
    }

    handle_path /test-results/* {
        root * /srv/test-results
        file_server browse
        header Access-Control-Allow-Origin *
        header Cache-Control "no-cache, no-store"
    }

    handle {
        reverse_proxy frontend:${FRONTEND_PORT:-5173}
    }
}

CADDY_APP
else
    cat >> "${OUTPUT_FILE}" <<CADDY_APP
# ==========================================================================
# Application server (reverse proxy)
# ==========================================================================
localhost:80, localhost:443, ${PROJECT_NAME}.local:80, ${PROJECT_NAME}.local:443 {
    tls /certs/server.crt /certs/server.key

    reverse_proxy app:3000

    handle_path /test-results/* {
        root * /srv/test-results
        file_server browse
        header Access-Control-Allow-Origin *
        header Cache-Control "no-cache, no-store"
    }
}

CADDY_APP
fi

# ---------------------------------------------------------------------------
# Mock proxy — intercepts HTTPS to mocked external services
# All traffic forwarded to WireMock for response generation
# ---------------------------------------------------------------------------
if [ ${#ALL_MOCK_DOMAINS[@]} -gt 0 ]; then
    # Build comma-separated domain list with :443 suffix
    DOMAIN_LIST=""
    DOMAIN_COMMENT=""
    for domain in "${ALL_MOCK_DOMAINS[@]}"; do
        if [ -n "${DOMAIN_LIST}" ]; then
            DOMAIN_LIST="${DOMAIN_LIST}, "
            DOMAIN_COMMENT="${DOMAIN_COMMENT}, "
        fi
        DOMAIN_LIST="${DOMAIN_LIST}${domain}:443"
        DOMAIN_COMMENT="${DOMAIN_COMMENT}${domain}"
    done

    cat >> "${OUTPUT_FILE}" <<CADDY_MOCK
# ==========================================================================
# Mock API Proxy — intercepts HTTPS to mocked external services
# Domains: ${DOMAIN_COMMENT}
# ==========================================================================
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

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo "[caddy-gen] Generated ${OUTPUT_FILE}"
echo "[caddy-gen] App: http://localhost:${HTTP_PORT} / https://localhost:${HTTPS_PORT}"
if [ -n "${FRONTEND_TYPE:-}" ]; then
    echo "[caddy-gen] Frontend: proxied via path-based routing (${FRONTEND_API_PREFIX:-/api}/* -> backend)"
fi
if [ ${#ALL_MOCK_DOMAINS[@]} -gt 0 ]; then
    echo "[caddy-gen] Mocked domains (via DNS aliases):"
    for domain in "${ALL_MOCK_DOMAINS[@]}"; do
        echo "  - ${domain}"
    done
fi
```

### Line count comparison

| Component | nginx generator | Caddy generator | Reduction |
|-----------|:--------------:|:--------------:|:---------:|
| Boilerplate / setup | 24 lines | 24 lines | 0% |
| Domain collection | 17 lines | 17 lines | 0% |
| Global config | 33 lines | 12 lines | -64% |
| App block (PHP) | 20 lines | 14 lines | -30% |
| App block (non-PHP) | 18 lines | 10 lines | -44% |
| App block (frontend) | N/A | 16 lines | (new) |
| Mock block | 20 lines | 18 lines | -10% |
| Summary output | 9 lines | 12 lines | +33% (added frontend) |
| **Total** | **~207 lines** | **~140 lines** | **-32%** |

The reduction is less dramatic than the ~60 lines estimated in doc 07 because this draft includes: the frontend routing block (new feature), CORS/cache headers on test-results (carried over from nginx), per-domain comments in the mock block, and summary output. The core routing logic is substantially simpler, but the surrounding infrastructure (domain collection, file I/O, logging) is the same size.

### Generated output comparison

For a project with `APP_TYPE=node-express` and two mocked domains (`api.example-provider.com`, `api.payment-provider.com`):

**Current nginx.conf** (~80 lines of output):

```nginx
worker_processes auto;
error_log /var/log/nginx/error.log warn;
pid /var/run/nginx.pid;

events {
    worker_connections 1024;
}

http {
    include       /etc/nginx/mime.types;
    default_type  application/octet-stream;
    log_format main '...';
    access_log /var/log/nginx/access.log main;
    sendfile on;
    keepalive_timeout 65;
    client_max_body_size 100M;
    ssl_certificate     /etc/nginx/certs/server.crt;
    ssl_certificate_key /etc/nginx/certs/server.key;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         HIGH:!aNULL:!MD5;

    server {
        listen 80;
        listen 443 ssl;
        server_name localhost myproject.local;
        location / {
            proxy_pass http://app:3000;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
            proxy_read_timeout 300;
            proxy_http_version 1.1;
            proxy_set_header Upgrade $http_upgrade;
            proxy_set_header Connection "upgrade";
        }
        location /test-results/ {
            alias /var/www/html/public/test-results/;
            autoindex on;
            autoindex_format html;
            add_header Access-Control-Allow-Origin *;
            add_header Cache-Control "no-cache, no-store";
        }
    }

    server {
        listen 443 ssl;
        server_name api.example-provider.com api.payment-provider.com;
        location / {
            proxy_pass http://wiremock:8080;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
            proxy_set_header X-Original-Host $host;
            proxy_read_timeout 300;
            proxy_buffering off;
        }
    }
}
```

**Proposed Caddyfile** (~25 lines of output):

```
# AUTO-GENERATED by devstack — do not edit manually
{
    auto_https off
}

localhost:80, localhost:443, myproject.local:80, myproject.local:443 {
    tls /certs/server.crt /certs/server.key

    reverse_proxy app:3000

    handle_path /test-results/* {
        root * /srv/test-results
        file_server browse
        header Access-Control-Allow-Origin *
        header Cache-Control "no-cache, no-store"
    }
}

api.example-provider.com:443, api.payment-provider.com:443 {
    tls /certs/server.crt /certs/server.key

    reverse_proxy wiremock:8080 {
        header_up X-Original-Host {http.request.host}
        header_up X-Real-IP {remote_host}
        header_up X-Forwarded-Proto {scheme}
    }
}
```

25 lines vs 80 lines. A 69% reduction in generated output.

---

## 7. Migration Checklist

### Phase 1: Create the Caddy generator (parallel, no risk)

- [ ] Create directory `core/caddy/`
- [ ] Create `core/caddy/generate-caddyfile.sh` (from section 6)
- [ ] Make executable: `chmod +x core/caddy/generate-caddyfile.sh`
- [ ] Test standalone: `bash core/caddy/generate-caddyfile.sh` produces valid `.generated/Caddyfile`
- [ ] Validate Caddyfile syntax: `docker run --rm -v $(pwd)/.generated/Caddyfile:/etc/caddy/Caddyfile caddy:2-alpine caddy validate --config /etc/caddy/Caddyfile`

### Phase 2: Update compose generator

- [ ] In `core/compose/generate.sh`, change the `web` service:
  - Image: `nginx:alpine` -> `caddy:2-alpine`
  - Config mount: `nginx.conf:/etc/nginx/nginx.conf:ro` -> `Caddyfile:/etc/caddy/Caddyfile:ro`
  - Cert mount: `certs:/etc/nginx/certs:ro` -> `certs:/certs:ro`
  - Test results mount: `results:/var/www/html/public/test-results:ro` -> `results:/srv/test-results:ro`
  - Health check: keep `wget` based, explicitly target port 80
- [ ] Validate: `docker compose -f .generated/docker-compose.yml config --quiet`

### Phase 3: Update devstack.sh

- [ ] `cmd_generate`: Change generator script path and log messages
- [ ] `cmd_verify_mocks`: Change "nginx routing" to "proxy routing" in error message
- [ ] Search for any remaining "nginx" string references

### Phase 4: Update cert-gen (companion change)

- [ ] In `core/certs/generate.sh`: Remove JKS/PKCS12 generation (lines 125-140)
- [ ] In `core/compose/generate.sh`: Change cert-gen image from `eclipse-temurin:17-alpine` to `alpine:3`
- [ ] In `core/compose/generate.sh`: Change cert-gen entrypoint to `["sh", "-c", "apk add --no-cache openssl && sh /scripts/generate.sh"]`
  - Alternative: create a minimal Dockerfile for the cert-gen container that has openssl pre-installed
- [ ] Test: Verify `ca.crt`, `server.crt`, `server.key` are generated correctly
- [ ] Test: Verify WireMock starts without JKS (it does not use it)

### Phase 5: Integration test

- [ ] `./devstack.sh stop && ./devstack.sh start` -- full lifecycle
- [ ] `./devstack.sh verify-mocks` -- all mocked domains reachable
- [ ] `./devstack.sh test` -- all Playwright tests pass
- [ ] `./devstack.sh logs web` -- no Caddy errors
- [ ] Test with `APP_TYPE=php-laravel` (change `project.env`, restart)
- [ ] Test with `APP_TYPE=go`
- [ ] Test with `APP_TYPE=node-express`
- [ ] Test with `APP_TYPE=python-fastapi`
- [ ] Test with `APP_TYPE=rust`
- [ ] Test recording: `./devstack.sh record example-api` (verify WireMock proxy-all still works)
- [ ] Test reload: `./devstack.sh reload-mocks` (verify WireMock reload still works)

### Phase 6: Cleanup

- [ ] Remove `core/nginx/` directory
- [ ] Update `docs/AI_BOOTSTRAP.md`:
  - Change "nginx.conf" references to "Caddyfile"
  - Change "core/nginx/generate-conf.sh" to "core/caddy/generate-caddyfile.sh"
  - Change architecture diagram to reference Caddy instead of nginx
- [ ] Update `README.md` if it references nginx
- [ ] Update `docs/QUICKSTART.md` if it references nginx
- [ ] Update `.generated/` in AI_BOOTSTRAP.md source-of-truth table: `nginx.conf` -> `Caddyfile`

### Files changed (summary)

| File | Change type |
|------|------------|
| `core/caddy/generate-caddyfile.sh` | **New file** |
| `core/compose/generate.sh` | Edit (web service definition) |
| `core/certs/generate.sh` | Edit (remove JKS generation) |
| `devstack.sh` | Edit (4 lines: paths and log messages) |
| `docs/AI_BOOTSTRAP.md` | Edit (nginx -> Caddy references) |
| `core/nginx/generate-conf.sh` | **Delete** |
| `core/nginx/` | **Delete directory** |
| `templates/apps/*/service.yml` | No changes |
| `templates/databases/*/service.yml` | No changes |
| `templates/extras/*/service.yml` | No changes |
| `mocks/*/mappings/*.json` | No changes |
| `project.env` | No changes |

---

## Appendix A: Caddy Directive Reference

Quick reference for the Caddy directives used in this design:

| Directive | Purpose | nginx equivalent |
|-----------|---------|-----------------|
| `auto_https off` | Disable all ACME/auto-cert behavior | N/A (nginx has no auto-HTTPS) |
| `tls /cert /key` | Load specific TLS cert/key files | `ssl_certificate` + `ssl_certificate_key` |
| `reverse_proxy upstream:port` | HTTP/WebSocket/gRPC reverse proxy | `proxy_pass` + `proxy_set_header` (x4) + `proxy_http_version` + `Upgrade`/`Connection` |
| `php_fastcgi upstream:port` | FastCGI proxy with PHP conventions | `fastcgi_pass` + `fastcgi_param` + `include fastcgi_params` + `location ~ \.php$` + `try_files` |
| `file_server` | Serve static files from `root` | `try_files` + `sendfile` |
| `file_server browse` | Serve static files with directory listing | `autoindex on` |
| `root * /path` | Set the document root | `root /path` |
| `handle_path /prefix/*` | Handle requests matching prefix, strip prefix | `location /prefix/ { alias ...; }` |
| `handle` | Handle all remaining requests (fallback) | `location /` (default) |
| `header_up Name Value` | Set header on proxied request to upstream | `proxy_set_header Name Value` |
| `header Name Value` | Set header on response to client | `add_header Name Value` |
| `{http.request.host}` | Placeholder: incoming request's Host header | `$host` |
| `{remote_host}` | Placeholder: client's IP address | `$remote_addr` |
| `{scheme}` | Placeholder: http or https | `$scheme` |

## Appendix B: Caddyfile Directive Order

Caddy processes directives in a specific order (not top-to-bottom like nginx). The order relevant to this design:

1. `root`
2. `header`
3. `handle_path` / `handle`
4. `reverse_proxy`
5. `php_fastcgi`
6. `file_server`

Within `handle` / `handle_path` blocks, the same order applies to the inner directives. This means:

- In the PHP block, `php_fastcgi` runs before `file_server`, which is correct (PHP files are processed by FPM, static files are served directly)
- In the frontend block, `handle_path /api/*` is evaluated before `handle` (the catch-all), which is correct (API requests go to the backend, everything else goes to the frontend)
- `handle_path /test-results/*` is evaluated before `reverse_proxy` in the non-PHP/non-frontend block, which is correct (test results are served statically, everything else is proxied)

No explicit `order` directive is needed. The defaults handle all cases in this design.
