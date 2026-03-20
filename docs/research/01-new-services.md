# New Services Research: NATS, MinIO, Adminer, Swagger UI, Beaver

> **Date**: 2026-03-20
> **Context**: Research for expanding the dev-strap service catalog. Each service section includes recommended Docker image, ports, environment variables, health checks, volumes, service.yml draft, manifest.json entry draft, compose generator integration notes, and dependency/conflict analysis.
> **Pattern reference**: Existing extras in `templates/extras/{redis,mailpit,prometheus,grafana,dozzle}/service.yml` and the compose generator at `core/compose/generate.sh`.

---

## Table of Contents

1. [NATS (Messaging/Streaming)](#1-nats-messagingstreaming)
2. [MinIO (S3-Compatible Object Storage)](#2-minio-s3-compatible-object-storage)
3. [Adminer (Database UI)](#3-adminer-database-ui)
4. [Swagger UI (API Documentation)](#4-swagger-ui-api-documentation)
5. [Beaver (Identity Research)](#5-beaver-identity-research)
6. [Compose Generator Changes (Shared)](#6-compose-generator-changes-shared)
7. [Volume Registration Strategy](#7-volume-registration-strategy)
8. [Open Questions](#8-open-questions)

---

## 1. NATS (Messaging/Streaming)

### Recommended Image

```
nats:2-alpine
```

**Rationale**: The official `nats` image on Docker Hub. The `2-alpine` tag tracks the latest NATS 2.x release on Alpine Linux, giving a small image (~20 MB). NATS 2.x includes JetStream (persistence/streaming) built in -- it just needs to be enabled via flag. Avoid `latest` to stay on the 2.x major version; NATS 3.x may introduce breaking changes. Alpine variant is consistent with dev-strap's existing use of Alpine images (redis:alpine, nginx:alpine).

### Ports

| Port | Protocol | Purpose | Expose to host? |
|------|----------|---------|-----------------|
| 4222 | TCP | Client connections (NATS protocol) | Yes, via `${NATS_PORT}` |
| 8222 | HTTP | Monitoring/management HTTP endpoint | Yes, via `${NATS_MONITOR_PORT}` |
| 6222 | TCP | Cluster routing (inter-node communication) | No -- single-node dev, not needed |

**Default host ports**: `NATS_PORT=4222`, `NATS_MONITOR_PORT=8222`. These are the canonical NATS ports and unlikely to collide with other dev-strap services. Port 8222 falls in the tooling range (8000-8499) per the catalog proposals doc.

### JetStream Configuration

JetStream is enabled by passing `-js` (or `--jetstream`) to the NATS server command. For dev use with persistence:

```
command: "--jetstream --store_dir /data --http_port 8222"
```

- `--jetstream` enables the JetStream subsystem.
- `--store_dir /data` tells JetStream where to persist stream data. This directory should be backed by a volume.
- `--http_port 8222` enables the HTTP monitoring endpoint (required for health checks and the built-in monitoring page).

No separate configuration file is needed for basic dev use. NATS reads its config from CLI flags or a `nats-server.conf` file. For dev-strap, CLI flags are sufficient and simpler (no supplementary config file to manage, unlike Prometheus which needs `prometheus.yml`).

### Health Check

```yaml
healthcheck:
  test: ["CMD", "wget", "--spider", "-q", "http://127.0.0.1:8222/healthz"]
  interval: 5s
  timeout: 3s
  retries: 10
```

**How it works**: NATS exposes an HTTP monitoring endpoint at port 8222. The `/healthz` endpoint returns 200 when the server is ready. This is the officially recommended health check path. The Alpine image includes `wget` but not `curl`, so `wget --spider` is the right tool (consistent with the pattern used by prometheus and grafana extras).

**Alternative**: `nats-server --signal check` can be used for a process-level check, but the HTTP health check is more reliable because it confirms the server is actually accepting connections.

### Volumes

```yaml
volumes:
  - ${PROJECT_NAME}-nats-data:/data
```

**Purpose**: JetStream persistence. Without a volume, stream data is lost on container restart. Named volume prefixed with `${PROJECT_NAME}` per dev-strap convention (see AI_BOOTSTRAP.md pitfall #9).

**Volume registration**: Must be added to the compose generator's COMPOSE_FOOTER section. See [Section 7](#7-volume-registration-strategy) for the approach.

### How Apps Connect

**Connection string pattern**:
```
nats://nats:4222
```

Inside the Docker network, the service name `nats` resolves to the NATS container. No authentication is configured by default (appropriate for dev). All major NATS client libraries accept this URL format:

| Language | Client Library | Connection Example |
|----------|---------------|-------------------|
| Go | `github.com/nats-io/nats.go` | `nats.Connect("nats://nats:4222")` |
| Node.js | `nats` (npm) | `connect({ servers: "nats://nats:4222" })` |
| Python | `nats-py` | `await nats.connect("nats://nats:4222")` |
| Rust | `async-nats` | `async_nats::connect("nats://nats:4222").await` |
| PHP | `basis-company/nats` | `new Connection("nats://nats:4222")` |

### Environment Variables for Apps

These should be documented for users to add to their app's service.yml:

```yaml
environment:
  - NATS_URL=nats://nats:4222
```

**No new variables in project.env** beyond the port config. The connection URL is deterministic from the service name.

### project.env Variables

```env
NATS_PORT=4222
NATS_MONITOR_PORT=8222
```

### Requires and Conflicts

- **requires**: `["app.*"]` -- NATS is a messaging system; it needs an app to connect to it. Consistent with how `redis` requires `app.*` in the current manifest.
- **conflicts**: None. NATS does not conflict with Redis, Mailpit, or any other service.

### service.yml Draft

```yaml
  nats:
    image: nats:2-alpine
    container_name: ${PROJECT_NAME}-nats
    command: "--jetstream --store_dir /data --http_port 8222"
    ports:
      - "${NATS_PORT}:4222"
      - "${NATS_MONITOR_PORT}:8222"
    volumes:
      - ${PROJECT_NAME}-nats-data:/data
    networks:
      - ${PROJECT_NAME}-internal
    healthcheck:
      test: ["CMD", "wget", "--spider", "-q", "http://127.0.0.1:8222/healthz"]
      interval: 5s
      timeout: 3s
      retries: 10
```

### manifest.json Entry Draft

```json
"nats": {
  "label": "NATS",
  "description": "High-performance messaging with JetStream persistence",
  "defaults": { "client_port": 4222, "monitor_port": 8222 },
  "requires": ["app.*"]
}
```

**Category**: `services` (alongside redis, mailpit).

### Compose Generator Changes

Two new `sed` substitutions needed in the extras processing loop in `core/compose/generate.sh`:

```bash
sed "s|\${NATS_PORT}|${NATS_PORT:-4222}|g" | \
sed "s|\${NATS_MONITOR_PORT}|${NATS_MONITOR_PORT:-8222}|g"
```

A named volume `${PROJECT_NAME}-nats-data` must be conditionally registered (see Section 7).

### Dependencies

- Does NOT need `cert-gen` -- NATS in dev mode runs unencrypted on the internal network.
- Does NOT need the app to be healthy first -- the app connects to NATS, not the other way around. However, the app's `depends_on` should include `nats: condition: service_healthy` if the app requires NATS at startup.

### Monitoring UI

NATS includes a built-in monitoring page at `http://localhost:${NATS_MONITOR_PORT}` (port 8222 by default). This shows:
- Server info and version
- Connection count
- Subscription count
- JetStream stream/consumer status
- Slow consumers
- Routes and gateways

This is a simple status page, not a full management UI. For richer management, `nats-cli` can be installed in the QA container or the app container. The `nats-box` Docker image (`natsio/nats-box`) is another option but adding it as a separate container seems excessive for dev-strap.

---

## 2. MinIO (S3-Compatible Object Storage)

### Recommended Image

```
minio/minio:latest
```

**Rationale**: Official MinIO image from `minio/minio` on Docker Hub. MinIO uses a date-based versioning scheme (e.g., `RELEASE.2025-04-22T22-12-26Z`) rather than semver, making `:latest` the practical choice for dev environments. The image is self-contained (~150 MB) and includes both the server and the `mc` (MinIO Client) CLI tool.

**Note**: The ADDING_SERVICES.md doc already uses `minio/minio:latest` as its example -- this is consistent.

### Ports

| Port | Protocol | Purpose | Expose to host? |
|------|----------|---------|-----------------|
| 9000 | HTTP | S3 API endpoint | Yes, via `${MINIO_API_PORT}` |
| 9001 | HTTP | Console web UI | Yes, via `${MINIO_CONSOLE_PORT}` |

**Default host ports**: `MINIO_API_PORT=9000`, `MINIO_CONSOLE_PORT=9001`.

**Port conflict warning**: Port 9000 is also the default for PHP-FPM (used internally by the `php-laravel` template). However, in dev-strap the PHP-FPM port is only used internally on the Docker network (nginx connects to `app:9000`), so there is no host-port collision. The PHP app's `service.yml` does not expose port 9000 to the host. MinIO's port 9000 is exposed on the host. No actual conflict exists.

### Server Command

```yaml
command: server /data --console-address ":9001"
```

- `server /data` starts the MinIO server with `/data` as the storage directory.
- `--console-address ":9001"` explicitly sets the console UI port. Without this flag, the console binds to a random high port, which breaks the port mapping.

### Default Credentials

```yaml
environment:
  MINIO_ROOT_USER: minioadmin
  MINIO_ROOT_PASSWORD: minioadmin
```

These are MinIO's own defaults. Using them explicitly in the template makes the credentials visible and documented. For dev use, simple credentials are appropriate. These same values are used as AWS Access Key ID / Secret Access Key when connecting via S3-compatible SDKs.

### Health Check

```yaml
healthcheck:
  test: ["CMD", "mc", "ready", "local"]
  interval: 5s
  timeout: 3s
  retries: 10
```

**How it works**: The `mc` (MinIO Client) CLI is included in the MinIO Docker image. `mc ready local` checks whether the local MinIO instance is ready to accept requests. This is the officially recommended health check.

**Alternative**: `curl -f http://localhost:9000/minio/health/live` also works but `mc ready local` is more reliable as it checks full readiness, not just liveness.

### Volumes

```yaml
volumes:
  - ${PROJECT_NAME}-minio-data:/data
```

**Purpose**: Persistent bucket and object storage across container restarts. Without a volume, all uploaded files and bucket configurations are lost.

### How Apps Connect (AWS SDK Compatibility)

MinIO is wire-compatible with the AWS S3 API. Apps connect using standard AWS SDKs with an endpoint override:

| Language | SDK | Configuration |
|----------|-----|--------------|
| Go | `aws-sdk-go-v2` | `EndpointResolverWithOptions` pointing to `http://minio:9000` |
| Node.js | `@aws-sdk/client-s3` | `endpoint: "http://minio:9000"`, `forcePathStyle: true` |
| Python | `boto3` | `endpoint_url="http://minio:9000"` |
| PHP | `aws/aws-sdk-php` | `endpoint => "http://minio:9000"`, `use_path_style_endpoint => true` |

**Critical**: `forcePathStyle: true` (or equivalent) is required. AWS SDKs default to virtual-hosted-style URLs (`bucket.s3.amazonaws.com`), but MinIO in dev uses path-style (`minio:9000/bucket`). Without this setting, DNS resolution fails.

### Environment Variables for Apps

```yaml
environment:
  - AWS_ENDPOINT_URL=http://minio:9000
  - AWS_ACCESS_KEY_ID=minioadmin
  - AWS_SECRET_ACCESS_KEY=minioadmin
  - AWS_DEFAULT_REGION=us-east-1
  - AWS_S3_FORCE_PATH_STYLE=true
```

**Note on `AWS_ENDPOINT_URL`**: This is a relatively new standard env var (supported by AWS SDK v2 for Go, Python boto3, and Node.js SDK v3 since late 2023). It provides a single environment variable that overrides the endpoint for all AWS services. Older SDKs may require per-service endpoint configuration in code.

**Note on region**: MinIO ignores the region, but some SDKs require it to be set. `us-east-1` is the conventional default.

### Console UI

Accessible at `http://localhost:${MINIO_CONSOLE_PORT}` (default: `http://localhost:9001`). Login with `MINIO_ROOT_USER` / `MINIO_ROOT_PASSWORD`. The console provides:
- Bucket creation and browsing
- Object upload/download/delete
- Access policy management
- Server metrics and diagnostics
- User/group management

This is a full-featured web application, not just a status page.

### project.env Variables

```env
MINIO_API_PORT=9000
MINIO_CONSOLE_PORT=9001
```

### Requires and Conflicts

- **requires**: None. MinIO is useful standalone (e.g., for a frontend-only app that needs file uploads). The catalog proposals doc also lists no requirements.
- **conflicts**: None.

### service.yml Draft

```yaml
  minio:
    image: minio/minio:latest
    container_name: ${PROJECT_NAME}-minio
    command: server /data --console-address ":9001"
    ports:
      - "${MINIO_API_PORT}:9000"
      - "${MINIO_CONSOLE_PORT}:9001"
    environment:
      MINIO_ROOT_USER: minioadmin
      MINIO_ROOT_PASSWORD: minioadmin
    volumes:
      - ${PROJECT_NAME}-minio-data:/data
    networks:
      - ${PROJECT_NAME}-internal
    healthcheck:
      test: ["CMD", "mc", "ready", "local"]
      interval: 5s
      timeout: 3s
      retries: 10
```

### manifest.json Entry Draft

```json
"minio": {
  "label": "MinIO",
  "description": "S3-compatible object storage with web console",
  "defaults": { "api_port": 9000, "console_port": 9001 }
}
```

**Category**: `services` (alongside redis, mailpit, nats).

### Compose Generator Changes

Two new `sed` substitutions:

```bash
sed "s|\${MINIO_API_PORT}|${MINIO_API_PORT:-9000}|g" | \
sed "s|\${MINIO_CONSOLE_PORT}|${MINIO_CONSOLE_PORT:-9001}|g"
```

Named volume `${PROJECT_NAME}-minio-data` must be conditionally registered (see Section 7).

### Dependencies

- Does NOT need `cert-gen` -- MinIO runs HTTP on the internal network.
- Does NOT need any other service to be healthy first.
- Apps that need MinIO should add `minio: condition: service_healthy` to their `depends_on`.

---

## 3. Adminer (Database UI)

### Recommended Image

```
adminer:latest
```

**Rationale**: The official `adminer` image on Docker Hub. Adminer is a single-PHP-file database management tool that supports PostgreSQL, MySQL/MariaDB, SQLite, MS SQL, Oracle, and others -- all in one ~500 KB PHP file. This makes it ideal for dev-strap because it works with both `postgres` and `mariadb` database types without needing separate images.

**Why not pgAdmin?** pgAdmin only supports PostgreSQL. Since dev-strap supports both PostgreSQL and MariaDB, Adminer's multi-database support is a significant advantage. pgAdmin is also much heavier (~400 MB image vs ~90 MB for Adminer).

**Why not phpMyAdmin?** phpMyAdmin only supports MySQL/MariaDB. Same single-database limitation as pgAdmin, just for the other side.

**Why not DBeaver?** DBeaver is a desktop application, not a Docker web UI.

### Ports

| Port | Protocol | Purpose | Expose to host? |
|------|----------|---------|-----------------|
| 8080 | HTTP | Web UI (Adminer's default internal port) | Yes, via `${ADMINER_PORT}` mapped to 8080 internal |

**Default host port**: `ADMINER_PORT=8083`. Port 8083 is proposed to avoid conflicts with:
- 8080 (common app dev server port, used by Dozzle internally)
- 8082 (test-dashboard in dev-strap)
- 8025 (Mailpit)

### Auto-Connection to Database

Adminer supports the `ADMINER_DEFAULT_SERVER` environment variable, which pre-fills the "Server" field on the login page:

```yaml
environment:
  ADMINER_DEFAULT_SERVER: db
```

This points to the `db` service in docker-compose (the database container's service name in dev-strap). The user still needs to enter username/password on the login page, but the server field is pre-populated.

**Additional useful env vars**:

| Variable | Value | Purpose |
|----------|-------|---------|
| `ADMINER_DEFAULT_SERVER` | `db` | Pre-fills the server hostname |
| `ADMINER_DESIGN` | `dracula` | UI theme (optional, cosmetic) |
| `ADMINER_PLUGINS` | (empty) | Space-separated list of plugins to load |

**Note**: Adminer auto-detects the database type (PostgreSQL vs MySQL) based on the connection. The user selects the database system from a dropdown on the login page. No additional configuration is needed for this.

### Health Check

```yaml
healthcheck:
  test: ["CMD", "wget", "-qO", "/dev/null", "http://localhost:8080/"]
  interval: 10s
  timeout: 3s
  retries: 5
```

**How it works**: Adminer serves its login page at the root URL. A successful `wget` of `/` confirms PHP is running and Adminer is loaded. The Adminer image is based on PHP's built-in web server (or Apache, depending on the variant). The default tag uses PHP's built-in server on port 8080.

**Note**: Adminer's base image does not include `curl`, but does include `wget` (it's Alpine-based when using the default tag). This is consistent with the pattern used by mailpit (`wget -qO /dev/null`).

### Volumes

None needed. Adminer is stateless -- it connects to the database on each request. No persistent storage required.

### How Apps Connect

Adminer is a developer-facing tool, not an app dependency. Apps do not connect to Adminer. Instead, developers access Adminer from their browser at `http://localhost:${ADMINER_PORT}` and use it to inspect/query the database.

### Support for Both PostgreSQL and MariaDB

Adminer handles this natively. On the login page, users select the database system from a dropdown:
- "MySQL" for MariaDB
- "PostgreSQL" for PostgreSQL

The `ADMINER_DEFAULT_SERVER=db` setting works for both because dev-strap names the database service `db` regardless of type.

Login credentials come from `project.env`:
- Server: `db` (pre-filled by `ADMINER_DEFAULT_SERVER`)
- Username: value of `DB_USER`
- Password: value of `DB_PASSWORD`
- Database: value of `DB_NAME`

### project.env Variables

```env
ADMINER_PORT=8083
```

### Requires and Conflicts

- **requires**: `["database.*"]` -- Adminer is useless without a database. This dependency matches the catalog proposals doc.
- **conflicts**: None.

### service.yml Draft

```yaml
  adminer:
    image: adminer:latest
    container_name: ${PROJECT_NAME}-adminer
    ports:
      - "${ADMINER_PORT}:8080"
    environment:
      ADMINER_DEFAULT_SERVER: db
    depends_on:
      db:
        condition: service_healthy
    networks:
      - ${PROJECT_NAME}-internal
    healthcheck:
      test: ["CMD", "wget", "-qO", "/dev/null", "http://localhost:8080/"]
      interval: 10s
      timeout: 3s
      retries: 5
```

**Note on `depends_on`**: Adminer depends on `db` being healthy. This is a deviation from other extras (redis, mailpit, prometheus) which have no `depends_on`. However, Adminer is genuinely useless until the database is up, and starting it before the DB just produces confusing connection errors on the login page. The `grafana` extra already uses `depends_on` (on prometheus), so this pattern is established.

**Caveat**: The `depends_on: db` means this service will fail to start if `DB_TYPE=none`. The `requires: ["database.*"]` in the manifest prevents this at the selection level, but the compose generator should also guard against including adminer when no database is selected. See Section 6 for details.

### manifest.json Entry Draft

```json
"adminer": {
  "label": "Database UI (Adminer)",
  "description": "Web-based database browser — supports PostgreSQL and MariaDB",
  "defaults": { "port": 8083 },
  "requires": ["database.*"]
}
```

**Category**: `tooling` (alongside qa, qa-dashboard, wiremock, devcontainer). This is a developer tool, not an application service.

### Compose Generator Changes

One new `sed` substitution:

```bash
sed "s|\${ADMINER_PORT}|${ADMINER_PORT:-8083}|g"
```

No volumes needed.

### Dependencies

- Needs `db` service to be healthy (expressed via `depends_on` in service.yml).
- Does NOT need `cert-gen`.
- Does NOT need the app.

---

## 4. Swagger UI (API Documentation)

### Recommended Image

```
swaggerapi/swagger-ui:latest
```

**Rationale**: The official Swagger UI Docker image maintained by SmartBear (the Swagger/OpenAPI company). Lightweight (~50 MB), well-maintained, and the standard way to serve Swagger UI. The image bundles an nginx server that serves the Swagger UI static assets and proxies API requests.

### Ports

| Port | Protocol | Purpose | Expose to host? |
|------|----------|---------|-----------------|
| 8080 | HTTP | Swagger UI web interface (internal port) | Yes, via `${SWAGGER_PORT}` mapped to 8080 internal |

**Default host port**: `SWAGGER_PORT=8084`. Port 8084 follows the proposed convention from the catalog proposals doc and avoids conflicts with other services.

### Configuration: API_URL vs SWAGGER_JSON

The Swagger UI Docker image supports two primary configuration modes:

#### Mode 1: `API_URL` (Recommended for dev-strap)

```yaml
environment:
  API_URL: http://app:3000/api-docs/openapi.json
```

Points Swagger UI at a URL that serves the OpenAPI spec. The spec is fetched at page load time from the running backend. This is the preferred mode for dev-strap because:
- It always shows the **live** spec from the running app.
- No file mounting or build step needed.
- The URL uses Docker-internal networking (`app:3000`).

**However**, there is a CORS consideration: The Swagger UI frontend runs in the user's browser (at `http://localhost:8084`), so the browser fetches the spec from `http://localhost:8084` which the Swagger UI nginx proxies to the backend. The `API_URL` in the Docker image is resolved **server-side by nginx**, not client-side, so CORS is not an issue when using the Docker image's built-in proxy.

**Wait -- correction**: In the `swaggerapi/swagger-ui` Docker image, `API_URL` is actually resolved **client-side** by the browser JavaScript. This means the URL must be reachable from the developer's browser, not just from within the Docker network. So `http://app:3000/...` will NOT work.

The correct approach is:

```yaml
environment:
  API_URL: http://localhost:${HTTP_PORT}/api-docs/openapi.json
```

Where `${HTTP_PORT}` is the host-mapped port for the nginx/web container. The browser can reach `localhost:${HTTP_PORT}`, and nginx routes `/api-docs/` to the app container.

**Alternative (and simpler)**: Use `BASE_URL` configuration or mount a static spec file.

#### Mode 2: `SWAGGER_JSON` (Static spec file)

```yaml
environment:
  SWAGGER_JSON: /spec/openapi.json
volumes:
  - ${APP_SOURCE}/docs/openapi.json:/spec/openapi.json:ro
```

Mounts a static OpenAPI spec file into the container. Swagger UI serves this file directly. This mode:
- Works regardless of whether the backend is running.
- Requires the spec file to exist at a known path in the app source.
- Does NOT auto-update when the spec changes (the container must be restarted, or the browser refreshed -- the file is read on page load).

### Recommended Approach for dev-strap

Use `SWAGGER_JSON` with a mounted spec file as the default, because:
1. It works without any app-specific configuration.
2. It does not depend on the app serving an OpenAPI endpoint.
3. The spec file path can be set via a `${SWAGGER_SPEC_PATH}` variable.

But also support `API_URL` via an env var override for apps that serve their spec dynamically.

```yaml
environment:
  SWAGGER_JSON: /spec/openapi.json
  # Users can override by setting SWAGGER_API_URL in project.env
  # which takes precedence over SWAGGER_JSON
```

**Simplification**: Since `SWAGGER_JSON` and `API_URL` can coexist (API_URL takes precedence), we can set both with sensible defaults.

### Per-App-Type Considerations

| App Type | How OpenAPI spec is typically generated | Default spec path |
|----------|----------------------------------------|-------------------|
| **node-express** | `swagger-jsdoc` or `@nestjs/swagger` generates at runtime; often also exported as `openapi.json` | `/api-docs/openapi.json` endpoint or `./docs/openapi.json` file |
| **go** | `swaggo/swag` generates `docs/swagger.json` at build time | `./docs/swagger.json` file |
| **php-laravel** | `darkaonline/l5-swagger` generates at runtime | `/api/documentation` endpoint or `./storage/api-docs/api-docs.json` file |
| **python-fastapi** | FastAPI auto-generates at `/openapi.json` endpoint | `/openapi.json` endpoint (always available) |

**Recommendation**: Default to mounting `${APP_SOURCE}/docs/openapi.json` (or `openapi.yaml`). Document in the service's README that users should either:
1. Place their spec file at `docs/openapi.json` in their app source, OR
2. Set `SWAGGER_API_URL` in `project.env` to point at their app's live spec endpoint

### Health Check

```yaml
healthcheck:
  test: ["CMD", "wget", "-qO", "/dev/null", "http://localhost:8080/"]
  interval: 10s
  timeout: 3s
  retries: 5
```

**How it works**: The Swagger UI container serves the UI at root `/`. A successful fetch of `/` confirms nginx + the static assets are loaded.

**Note**: The swagger-ui image is based on nginx, which does not include `wget` by default. It DOES include `curl`. So the health check should use `curl`:

```yaml
healthcheck:
  test: ["CMD-SHELL", "curl -sf http://localhost:8080/ > /dev/null"]
  interval: 10s
  timeout: 3s
  retries: 5
```

This is a deviation from the `wget` pattern used by other extras, but is necessary because the swagger-ui base image is nginx, not Alpine.

### Volumes

No persistent volume needed. Swagger UI is stateless. The only volume is the optional spec file mount:

```yaml
volumes:
  - ${SWAGGER_SPEC_PATH}:/spec/openapi.json:ro
```

Where `${SWAGGER_SPEC_PATH}` defaults to `${APP_SOURCE}/docs/openapi.json`.

### project.env Variables

```env
SWAGGER_PORT=8084
SWAGGER_SPEC_PATH=./docs/openapi.json
```

`SWAGGER_SPEC_PATH` is relative to the project root (resolved to absolute by the compose generator, same as `APP_SOURCE`).

### Requires and Conflicts

- **requires**: `["app.*"]` -- Swagger UI documents an API, which requires an app. Even with a static spec file, it only makes sense when an app exists.
- **conflicts**: None.

### service.yml Draft

```yaml
  swagger-ui:
    image: swaggerapi/swagger-ui:latest
    container_name: ${PROJECT_NAME}-swagger-ui
    ports:
      - "${SWAGGER_PORT}:8080"
    environment:
      SWAGGER_JSON: /spec/openapi.json
    volumes:
      - ${SWAGGER_SPEC_PATH}:/spec/openapi.json:ro
    networks:
      - ${PROJECT_NAME}-internal
    healthcheck:
      test: ["CMD-SHELL", "curl -sf http://localhost:8080/ > /dev/null"]
      interval: 10s
      timeout: 3s
      retries: 5
```

**Note on service name**: The service name `swagger-ui` contains a hyphen. This is valid in docker-compose YAML. However, it means the Docker-internal hostname is `swagger-ui` (with hyphen), which is fine for browser-based access but worth noting.

### manifest.json Entry Draft

```json
"swagger-ui": {
  "label": "API Documentation (Swagger UI)",
  "description": "Live OpenAPI spec viewer for your backend API",
  "defaults": { "port": 8084 },
  "requires": ["app.*"]
}
```

**Category**: `tooling` (alongside qa, qa-dashboard, wiremock, devcontainer, adminer).

### Compose Generator Changes

Two new `sed` substitutions:

```bash
sed "s|\${SWAGGER_PORT}|${SWAGGER_PORT:-8084}|g" | \
sed "s|\${SWAGGER_SPEC_PATH}|${SWAGGER_SPEC_ABS}|g"
```

Where `SWAGGER_SPEC_ABS` is resolved similarly to `APP_SOURCE_ABS`:

```bash
SWAGGER_SPEC_ABS="${DEVSTACK_DIR}/${SWAGGER_SPEC_PATH#./}"
```

This resolution needs to happen before the extras loop, alongside the existing `APP_SOURCE_ABS` resolution.

### Dependencies

- Does NOT need `cert-gen`.
- Does NOT strictly need the app to be running (if using a static spec file).
- When using `API_URL` mode, the app should be healthy first. But since we default to `SWAGGER_JSON` mode, no `depends_on` is needed.

---

## 5. Beaver (Identity Research)

### What is "Beaver"?

There is no widely-known Docker-based dev tool called "Beaver" in the conventional sense. After thorough analysis, here are the candidates:

#### 5.1 Beaver (Log Management / Log Shipping)

The most likely match in a dev-tooling context. **Beaver** was historically associated with **python-beaver** (`beaver`), a lightweight Python daemon that ships log files to various destinations (Redis, MQTT, RabbitMQ, ZeroMQ, etc.). It was used as a lightweight Logstash alternative.

- **GitHub**: `python-beaver/python-beaver` (archived/unmaintained)
- **Status**: Effectively dead. Last meaningful updates were around 2016-2017.
- **Docker image**: No official Docker image. Would require building a custom image.
- **Verdict**: NOT recommended for dev-strap. The project is abandoned, and dev-strap already has Dozzle for container log viewing, which serves the log-viewing use case much better.

#### 5.2 Beaver (CI/CD Tool)

No widely-known CI/CD tool named "Beaver" exists in the Docker ecosystem. There is:
- **Beaver CI** (`nicholasgasior/beaver`): A very small, obscure CI runner. Minimal community adoption, no meaningful Docker presence.
- **Verdict**: NOT a viable candidate.

#### 5.3 Beaver (Build Tool)

There was a build automation tool called **Beaver** (`sociomantic/beaver`) in the D language ecosystem. It was a CI build helper for D projects.
- **Status**: Archived.
- **Verdict**: Irrelevant to dev-strap's polyglot scope.

#### 5.4 Beaver (Apache Beaver / Incubating)

Apache Beaver is an incubating Apache project for data observability and monitoring. However, it is very early-stage and does not have stable Docker images suitable for dev tooling.

#### 5.5 Other Possible Meanings

- **Eager Beaver**: Slang/informal name for various small utilities. No standard Docker image.
- **CodeBeaver**: An AI code review tool (SaaS, not self-hosted).
- **Beaver** as a generic name: Could be an internal tool name from the user's organization.

### Recommendation

**Beaver does not have a clear, well-established identity** as a Docker dev tool. The most actionable interpretations are:

1. **If the intent is log management**: dev-strap already has Dozzle. If more sophisticated log aggregation is needed, consider **Loki** (Grafana Loki) as a log aggregation backend that integrates with the existing Grafana extra. Loki + Grafana is the modern replacement for what Beaver once tried to do.

2. **If the intent is CI/CD**: Consider **Gitea** (lightweight Git server + CI) or **Woodpecker CI** (community fork of Drone CI) as containerized CI runners for local dev.

3. **If "Beaver" is an internal/proprietary tool**: More context is needed from the user. The name may refer to something specific to their organization.

**Action**: Flag for clarification with the user. Do not create a template until the identity is confirmed.

---

## 6. Compose Generator Changes (Shared)

All four new services (NATS, MinIO, Adminer, Swagger UI) require changes to the extras processing loop in `core/compose/generate.sh`.

### Current sed Chain (lines 92-101)

```bash
EXTRAS_SERVICES="${EXTRAS_SERVICES}
$(cat "${extra_file}" | \
    sed "s|\${PROJECT_NAME}|${PROJECT_NAME}|g" | \
    sed "s|\${DB_NAME}|${DB_NAME}|g" | \
    sed "s|\${DB_USER}|${DB_USER}|g" | \
    sed "s|\${DB_PASSWORD}|${DB_PASSWORD}|g" | \
    sed "s|\${MAILPIT_PORT}|${MAILPIT_PORT:-8025}|g" | \
    sed "s|\${DEVSTACK_DIR}|${DEVSTACK_DIR}|g" | \
    sed "s|\${PROMETHEUS_PORT}|${PROMETHEUS_PORT:-9090}|g" | \
    sed "s|\${GRAFANA_PORT}|${GRAFANA_PORT:-3001}|g" | \
    sed "s|\${DOZZLE_PORT}|${DOZZLE_PORT:-9999}|g")"
```

### New sed Lines to Add

```bash
    sed "s|\${NATS_PORT}|${NATS_PORT:-4222}|g" | \
    sed "s|\${NATS_MONITOR_PORT}|${NATS_MONITOR_PORT:-8222}|g" | \
    sed "s|\${MINIO_API_PORT}|${MINIO_API_PORT:-9000}|g" | \
    sed "s|\${MINIO_CONSOLE_PORT}|${MINIO_CONSOLE_PORT:-9001}|g" | \
    sed "s|\${ADMINER_PORT}|${ADMINER_PORT:-8083}|g" | \
    sed "s|\${SWAGGER_PORT}|${SWAGGER_PORT:-8084}|g" | \
    sed "s|\${SWAGGER_SPEC_PATH}|${SWAGGER_SPEC_ABS}|g"
```

### Additional Variable Resolution (before the extras loop)

```bash
# Resolve SWAGGER_SPEC_PATH to absolute path
if [ -n "${SWAGGER_SPEC_PATH:-}" ]; then
    SWAGGER_SPEC_ABS="${DEVSTACK_DIR}/${SWAGGER_SPEC_PATH#./}"
else
    SWAGGER_SPEC_ABS="${DEVSTACK_DIR}/docs/openapi.json"
fi
```

### Scalability Concern

The sed chain is growing. With four new services, it reaches 16 substitutions. This is becoming unwieldy. A more scalable approach (for future consideration, not this PR) would be:

```bash
# Generic substitution: replace all ${VAR} with the env var's value
envsubst < "${extra_file}"
```

However, `envsubst` replaces ALL `${VAR}` patterns, which could cause issues if templates contain shell syntax that should be preserved. The current explicit `sed` approach is safer and should be maintained for now.

### Guard for Adminer Without Database

The Adminer service.yml has `depends_on: db`. If a user somehow adds `adminer` to EXTRAS without selecting a database, the compose file will be invalid (referencing a non-existent `db` service). The `requires: ["database.*"]` in the manifest prevents this at the UI/contract level, but the generator should also guard:

```bash
# In the extras loop, after reading extra_file:
if [ "${extra}" = "adminer" ] && [ "${DB_TYPE}" = "none" ]; then
    echo "[compose-gen] WARNING: Skipping 'adminer' — no database configured"
    continue
fi
```

---

## 7. Volume Registration Strategy

### Current Approach

Volumes are hardcoded in the `COMPOSE_FOOTER` heredoc at the end of `core/compose/generate.sh`:

```bash
volumes:
  ${PROJECT_NAME}-certs:${DB_VOLUMES}${APP_VOLUMES}
```

Where `DB_VOLUMES` and `APP_VOLUMES` are conditionally set strings.

### Problem

NATS and MinIO both need named volumes (`${PROJECT_NAME}-nats-data`, `${PROJECT_NAME}-minio-data`). These volumes must appear in the `volumes:` section of the compose file. But they should only appear when the respective extra is enabled.

### Recommended Approach

Add an `EXTRAS_VOLUMES` variable (similar to `EXTRAS_SERVICES` and `EXTRAS_DEPENDS`) that accumulates volume declarations:

```bash
EXTRAS_VOLUMES=""
# Inside the extras loop:
case "${extra}" in
    nats)
        EXTRAS_VOLUMES="${EXTRAS_VOLUMES}
  ${PROJECT_NAME}-nats-data:"
        ;;
    minio)
        EXTRAS_VOLUMES="${EXTRAS_VOLUMES}
  ${PROJECT_NAME}-minio-data:"
        ;;
esac
```

Then append to the footer:

```bash
volumes:
  ${PROJECT_NAME}-certs:${DB_VOLUMES}${APP_VOLUMES}${EXTRAS_VOLUMES}
```

This keeps volume registration co-located with the extras loop and avoids hardcoding service-specific volumes in the footer.

### Alternative: Bind Mounts

As noted in `ADDING_SERVICES.md`, bind mounts avoid the volume registration problem entirely:

```yaml
volumes:
  - ${DEVSTACK_DIR}/data/nats:/data
```

But this creates directories in the project tree (`data/nats/`, `data/minio/`), which may not be desirable. Named volumes are cleaner for dev-strap's use case. The existing `DB_VOLUMES` already uses named volumes, establishing the convention.

---

## 8. Open Questions

### 8.1 Beaver Identity

"Beaver" needs clarification. See Section 5 for analysis. Possible next steps:
- Ask the user what they mean by "Beaver"
- If log aggregation is the goal, research Grafana Loki as a Dozzle complement
- If CI/CD is the goal, research Woodpecker CI or Gitea Actions

### 8.2 Swagger UI Spec Path Flexibility

Should `SWAGGER_SPEC_PATH` support:
- A directory (serve all `.json`/`.yaml` files)?
- Multiple specs (for multi-app setups)?
- A URL fallback (try file first, then URL)?

For v1, a single file path is sufficient. Multi-spec support can come later.

### 8.3 Adminer Theme

Should dev-strap ship a default Adminer theme? Options:
- `dracula` (dark theme, popular with developers)
- `pepa-linha-dark`
- Default (no `ADMINER_DESIGN` env var)

Recommendation: Do not set a theme. Let users customize. Keeps the template minimal.

### 8.4 Port Allocation Document

The catalog proposals doc (Section 5.1) proposes a port range strategy. The new services fit cleanly:

| Service | Port(s) | Range | Fits? |
|---------|---------|-------|-------|
| NATS client | 4222 | Services (4200-4299) | Yes |
| NATS monitor | 8222 | Tooling (8000-8499) | Yes |
| MinIO API | 9000 | Observability (9000-9999) | Debatable -- MinIO is a service, not observability |
| MinIO Console | 9001 | Observability (9000-9999) | Same concern |
| Adminer | 8083 | Tooling (8000-8499) | Yes |
| Swagger UI | 8084 | Tooling (8000-8499) | Yes |

MinIO's ports (9000, 9001) fall in the "Observability" range by the proposals doc's scheme, but MinIO is a service, not an observability tool. This is fine for now -- the port ranges are guidelines, not hard rules.

### 8.5 NATS CLI Tool Integration

Should dev-strap include `nats-cli` anywhere? Options:
- Install it in the QA container (useful for testing messaging)
- Add a `nats-box` sidecar container (overkill for dev)
- Document how to install it in the app container

Recommendation: Document it, do not auto-install. Users who need `nats-cli` can add it to their Dockerfile.

---

## Summary: Implementation Checklist

For each service, the implementation work is:

| Step | NATS | MinIO | Adminer | Swagger UI |
|------|------|-------|---------|------------|
| Create `templates/extras/{name}/` directory | `nats/` | `minio/` | `adminer/` | `swagger-ui/` |
| Write `service.yml` | See draft above | See draft above | See draft above | See draft above |
| Add supplementary config files | None needed | None needed | None needed | None needed |
| Add port vars to `project.env` | `NATS_PORT`, `NATS_MONITOR_PORT` | `MINIO_API_PORT`, `MINIO_CONSOLE_PORT` | `ADMINER_PORT` | `SWAGGER_PORT`, `SWAGGER_SPEC_PATH` |
| Add `sed` substitutions to `core/compose/generate.sh` | 2 seds | 2 seds | 1 sed | 2 seds |
| Register named volume in generator | Yes (`nats-data`) | Yes (`minio-data`) | No | No |
| Add entry to `contract/manifest.json` | `services.nats` | `services.minio` | `tooling.adminer` | `tooling.swagger-ui` |
| Add guard in generator for missing deps | No | No | Yes (skip if no DB) | No |
| Update `ADDING_SERVICES.md` built-in extras table | Yes | Yes | Yes | Yes |
| Update `project.env` comments | Yes | Yes | Yes | Yes |

**Estimated effort**: Each service is a small, self-contained change. The compose generator changes can be done in a single pass. Total: ~2-3 hours for all four services, including testing.
