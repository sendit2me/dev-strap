# Research: Caddy v2 Deep Dive for dev-strap Proxy Layer

> **Date**: 2026-03-20
> **Context**: Follows `07-traefik-v3-evaluation.md` which recommended Caddy as the nginx replacement. This document provides the detailed technical research needed to implement that recommendation: exact Caddyfile syntax for every dev-strap use case, Docker integration, limitations, and cert handling.

---

## Table of Contents

1. [Caddyfile Syntax for Every dev-strap Use Case](#1-caddyfile-syntax-for-every-dev-strap-use-case)
   - [1a. HTTP Reverse Proxy](#1a-http-reverse-proxy)
   - [1b. FastCGI Proxy (PHP-FPM)](#1b-fastcgi-proxy-php-fpm)
   - [1c. WebSocket Proxying](#1c-websocket-proxying)
   - [1d. gRPC Proxying](#1d-grpc-proxying)
   - [1e. TLS with Custom Certificates](#1e-tls-with-custom-certificates)
   - [1f. Dynamic Header Injection](#1f-dynamic-header-injection)
   - [1g. SNI-Based Routing](#1g-sni-based-routing)
2. [Caddy Docker Image](#2-caddy-docker-image)
3. [Caddy vs nginx Feature-by-Feature](#3-caddy-vs-nginx-feature-by-feature)
4. [Caddy Limitations and Gotchas](#4-caddy-limitations-and-gotchas)
5. [Caddy Cert Handling](#5-caddy-cert-handling)
6. [Complete dev-strap Caddyfile Examples](#6-complete-dev-strap-caddyfile-examples)
7. [Sources](#7-sources)

---

## 1. Caddyfile Syntax for Every dev-strap Use Case

### 1a. HTTP Reverse Proxy

#### Basic reverse proxy to a backend on port 3000

```
localhost {
    reverse_proxy app:3000
}
```

That is the entire config. One line of routing.

#### Header forwarding -- what Caddy adds automatically

Caddy's `reverse_proxy` automatically adds the following headers on every proxied request:

| Header | Caddy Behavior | nginx Equivalent |
|--------|---------------|-----------------|
| `X-Forwarded-For` | **Automatic** -- sets or augments with the client's IP | `proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;` |
| `X-Forwarded-Proto` | **Automatic** -- set to `http` or `https` | `proxy_set_header X-Forwarded-Proto $scheme;` |
| `X-Forwarded-Host` | **Automatic** -- set to the original Host header value | `proxy_set_header Host $host;` (not exactly the same) |
| `X-Real-IP` | **NOT automatic** -- must be set manually if needed | `proxy_set_header X-Real-IP $remote_addr;` |

To add `X-Real-IP` manually (if the upstream app requires it):

```
localhost {
    reverse_proxy app:3000 {
        header_up X-Real-IP {http.request.remote.host}
    }
}
```

**Key finding**: Three of the four standard proxy headers that require explicit configuration in nginx are automatic in Caddy. The `X-Real-IP` header is less commonly needed because `X-Forwarded-For` carries the same information and is the standard.

#### Security: incoming header spoofing prevention

By default, Caddy **ignores** incoming values of `X-Forwarded-*` headers from client requests, preventing spoofing. If Caddy is behind another proxy (CDN, load balancer), configure `trusted_proxies` in the global `servers` option to accept forwarded headers from known upstream proxies:

```
{
    servers {
        trusted_proxies static 10.0.0.0/8 172.16.0.0/12
    }
}
```

For dev-strap, this is not needed -- Caddy is the first (and only) proxy.

#### Equivalent nginx config (for comparison)

What takes 7 lines in nginx:
```nginx
location / {
    proxy_pass http://app:3000;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_read_timeout 300;
}
```

Becomes 1 line in Caddy:
```
reverse_proxy app:3000
```

---

### 1b. FastCGI Proxy (PHP-FPM)

#### Basic php_fastcgi directive

```
localhost {
    root * /var/www/html/public
    php_fastcgi app:9000
    file_server
}
```

This three-line block replaces the following nginx configuration (12+ lines):

```nginx
root /var/www/html/public;
index index.html index.htm index.php;

location / {
    try_files $uri $uri/ /index.php?$query_string;
}

location ~ \.php$ {
    fastcgi_pass app:9000;
    fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
    include fastcgi_params;
    fastcgi_read_timeout 300;
    fastcgi_send_timeout 300;
}
```

#### What php_fastcgi expands to

The `php_fastcgi app:9000` directive is syntactic sugar. It expands to a `route` block containing:

1. **Path canonicalization**: A matcher (`@canonicalPath`) that redirects directory requests missing a trailing slash (308 redirect).

2. **File matching and rewriting**: A `try_files` check using `{path} {path}/index.php index.php` with `split_path .php`. This:
   - First checks if `{path}` is a real file on disk (serves it directly -- CSS, JS, images)
   - Then checks if `{path}/index.php` exists (directory with index)
   - Falls back to `index.php` (the front controller -- Laravel's `public/index.php`)

3. **FastCGI transport**: A `reverse_proxy` with the FastCGI transport to the specified upstream.

This default expansion handles the `try_files $uri $uri/ /index.php?$query_string` pattern that Laravel requires, without any additional configuration.

#### Does it handle try_files equivalent?

**Yes, by default.** The default `try_files` behavior matches exactly what Laravel needs:
- Static files served directly (CSS, JS, images, fonts)
- All other requests routed to `index.php` (Laravel's front controller)

To override the default `try_files` behavior:

```
php_fastcgi app:9000 {
    try_files {path} {path}/index.php =404
}
```

This variant returns a 404 instead of falling back to `index.php` for missing files.

#### Static file serving alongside PHP

The `file_server` directive after `php_fastcgi` handles static file serving. The expanded form of `php_fastcgi` already tries to serve static files first (before falling through to PHP), so the `file_server` at the end acts as the final handler for anything `php_fastcgi` did not match.

For a complete Laravel setup:

```
localhost {
    root * /var/www/html/public
    php_fastcgi app:9000
    encode gzip zstd
    file_server
}
```

#### Configurable subdirectives

| Subdirective | Purpose | Default |
|-------------|---------|---------|
| `root` | Override the file root (useful when PHP-FPM root differs from Caddy root) | Inherits from `root` directive |
| `index` | Filename to treat as directory index | `index.php` |
| `try_files` | Override the file search order | `{path} {path}/index.php index.php` |
| `split` | Substring for splitting path info from the path | `.php` |
| `env` | Set extra FastCGI environment variables | (none) |
| `resolve_root_symlink` | Resolve symlinks in the root path | `false` |
| `dial_timeout` | Timeout connecting to the upstream socket | `3s` |
| `read_timeout` | Timeout reading from the FastCGI upstream | no timeout |
| `write_timeout` | Timeout writing to the FastCGI upstream | no timeout |
| `capture_stderr` | Capture stderr output from PHP-FPM | `false` |

#### dev-strap implication

The current nginx generator needs 20+ lines for PHP-FPM configuration (the `location ~ \.php$` block, `fastcgi_params`, `try_files`, `SCRIPT_FILENAME`). Caddy replaces all of that with a single `php_fastcgi app:9000` directive that handles the same semantics by default. This is the single biggest line-count reduction in the migration.

---

### 1c. WebSocket Proxying

#### Is it truly automatic?

**Yes.** WebSocket proxying works out of the box with `reverse_proxy`. No additional configuration is needed.

```
localhost {
    reverse_proxy app:3000
}
```

This single line handles both HTTP and WebSocket connections. Caddy detects the HTTP Upgrade request, performs the upgrade, and transitions the connection to a bidirectional tunnel.

**Contrast with nginx**, which requires explicit upgrade header handling:

```nginx
proxy_http_version 1.1;
proxy_set_header Upgrade $http_upgrade;
proxy_set_header Connection "upgrade";
```

These three nginx lines are completely unnecessary in Caddy.

#### Long-lived connections

For WebSocket connections that should persist across config reloads:

```
localhost {
    reverse_proxy app:3000 {
        stream_close_delay 5m
    }
}
```

Without `stream_close_delay`, WebSocket connections are forcibly closed (with a Close control frame sent to both sides) when Caddy reloads its configuration. Setting a delay allows existing connections to remain open for the specified duration during a reload.

For very long-lived connections (e.g., persistent dashboard connections in dev):

```
reverse_proxy app:3000 {
    stream_timeout 24h
    stream_close_delay 30s
}
```

| Option | Purpose | Default |
|--------|---------|---------|
| `stream_timeout` | Force-close streaming connections after this duration | no timeout |
| `stream_close_delay` | Keep connections open during config reload for this duration | `0` (close immediately) |

#### dev-strap implication

The current nginx generator has a WebSocket upgrade block in the non-PHP app server block but NOT in the PHP server block (since PHP-FPM does not typically use WebSocket). With Caddy, WebSocket support is always available regardless of app type -- no conditional generation needed.

---

### 1d. gRPC Proxying

#### Does reverse_proxy handle gRPC automatically?

**Mostly yes**, but gRPC requires HTTP/2, and if the backend speaks cleartext HTTP/2 (h2c -- the common case in development), you need to tell Caddy to use h2c transport.

#### Basic gRPC reverse proxy

```
localhost {
    reverse_proxy h2c://app:50051
}
```

The `h2c://` scheme prefix tells Caddy to use cleartext HTTP/2 to the backend. This is the typical dev setup where gRPC backends do not use TLS internally.

#### gRPC with streaming support

For streaming RPCs (server-streaming, client-streaming, bidirectional), add `flush_interval -1` to disable response buffering:

```
localhost {
    reverse_proxy h2c://app:50051 {
        flush_interval -1
        transport http {
            versions h2c
        }
    }
}
```

`flush_interval -1` enables "low-latency mode" -- responses are flushed to the client immediately after each write from the upstream, which is critical for streaming RPCs.

#### gRPC with TLS to upstream

If the gRPC backend uses TLS:

```
localhost {
    reverse_proxy https://app:50051 {
        transport http {
            versions 2
            tls_server_name app
        }
    }
}
```

#### Known gRPC considerations

1. **Streaming RPC order-of-operations**: There are known edge cases where Caddy may not properly handle streaming requests if the client reads response headers before finishing sending its request. This is common in gRPC metadata flows. For standard unary and simple streaming RPCs, Caddy works well. For complex bidirectional streaming patterns, test thoroughly.

2. **Timeout configuration**: For long-running streams, disable or extend timeouts:
   ```
   reverse_proxy h2c://app:50051 {
       flush_interval -1
       transport http {
           versions h2c
           read_timeout 0
           write_timeout 0
       }
   }
   ```

3. **gRPC-Web**: Caddy handles gRPC-Web (browser clients that use HTTP/1.1 POST with base64-encoded protobuf) via standard reverse proxy. If both gRPC and gRPC-Web need to go to the same backend multiplexer (like `grpcwebproxy`), ensure the backend handles protocol detection.

#### Contrast with nginx

nginx requires a separate `grpc_pass` directive (distinct from `proxy_pass`) and HTTP/2 must be explicitly enabled on the `listen` directive:

```nginx
listen 443 ssl http2;
location / {
    grpc_pass grpc://app:50051;
}
```

Caddy unifies all protocols under `reverse_proxy`.

#### dev-strap implication

When gRPC app templates are added, the Caddyfile generator needs zero changes. The existing `reverse_proxy` directive handles gRPC the same way it handles HTTP. The only difference is using `h2c://` as the scheme. This can be a simple `APP_TYPE` check:

```bash
if [ "${APP_TYPE}" = "go-grpc" ]; then
    echo "    reverse_proxy h2c://app:50051"
else
    echo "    reverse_proxy app:3000"
fi
```

No separate `grpc_pass` directive, no HTTP/2 listen directive, no protocol-specific blocks.

---

### 1e. TLS with Custom Certificates

#### Basic syntax

```
localhost {
    tls /certs/server.crt /certs/server.key
    reverse_proxy app:3000
}
```

Both file paths are required. Both must be PEM-encoded. The cert file can (and should) be a bundle: server certificate followed by any intermediate CA certificates.

#### Can different site blocks use different certs?

**Yes.** Each site block has its own `tls` directive:

```
localhost {
    tls /certs/app.crt /certs/app.key
    reverse_proxy app:3000
}

api.stripe.com {
    tls /certs/mock.crt /certs/mock.key
    reverse_proxy wiremock:8080
}
```

For dev-strap, the same cert covers all domains (SANs), so the same cert/key paths appear in every site block.

#### Can one cert cover multiple SANs?

**Yes.** This is exactly how dev-strap works. The cert-gen container produces a single `server.crt` with SANs for:
- `localhost`
- `${PROJECT_NAME}.local`
- All mocked domains (`api.stripe.com`, `api.sendgrid.com`, etc.)

All site blocks reference the same cert/key pair. Caddy matches the incoming SNI against the SANs in the loaded cert.

#### Does Caddy try to auto-manage certs when you provide your own?

**No.** When you specify `tls cert_file key_file`, Caddy treats those as manually loaded certificates and disables automatic HTTPS (ACME) for that site block. From the documentation: "Manually loading certificates (unless `ignore_loaded_certificates` is set)" prevents automatic HTTPS activation.

However, to be absolutely safe and prevent any ACME attempts (especially for non-public domain names like `api.stripe.com` that could never be validated via ACME), set the global option:

```
{
    auto_https off
}
```

This disables:
- ACME certificate management for all site blocks
- HTTP-to-HTTPS redirects

Since dev-strap provides its own certs for all site blocks, `auto_https off` is the correct setting.

#### TLS protocol and cipher configuration

```
localhost {
    tls /certs/server.crt /certs/server.key {
        protocols tls1.2 tls1.3
        ciphers TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256 TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384
    }
}
```

Defaults are already secure: TLS 1.2 minimum, TLS 1.3 maximum. The documentation explicitly warns "DO NOT change these unless you know what you're doing." For dev-strap, the defaults are fine.

#### What happens if cert files don't exist at startup?

**Caddy fails during provisioning.** If the cert file does not exist, Caddy returns an error like `open cert_notexist.pem: no such file or directory` during the provisioning phase and **does not start**.

This is important for dev-strap because the cert-gen container must finish before Caddy starts. In Docker Compose, this is handled with `depends_on` and health checks:

```yaml
services:
  cert-gen:
    # ... generates certs
    healthcheck:
      test: ["CMD", "test", "-f", "/certs/server.crt"]
      interval: 2s
      retries: 10

  web:
    image: caddy:2-alpine
    depends_on:
      cert-gen:
        condition: service_healthy
    volumes:
      - certs:/certs:ro
```

This is the same pattern currently used with nginx. No change needed.

---

### 1f. Dynamic Header Injection

#### X-Original-Host header for mock interception

```
api.stripe.com, api.sendgrid.com {
    tls /certs/server.crt /certs/server.key

    reverse_proxy wiremock:8080 {
        header_up X-Original-Host {http.request.host}
    }
}
```

**Confirmed working.** The `{http.request.host}` placeholder resolves to the Host header value of the incoming request (e.g., `api.stripe.com`). This is a runtime value, not a static string -- exactly what mock interception needs.

#### header_up syntax

The `header_up` subdirective within `reverse_proxy` modifies **request** headers sent to the upstream:

```
reverse_proxy backend:8080 {
    # Set (overwrite) a header
    header_up X-Custom "value"

    # Set a header using a placeholder
    header_up X-Original-Host {http.request.host}

    # Add a header (does not overwrite existing)
    header_up +X-Extra "additional-value"

    # Delete a header
    header_up -X-Unwanted

    # Regex replacement
    header_up Authorization "^Bearer (.*)$" "Token $1"
}
```

The `header_down` subdirective modifies **response** headers coming back from the upstream:

```
reverse_proxy backend:8080 {
    header_down -Server
    header_down +X-Frame-Options "DENY"
}
```

#### Available placeholders

| Placeholder | Description | nginx Equivalent |
|------------|-------------|-----------------|
| `{http.request.host}` | Host header value (without port) | `$host` |
| `{http.request.hostport}` | Host header value with port | `$http_host` |
| `{http.request.method}` | HTTP method (GET, POST, etc.) | `$request_method` |
| `{http.request.scheme}` | `http` or `https` | `$scheme` |
| `{http.request.uri}` | Full URI (path + query) | `$request_uri` |
| `{http.request.uri.path}` | Path component only | `$uri` |
| `{http.request.uri.query}` | Query string only | `$query_string` |
| `{http.request.remote}` | Client address (IP:port) | `$remote_addr:$remote_port` |
| `{http.request.remote.host}` | Client IP only | `$remote_addr` |
| `{http.request.remote.port}` | Client port only | `$remote_port` |
| `{http.request.proto}` | Protocol (HTTP/1.1, HTTP/2) | `$server_protocol` |
| `{http.request.header.NAME}` | Any request header value | `$http_name` |
| `{http.request.orig_uri}` | Original URI before rewrites | `$request_uri` |
| `{http.request.orig_uri.path}` | Original path before rewrites | (none) |

#### Conditional headers

Headers can be set conditionally using matchers:

```
localhost {
    @api path /api/*
    reverse_proxy @api backend:8080 {
        header_up X-API-Request "true"
    }

    reverse_proxy frontend:3000
}
```

Or using `handle` blocks for conditional routing:

```
localhost {
    handle /api/* {
        reverse_proxy backend:8080 {
            header_up X-API-Request "true"
        }
    }
    handle {
        reverse_proxy frontend:3000
    }
}
```

For response headers, use `@matcher` syntax with response matchers:

```
header @ok status 2xx {
    X-Cache-Status "HIT"
}
```

Caddy also supports CEL (Common Expression Language) expressions for complex matching:

```
@complex expression `{http.request.method} == "POST" && path("/api/*")`
```

#### dev-strap implication

The `{http.request.host}` placeholder replaces nginx's `$host` variable. Mock interception header injection works identically:

| Feature | nginx | Caddy |
|---------|-------|-------|
| Set X-Original-Host | `proxy_set_header X-Original-Host $host;` | `header_up X-Original-Host {http.request.host}` |
| Set X-Forwarded-Proto | `proxy_set_header X-Forwarded-Proto $scheme;` | *Automatic* |
| Set X-Forwarded-For | `proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;` | *Automatic* |

---

### 1g. SNI-Based Routing

#### How mock interception routing works

Mock interception routes based on the **hostname** in the incoming request. In Caddy, this is handled naturally by having separate site blocks for different domains:

```
# Route to app
localhost, myapp.local {
    reverse_proxy app:3000
}

# Route to WireMock (mock interception)
api.stripe.com, api.sendgrid.com {
    reverse_proxy wiremock:8080
}
```

Caddy matches the incoming TLS SNI (for HTTPS) or Host header (for HTTP) against the site addresses. Each site block handles its own TLS termination and routing. This is functionally equivalent to nginx's separate `server` blocks with different `server_name` directives.

#### Does Caddy support true SNI-based routing (Layer 4)?

For HTTP-level routing (Layer 7), Caddy's native site block matching is sufficient and is what dev-strap needs. Caddy matches the SNI value from the TLS ClientHello against site block addresses.

For TCP-level SNI routing (Layer 4 -- routing without terminating TLS), Caddy requires the community `caddy-l4` module (github.com/mholt/caddy-l4). This module enables raw TCP/UDP routing based on TLS SNI:

```
{
    layer4 {
        :443 {
            @backend1 tls sni app1.example.com
            route @backend1 {
                proxy backend1:443
            }

            @backend2 tls sni app2.example.com
            route @backend2 {
                proxy backend2:443
            }
        }
    }
}
```

**dev-strap does NOT need Layer 4 routing.** The mock interception pattern terminates TLS at Caddy (to inject headers and route to WireMock over plain HTTP). Layer 7 site-block routing covers this use case completely.

---

## 2. Caddy Docker Image

### Image details

| Property | Value |
|----------|-------|
| Image | `caddy:2-alpine` |
| Base | Alpine Linux (~5MB base) |
| Total compressed size | ~16MB (compressed download) |
| Architecture | `amd64`, `arm64`, `arm/v6`, `arm/v7` |
| Caddy binary | Single static Go binary, no dependencies |
| Shell | `/bin/sh` (Alpine -- no bash) |

**Note**: `curl` is NOT included in the Caddy Alpine image. For health checks, use `wget` (included in Alpine) or the Caddy binary itself.

### Mounting a custom Caddyfile

```yaml
web:
  image: caddy:2-alpine
  volumes:
    - ./Caddyfile:/etc/caddy/Caddyfile:ro
    - caddy_data:/data
    - caddy_config:/config
```

Key paths inside the container:

| Path | Purpose | Persist? |
|------|---------|----------|
| `/etc/caddy/Caddyfile` | Configuration file | Mount from host |
| `/data` (or `/data/caddy`) | TLS certs, OCSP staples, runtime state | Yes (volume) |
| `/config` (or `/config/caddy`) | Last known good config (auto-save) | Yes (volume) |

For dev-strap, `/data` and `/config` persistence is not critical (certs are provided externally, not auto-managed). They can be left as anonymous volumes or omitted.

### Health check options

Caddy does not have a dedicated built-in health endpoint (like `/healthz`), but several approaches work:

**Option 1: wget against the server itself (recommended for dev-strap)**

```yaml
healthcheck:
  test: ["CMD", "wget", "--spider", "-q", "http://127.0.0.1:80/"]
  interval: 5s
  timeout: 3s
  retries: 20
```

**Option 2: Use Caddy's respond directive to create a health endpoint**

In the Caddyfile:
```
localhost {
    handle /health {
        respond "OK" 200
    }
    reverse_proxy app:3000
}
```

Then in Docker Compose:
```yaml
healthcheck:
  test: ["CMD", "wget", "--spider", "-q", "http://127.0.0.1:80/health"]
  interval: 5s
  timeout: 3s
  retries: 10
```

**Option 3: Check the admin API**

```yaml
healthcheck:
  test: ["CMD", "wget", "--spider", "-q", "http://127.0.0.1:2019/config/"]
  interval: 5s
  timeout: 3s
  retries: 10
```

### Config reload without restart

Caddy supports three reload mechanisms:

#### 1. CLI reload (recommended for Docker)

```bash
docker compose exec -w /etc/caddy web caddy reload
```

This reads the Caddyfile at `/etc/caddy/Caddyfile`, adapts it to JSON, and sends it to the admin API. Zero-downtime -- existing connections are preserved.

#### 2. Admin API reload

```bash
# Reload with JSON config
curl localhost:2019/load \
  -H "Content-Type: application/json" \
  -d @caddy.json

# Reload with Caddyfile format
curl localhost:2019/load \
  -H "Content-Type: text/caddyfile" \
  --data-binary @Caddyfile
```

The admin API listens on `localhost:2019` by default. This can be changed via the `CADDY_ADMIN` environment variable or the `admin` global option.

#### 3. Force reload (even if config unchanged)

```bash
curl localhost:2019/load \
  -H "Content-Type: text/caddyfile" \
  -H "Cache-Control: must-revalidate" \
  --data-binary @Caddyfile
```

#### Admin API endpoints

| Endpoint | Method | Purpose |
|----------|--------|---------|
| `/load` | POST | Replace entire config (zero-downtime) |
| `/stop` | POST | Gracefully shut down the server |
| `/config/` | GET | Export current config |
| `/config/[path]` | POST/PUT/PATCH/DELETE | Modify specific config sections |
| `/adapt` | POST | Convert config to JSON without loading |
| `/pki/ca/<id>` | GET | Get PKI CA info |
| `/reverse_proxy/upstreams` | GET | Check upstream backend status |

#### Disabling the admin API

If the admin API is not needed (security concern or simplicity):

```
{
    admin off
}
```

This disables config reloads entirely -- the server must be restarted to apply config changes. For dev-strap, keeping the admin API enabled is useful for the `caddy reload` command but exposing port 2019 to the host is unnecessary.

### dev-strap Docker Compose service definition

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
  depends_on:
    cert-gen:
      condition: service_healthy
  healthcheck:
    test: ["CMD", "wget", "--spider", "-q", "http://127.0.0.1:80/"]
    interval: 5s
    timeout: 3s
    retries: 20
  networks:
    ${PROJECT_NAME}-internal:
      aliases:
        - ${PROJECT_NAME}.local
        # ... all mocked domain aliases
```

---

## 3. Caddy vs nginx Feature-by-Feature

### 3.1 Protocol Support

| Protocol | nginx | Caddy v2 | Notes |
|----------|-------|----------|-------|
| HTTP/1.1 reverse proxy | Yes (`proxy_pass`) | Yes (`reverse_proxy`) | Equivalent |
| HTTP/2 to clients | Yes (`listen ... http2`) | Yes (automatic) | Caddy enables by default |
| HTTP/2 to upstream (h2c) | Limited | Yes (`h2c://` scheme) | Caddy is simpler |
| HTTP/3 (QUIC) | Experimental | Yes (built-in) | Caddy ahead |
| WebSocket | Yes (manual headers) | Yes (automatic) | Caddy eliminates 3 lines of boilerplate |
| gRPC | Yes (`grpc_pass`) | Yes (`reverse_proxy h2c://`) | Caddy uses unified directive |
| FastCGI (PHP-FPM) | Yes (`fastcgi_pass`) | Yes (`php_fastcgi`) | Both work; Caddy is more concise |
| TCP/UDP raw proxy | Yes (stream module) | No (requires `caddy-l4` plugin) | nginx ahead for raw TCP |
| TLS termination | Yes | Yes | Equivalent |
| TLS passthrough (SNI) | Yes (stream + SNI) | Plugin only (`caddy-l4`) | nginx ahead |

### 3.2 TLS Configuration

| Aspect | nginx | Caddy v2 |
|--------|-------|----------|
| Custom cert files | `ssl_certificate /path;` + `ssl_certificate_key /path;` | `tls /cert /key` |
| Lines of config for TLS | 4-6 (`ssl_certificate`, `ssl_certificate_key`, `ssl_protocols`, `ssl_ciphers`) | 1 (`tls /cert /key`) -- secure defaults |
| Auto-HTTPS (ACME) | Requires certbot | Built-in (on by default) |
| Internal CA | Not possible | Built-in (`tls internal`, PKI app) |
| Per-site certs | Separate `server` blocks | Separate site blocks (same) |
| Default protocols | Must specify (`TLSv1.2 TLSv1.3`) | TLS 1.2 + 1.3 by default |
| Default ciphers | Must specify (`HIGH:!aNULL:!MD5`) | Secure defaults, no config needed |

### 3.3 Header Manipulation

| Aspect | nginx | Caddy v2 |
|--------|-------|----------|
| Set upstream request header | `proxy_set_header Name value;` | `header_up Name value` |
| Dynamic host value | `$host`, `$remote_addr`, etc. | `{http.request.host}`, `{http.request.remote.host}`, etc. |
| Remove response header | `proxy_hide_header Name;` | `header_down -Name` |
| Add response header | `add_header Name value;` | `header Name value` or `header_down +Name value` |
| Conditional headers | Requires `if` or `map` (fragile) | Matcher syntax `@name` (clean) |
| Auto-added proxy headers | None (all manual) | `X-Forwarded-For`, `X-Forwarded-Proto`, `X-Forwarded-Host` |

### 3.4 Config Syntax Verbosity

Side-by-side comparison for a dev-strap-equivalent config (reverse proxy + mock interception):

**nginx**: ~80 lines

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
        server_name localhost myapp.local;

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
    }

    server {
        listen 443 ssl;
        server_name api.stripe.com api.sendgrid.com;

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

**Caddy**: ~20 lines

```
{
    auto_https off
}

localhost:80, localhost:443, myapp.local:80, myapp.local:443 {
    tls /certs/server.crt /certs/server.key
    reverse_proxy app:3000
}

api.stripe.com:443, api.sendgrid.com:443 {
    tls /certs/server.crt /certs/server.key
    reverse_proxy wiremock:8080 {
        header_up X-Original-Host {http.request.host}
    }
}
```

**Reduction: ~80 lines to ~20 lines (75% less).**

The Caddy version is not just shorter -- it is also more readable. Every line has clear purpose. There is no boilerplate (`worker_processes`, `events`, `http`, `sendfile`, `keepalive_timeout`, `mime.types`).

### 3.5 Operational Characteristics

| Aspect | nginx | Caddy v2 |
|--------|-------|----------|
| Hot reload | `nginx -s reload` (zero-downtime) | `caddy reload` (zero-downtime) |
| Config validation | `nginx -t` | `caddy validate` / `caddy adapt` |
| Docker image size | ~12MB (`nginx:alpine-slim`) | ~16MB (`caddy:2-alpine`) |
| Memory at idle | ~2-5MB | ~15-25MB |
| Memory under dev load | ~10-20MB | ~25-40MB |
| Startup time | <1 second | <1 second |
| Throughput (req/s) | ~100K | ~85K |
| Written in | C | Go |
| Binary | Multiple files + modules | Single static binary |
| Config watch / auto-reload | No (manual signal) | Via admin API |
| Error messages | Cryptic (`upstream prematurely closed connection`) | Structured JSON logs with context |
| Log format | Custom format string (not structured) | Structured JSON (default), configurable |
| Directive ordering | Matters (location matching is complex) | Explicit ordering with `handle` blocks |

### 3.6 Community and Ecosystem

| Aspect | nginx | Caddy v2 |
|--------|-------|----------|
| GitHub stars | ~26K (nginx/nginx) | ~61K (caddyserver/caddy) |
| First release | 2004 | 2015 (v1), 2020 (v2) |
| Maintainer | F5/NGINX Inc. | Ardan Labs / Matt Holt |
| License | BSD 2-clause | Apache 2.0 |
| Plugin ecosystem | Extensive (C modules) | Growing (Go modules, `xcaddy` builder) |
| Stack Overflow questions | ~65K | ~2K |
| Docker Hub pulls | 1B+ | 500M+ |
| Developer familiarity | Very high | Medium (growing) |

**Key finding on community**: nginx has more Stack Overflow answers and general documentation because it has been around for 20+ years. Caddy has more GitHub stars (indicating strong developer interest) and excellent official documentation. For dev-strap's use cases, Caddy's official docs cover everything needed.

---

## 4. Caddy Limitations and Gotchas

### 4.1 Does php_fastcgi work with ALL PHP-FPM setups?

**Yes, with caveats**:

- Works with TCP connections (`app:9000`) and Unix sockets (`unix//var/run/php-fpm.sock`)
- The root path inside Caddy must match the root path inside PHP-FPM. If PHP-FPM is in a separate container (as in dev-strap), the `root` directive in Caddy points to files on Caddy's filesystem. If Caddy does not have access to the PHP source files (because they are only in the PHP-FPM container), the `try_files` file-existence check will fail.

**dev-strap solution**: Mount the app source code into both the PHP-FPM container and the Caddy container at the same path (`/var/www/html`). This is the same approach currently used with nginx.

```yaml
web:
  image: caddy:2-alpine
  volumes:
    - app-source:/var/www/html:ro   # Same mount as PHP-FPM
    - ./Caddyfile:/etc/caddy/Caddyfile:ro
    - certs:/certs:ro
```

- The `dial_timeout` default of 3 seconds is usually fine, but if PHP-FPM takes longer to start, increase it:
  ```
  php_fastcgi app:9000 {
      dial_timeout 10s
  }
  ```

### 4.2 Docker networking gotchas

1. **Container name resolution**: Caddy resolves upstream hostnames (e.g., `app`, `wiremock`) via Docker's internal DNS. The containers must be on the same Docker network. This is identical to nginx behavior.

2. **Network aliases**: DNS aliases (for mock interception) work the same way with Caddy as with nginx. The `web` service gets network aliases for all mocked domains, and Docker DNS resolves those domain names to the Caddy container's IP.

3. **No Docker socket needed**: Unlike Traefik, Caddy does not need access to `/var/run/docker.sock`. It uses a static Caddyfile, not Docker labels. This is simpler and more secure.

4. **caddy-docker-proxy**: The community `caddy-docker-proxy` plugin adds Docker-labels-based configuration (similar to Traefik). dev-strap does NOT need this -- the Caddyfile generator approach is simpler and more predictable.

### 4.3 Performance differences from nginx

For a development environment, performance differences are negligible:

| Metric | nginx | Caddy | Impact on Dev |
|--------|-------|-------|--------------|
| Throughput | ~100K req/s | ~85K req/s | Irrelevant (dev traffic is <100 req/s) |
| Latency | ~0.5ms | ~0.7ms | Imperceptible |
| Memory (idle) | ~3MB | ~20MB | Noise (app uses 100-500MB) |
| Memory (load) | ~15MB | ~35MB | Noise |
| Image download | ~12MB | ~16MB | 4MB difference, one-time |
| Startup | <1s | <1s | Identical |

The performance gap narrows in recent benchmarks (2025). Caddy has improved significantly since early versions. For high-traffic production (10K+ req/s), nginx has measurable advantages. For development environments with single-digit concurrent users, the difference is literally unmeasurable.

### 4.4 Can Caddy listen on port 80 and 443 in the same site block?

**Yes.** Use multiple addresses in the site block:

```
localhost:80, localhost:443 {
    tls /certs/server.crt /certs/server.key
    reverse_proxy app:3000
}
```

With `auto_https off`, Caddy does not automatically redirect HTTP to HTTPS. Both ports serve traffic independently. The `tls` directive applies only to the HTTPS listener (port 443); port 80 connections are plain HTTP.

This is exactly what dev-strap needs: both HTTP and HTTPS access to the app, no forced redirect.

### 4.5 What happens if a cert file doesn't exist at startup?

**Caddy refuses to start.** It fails during the provisioning phase with an error like:

```
Error: loading initial config: loading new config: setting up config: adapting config using caddyfile: provision tls: open /certs/server.crt: no such file or directory
```

This is a hard failure, not a warning. Caddy will not start in a degraded mode with missing certs.

**Mitigation for dev-strap**: Use `depends_on` with `condition: service_healthy` in Docker Compose to ensure the cert-gen container has finished before Caddy starts. This is the same pattern already used with nginx.

**Alternative**: If startup order is hard to guarantee, Caddy could use `tls internal` (its own internal CA) instead of external cert files. This eliminates the cert-gen dependency entirely. See [Section 5](#5-caddy-cert-handling) for details.

### 4.6 Does Caddy's auto-HTTPS interfere when you provide manual certs?

**Not if configured correctly.** Two approaches:

1. **Per-site `tls` directive**: When you specify `tls cert_file key_file`, Caddy automatically disables ACME for that site. No global option needed.

2. **Global `auto_https off`**: Disables ACME and HTTP-to-HTTPS redirects for ALL sites. This is the safest option for dev-strap since all sites use manual certs.

The potential gotcha: if you use `auto_https disable_certs` (instead of `off`), there is a known issue (GitHub issue #6148) where Caddy may still attempt ACME management in some edge cases. Use `auto_https off` to be safe.

### 4.7 Logging gotcha

By default, Caddy **does not log individual HTTP requests**. It only logs internal events (startup, errors, config changes). To enable access logging:

```
localhost {
    log {
        output stdout
        format json
    }
    reverse_proxy app:3000
}
```

Or globally:

```
{
    log {
        output stdout
        level INFO
    }
}
```

This differs from nginx, which logs all requests by default to `access.log`. For dev-strap, enabling request logging per-site or globally is recommended for debugging.

### 4.8 Directive ordering

Caddy uses an explicit directive ordering system. The default order works for most cases, but when using `handle` blocks or complex routing, the order of directives matters:

```
# This works (correct order)
localhost {
    root * /var/www/html/public
    php_fastcgi app:9000
    file_server
}

# This does NOT work (file_server before php_fastcgi)
localhost {
    root * /var/www/html/public
    file_server
    php_fastcgi app:9000
}
```

The default directive order is documented and places `reverse_proxy` and `php_fastcgi` before `file_server`. For dev-strap's simple use cases, the default order is correct.

---

## 5. Caddy Cert Handling

### 5.1 Using dev-strap's existing certs

dev-strap currently generates:
- Self-signed CA: `/certs/ca.crt` + `/certs/ca.key`
- Server cert with SANs: `/certs/server.crt`
- Server key: `/certs/server.key`

The cert SANs include: `localhost`, `${PROJECT_NAME}.local`, and all mocked domains.

**Can Caddy use these directly?** Yes. The Caddyfile is straightforward:

```
{
    auto_https off
}

localhost:443, myapp.local:443 {
    tls /certs/server.crt /certs/server.key
    reverse_proxy app:3000
}

api.stripe.com:443 {
    tls /certs/server.crt /certs/server.key
    reverse_proxy wiremock:8080 {
        header_up X-Original-Host {http.request.host}
    }
}
```

No changes to the cert generation process are needed. PEM-encoded cert and key files work directly.

### 5.2 Does Caddy try to replace manual certs with ACME?

**No**, as long as one of these conditions is met:
- The `tls` directive specifies cert/key file paths (per-site disable)
- The global `auto_https off` option is set (global disable)

With `auto_https off`, Caddy will not contact any ACME server (Let's Encrypt, ZeroSSL, or any other). No network requests for certificate management. No DNS validation attempts. This is critical because dev-strap uses non-public domain names (`api.stripe.com` routed to localhost) that could never be validated by a public ACME CA.

### 5.3 Startup timing: certs must exist before Caddy starts

**The cert-gen container must complete before Caddy starts.** Caddy validates cert files during provisioning and fails hard if they are missing.

Docker Compose handles this with the same pattern currently used for nginx:

```yaml
services:
  cert-gen:
    image: ${PROJECT_NAME}-certgen
    volumes:
      - ${PROJECT_NAME}-certs:/certs
    healthcheck:
      test: ["CMD", "test", "-f", "/certs/server.crt"]
      interval: 2s
      timeout: 2s
      retries: 30

  web:
    image: caddy:2-alpine
    depends_on:
      cert-gen:
        condition: service_healthy
    volumes:
      - ${PROJECT_NAME}-certs:/certs:ro
```

### 5.4 Alternative: Could Caddy replace cert-gen entirely?

**Yes -- this is a significant opportunity.** Caddy has a built-in PKI system (powered by Smallstep libraries) that can act as an internal CA and issue certificates automatically.

#### Option A: `tls internal` (simplest)

```
{
    auto_https off
    local_certs
}

localhost:443, myapp.local:443 {
    tls internal
    reverse_proxy app:3000
}

api.stripe.com:443, api.sendgrid.com:443 {
    tls internal
    reverse_proxy wiremock:8080 {
        header_up X-Original-Host {http.request.host}
    }
}
```

What this does:
1. Caddy generates a root CA certificate and key (stored at `/data/caddy/pki/authorities/local/`)
2. Caddy generates an intermediate CA signed by the root
3. For each site block with `tls internal`, Caddy issues a leaf certificate with SANs matching the site addresses
4. Certificates auto-renew before expiry (default leaf lifetime: 12 hours)

The root CA cert is at: `/data/caddy/pki/authorities/local/root.crt`

#### Option B: `tls internal` with custom CA

```
{
    auto_https off
    pki {
        ca local {
            name "dev-strap Local Authority"
            root_cn "dev-strap Root CA"
            intermediate_cn "dev-strap Intermediate"
            intermediate_lifetime 8760h
        }
    }
}
```

This gives dev-strap control over the CA naming and certificate lifetime.

#### What would this eliminate?

| Component | Current (cert-gen) | With Caddy PKI |
|-----------|-------------------|----------------|
| Java-based cert-gen container | Required | **Eliminated** |
| `core/certs/generate.sh` | Required | **Eliminated** |
| `depends_on: cert-gen` | Required | **Eliminated** |
| Shared volume for certs | Required | **Eliminated** |
| Startup ordering complexity | Moderate | **None** |
| Trust store installation | Manual (`ca.crt`) | Manual (`root.crt` from `/data/caddy/pki/`) |

#### What would still need to happen?

The app container needs to trust the CA so outgoing HTTPS requests to mocked domains are accepted. Currently, dev-strap copies `ca.crt` into the app container's trust store. With Caddy PKI, the root cert would need to be extracted from Caddy's data volume and installed in the app container.

This can be done with a startup script or by mounting the Caddy PKI data volume:

```yaml
app:
  volumes:
    - caddy_data:/caddy-data:ro
  environment:
    - NODE_EXTRA_CA_CERTS=/caddy-data/caddy/pki/authorities/local/root.crt
```

Or for Java apps:
```bash
keytool -importcert -file /caddy-data/caddy/pki/authorities/local/root.crt \
  -keystore $JAVA_HOME/lib/security/cacerts -storepass changeit -noprompt
```

#### Recommendation

**Phase 1**: Use existing cert-gen with Caddy (zero migration risk). This is a direct swap of nginx for Caddy with no other changes.

**Phase 2 (future)**: Evaluate replacing cert-gen with Caddy's internal PKI. This eliminates a container, a generator script, and startup ordering complexity. The trade-off is that cert extraction for the app trust store is slightly different.

---

## 6. Complete dev-strap Caddyfile Examples

### 6.1 Node/Express App with Mock Interception

```
# AUTO-GENERATED by devstack -- do not edit manually
{
    auto_https off
    log {
        level WARN
    }
}

# Application server (reverse proxy)
localhost:80, localhost:443, myapp.local:80, myapp.local:443 {
    tls /certs/server.crt /certs/server.key

    reverse_proxy app:3000

    handle_path /test-results/* {
        root * /srv/test-results
        file_server browse
    }
}

# Mock API Proxy -- intercepts HTTPS to mocked external services
api.stripe.com:443, api.sendgrid.com:443, hooks.slack.com:443 {
    tls /certs/server.crt /certs/server.key

    reverse_proxy wiremock:8080 {
        header_up X-Original-Host {http.request.host}
        header_up X-Real-IP {http.request.remote.host}
        header_up X-Forwarded-Proto {http.request.scheme}
    }
}
```

### 6.2 PHP-Laravel App with Mock Interception

```
# AUTO-GENERATED by devstack -- do not edit manually
{
    auto_https off
    log {
        level WARN
    }
}

# Application server (PHP-FPM)
localhost:80, localhost:443, myapp.local:80, myapp.local:443 {
    tls /certs/server.crt /certs/server.key

    root * /var/www/html/public
    php_fastcgi app:9000
    file_server

    handle_path /test-results/* {
        root * /srv/test-results
        file_server browse
    }
}

# Mock API Proxy
api.stripe.com:443, api.sendgrid.com:443 {
    tls /certs/server.crt /certs/server.key

    reverse_proxy wiremock:8080 {
        header_up X-Original-Host {http.request.host}
        header_up X-Real-IP {http.request.remote.host}
        header_up X-Forwarded-Proto {http.request.scheme}
    }
}
```

### 6.3 Go gRPC App with Mock Interception

```
# AUTO-GENERATED by devstack -- do not edit manually
{
    auto_https off
    log {
        level WARN
    }
}

# Application server (gRPC)
localhost:80, localhost:443, myapp.local:80, myapp.local:443 {
    tls /certs/server.crt /certs/server.key

    reverse_proxy h2c://app:50051 {
        flush_interval -1
        transport http {
            versions h2c
        }
    }
}

# Mock API Proxy
api.stripe.com:443 {
    tls /certs/server.crt /certs/server.key

    reverse_proxy wiremock:8080 {
        header_up X-Original-Host {http.request.host}
    }
}
```

### 6.4 Generator Line Count Comparison

| Component | nginx generator | Caddy generator |
|-----------|:---------------:|:---------------:|
| Boilerplate (global settings) | 30 lines | 6 lines |
| App block (HTTP proxy) | 18 lines | 4 lines |
| App block (PHP-FPM) | 22 lines | 5 lines |
| Mock block | 15 lines | 7 lines |
| Domain collection loop | 15 lines | 15 lines (same) |
| Total (HTTP app) | ~78 lines | ~32 lines |
| Total (PHP app) | ~82 lines | ~33 lines |

---

## 7. Sources

### Official Caddy Documentation
- [reverse_proxy (Caddyfile directive)](https://caddyserver.com/docs/caddyfile/directives/reverse_proxy)
- [php_fastcgi (Caddyfile directive)](https://caddyserver.com/docs/caddyfile/directives/php_fastcgi)
- [tls (Caddyfile directive)](https://caddyserver.com/docs/caddyfile/directives/tls)
- [Automatic HTTPS](https://caddyserver.com/docs/automatic-https)
- [Global options (Caddyfile)](https://caddyserver.com/docs/caddyfile/options)
- [API Documentation](https://caddyserver.com/docs/api)
- [Request matchers (Caddyfile)](https://caddyserver.com/docs/caddyfile/matchers)
- [header (Caddyfile directive)](https://caddyserver.com/docs/caddyfile/directives/header)
- [request_header (Caddyfile directive)](https://caddyserver.com/docs/caddyfile/directives/request_header)
- [Common Caddyfile Patterns](https://caddyserver.com/docs/caddyfile/patterns)
- [Reverse proxy quick-start](https://caddyserver.com/docs/quick-starts/reverse-proxy)
- [Placeholder Support](https://caddyserver.com/docs/extending-caddy/placeholders)
- [Layer 4 module](https://caddyserver.com/docs/modules/layer4)

### Community and Ecosystem
- [Caddy Docker Image (Docker Hub)](https://hub.docker.com/_/caddy)
- [caddy-docker source (GitHub)](https://github.com/caddyserver/caddy-docker)
- [caddy-l4 Layer 4 module (GitHub)](https://github.com/mholt/caddy-l4)
- [caddy-docker-proxy (GitHub)](https://github.com/lucaslorentz/caddy-docker-proxy)
- [Caddy Community Forum](https://caddy.community)

### gRPC with Caddy
- [Proxying Streaming gRPC with Caddy 2](https://caddy.community/t/proxying-streaming-grpc-with-caddy-2/11973)
- [Proxying Streaming gRPC with Caddy (Wiki)](https://caddy.community/t/proxying-streaming-grpc-with-caddy/16363)
- [Configuring Caddy as a gRPC reverse proxy](https://vipinpg.com/blog/configuring-caddy-as-a-grpc-reverse-proxy-for-self-hosted-ai-inference-apis-with-automatic-tls-and-load-balancing)
- [TIL: Caddy Reverse Proxy GRPC](https://blag.felixhummel.de/25/10-10-til-caddy-reverse-proxy-grpc.html)

### PHP-FPM with Caddy
- [How to use Caddy Server with PHP (PHP.Watch)](https://php.watch/articles/caddy-php)
- [How to use Caddy with PHP and Docker (BitPress)](https://bitpress.io/caddy-with-docker-and-php/)
- [Example: Docker Laravel (Caddy Community)](https://caddy.community/t/example-docker-laravel/8700)
- [Handling PHP-FPM using Caddy (mwop.net)](https://mwop.net/blog/2025-03-21-caddy-php-fpm.html)
- [Troubleshooting PHP FPM and FastCGI (Caddy Wiki)](https://github.com/caddyserver/caddy/wiki/Troubleshooting-PHP-FPM-and-FastCGI)

### TLS and Certificates
- [Caddy, self-signed certificates and CAs for web development](https://dev.to/migsarnavarro/caddy-self-signed-certificates-and-certificate-authorities-for-web-development-653)
- [Custom CA in Caddy for HTTPS on LAN](https://waitwhat.sh/blog/custom_ca_caddy/)
- [Caddy auto_https disable_certs issue #6148](https://github.com/caddyserver/caddy/issues/6148)
- [How to disable automatic TLS certificate management issue #3013](https://github.com/caddyserver/caddy/issues/3013)
- [Caddy doesn't find my certificate (Community)](https://caddy.community/t/caddy-doesn-t-find-my-certificate-no-such-file-or-directory/15954)

### Headers and Proxying
- [Caddy reverse_proxy + X-Forwarded-For headers (Community)](https://caddy.community/t/caddy-reverse-proxy-x-forwarded-for-headers/26682)
- [How to prevent automatic X-Forwarded-For header issue #3976](https://github.com/caddyserver/caddy/issues/3976)
- [V2: reverse proxy transparency issue #2873](https://github.com/caddyserver/caddy/issues/2873)

### Performance Comparisons
- [Caddy vs Nginx on VPS in 2025 (Onidel)](https://onidel.com/blog/caddy-vs-nginx-vps-2025)
- [Traefik vs Caddy vs nginx Proxy Manager 2026 (SelfHostWise)](https://selfhostwise.com/posts/traefik-vs-caddy-vs-nginx-proxy-manager-which-reverse-proxy-should-you-choose-in-2026/)
- [35 Million Hot Dogs: Benchmarking Caddy vs Nginx (Tyblog)](https://blog.tjll.net/reverse-proxy-hot-dog-eating-contest-caddy-vs-nginx/)
- [Nginx vs Caddy vs Traefik Comparison (ZeonEdge)](https://zeonedge.com/blog/nginx-vs-caddy-vs-traefik-comparison)
- [Ultimate Web Server Benchmark (LinuxConfig)](https://linuxconfig.org/ultimate-web-server-benchmark-apache-nginx-litespeed-openlitespeed-caddy-lighttpd-compared)
- [Caddy vs Nginx RAM and CPU (LowEndTalk)](https://lowendtalk.com/discussion/110280/caddy-vs-nginx-ram-and-cpu-foodprint)

### Layer 4 / SNI Routing
- [Layer 4 Traffic Proxying with Caddy (zhul.in)](https://zhul.in/en/2025/12/10/caddy-traffic-proxy-on-layer-4/)
- [Layer 4 Reverse Proxy with SNI Routing (Medium)](https://medium.com/@panda1100/how-to-setup-layer-4-reverse-proxy-to-multiplex-tls-traffic-with-sni-routing-a226c8168826)

### Docker and Startup
- [Using Caddy with Docker for Production (Medium)](https://medium.com/@shahadathhs/using-caddy-with-docker-for-production-a-practical-guide-c37f6f8f54ee)
- [Docker Compose Local HTTPS with Caddy (CodeWithHugo)](https://codewithhugo.com/docker-compose-local-https/)
- [Caddy in Docker On Private Network (Community)](https://caddy.community/t/caddy-in-docker-on-private-network/20277)
