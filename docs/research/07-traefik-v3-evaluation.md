# Research: Traefik v3 Evaluation for dev-strap Proxy Layer

> **Date**: 2026-03-20
> **Context**: dev-strap uses nginx for two roles: (1) mock API interception via DNS aliasing + TLS termination, and (2) app reverse proxy. The dual role creates protocol-specific headaches (FastCGI for PHP, WebSocket upgrade headers, future gRPC needs). This document evaluates whether Traefik v3, Caddy, or a hybrid approach could solve this more elegantly.

---

## Table of Contents

1. [Current Architecture and Pain Points](#1-current-architecture-and-pain-points)
2. [Feature Comparison: Traefik v3 vs nginx vs Caddy](#2-feature-comparison-traefik-v3-vs-nginx-vs-caddy)
3. [Mock Interception Feasibility with Traefik](#3-mock-interception-feasibility-with-traefik)
4. [Mock Interception Feasibility with Caddy](#4-mock-interception-feasibility-with-caddy)
5. [Architecture Options](#5-architecture-options)
6. [Docker Compose Integration with Traefik Labels](#6-docker-compose-integration-with-traefik-labels)
7. [Performance and Resource Considerations](#7-performance-and-resource-considerations)
8. [Migration Complexity](#8-migration-complexity)
9. [The "Simpler" Angle](#9-the-simpler-angle)
10. [Recommendation](#10-recommendation)
11. [Draft Implementation](#11-draft-implementation)
12. [Migration Path](#12-migration-path)

---

## 1. Current Architecture and Pain Points

### What nginx does today

**Role 1 -- Mock interception** (the clever part):
```
App -> DNS resolves api.stripe.com to nginx (Docker network alias)
    -> nginx terminates TLS (cert has SAN for api.stripe.com)
    -> nginx adds X-Original-Host: api.stripe.com header
    -> nginx proxy_pass to wiremock:8080
    -> WireMock matches and returns stub
```

**Role 2 -- App reverse proxy** (the mundane part):
```
Browser -> localhost:8080 -> nginx -> app:3000  (Node/Go: proxy_pass)
                                   -> app:9000  (PHP: fastcgi_pass)
```

### The protocol problem

Every protocol needs different nginx directives:

| Protocol | nginx Directive | Extra Config |
|----------|----------------|--------------|
| HTTP | `proxy_pass` | Standard headers |
| PHP-FPM | `fastcgi_pass` | `fastcgi_params`, `SCRIPT_FILENAME` |
| WebSocket | `proxy_pass` | `Upgrade` + `Connection` headers, `proxy_http_version 1.1` |
| gRPC | `grpc_pass` | HTTP/2 required |
| HTTP/2 | `proxy_pass` | Need `http2` on `listen` directive |

The nginx generator (`core/nginx/generate-conf.sh`, 200 lines) already branches on `APP_TYPE` to choose between `proxy_pass` and `fastcgi_pass`. Every new protocol means another branch. This is the pain point.

### What is NOT a pain point

Mock interception works well. The pattern (DNS alias -> TLS termination -> header injection -> proxy to WireMock) is simple, proven, and protocol-agnostic from the mock side (WireMock always receives plain HTTP). This side has no protocol headaches.

---

## 2. Feature Comparison: Traefik v3 vs nginx vs Caddy

### 2.1 Protocol Support

| Capability | nginx | Traefik v3 | Caddy v2 |
|-----------|-------|-----------|---------|
| HTTP/1.1 reverse proxy | Yes | Yes | Yes |
| HTTP/2 | Yes (since 1.9.5) | Yes (native) | Yes (native, + HTTP/3) |
| WebSocket | Yes (needs `Upgrade` headers) | Yes (automatic) | Yes (automatic) |
| gRPC | Yes (`grpc_pass`) | Yes (native via h2c/HTTPS) | Yes (native) |
| FastCGI (PHP-FPM) | Yes (native, `fastcgi_pass`) | **No** (PR #11732 open since 2022, still in design review as of Jan 2026) | **Yes** (native `php_fastcgi` directive) |
| TCP/UDP raw | Yes (stream module) | Yes (TCP/UDP routers) | No (HTTP only) |
| TLS termination | Yes | Yes | Yes |
| TLS passthrough (SNI) | Yes (stream + SNI) | Yes (TCP router + HostSNI) | Limited |

**Key finding**: Traefik v3 does NOT support FastCGI. The feature has been requested since 2016 (issue #753), a serversTransport PR (#11732) is open but in "needs-design-review" status with no merge timeline. The Traefik maintainers have explicitly said this is not on their roadmap. This is a blocking gap for dev-strap, which supports PHP-Laravel.

### 2.2 Configuration Model

| Aspect | nginx | Traefik v3 | Caddy v2 |
|--------|-------|-----------|---------|
| Config format | `nginx.conf` (custom DSL) | YAML/TOML (static) + Docker labels/file (dynamic) | Caddyfile (simple DSL) or JSON |
| Config generation | Template-based shell script | Docker labels on containers OR file provider | Caddyfile generation or caddy-docker-proxy labels |
| Hot reload | `nginx -s reload` (no downtime) | Automatic (watches Docker events + file changes) | Automatic (watches Caddyfile changes) |
| Protocol auto-detect | No (explicit directives per protocol) | Yes (HTTP, HTTP/2, gRPC, WS auto-detected) | Yes (HTTP, HTTP/2, gRPC, WS auto-detected) |
| Docker integration | None (static config file) | Native Docker provider (reads labels) | Plugin (`caddy-docker-proxy`, community-maintained) |

### 2.3 TLS and Certificate Management

| Aspect | nginx | Traefik v3 | Caddy v2 |
|--------|-------|-----------|---------|
| Custom cert files | Yes (`ssl_certificate` directive) | Yes (file provider, `tls.certificates` section) | Yes (`tls cert.pem key.pem`) |
| Custom CA | Yes (any cert chain works) | Yes (any cert chain works) | Yes (also has internal CA feature) |
| Auto-HTTPS (Let's Encrypt) | No (needs certbot) | Yes (built-in ACME) | Yes (built-in, on by default) |
| SANs for mock domains | Works (cert generated externally) | Works (cert generated externally) | Works (cert generated externally) |
| SNI-based routing | Yes (separate server blocks) | Yes (TCP router `HostSNI()` rule) | Limited |

**For dev-strap's use case**: All three can use the externally generated certificate (from `core/certs/generate.sh`). None need their auto-HTTPS features. The cert-gen container produces `server.crt`/`server.key` with SANs for all mocked domains, and any of these proxies can load those files.

### 2.4 Header Injection

| Aspect | nginx | Traefik v3 | Caddy v2 |
|--------|-------|-----------|---------|
| Add custom request headers | `proxy_set_header X-Original-Host $host` | `headers` middleware: `customRequestHeaders.X-Original-Host` | `header_up X-Original-Host {http.request.host}` |
| Via Docker labels | N/A | `traefik.http.middlewares.mock.headers.customrequestheaders.X-Original-Host={host}` | `caddy.reverse_proxy.header_up=X-Original-Host {http.request.host}` |
| Dynamic host capture | Yes (`$host` variable) | **Partial** -- static values in labels; dynamic requires custom plugin or Go template in file provider | Yes (`{http.request.host}` placeholder) |

**Critical detail for mock interception**: The `X-Original-Host` header must contain the *incoming* request's Host value (e.g., `api.stripe.com`). In nginx, `$host` captures this dynamically. In Traefik, Docker labels only support static string values for `customRequestHeaders`. To inject a dynamic header based on the incoming request's Host, you would need the file provider with Go templating, or a custom middleware plugin. Caddy handles this natively with `{http.request.host}`.

However, Traefik's `X-Forwarded-Host` header is added **automatically** by default. WireMock could match on `X-Forwarded-Host` instead of `X-Original-Host`, which would eliminate the need for custom header injection entirely.

---

## 3. Mock Interception Feasibility with Traefik

### 3.1 Can Traefik replicate the current flow?

Current flow:
```
App -> DNS(api.stripe.com) -> nginx:443 -> TLS terminate -> add X-Original-Host -> wiremock:8080
```

Proposed Traefik flow:
```
App -> DNS(api.stripe.com) -> traefik:443 -> TLS terminate -> X-Forwarded-Host auto-added -> wiremock:8080
```

**Step-by-step feasibility**:

| Step | nginx (current) | Traefik (proposed) | Feasible? |
|------|----------------|-------------------|-----------|
| Docker DNS alias resolves to proxy | `web` service gets network aliases | `proxy` service gets same aliases | Yes |
| TLS termination with custom cert | `ssl_certificate /certs/server.crt` | File provider: `tls.certificates[].certFile` | Yes |
| Route by SNI/Host to WireMock | `server_name api.stripe.com` + `proxy_pass wiremock:8080` | HTTP router: `Host()` rule + service pointing to `wiremock:8080` | Yes |
| Add X-Original-Host header | `proxy_set_header X-Original-Host $host` | Use `X-Forwarded-Host` (auto-added) OR file-provider middleware | **Mostly** -- requires WireMock mapping change or file provider |
| Multiple mocked domains | Single `server_name` line with all domains | Multiple `Host()` rules OR `HostRegexp()` | Yes |

### 3.2 The X-Original-Host challenge

Traefik's Docker labels do not support dynamic variable interpolation in custom header values. You cannot write:
```
traefik.http.middlewares.mock.headers.customrequestheaders.X-Original-Host={{.Request.Host}}
```

**Workarounds**:

1. **Use X-Forwarded-Host instead** (simplest): Traefik adds `X-Forwarded-Host` automatically with the original Host value. Change WireMock mappings to match on `X-Forwarded-Host` instead of `X-Original-Host`. This is a one-line change per mapping that has host-based matching.

2. **Use the file provider**: Generate a dynamic config file (YAML) with Go templates that inject `{{.Request.Host}}`. But this reintroduces config generation, defeating the purpose of Docker labels.

3. **Separate router per domain**: Create one Traefik router per mocked domain, each with a static `X-Original-Host` value matching its domain. This works but means N routers for N domains, configured via labels or file.

Option 1 (use `X-Forwarded-Host`) is strongly preferred. It eliminates custom middleware entirely.

### 3.3 Mock interception via file provider

If Docker labels prove insufficient, Traefik's file provider can generate the equivalent of nginx.conf:

```yaml
# .generated/traefik-dynamic.yml
http:
  routers:
    mock-intercept:
      rule: "HostRegexp(`{host:.*}`)"
      entryPoints:
        - websecure
      service: wiremock
      tls: {}
      middlewares:
        - add-original-host

  middlewares:
    add-original-host:
      headers:
        customRequestHeaders:
          X-Original-Host: "{{ .Request.Host }}"

  services:
    wiremock:
      loadBalancer:
        servers:
          - url: "http://wiremock:8080"
```

**Problem**: Go template `{{ .Request.Host }}` is NOT available in Traefik's file provider. The file provider supports Go templating for *file contents* (reading env vars, iterating over data), not for *runtime request values*. This means the file provider cannot dynamically inject the Host header either.

**Conclusion**: For mock interception header injection, Traefik requires either:
- Using `X-Forwarded-Host` (which Traefik adds automatically)
- Creating one router per domain with a static header value
- Writing a custom Traefik plugin (overkill)

---

## 4. Mock Interception Feasibility with Caddy

Caddy handles the mock interception use case more naturally:

```
# Caddyfile (generated)
api.stripe.com, api.sendgrid.com {
    tls /certs/server.crt /certs/server.key

    reverse_proxy wiremock:8080 {
        header_up X-Original-Host {http.request.host}
    }
}

localhost:80, localhost:443 {
    tls /certs/server.crt /certs/server.key

    reverse_proxy app:3000
}
```

Every capability dev-strap needs works natively:
- Custom TLS certificate files with SANs
- Dynamic `X-Original-Host` header injection using `{http.request.host}` placeholder
- Multiple domains in a single site block
- WebSocket, HTTP/2, gRPC auto-detected (no special directives)
- FastCGI for PHP: `php_fastcgi app:9000` (built-in directive)

The Caddyfile syntax is dramatically simpler than nginx.conf. A full dev-strap Caddyfile would be approximately 15-20 lines versus 80+ lines for the current nginx.conf.

---

## 5. Architecture Options

### 5.1 Option A: Replace nginx with Traefik (Full Replacement)

```
┌─────────────────────────────────────────────────┐
│  Traefik v3                                     │
│  - Docker provider (reads labels from services) │
│  - File provider (for TLS certs)                │
│  - Routes app traffic (HTTP/WS/gRPC)            │
│  - Routes mock traffic (TLS + proxy to WireMock)│
└─────────────────────────────────────────────────┘
```

**Pros**:
- Docker labels eliminate `generate-conf.sh` entirely for app routing
- WebSocket, gRPC, HTTP/2 work without protocol-specific config
- Hot reload for routing changes (no `nginx -s reload`)

**Cons**:
- **No FastCGI support** -- PHP-Laravel breaks entirely. Would need nginx *inside* the PHP container as a sidecar, negating the simplification
- Dynamic `X-Original-Host` header injection not possible via labels (must use `X-Forwarded-Host` workaround or per-domain routers)
- Larger image (~50MB vs ~12MB for nginx:alpine-slim)
- Higher memory usage (400-800MB under load vs 200-400MB for nginx)
- Traefik's configuration model (static vs dynamic config, providers, entrypoints, routers, services, middlewares) has its own learning curve
- Labels-based config is less readable than a Caddyfile or nginx.conf for debugging

**Verdict**: Not viable as a full replacement due to the FastCGI gap.

### 5.2 Option B: Replace nginx with Caddy (Full Replacement)

```
┌────────────────────────────────────────┐
│  Caddy v2                              │
│  - Generated Caddyfile                 │
│  - Routes app traffic (all protocols)  │
│  - Routes mock traffic (TLS + proxy)   │
│  - FastCGI for PHP-FPM                 │
└────────────────────────────────────────┘
```

**Pros**:
- Native FastCGI support (`php_fastcgi app:9000`) -- PHP works
- Native WebSocket, gRPC, HTTP/2 support -- no protocol-specific config
- Dynamic `{http.request.host}` placeholder -- mock header injection works
- Simpler config syntax (Caddyfile is 15-20 lines vs 80+ for nginx.conf)
- Custom TLS certs work (`tls cert.pem key.pem`)
- Automatic hot reload when Caddyfile changes
- Built-in internal CA (could potentially replace `core/certs/generate.sh` for mock certs in the future)

**Cons**:
- Still needs a config generator (Caddyfile instead of nginx.conf), but generator is simpler
- No native Docker provider (caddy-docker-proxy is community-maintained)
- Image size ~40MB (vs ~12MB nginx:alpine-slim, vs ~50MB Traefik)
- Caddy is less widely known than nginx (developer familiarity)
- No TCP/UDP raw routing (if future non-HTTP mocks are needed)

**Verdict**: Viable. Solves the protocol problem cleanly. Still needs config generation but the generator would be dramatically simpler.

### 5.3 Option C: Hybrid -- Traefik for App Routing, nginx for Mocks

```
┌─────────────────────────┐    ┌──────────────────────┐
│  Traefik v3             │    │  nginx (slim)        │
│  - App reverse proxy    │    │  - Mock interception │
│  - WS/gRPC/HTTP auto    │    │  - TLS termination   │
│  - Docker labels        │    │  - X-Original-Host   │
└─────────────────────────┘    └──────────────────────┘
```

**Pros**:
- Traefik handles the protocol problem (app routing) with auto-detection
- nginx keeps doing what it does well (mock interception -- simple, proven)
- Separation of concerns: two containers, two jobs
- Mock interception is unchanged (no risk to the clever DNS trick)

**Cons**:
- **Two proxy containers** instead of one (more resource usage, more complexity)
- Still no FastCGI in Traefik -- PHP-Laravel would need a THIRD container (nginx sidecar) or a different approach
- Two things to configure, debug, and maintain
- Port management gets complex (which proxy gets ports 80/443?)
- Docker DNS aliases must point to the mock proxy, not the app proxy

**Verdict**: Over-engineered. The separation creates more problems than it solves.

### 5.4 Option D: Caddy for App Routing, nginx for Mocks

```
┌─────────────────────────┐    ┌──────────────────────┐
│  Caddy v2               │    │  nginx (slim)        │
│  - App reverse proxy    │    │  - Mock interception │
│  - WS/gRPC/HTTP/FastCGI │    │  - TLS termination   │
│  - Simple Caddyfile     │    │  - X-Original-Host   │
└─────────────────────────┘    └──────────────────────┘
```

**Verdict**: Same over-engineering problem as Option C. If Caddy can do both jobs (it can), there is no reason to keep nginx for mocks.

### 5.5 Option E: Keep nginx, Accept the Protocol Branching

```
┌──────────────────────────────────────┐
│  nginx (current)                     │
│  - App reverse proxy (with branches) │
│  - Mock interception                 │
│  - Generator handles protocol diffs  │
└──────────────────────────────────────┘
```

**Pros**:
- No migration risk
- Smallest image size (~12MB)
- Most widely understood by developers
- Mock interception is battle-tested
- FastCGI works today

**Cons**:
- Generator grows with each new protocol
- WebSocket config is already duplicated (present in non-PHP block, absent in PHP block)
- Adding gRPC would require a new branch
- The generator is the complexity hot spot

**Verdict**: Status quo is functional. The question is whether the protocol branching cost is high enough to justify a migration.

### 5.6 Analysis Matrix

| Criterion | A: Traefik Full | B: Caddy Full | C: Hybrid Traefik+nginx | D: Hybrid Caddy+nginx | E: Keep nginx |
|-----------|:---------------:|:-------------:|:----------------------:|:---------------------:|:-------------:|
| PHP-FPM support | **BLOCKED** | Yes | **BLOCKED** | Yes | Yes |
| WebSocket auto | Yes | Yes | Yes | Yes | Manual |
| gRPC auto | Yes | Yes | Yes | Yes | Manual |
| Mock interception | Partial | Full | Full (nginx) | Full (nginx) | Full |
| X-Original-Host | Workaround | Native | Native (nginx) | Native (nginx) | Native |
| Config generator needed | No (labels) | Yes (simpler) | Partial | Partial | Yes |
| Migration risk | High | Medium | High | Medium | None |
| Container count | 1 proxy | 1 proxy | 2 proxies | 2 proxies | 1 proxy |
| Image size | ~50MB | ~40MB | ~62MB combined | ~52MB combined | ~12MB |
| Developer familiarity | Medium | Low-Medium | Low | Low | High |

---

## 6. Docker Compose Integration with Traefik Labels

Even though Traefik is not the recommended choice, understanding the labels pattern is valuable for future reference.

### 6.1 How Labels Would Replace generate-conf.sh

**Current approach** (nginx): A shell script reads `project.env` and `mocks/*/domains`, generates `nginx.conf`.

**Traefik approach**: Services declare their own routing via Docker Compose labels. No generation script needed for app routing.

```yaml
services:
  traefik:
    image: traefik:v3.6
    command:
      - "--providers.docker=true"
      - "--providers.docker.exposedbydefault=false"
      - "--providers.docker.network=${PROJECT_NAME}-internal"
      - "--entryPoints.web.address=:80"
      - "--entryPoints.websecure.address=:443"
      - "--providers.file.directory=/etc/traefik/dynamic"
      - "--providers.file.watch=true"
    ports:
      - "${HTTP_PORT}:80"
      - "${HTTPS_PORT}:443"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - ${PROJECT_NAME}-certs:/certs:ro
      - ${OUTPUT_DIR}/traefik-dynamic.yml:/etc/traefik/dynamic/tls.yml:ro
    networks:
      ${PROJECT_NAME}-internal:
        aliases:
          - ${PROJECT_NAME}.local
          # ... all mocked domain aliases

  app:
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.app.rule=Host(`localhost`) || Host(`${PROJECT_NAME}.local`)"
      - "traefik.http.routers.app.entrypoints=web,websecure"
      - "traefik.http.routers.app.tls=true"
      - "traefik.http.services.app.loadbalancer.server.port=3000"

  wiremock:
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.mock.rule=Host(`api.stripe.com`) || Host(`api.sendgrid.com`)"
      - "traefik.http.routers.mock.entrypoints=websecure"
      - "traefik.http.routers.mock.tls=true"
      - "traefik.http.services.mock.loadbalancer.server.port=8080"
      - "traefik.http.routers.mock.middlewares=mock-headers"
      - "traefik.http.middlewares.mock-headers.headers.customrequestheaders.X-Forwarded-Host="
      # Note: X-Forwarded-Host is added automatically; WireMock must match on it
```

### 6.2 The TLS Dynamic Config (Still Needed)

```yaml
# .generated/traefik-dynamic.yml
tls:
  certificates:
    - certFile: /certs/server.crt
      keyFile: /certs/server.key
```

### 6.3 What the Labels Do NOT Eliminate

Even with Traefik labels, the compose generator still needs to:
- Read `mocks/*/domains` to build the network aliases list
- Read `mocks/*/domains` to build the WireMock Host routing rule
- Generate the TLS dynamic config pointing to certs
- Build the Docker Compose file itself (services, networks, volumes)

The labels eliminate `generate-conf.sh` (nginx config) but `generate.sh` (compose assembly) must still exist with comparable complexity. The routing rules that were in nginx.conf move to Docker labels in docker-compose.yml, but they still need to be generated from the same source data.

**The "no config generation" promise of Traefik labels is misleading for dev-strap's use case.** It works when services are static and known ahead of time. dev-strap's services are dynamic (mock domains are user-defined).

---

## 7. Performance and Resource Considerations

| Metric | nginx:alpine | Traefik v3 | Caddy v2 |
|--------|-------------|-----------|---------|
| Docker image size (compressed) | ~12MB (alpine-slim) | ~50MB | ~40MB |
| Memory at idle | ~2-5MB | ~30-50MB | ~15-25MB |
| Memory under dev load | ~10-20MB | ~50-100MB | ~25-40MB |
| Startup time | <1 second | 1-2 seconds | <1 second |
| Raw throughput (req/s) | ~100K | ~74K | ~85K |

**For a dev environment, none of these differences matter.** The app container, database, and WireMock each use 100-500MB. The proxy's overhead is noise. The image size difference (12MB vs 50MB) is a one-time download. Startup time differences are sub-second.

**The only performance concern**: Traefik v3 has had reported memory leak issues (GitHub issue #10859), with some users seeing memory climb from 70MB to 5GB over time. This was specific to v3.0.x and may be fixed in v3.6. For a dev environment that gets restarted frequently (`devstack.sh stop/start`), this is unlikely to be a real problem.

---

## 8. Migration Complexity

### 8.1 If We Migrate to Caddy (Option B)

**Files to change**:

| File | Change | Effort |
|------|--------|--------|
| `core/nginx/generate-conf.sh` | Replace entirely with `core/caddy/generate-caddyfile.sh` | **Rewrite** (but simpler: ~60 lines vs 200) |
| `core/compose/generate.sh` | Change `web` service from `nginx:alpine` to `caddy:alpine`, change volume mount from `nginx.conf` to `Caddyfile` | Low |
| `templates/apps/*/service.yml` | No changes (app containers are unaffected) | None |
| `core/certs/generate.sh` | No changes (cert format is standard PEM, works with Caddy) | None |
| `devstack.sh` | Change `logs web` references, update health check | Low |
| WireMock mappings | No changes (if using Caddy's `{http.request.host}` -> same `X-Original-Host` header name) | None |
| Tests | Update any nginx-specific assertions | Low |

**Estimated total effort**: 1-2 days. The Caddyfile generator is the main work item, and it is dramatically simpler than the nginx generator.

### 8.2 If We Migrate to Traefik (Option A -- not recommended)

**Files to change**:

| File | Change | Effort |
|------|--------|--------|
| `core/nginx/generate-conf.sh` | Delete entirely | - |
| `core/compose/generate.sh` | Major rewrite: add Traefik service with labels, build WireMock Host rules from domains, add TLS dynamic config generation | **High** |
| `templates/apps/*/service.yml` | Add Traefik labels to each template | Medium |
| WireMock mappings | Change `X-Original-Host` matching to `X-Forwarded-Host` | Medium (every mapping file) |
| PHP-Laravel template | **BLOCKED** -- no solution without FastCGI | **Breaking** |

**Estimated total effort**: 3-5 days, with a permanent gap for PHP support.

### 8.3 Incremental Migration Possibility

Both Caddy and Traefik can run alongside nginx during migration:

```yaml
services:
  web:          # nginx (existing, handles mocks)
  web-new:      # Caddy or Traefik (new, handles app routing)
```

Mock interception continues through nginx (DNS aliases point to `web`). App routing moves to `web-new`. Once validated, swap DNS aliases and ports to the new proxy and remove nginx.

This incremental path works for Option B (Caddy) and reduces risk.

---

## 9. The "Simpler" Angle

The user's instinct was "think bigger, which may actually mean simpler." Let's evaluate each option against that lens.

### 9.1 Traefik + Docker Labels: Simpler or Different Complexity?

**What it eliminates**: `generate-conf.sh` (nginx config generator)

**What it introduces**:
- Traefik static config (entrypoints, providers)
- Docker labels syntax (verbose, error-prone, hard to read)
- TLS dynamic config file (still generated)
- Two configuration models (static vs dynamic)
- Docker socket mount (security consideration)
- WireMock mapping changes (`X-Forwarded-Host`)

**Verdict**: Different complexity, not less. The total system knowledge required is comparable. An nginx.conf is readable by any web developer; Traefik labels require learning Traefik's conceptual model (entrypoints, routers, services, middlewares, providers).

### 9.2 Caddy: Actually Simpler

**What it eliminates**:
- Protocol branching in the generator (no `fastcgi_pass` vs `proxy_pass` vs `grpc_pass`)
- WebSocket upgrade header boilerplate
- nginx DSL complexity (`location`, `server`, `upstream` blocks)

**What it preserves**:
- A config file generator (but ~60 lines instead of 200)
- The same architectural pattern (proxy container with generated config)

**What it introduces**:
- Caddyfile syntax (simple, but new to learn)
- Slightly larger image size (negligible)

**The Caddyfile generator would look approximately like this**:

```bash
#!/bin/bash
# Generate Caddyfile -- approximately 60 lines total

cat > "${OUTPUT_FILE}" <<CADDY_HEAD
# AUTO-GENERATED by devstack
{
    auto_https off
}
CADDY_HEAD

# App server block
if [ "${APP_TYPE}" = "php-laravel" ]; then
    cat >> "${OUTPUT_FILE}" <<CADDY_APP
localhost:80, localhost:443 {
    tls /certs/server.crt /certs/server.key
    root * /var/www/html/public
    php_fastcgi app:9000
    file_server
}
CADDY_APP
else
    cat >> "${OUTPUT_FILE}" <<CADDY_APP
localhost:80, localhost:443 {
    tls /certs/server.crt /certs/server.key
    reverse_proxy app:3000
}
CADDY_APP
fi

# Mock interception -- ONE block for all mocked domains
if [ ${#ALL_MOCK_DOMAINS[@]} -gt 0 ]; then
    DOMAIN_LIST=$(printf ", %s" "${ALL_MOCK_DOMAINS[@]}")
    DOMAIN_LIST="${DOMAIN_LIST:2}"  # trim leading ", "
    cat >> "${OUTPUT_FILE}" <<CADDY_MOCK
${DOMAIN_LIST} {
    tls /certs/server.crt /certs/server.key
    reverse_proxy wiremock:8080 {
        header_up X-Original-Host {http.request.host}
    }
}
CADDY_MOCK
fi
```

Compare this to the current 200-line `generate-conf.sh`. The protocol branching collapses because:
- `php_fastcgi` replaces both `fastcgi_pass` and its 5 lines of params
- `reverse_proxy` handles HTTP, WebSocket, gRPC, and HTTP/2 automatically
- No `proxy_http_version`, `Upgrade`, `Connection` boilerplate
- No `location` blocks for PHP regex matching

**This IS actually simpler. Not different complexity -- less complexity.**

### 9.3 The Radical "No Proxy for App Traffic" Option

What if mock interception stays on nginx, and app traffic has no proxy at all?

```yaml
app:
  ports:
    - "3000:3000"   # Direct exposure, no proxy
```

The browser connects directly to the app container. No proxy, no protocol concerns, no config generation for app routing.

**Problems**:
- No HTTPS for app traffic (browser connects via HTTP)
- No unified port (each service gets its own port)
- PHP-FPM cannot be exposed directly (it speaks FastCGI, not HTTP)
- Loses the single-entry-point developer experience
- Already evaluated and rejected for Vite in research doc 03

This only works if you give up on HTTPS for app traffic and PHP-FPM support. Not viable.

---

## 10. Recommendation

### Primary Recommendation: Replace nginx with Caddy (Option B)

**Caddy is the right tool for dev-strap's proxy layer.** The rationale:

1. **Solves the actual problem**: Protocol branching disappears. `php_fastcgi`, `reverse_proxy`, WebSocket, gRPC, HTTP/2 all work with minimal config. No per-protocol branches in the generator.

2. **Mock interception works natively**: `{http.request.host}` placeholder injects the original Host header dynamically. Custom TLS certs load via `tls cert.pem key.pem`. Multiple mocked domains go in a single site block.

3. **Actually simpler**: The Caddyfile generator is ~60 lines vs ~200 for nginx. The Caddyfile is ~15 lines vs ~80 for nginx.conf. This is a net reduction in total codebase complexity.

4. **FastCGI is built-in**: Unlike Traefik, Caddy's `php_fastcgi` directive is a first-class citizen. PHP-Laravel keeps working.

5. **Future-proof**: When gRPC templates are added (Go services talking to gRPC backends), Caddy handles it without generator changes. When WebSocket-heavy apps are added, Caddy handles it without generator changes.

6. **Low migration risk**: The cert generation system is unchanged. WireMock mappings are unchanged (same `X-Original-Host` header). App service templates are unchanged. Only the proxy container and its config generator change.

### Why NOT Traefik

Traefik is the wrong tool for this job because:

1. **No FastCGI** -- a blocking gap with no resolution timeline
2. **Dynamic header injection is awkward** -- labels only support static values
3. **Does not actually eliminate config generation** -- mock domain routing rules still need to be generated from `mocks/*/domains`
4. **Docker socket mount** -- requires `docker.sock` access, which is a security concern and adds container dependency
5. **Higher resource usage** -- 3-4x the memory of nginx, though negligible for dev
6. **The complexity is different, not less** -- Traefik's conceptual model (entrypoints, routers, services, middlewares, providers) is its own learning curve

Traefik excels at dynamic service discovery in production Kubernetes/Swarm environments. dev-strap generates static configuration from a known directory structure. Traefik's strengths are irrelevant here; its weaknesses (no FastCGI, static label values) are directly painful.

### Why NOT Keeping nginx

The status quo works but has a cost trajectory:
- Every new protocol (gRPC, HTTP/3) means more branches in `generate-conf.sh`
- The PHP-FPM block is already 20 lines of boilerplate that Caddy replaces with one line
- WebSocket upgrade headers are boilerplate that Caddy handles automatically
- The nginx DSL is powerful but verbose for dev-strap's simple routing needs

The migration cost (1-2 days) pays for itself the first time a new protocol template is added.

---

## 11. Draft Implementation

### 11.1 New File: `core/caddy/generate-caddyfile.sh`

```bash
#!/bin/bash
# =============================================================================
# Caddyfile Generator
# =============================================================================
# Replaces core/nginx/generate-conf.sh
# Reads mocks/*/domains and project.env to produce a Caddyfile.
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
# Generate Caddyfile
# ---------------------------------------------------------------------------

# Global options
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
# App server block
# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
# Mock proxy -- intercepts HTTPS to mocked external services
# ---------------------------------------------------------------------------
if [ ${#ALL_MOCK_DOMAINS[@]} -gt 0 ]; then
    DOMAIN_LIST=""
    for domain in "${ALL_MOCK_DOMAINS[@]}"; do
        DOMAIN_LIST="${DOMAIN_LIST}${domain}:443, "
    done
    # Remove trailing ", "
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
if [ ${#ALL_MOCK_DOMAINS[@]} -gt 0 ]; then
    echo "[caddy-gen] Mocked domains (via DNS aliases):"
    for domain in "${ALL_MOCK_DOMAINS[@]}"; do
        echo "  - ${domain}"
    done
fi
```

### 11.2 Changes to `core/compose/generate.sh`

Replace the `web` service section:

```yaml
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

Plus the PHP-specific app source mount (same as current).

### 11.3 Health Check Update

```yaml
    healthcheck:
      test: ["CMD", "wget", "--spider", "-q", "http://127.0.0.1:80/"]
      interval: 5s
      timeout: 3s
      retries: 20
```

Caddy's default health behavior works with the same wget check.

---

## 12. Migration Path

### Phase 1: Add Caddy Generator (Parallel)

1. Create `core/caddy/generate-caddyfile.sh`
2. Add a `PROXY_TYPE` variable to `project.env` (default: `nginx`)
3. Update `core/compose/generate.sh` to conditionally use Caddy or nginx based on `PROXY_TYPE`
4. Test both paths in parallel
5. **Risk**: None. nginx remains the default.

### Phase 2: Validate Mock Interception

1. Run the full test suite with `PROXY_TYPE=caddy`
2. Verify all mocked domains resolve and return stubs
3. Verify `X-Original-Host` header reaches WireMock correctly
4. Test with PHP-Laravel (`php_fastcgi` directive)
5. Test with Node-Express (standard `reverse_proxy`)
6. Test with Go (standard `reverse_proxy`)
7. **Risk**: Low. Caddy's feature set covers all current use cases.

### Phase 3: Make Caddy the Default

1. Change `PROXY_TYPE` default to `caddy`
2. Update documentation
3. Keep nginx generator for one release cycle (users can opt back)
4. **Risk**: Low. Users who depend on nginx can set `PROXY_TYPE=nginx`.

### Phase 4: Remove nginx Generator

1. Delete `core/nginx/generate-conf.sh`
2. Remove nginx-specific compose generation code
3. Remove `PROXY_TYPE` variable (Caddy is the only option)
4. **Risk**: Low. By this point Caddy has been the default through a full release cycle.

### Timeline Estimate

| Phase | Effort | Calendar Time |
|-------|--------|---------------|
| Phase 1 | 1 day | Immediate |
| Phase 2 | 0.5 days | Same sprint |
| Phase 3 | 0.5 days | Next sprint |
| Phase 4 | 0.5 days | Sprint after |

---

## Appendix A: Alternatives Briefly Considered

### Envoy

- gRPC-native, protocol detection, advanced load balancing
- **Configuration is extremely verbose** (hundreds of lines of YAML for simple routing)
- No FastCGI support
- Designed for service mesh / sidecar patterns, not dev environment proxying
- Massive overkill for dev-strap's needs
- **Rejected**: wrong problem space

### HAProxy

- High-performance TCP/HTTP load balancer
- No FastCGI support
- No TLS certificate auto-management
- Configuration syntax is its own learning curve
- **Rejected**: no advantages over nginx for dev-strap's use case

### No Proxy (Direct Exposure)

- Expose app ports directly to host, no proxy layer
- **Rejected**: PHP-FPM cannot be exposed directly (FastCGI protocol), and losing HTTPS for app traffic is a significant regression

## Appendix B: Sources

- [Traefik v3 Docker Provider](https://doc.traefik.io/traefik/expose/docker/basic/)
- [Traefik Headers Middleware](https://doc.traefik.io/traefik/reference/routing-configuration/http/middlewares/headers/)
- [Traefik FastCGI Issue #9521](https://github.com/traefik/traefik/issues/9521) -- open, no merge timeline
- [Traefik FastCGI PR #11732](https://github.com/traefik/traefik/pull/11732) -- open, in design review
- [Traefik FastCGI Original Issue #753](https://github.com/traefik/traefik/issues/753) -- closed as duplicate, never implemented
- [Traefik TCP/SNI Routing](https://doc.traefik.io/traefik/reference/routing-configuration/tcp/tls/)
- [Traefik TLS Certificates](https://doc.traefik.io/traefik/reference/routing-configuration/http/tls/tls-certificates/)
- [Traefik gRPC Examples](https://doc.traefik.io/traefik/v3.6/user-guides/grpc/)
- [Traefik File Provider](https://doc.traefik.io/traefik/reference/routing-configuration/other-providers/file/)
- [Traefik Dynamic Configuration](https://doc.traefik.io/traefik/reference/routing-configuration/dynamic-configuration-methods/)
- [Caddy php_fastcgi Directive](https://caddyserver.com/docs/caddyfile/directives/php_fastcgi)
- [Caddy TLS Directive](https://caddyserver.com/docs/caddyfile/directives/tls)
- [Caddy reverse_proxy Directive](https://caddyserver.com/docs/caddyfile/directives/reverse_proxy)
- [caddy-docker-proxy Plugin](https://github.com/lucaslorentz/caddy-docker-proxy)
- [Nginx vs Caddy vs Traefik Comparison (ZeonEdge)](https://zeonedge.com/blog/nginx-vs-caddy-vs-traefik-comparison)
- [Reverse Proxy Comparison 2026 (Calmops)](https://calmops.com/network/reverse-proxy-comparison-nginx-traefik-haproxy/)
- [Traefik v3 vs Nginx Performance Analysis](https://hhf.technology/blog/traefik-vs-nginx)
- [Traefik Memory Leak Issue #10859](https://github.com/traefik/traefik/issues/10859)
- [Traefik Docker Compose Guide 2025 (SimpleHomelab)](https://www.simplehomelab.com/udms-18-traefik-docker-compose-guide/)
- [Using Self-Signed Certs with Traefik v3.4](https://community.traefik.io/t/using-self-signed-certs-on-v3-4/28093)
- [BretFisher/compose-dev-tls (Traefik + TLS for Docker dev)](https://github.com/BretFisher/compose-dev-tls)
