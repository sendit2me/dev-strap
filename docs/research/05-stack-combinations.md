# Stack Combinations, Auto-Wiring, and Preset Bundle Research

> **Purpose**: Deep research into real-world development stack combinations, the wiring they require, preset bundle designs, environment variable conventions, and resource estimates -- to inform dev-strap's catalog expansion.
>
> **Date**: 2026-03-20
>
> **Inputs**: `contract/manifest.json` (current catalog), `docs/dev-strap-catalog-proposals.md` (proposals), existing templates and `core/compose/generate.sh` (current wiring patterns).

---

## Table of Contents

1. [Common Stack Combinations](#1-common-stack-combinations)
2. [Auto-Wiring Map](#2-auto-wiring-map)
3. [Preset Bundle Designs](#3-preset-bundle-designs)
4. [Environment Variable Conventions](#4-environment-variable-conventions)
5. [Resource Estimation](#5-resource-estimation)
6. [Implementation Considerations](#6-implementation-considerations)

---

## 1. Common Stack Combinations

### 1.1 SPA + API

**Pattern**: Vite frontend + backend API + database + cache

This is the dominant architecture for modern web applications. The frontend is a single-page application (React, Vue, Svelte, or Angular) built with Vite. The backend is a JSON API. The two communicate over HTTP, typically proxied through the Vite dev server during development.

#### Services Needed

| Service | Image | Role |
|---------|-------|------|
| Vite | node:20-alpine | Frontend dev server with HMR |
| Backend (Go, Node, or Python) | varies | JSON API |
| PostgreSQL | postgres:16-alpine | Primary data store |
| Redis | redis:alpine | Session store, cache, rate limiting |
| Nginx | nginx:alpine | Reverse proxy, TLS termination (dev-strap's `web` service) |

#### Wiring and Configuration

The critical wiring point is the **Vite-to-backend proxy**. In a standard development setup, Vite's dev server proxies API requests to the backend so the frontend can call `/api/*` without CORS issues.

**Vite config (`vite.config.ts`)**:
```ts
export default defineConfig({
  server: {
    proxy: {
      '/api': {
        target: 'http://app:3000',  // backend container hostname
        changeOrigin: true,
      },
    },
  },
});
```

In dev-strap's Docker network, the backend container is reachable by its service name (`app`, `go`, `node`, etc.). The Vite container needs to know the backend hostname and port.

**Environment variables the app needs**:

| Variable | Value | Consumer |
|----------|-------|----------|
| `VITE_API_URL` | `/api` (relative, proxied) or `http://localhost:3000` (direct) | Vite frontend (build-time) |
| `DB_HOST` | `db` | Backend |
| `DB_PORT` | `5432` | Backend |
| `DB_NAME` | `${PROJECT_NAME}` | Backend |
| `DB_USER` | `${PROJECT_NAME}` | Backend |
| `DB_PASSWORD` | `secret` | Backend |
| `REDIS_URL` | `redis://redis:6379` | Backend |

**Ports (host-mapped)**:

| Service | Container Port | Default Host Port |
|---------|---------------|-------------------|
| Vite | 5173 | 5173 |
| Backend | 3000 (Node/Go) or 8000 (Python) | not exposed directly (behind nginx) |
| PostgreSQL | 5432 | 5432 |
| Redis | 6379 | not exposed (internal only) |
| Nginx | 80, 443 | 8080, 8443 |

**Common pain points**:

1. **HMR WebSocket through Docker**: Vite's HMR uses WebSocket connections. If the container network or a proxy doesn't forward WebSocket frames, hot reload breaks silently. The Vite container must expose port 5173 directly or the proxy layer must handle `Upgrade` headers.

2. **API proxy configuration**: Developers must manually configure `vite.config.ts` to proxy to the backend. dev-strap should generate this or at least inject the correct `PROXY_TARGET` env var.

3. **Frontend build vs dev mode**: The Vite dev server is for development only. Production builds output static files. dev-strap should only run the dev server, never `vite build` -- that belongs in CI.

4. **Volume mount performance on macOS**: Vite watches thousands of files in `node_modules`. On Docker Desktop for macOS, native bind mounts are slow. The mitigation is to keep `node_modules` in an anonymous volume (`/app/node_modules`) rather than bind-mounting from host. dev-strap already does this for Node.js backends.

5. **Port collisions**: If Node.js backend defaults to 3000 and Vite defaults to 5173, no collision. But if a Go backend also defaults to 3000, you need port assignment logic.

---

### 1.2 API-Only Microservice

**Pattern**: Single backend + database + cache + message broker

Headless APIs serving mobile apps, other services, or SPAs hosted elsewhere. No frontend container needed.

#### Services Needed

| Service | Image | Role |
|---------|-------|------|
| Backend (Go, Node, Python, or Rust) | varies | API server |
| PostgreSQL | postgres:16-alpine | Primary data store |
| Redis | redis:alpine | Cache, rate limiting, pub/sub |
| NATS | nats:latest | Async messaging (event bus) |

#### Wiring and Configuration

This is the simplest pattern from a wiring perspective. Each service connects to the others through Docker DNS. The primary connection points are:

- **App to DB**: hostname `db`, port `5432`
- **App to Redis**: hostname `redis`, port `6379`
- **App to NATS**: hostname `nats`, port `4222`

All connections happen over the internal Docker network. The only host-exposed port is typically the API itself (through nginx) and perhaps a database port for local tooling.

**Environment variables the app needs**:

| Variable | Value | Notes |
|----------|-------|-------|
| `DB_HOST` | `db` | |
| `DB_PORT` | `5432` | |
| `DB_NAME` / `DB_USER` / `DB_PASSWORD` | project defaults | |
| `REDIS_URL` | `redis://redis:6379` | Combined format preferred for most libraries |
| `NATS_URL` | `nats://nats:4222` | Standard NATS connection string |
| `PORT` | `3000` / `8000` / `8080` | Varies by language |

**Common pain points**:

1. **Health check ordering**: The backend should not start accepting requests until both the database and Redis are healthy. NATS is more tolerant -- clients reconnect automatically. Docker Compose `depends_on` with `condition: service_healthy` handles this, which dev-strap already uses.

2. **NATS JetStream initialization**: If using JetStream (persistent messaging), streams and consumers need to be created before the app can use them. This is an application-level concern, but dev-strap could include a NATS config file that enables JetStream by default.

3. **Multiple backend instances**: Microservice patterns sometimes run multiple instances of the same backend. Docker Compose `replicas` can handle this, but it changes how the service name resolves (load-balanced across instances). dev-strap should not enable this by default but should make it possible.

---

### 1.3 Full-Stack with Observability

**Pattern**: Vite + backend + database + cache + metrics + dashboards + log viewer

This is the "production-like" development environment. Teams that practice production parity want metrics collection, dashboards, and log aggregation even in development.

#### Services Needed

| Service | Image | Role |
|---------|-------|------|
| Vite | node:20-alpine | Frontend dev server |
| Backend | varies | API server |
| PostgreSQL | postgres:16-alpine | Primary data store |
| Redis | redis:alpine | Cache/queue |
| Prometheus | prom/prometheus:latest | Metrics collection |
| Grafana | grafana/grafana:latest | Dashboards |
| Dozzle | amir20/dozzle:latest | Log viewer |
| Nginx | nginx:alpine | Reverse proxy |

#### Wiring and Configuration

This is the most complex wiring scenario. Beyond the basic SPA+API wiring:

- **Prometheus must scrape the backend**: The backend needs a `/metrics` endpoint (e.g., using `prom-client` for Node, `promhttp` for Go, `prometheus-fastapi-instrumentator` for Python). Prometheus needs a `scrape_configs` entry pointing at the backend's hostname and port. Currently, dev-strap's prometheus.yml only scrapes itself (`localhost:9090`). For this stack, it should also scrape `app:PORT/metrics`.

- **Grafana must connect to Prometheus**: Already implemented via `provisioning/datasources/prometheus.yml` setting `url: http://prometheus:9090`. This is the auto-wiring pattern to replicate for other service pairs.

- **Dozzle reads the Docker socket**: Already implemented. No additional wiring needed.

- **Redis metrics**: An optional `redis_exporter` container can expose Redis metrics to Prometheus. Not strictly necessary for development but useful.

**Environment variables** combine all from SPA+API plus:

| Variable | Value | Consumer |
|----------|-------|----------|
| `METRICS_ENABLED` | `true` | Backend -- enable /metrics endpoint |
| `GF_SECURITY_ADMIN_USER` | `admin` | Grafana |
| `GF_SECURITY_ADMIN_PASSWORD` | `admin` | Grafana |

**Ports (host-mapped)**:

| Service | Default Host Port |
|---------|-------------------|
| Vite | 5173 |
| Nginx | 8080, 8443 |
| PostgreSQL | 5432 |
| Prometheus | 9090 |
| Grafana | 3001 |
| Dozzle | 9999 |

**Common pain points**:

1. **Resource consumption**: This stack runs 8+ containers. On a laptop with 8 GB RAM, you can hit memory pressure. Prometheus and Grafana together consume 300-500 MB idle.

2. **Prometheus scrape target configuration**: The Prometheus config must know the backend's hostname and metrics port. If the backend choice changes (Go on 3000 vs Python on 8000), the Prometheus config must be regenerated. This is an auto-wiring opportunity.

3. **Grafana dashboard provisioning**: Having Grafana without dashboards is of limited value. Pre-built dashboards for common metrics (HTTP request latency, error rates, Go runtime / Node.js event loop / Python GC metrics) would differentiate dev-strap. These can be provisioned via files in `provisioning/dashboards/`.

4. **Cold start time**: With this many containers, first boot can take 30-60 seconds due to image pulls and health check stabilization. Subsequent starts are faster (5-15 seconds) because images are cached.

---

### 1.4 Data Pipeline

**Pattern**: Python + database + message broker + object storage

Used by data engineering and ETL teams. The backend processes data from various sources, transforms it, stores results in a database, and publishes events.

#### Services Needed

| Service | Image | Role |
|---------|-------|------|
| Python (FastAPI) | python:3.12-slim | API + data processing |
| PostgreSQL | postgres:16-alpine | Data warehouse / result store |
| NATS | nats:latest | Event bus (data arrival, processing complete) |
| MinIO | minio/minio:latest | Object storage for raw data, exports |

#### Wiring and Configuration

- **Python to PostgreSQL**: Standard DB connection via `DB_HOST=db`.
- **Python to NATS**: `NATS_URL=nats://nats:4222`. Python uses the `nats-py` async client.
- **Python to MinIO**: MinIO speaks the S3 API. Python uses `boto3` with an endpoint override. This requires multiple environment variables.

**Environment variables**:

| Variable | Value | Notes |
|----------|-------|-------|
| `DB_HOST` | `db` | |
| `DB_PORT` | `5432` | |
| `NATS_URL` | `nats://nats:4222` | |
| `AWS_ENDPOINT_URL` | `http://minio:9000` | boto3 endpoint override |
| `AWS_ACCESS_KEY_ID` | `minioadmin` | MinIO default credentials |
| `AWS_SECRET_ACCESS_KEY` | `minioadmin` | MinIO default credentials |
| `AWS_DEFAULT_REGION` | `us-east-1` | Required by boto3, value is arbitrary for MinIO |
| `S3_BUCKET` | `${PROJECT_NAME}-data` | Convention |
| `AWS_S3_FORCE_PATH_STYLE` | `true` | MinIO requires path-style URLs, not virtual-hosted |

**Ports (host-mapped)**:

| Service | Default Host Port |
|---------|-------------------|
| Python API | 8000 |
| PostgreSQL | 5432 |
| NATS client | 4222 |
| NATS monitor | 8222 |
| MinIO API | 9000 |
| MinIO Console | 9001 |

**Common pain points**:

1. **MinIO bucket initialization**: MinIO starts empty. The first time the app runs, it needs to create a bucket. This is typically handled by an init script or an entrypoint that calls `mc mb local/${BUCKET_NAME}`. dev-strap could include an init container for this.

2. **NATS JetStream setup**: Data pipelines often use JetStream for guaranteed delivery. The NATS server needs to be started with `--jetstream` flag and a storage directory. The docker run command should include `-js` or a config file with `jetstream: { store_dir: /data }`.

3. **Large file processing**: Data pipelines handle large files. Volume mounts for data directories and MinIO storage can consume significant disk space. dev-strap should document disk requirements.

4. **Python dependency management**: Python projects use `pip`, `poetry`, `pipenv`, or `uv`. The Dockerfile needs to install dependencies on build. Using a `requirements.txt` volume mount with `pip install --no-cache-dir` works, but poetry/uv setups need different treatment.

---

### 1.5 Event-Driven

**Pattern**: Go or Rust + NATS + Redis + PostgreSQL

Backend services that communicate primarily through events rather than synchronous HTTP calls. Common in microservice architectures.

#### Services Needed

| Service | Image | Role |
|---------|-------|------|
| Backend (Go or Rust) | varies | Event processor / API |
| NATS | nats:latest | Event bus |
| Redis | redis:alpine | State cache, deduplication |
| PostgreSQL | postgres:16-alpine | Persistent state |

#### Wiring and Configuration

This is similar to the API-only pattern but with NATS as the central communication backbone rather than HTTP.

- **App to NATS**: `NATS_URL=nats://nats:4222`. Go uses `nats.go`, Rust uses `async-nats`.
- **App to Redis**: `REDIS_URL=redis://redis:6379`. Used for caching event processing state and deduplication (idempotency keys).
- **App to PostgreSQL**: Standard DB connection. Used for persistent state that survives container restarts.

**Environment variables**:

| Variable | Value |
|----------|-------|
| `NATS_URL` | `nats://nats:4222` |
| `REDIS_URL` | `redis://redis:6379` |
| `DB_HOST` | `db` |
| `DB_PORT` | `5432` |
| `DB_NAME` / `DB_USER` / `DB_PASSWORD` | project defaults |

**Common pain points**:

1. **Event ordering**: NATS pub/sub does not guarantee ordering by default. JetStream provides ordered consumers but requires explicit setup. dev-strap should enable JetStream by default when NATS is selected.

2. **Dead letter handling**: Failed event processing needs a dead letter subject or queue. This is application-level, but dev-strap could include a NATS monitoring dashboard (NATS has a built-in monitor at port 8222) to help developers inspect subjects and consumers.

3. **Multiple service instances**: Event-driven architectures often have multiple consumers. Docker Compose `deploy.replicas` can test this, but it adds complexity. Keep as single-instance by default.

4. **Rust compile times**: Rust containers take significantly longer to build than Go due to compilation. The Dockerfile should leverage `cargo-chef` or multi-stage builds with cached dependency layers. cargo-watch for hot reload is slow on large projects -- incremental compilation helps but is still 5-15 seconds per change.

---

### 1.6 Content Management

**Pattern**: PHP/Laravel + MariaDB + MinIO + Mailpit

Traditional content management and CMS applications. Laravel is the dominant framework in this space.

#### Services Needed

| Service | Image | Role |
|---------|-------|------|
| PHP (Laravel) | php:8.3-fpm-alpine | Application server |
| MariaDB | mariadb:10.11 | Primary database |
| MinIO | minio/minio:latest | File uploads, media storage |
| Mailpit | axllent/mailpit:latest | Email capture during development |
| Redis | redis:alpine | Session store, cache, queue |
| Nginx | nginx:alpine | Web server (already in dev-strap) |

#### Wiring and Configuration

Laravel has its own conventions for environment variables (`.env` file). The dev-strap template already uses Laravel's variable names (`DB_CONNECTION`, `DB_HOST`, `DB_DATABASE`, `DB_USERNAME`, `DB_PASSWORD`).

For MinIO, Laravel uses the `s3` filesystem driver:

| Variable | Value | Notes |
|----------|-------|-------|
| `FILESYSTEM_DISK` | `s3` | Laravel uses the S3 driver for MinIO |
| `AWS_ENDPOINT` | `http://minio:9000` | Laravel's config key differs from boto3 |
| `AWS_ACCESS_KEY_ID` | `minioadmin` | |
| `AWS_SECRET_ACCESS_KEY` | `minioadmin` | |
| `AWS_DEFAULT_REGION` | `us-east-1` | |
| `AWS_BUCKET` | `${PROJECT_NAME}-media` | |
| `AWS_USE_PATH_STYLE_ENDPOINT` | `true` | MinIO needs path-style URLs |

For Mailpit:

| Variable | Value | Notes |
|----------|-------|-------|
| `MAIL_MAILER` | `smtp` | |
| `MAIL_HOST` | `mailpit` | Container hostname |
| `MAIL_PORT` | `1025` | Mailpit SMTP port |
| `MAIL_USERNAME` | `null` | Mailpit accepts any auth |
| `MAIL_PASSWORD` | `null` | |
| `MAIL_ENCRYPTION` | `null` | No TLS for local dev |

For Redis (Laravel):

| Variable | Value | Notes |
|----------|-------|-------|
| `REDIS_HOST` | `redis` | Laravel uses separate host/port |
| `REDIS_PORT` | `6379` | |
| `REDIS_PASSWORD` | `null` | No auth in dev |
| `CACHE_DRIVER` | `redis` | |
| `SESSION_DRIVER` | `redis` | |
| `QUEUE_CONNECTION` | `redis` | |

**Common pain points**:

1. **Composer install**: Laravel requires `composer install` on first boot. This is slow (30-60 seconds) and needs network access. The init script must run this.

2. **File permissions**: PHP-FPM runs as `www-data` (uid 82). Files created by Composer or Artisan may have wrong ownership for the host user. Using `user: "${UID}:${GID}"` in the compose service can help, but it breaks PHP-FPM's default config.

3. **Laravel key generation**: `php artisan key:generate` must run before the app works. Another init step.

4. **Public storage symlink**: `php artisan storage:link` creates a symlink for public file access. This must run inside the container.

5. **MinIO port conflict**: MinIO defaults to port 9000, and PHP-FPM also listens on 9000. dev-strap already uses PHP-FPM internally (behind nginx), so no host-port conflict, but the container port overlap can cause confusion.

---

### 1.7 ML/Data Science

**Pattern**: Python + PostgreSQL + MinIO + Redis

Machine learning and data science development environments. The backend serves model predictions and the data pipeline stores training data and model artifacts.

#### Services Needed

| Service | Image | Role |
|---------|-------|------|
| Python (FastAPI) | python:3.12-slim | Model serving API, experiment tracking |
| PostgreSQL | postgres:16-alpine | Feature store, experiment metadata |
| MinIO | minio/minio:latest | Training data, model artifacts |
| Redis | redis:alpine | Prediction cache, feature cache |

#### Wiring and Configuration

Very similar to the data pipeline pattern. The key difference is that ML workloads may need GPU access, which Docker Compose supports via the `deploy.resources.reservations.devices` key. This is beyond dev-strap's current scope but worth noting for future consideration.

**Environment variables** are identical to the data pipeline pattern (section 1.4), with additional ML-specific ones:

| Variable | Value | Notes |
|----------|-------|-------|
| `MODEL_STORE_BUCKET` | `${PROJECT_NAME}-models` | MinIO bucket for model artifacts |
| `MLFLOW_TRACKING_URI` | `http://localhost:5000` | If MLflow is added |
| `TORCH_HOME` | `/cache/torch` | Persistent cache for PyTorch models |
| `HF_HOME` | `/cache/huggingface` | Persistent cache for HuggingFace |

**Common pain points**:

1. **Large image sizes**: ML Python images with PyTorch, TensorFlow, or scikit-learn can be 2-5 GB. Using slim base images and careful dependency management is important.

2. **GPU passthrough**: Not available in Docker Desktop for macOS. On Linux, requires `nvidia-container-toolkit`. dev-strap should not attempt GPU support initially.

3. **Long startup times**: ML dependencies take a long time to install. Pre-built images (with dependencies baked in) are preferred over installing at container start.

4. **Data volume sizes**: Training datasets can be gigabytes. MinIO volumes need adequate disk space.

---

## 2. Auto-Wiring Map

This section documents every service pair that requires configuration when co-selected. "Auto-wiring" means dev-strap can infer the configuration from the selections without asking the user.

### 2.1 Complete Wiring Matrix

| Service A | Service B | What Gets Wired | Mechanism | Direction |
|-----------|-----------|----------------|-----------|-----------|
| **Vite** | any backend app | `proxy_target` in Vite config | Set env `PROXY_TARGET=http://{backend}:{port}` | Vite -> Backend |
| **Swagger UI** | any backend app | `SWAGGER_JSON_URL` | Set env `SWAGGER_JSON_URL=http://{backend}:{port}/openapi.json` | Swagger -> Backend |
| **Adminer** | PostgreSQL | `ADMINER_DEFAULT_SERVER` | Set env `ADMINER_DEFAULT_SERVER=db` | Adminer -> DB |
| **Adminer** | MariaDB | `ADMINER_DEFAULT_SERVER` | Set env `ADMINER_DEFAULT_SERVER=db` | Adminer -> DB |
| **Grafana** | Prometheus | Datasource provisioning | File: `provisioning/datasources/prometheus.yml` with `url: http://prometheus:9090` | Grafana -> Prometheus |
| **Prometheus** | any backend app | Scrape target | Add to `scrape_configs`: `targets: ['{backend}:{port}']` with `/metrics` path | Prometheus -> Backend |
| **QA container** | any app | `BASE_URL` | Set env `BASE_URL=http://{backend}:{port}` or `https://web:443` | QA -> App |
| **Any backend** | PostgreSQL | DB connection env vars | `DB_HOST=db`, `DB_PORT=5432`, `DB_NAME`, `DB_USER`, `DB_PASSWORD` | Backend -> DB |
| **Any backend** | MariaDB | DB connection env vars | `DB_HOST=db`, `DB_PORT=3306`, `DB_NAME`, `DB_USER`, `DB_PASSWORD` | Backend -> DB |
| **Any backend** | Redis | Redis connection | `REDIS_URL=redis://redis:6379` | Backend -> Redis |
| **Any backend** | NATS | NATS connection | `NATS_URL=nats://nats:4222` | Backend -> NATS |
| **Any backend** | MinIO | S3-compatible connection | `AWS_ENDPOINT_URL=http://minio:9000`, `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` | Backend -> MinIO |
| **Any backend** | Mailpit | SMTP connection | `SMTP_HOST=mailpit`, `SMTP_PORT=1025` | Backend -> Mailpit |
| **Dozzle** | all containers | Docker socket | Volume mount: `/var/run/docker.sock:/var/run/docker.sock:ro` | Dozzle -> Docker |

### 2.2 Wiring Implementation Patterns

dev-strap currently has three wiring mechanisms, and the expansion requires a fourth:

**Pattern 1: Static provisioning files (already used)**

Grafana's datasource for Prometheus is a YAML file mounted into the container at build time:
```yaml
# templates/extras/grafana/provisioning/datasources/prometheus.yml
datasources:
  - name: Prometheus
    type: prometheus
    url: http://prometheus:9090
```
This works because Grafana and Prometheus always use the same Docker hostnames. No variable substitution needed.

**Pattern 2: Template variable substitution (already used)**

Backend service templates use `${DB_HOST}`, `${DB_PORT}`, etc. These are substituted by `core/compose/generate.sh` using `sed`. This is the mechanism for wiring backends to databases.

**Pattern 3: Implicit Docker DNS (already used)**

Services refer to each other by container service name (`db`, `redis`, `web`). This requires no explicit configuration -- Docker Compose's internal DNS handles it. The service name must be predictable (and it is, because dev-strap controls the service names in the generated compose file).

**Pattern 4: Conditional template injection (new, needed)**

When NATS is selected alongside a backend, the backend's service template needs additional environment variables (`NATS_URL`). Similarly, when MinIO is selected, the backend needs `AWS_ENDPOINT_URL` and credentials.

Options for implementing this:

**Option A: Environment variable snippets**
Each optional service provides an env-snippet file. If the service is selected, its snippet is appended to the backend's `environment:` block during generation.

```
templates/extras/nats/env-snippet.yml:
  - NATS_URL=nats://nats:4222

templates/extras/minio/env-snippet.yml:
  - AWS_ENDPOINT_URL=http://minio:9000
  - AWS_ACCESS_KEY_ID=minioadmin
  - AWS_SECRET_ACCESS_KEY=minioadmin
  - AWS_DEFAULT_REGION=us-east-1
  - AWS_S3_FORCE_PATH_STYLE=true
```

**Option B: Wiring rules in manifest.json**
Add a `wiring` key to each service definition that specifies what environment variables to inject into dependent services.

```json
{
  "nats": {
    "wiring": {
      "inject_env": {
        "target": "app.*",
        "vars": {
          "NATS_URL": "nats://nats:4222"
        }
      }
    }
  }
}
```

**Option C: Lookup table in generate.sh**
A shell associative array mapping extra service names to environment variables. Simplest to implement, least flexible.

**Recommendation**: Option A (env-snippet files) fits dev-strap's existing file-based template pattern and is easy to understand. Each service's wiring is co-located with its template.

### 2.3 Language-Specific Wiring Overrides

Some wiring needs to change based on the backend language:

| Service | Go | Node.js | Python | PHP/Laravel | Rust |
|---------|-----|---------|--------|-------------|------|
| **CA cert trust** | `SSL_CERT_FILE=/certs/ca.crt` | `NODE_EXTRA_CA_CERTS=/certs/ca.crt` | `REQUESTS_CA_BUNDLE=/certs/ca.crt` | `update-ca-certificates` in Dockerfile | `SSL_CERT_FILE=/certs/ca.crt` |
| **DB connection** | `DB_HOST` + `DB_PORT` + individual vars | `DATABASE_URL` (connection string) or individual vars | `DATABASE_URL` (SQLAlchemy) or individual vars | `DB_CONNECTION` + `DB_HOST` + `DB_DATABASE` + `DB_USERNAME` + `DB_PASSWORD` | `DATABASE_URL` (connection string) |
| **Redis** | `REDIS_URL` | `REDIS_URL` | `REDIS_URL` | `REDIS_HOST` + `REDIS_PORT` | `REDIS_URL` |
| **MinIO** | `AWS_ENDPOINT_URL` + creds | `AWS_ENDPOINT_URL` + creds | `AWS_ENDPOINT_URL` + creds | `AWS_ENDPOINT` + `AWS_USE_PATH_STYLE_ENDPOINT=true` + creds | `AWS_ENDPOINT_URL` + creds |
| **NATS** | `NATS_URL` | `NATS_URL` | `NATS_URL` | N/A (uncommon) | `NATS_URL` |
| **SMTP** | `SMTP_HOST` + `SMTP_PORT` | `SMTP_HOST` + `SMTP_PORT` | `SMTP_HOST` + `SMTP_PORT` | `MAIL_HOST` + `MAIL_PORT` + `MAIL_MAILER=smtp` | `SMTP_HOST` + `SMTP_PORT` |

PHP/Laravel has the most divergent naming conventions. The dev-strap PHP template already handles this for DB variables. The same pattern should extend to Redis, MinIO, and SMTP.

---

## 3. Preset Bundle Designs

### 3.1 spa-api (SPA + API)

**Target user**: Most common modern web app. Frontend SPA with a JSON API backend.

| Attribute | Value |
|-----------|-------|
| **Auto-selected items** | |
| app | `vite` |
| database | `postgres` |
| tooling | `qa`, `wiremock` |
| **User must choose** | |
| app (additional) | One backend: `node-express`, `go`, `python-fastapi`, or `rust` |
| **Optional add-ons shown** | `redis`, `swagger-ui`, `db-ui`, `mailpit` |
| **Auto-wiring that fires** | Vite proxy_target -> backend hostname:port; QA BASE_URL -> https://web:443; backend -> DB env vars |
| **Service count** | 6-7 (cert-gen, vite, backend, db, web, tester, test-dashboard) + optional |
| **Estimated idle RAM** | ~400-600 MB |
| **Estimated loaded RAM** | ~800-1200 MB |

**Manifest selections**:
```json
{
  "preset": "spa-api",
  "selections": {
    "app": ["vite"],
    "database": ["postgres"],
    "tooling": ["qa", "wiremock"]
  },
  "prompts": ["app"],
  "prompt_hint": "Choose a backend language for your API"
}
```

**Generated services** (assuming Go backend is chosen):
1. `cert-gen` -- TLS certificate generator
2. `vite` -- frontend dev server (port 5173)
3. `app` (Go) -- API backend (port 3000, internal)
4. `db` (PostgreSQL) -- database (port 5432)
5. `web` (nginx) -- reverse proxy (ports 8080/8443)
6. `wiremock` -- mock external APIs
7. `tester` -- Playwright test runner
8. `test-dashboard` -- test report viewer (port 8082)

**Total: 8 services, ~500 MB idle RAM**

---

### 3.2 api-only (API Service)

**Target user**: Backend microservice or headless API.

| Attribute | Value |
|-----------|-------|
| **Auto-selected items** | |
| database | `postgres` |
| services | `redis` |
| tooling | `qa`, `swagger-ui` |
| **User must choose** | |
| app | One backend: `node-express`, `go`, `python-fastapi`, or `rust` |
| **Optional add-ons shown** | `nats`, `minio`, `db-ui`, `mailpit`, `wiremock` |
| **Auto-wiring that fires** | Backend -> DB env vars; Backend -> Redis URL; Swagger -> backend OpenAPI endpoint; QA BASE_URL -> backend |
| **Service count** | 6 (cert-gen, backend, db, redis, web, tester) + optional |
| **Estimated idle RAM** | ~350-500 MB |
| **Estimated loaded RAM** | ~600-900 MB |

**Manifest selections**:
```json
{
  "preset": "api-only",
  "selections": {
    "database": ["postgres"],
    "services": ["redis"],
    "tooling": ["qa", "swagger-ui"]
  },
  "prompts": ["app"],
  "prompt_hint": "Choose a language for your API"
}
```

**Generated services** (assuming Node.js is chosen):
1. `cert-gen`
2. `app` (Node.js/Express) -- API (port 3000, internal)
3. `db` (PostgreSQL)
4. `redis`
5. `web` (nginx)
6. `swagger-ui` (port 8084)
7. `tester`
8. `test-dashboard`

**Total: 8 services, ~400 MB idle RAM**

---

### 3.3 full-stack (Full Stack + Observability)

**Target user**: Teams wanting production parity in development.

| Attribute | Value |
|-----------|-------|
| **Auto-selected items** | |
| app | `vite` |
| database | `postgres` |
| services | `redis` |
| tooling | `qa`, `wiremock`, `swagger-ui`, `db-ui` |
| observability | `prometheus`, `grafana`, `dozzle` |
| **User must choose** | |
| app (additional) | One backend: `node-express`, `go`, `python-fastapi`, or `rust` |
| **Optional add-ons shown** | `nats`, `minio`, `mailpit` |
| **Auto-wiring that fires** | All SPA+API wiring + Grafana->Prometheus datasource + Prometheus->backend scrape target + Adminer->DB server + Swagger->backend OpenAPI |
| **Service count** | 12-14 |
| **Estimated idle RAM** | ~900-1300 MB |
| **Estimated loaded RAM** | ~1500-2200 MB |

**Manifest selections**:
```json
{
  "preset": "full-stack",
  "selections": {
    "app": ["vite"],
    "database": ["postgres"],
    "services": ["redis"],
    "tooling": ["qa", "wiremock", "swagger-ui", "db-ui"],
    "observability": ["prometheus", "grafana", "dozzle"]
  },
  "prompts": ["app"],
  "prompt_hint": "Choose a backend language"
}
```

**Generated services** (assuming Go backend):
1. `cert-gen`
2. `vite` (port 5173)
3. `app` (Go)
4. `db` (PostgreSQL)
5. `redis`
6. `web` (nginx, ports 8080/8443)
7. `wiremock`
8. `swagger-ui` (port 8084)
9. `db-ui` / Adminer (port 8083)
10. `prometheus` (port 9090)
11. `grafana` (port 3001)
12. `dozzle` (port 9999)
13. `tester`
14. `test-dashboard` (port 8082)

**Total: 14 services, ~1.1 GB idle RAM**

**Warning**: This preset should display a resource estimate to the user before confirming. Laptops with less than 16 GB RAM may struggle.

---

### 3.4 data-pipeline (Data Pipeline)

**Target user**: Data engineering, ETL, event processing.

| Attribute | Value |
|-----------|-------|
| **Auto-selected items** | |
| app | `python-fastapi` |
| database | `postgres` |
| services | `nats`, `minio` |
| **User must choose** | Nothing (fully specified) |
| **Optional add-ons shown** | `redis`, `db-ui`, `prometheus`, `grafana` |
| **Auto-wiring that fires** | Python -> DB env vars; Python -> NATS_URL; Python -> MinIO/S3 env vars |
| **Service count** | 7 |
| **Estimated idle RAM** | ~500-700 MB |
| **Estimated loaded RAM** | ~800-1200 MB |

**Manifest selections**:
```json
{
  "preset": "data-pipeline",
  "selections": {
    "app": ["python-fastapi"],
    "database": ["postgres"],
    "services": ["nats", "minio"]
  },
  "prompts": [],
  "prompt_hint": null
}
```

**Generated services**:
1. `cert-gen`
2. `app` (Python/FastAPI, port 8000)
3. `db` (PostgreSQL)
4. `nats` (client port 4222, monitor port 8222)
5. `minio` (API port 9000, console port 9001)
6. `web` (nginx)
7. `tester`
8. `test-dashboard`

**Total: 8 services, ~600 MB idle RAM**

---

### 3.5 event-driven (Event-Driven Architecture) -- NEW

**Target user**: Microservices communicating through events.

| Attribute | Value |
|-----------|-------|
| **Auto-selected items** | |
| database | `postgres` |
| services | `nats`, `redis` |
| **User must choose** | |
| app | One backend: `go` or `rust` (steered toward compiled languages) |
| **Optional add-ons shown** | `minio`, `prometheus`, `grafana`, `dozzle`, `db-ui` |
| **Auto-wiring that fires** | Backend -> DB env vars; Backend -> NATS_URL; Backend -> REDIS_URL |
| **Service count** | 7 |
| **Estimated idle RAM** | ~400-550 MB |
| **Estimated loaded RAM** | ~700-1000 MB |

**Manifest selections**:
```json
{
  "preset": "event-driven",
  "selections": {
    "database": ["postgres"],
    "services": ["nats", "redis"]
  },
  "prompts": ["app"],
  "prompt_hint": "Choose a language (Go and Rust are best suited for event-driven workloads)"
}
```

**Generated services** (assuming Go):
1. `cert-gen`
2. `app` (Go)
3. `db` (PostgreSQL)
4. `nats` (ports 4222, 8222)
5. `redis`
6. `web` (nginx)
7. `tester`
8. `test-dashboard`

**Total: 8 services, ~450 MB idle RAM**

**NATS configuration**: This preset should enable JetStream by default:
```
# nats-server.conf
jetstream {
  store_dir: /data/jetstream
  max_mem: 256MB
  max_file: 1GB
}
```

---

### 3.6 content-platform (Content Platform) -- NEW

**Target user**: CMS, content-heavy websites, Laravel ecosystem.

| Attribute | Value |
|-----------|-------|
| **Auto-selected items** | |
| app | `php-laravel` |
| database | `mariadb` |
| services | `redis`, `minio`, `mailpit` |
| tooling | `db-ui` |
| **User must choose** | Nothing (fully specified) |
| **Optional add-ons shown** | `qa`, `wiremock`, `prometheus`, `grafana` |
| **Auto-wiring that fires** | Laravel -> MariaDB env vars (using Laravel naming); Laravel -> Redis host/port; Laravel -> MinIO/S3 (using Laravel naming); Laravel -> Mailpit SMTP |
| **Service count** | 9 |
| **Estimated idle RAM** | ~500-700 MB |
| **Estimated loaded RAM** | ~800-1100 MB |

**Manifest selections**:
```json
{
  "preset": "content-platform",
  "selections": {
    "app": ["php-laravel"],
    "database": ["mariadb"],
    "services": ["redis", "minio", "mailpit"],
    "tooling": ["db-ui"]
  },
  "prompts": [],
  "prompt_hint": null
}
```

**Generated services**:
1. `cert-gen`
2. `app` (PHP/Laravel)
3. `db` (MariaDB)
4. `redis`
5. `minio` (ports 9000, 9001)
6. `mailpit` (port 8025)
7. `db-ui` / Adminer (port 8083)
8. `web` (nginx, ports 8080/8443)
9. `tester`
10. `test-dashboard`

**Total: 10 services, ~600 MB idle RAM**

---

### 3.7 minimal (Bare Minimum) -- NEW

**Target user**: Quick prototyping, learning, or when resource constraints are tight.

| Attribute | Value |
|-----------|-------|
| **Auto-selected items** | None |
| **User must choose** | |
| app | One backend: any |
| database | Optional: `postgres` or `mariadb` or none |
| **Optional add-ons shown** | Everything else |
| **Auto-wiring that fires** | Backend -> DB env vars (if DB selected) |
| **Service count** | 3-5 |
| **Estimated idle RAM** | ~150-300 MB |
| **Estimated loaded RAM** | ~250-500 MB |

**Manifest selections**:
```json
{
  "preset": "minimal",
  "selections": {},
  "prompts": ["app", "database"],
  "prompt_hint": "Choose your app type and optionally a database"
}
```

**Generated services** (assuming Node.js, no database):
1. `cert-gen`
2. `app` (Node.js/Express)
3. `web` (nginx)
4. `tester`
5. `test-dashboard`

**Total: 5 services, ~200 MB idle RAM**

This is the lightest-weight preset and the best for resource-constrained environments or quick experiments.

---

### 3.8 Preset Comparison Summary

| Preset | Services | Idle RAM | Loaded RAM | First Boot | User Prompts |
|--------|----------|----------|------------|------------|--------------|
| **minimal** | 3-5 | 150-300 MB | 250-500 MB | ~15s | app, database |
| **spa-api** | 8 | 400-600 MB | 800-1200 MB | ~25s | backend choice |
| **api-only** | 8 | 350-500 MB | 600-900 MB | ~20s | language choice |
| **event-driven** | 8 | 400-550 MB | 700-1000 MB | ~20s | language choice |
| **data-pipeline** | 8 | 500-700 MB | 800-1200 MB | ~25s | none |
| **content-platform** | 10 | 500-700 MB | 800-1100 MB | ~30s | none |
| **full-stack** | 14 | 900-1300 MB | 1500-2200 MB | ~45s | backend choice |

---

## 4. Environment Variable Conventions

### 4.1 Database Connection

There are two dominant patterns for providing database credentials to applications: a single connection URL, or individual host/port/name/user/password variables.

#### Connection URL Format

```
postgresql://user:password@host:port/dbname
mysql://user:password@host:port/dbname
```

**Used by**: SQLAlchemy (Python), Sequelize (Node.js), Diesel (Rust), many Go ORMs.

The URL format is preferred by most modern ORMs because it is a single variable that encodes everything. It also makes it easy to swap between local and remote databases by changing one variable.

#### Individual Variable Format

```
DB_HOST=db
DB_PORT=5432
DB_NAME=myproject
DB_USER=myproject
DB_PASSWORD=secret
```

**Used by**: Go's `database/sql` (typically), PHP/Laravel, many older Node.js libraries.

#### Framework-Specific Naming

| Framework | Variable Name(s) | Format |
|-----------|------------------|--------|
| **Django** | `DATABASE_URL` | `postgresql://user:pass@host:port/db` |
| **FastAPI/SQLAlchemy** | `DATABASE_URL` | `postgresql+asyncpg://user:pass@host:port/db` |
| **Express/Sequelize** | `DATABASE_URL` | `postgres://user:pass@host:port/db` |
| **Express/Prisma** | `DATABASE_URL` | `postgresql://user:pass@host:port/db?schema=public` |
| **Go (standard)** | `DB_HOST`, `DB_PORT`, `DB_NAME`, `DB_USER`, `DB_PASSWORD` | Individual vars |
| **Go (GORM)** | `DATABASE_URL` or `DB_DSN` | `host=db user=user password=pass dbname=db port=5432 sslmode=disable` |
| **Laravel** | `DB_CONNECTION`, `DB_HOST`, `DB_PORT`, `DB_DATABASE`, `DB_USERNAME`, `DB_PASSWORD` | Individual vars, note `DB_DATABASE` not `DB_NAME`, `DB_USERNAME` not `DB_USER` |
| **Rust/Diesel** | `DATABASE_URL` | `postgres://user:pass@host:port/db` |
| **Rust/SQLx** | `DATABASE_URL` | `postgres://user:pass@host:port/db` |

**Recommendation for dev-strap**: Provide **both** formats. Set `DATABASE_URL` as a composed value and also set the individual variables. This covers all frameworks:

```yaml
environment:
  - DATABASE_URL=postgresql://${DB_USER}:${DB_PASSWORD}@db:${DB_PORT}/${DB_NAME}
  - DB_HOST=db
  - DB_PORT=${DB_PORT}
  - DB_NAME=${DB_NAME}
  - DB_USER=${DB_USER}
  - DB_PASSWORD=${DB_PASSWORD}
```

For Laravel, use the override names (already implemented in the PHP template).

### 4.2 Redis Connection

#### URL Format (preferred)

```
REDIS_URL=redis://redis:6379
REDIS_URL=redis://redis:6379/0    (with database number)
REDIS_URL=redis://:password@redis:6379/0    (with auth)
```

**Used by**: `ioredis` (Node.js), `redis-py` (Python), most Go Redis clients.

#### Individual Variables

```
REDIS_HOST=redis
REDIS_PORT=6379
REDIS_PASSWORD=    (empty for no auth)
REDIS_DB=0
```

**Used by**: Laravel (`REDIS_HOST`, `REDIS_PORT`, `REDIS_PASSWORD`), some older libraries.

| Framework | Variable(s) | Notes |
|-----------|-------------|-------|
| **Node.js (ioredis)** | `REDIS_URL` | Preferred |
| **Python (redis-py)** | `REDIS_URL` | Preferred |
| **Go (go-redis)** | `REDIS_URL` or `REDIS_ADDR` | `REDIS_ADDR` uses `host:port` format |
| **Laravel** | `REDIS_HOST`, `REDIS_PORT`, `REDIS_PASSWORD` | Individual vars |
| **Rust (redis-rs)** | `REDIS_URL` | URL format |

**Recommendation**: Provide `REDIS_URL=redis://redis:6379` plus individual vars. For Laravel, the template already uses `REDIS_HOST` and `REDIS_PORT`.

### 4.3 S3 / MinIO Connection

MinIO speaks the S3 protocol, so applications use S3 SDKs to connect. The critical difference from AWS S3 is the endpoint override.

#### Standard AWS SDK Variables

```
AWS_ENDPOINT_URL=http://minio:9000         # overrides S3 endpoint
AWS_ACCESS_KEY_ID=minioadmin
AWS_SECRET_ACCESS_KEY=minioadmin
AWS_DEFAULT_REGION=us-east-1               # required by SDKs, arbitrary for MinIO
AWS_S3_FORCE_PATH_STYLE=true               # MinIO needs path-style, not virtual-hosted
```

These are recognized by AWS SDKs in all languages (boto3, aws-sdk-js, aws-sdk-go, aws-sdk-rust).

**Note on `AWS_ENDPOINT_URL`**: This is the newer unified env var (supported since 2023 in AWS SDKs). Older SDKs may need language-specific overrides.

| Framework/SDK | Endpoint Variable | Path Style Variable |
|---------------|-------------------|---------------------|
| **Python (boto3)** | `AWS_ENDPOINT_URL` (new) or explicit `endpoint_url` parameter | `AWS_S3_FORCE_PATH_STYLE=true` or config |
| **Node.js (aws-sdk v3)** | `AWS_ENDPOINT_URL` or `forcePathStyle` in client config | Client config: `forcePathStyle: true` |
| **Go (aws-sdk-go-v2)** | `AWS_ENDPOINT_URL` or `BaseEndpoint` in config | `UsePathStyle: true` in client config |
| **Laravel** | `AWS_ENDPOINT` (note: no `_URL` suffix) | `AWS_USE_PATH_STYLE_ENDPOINT=true` |
| **Rust (aws-sdk-rust)** | `AWS_ENDPOINT_URL` | `force_path_style(true)` in config |

**Recommendation**: Set `AWS_ENDPOINT_URL` for all languages. Add `AWS_ENDPOINT` (without `_URL`) additionally in the Laravel template for compatibility.

### 4.4 NATS Connection

#### URL Format

```
NATS_URL=nats://nats:4222
```

This is the standard format used by NATS client libraries in all languages.

#### Individual Variables (less common)

```
NATS_HOST=nats
NATS_PORT=4222
```

| Framework | Variable | Notes |
|-----------|----------|-------|
| **Go (nats.go)** | `NATS_URL` | Standard |
| **Node.js (nats.js)** | `NATS_URL` or `NATS_SERVERS` | `NATS_SERVERS` for comma-separated multi-server |
| **Python (nats-py)** | `NATS_URL` | Standard |
| **Rust (async-nats)** | `NATS_URL` | Standard |

**Recommendation**: Use `NATS_URL=nats://nats:4222`. All client libraries support this format.

### 4.5 SMTP / Email (Mailpit)

| Framework | Variables | Notes |
|-----------|-----------|-------|
| **Node.js (nodemailer)** | `SMTP_HOST`, `SMTP_PORT` | Or a single `SMTP_URL=smtp://mailpit:1025` |
| **Python (smtplib/fastapi-mail)** | `MAIL_SERVER`, `MAIL_PORT` | Or `SMTP_HOST`, `SMTP_PORT` |
| **Go (net/smtp)** | `SMTP_HOST`, `SMTP_PORT` | Standard Go convention |
| **Laravel** | `MAIL_HOST`, `MAIL_PORT`, `MAIL_MAILER=smtp` | Laravel-specific names |

**Recommendation**: Use `SMTP_HOST=mailpit` and `SMTP_PORT=1025` for all non-Laravel backends. Override to `MAIL_HOST` and `MAIL_PORT` in the Laravel template.

### 4.6 Complete Environment Variable Reference

This table shows every environment variable dev-strap should inject, by service combination:

| When This Is Selected | Inject Into Backend | Variable | Value |
|-----------------------|---------------------|----------|-------|
| PostgreSQL | all backends | `DATABASE_URL` | `postgresql://${DB_USER}:${DB_PASSWORD}@db:5432/${DB_NAME}` |
| PostgreSQL | all backends | `DB_HOST` | `db` |
| PostgreSQL | all backends | `DB_PORT` | `5432` |
| PostgreSQL | all backends | `DB_NAME` | `${DB_NAME}` |
| PostgreSQL | all backends | `DB_USER` | `${DB_USER}` |
| PostgreSQL | all backends | `DB_PASSWORD` | `${DB_PASSWORD}` |
| MariaDB | all backends | `DATABASE_URL` | `mysql://${DB_USER}:${DB_PASSWORD}@db:3306/${DB_NAME}` |
| MariaDB | all backends | `DB_HOST` | `db` |
| MariaDB | all backends | `DB_PORT` | `3306` |
| Redis | all backends | `REDIS_URL` | `redis://redis:6379` |
| Redis | all backends | `REDIS_HOST` | `redis` |
| Redis | all backends | `REDIS_PORT` | `6379` |
| NATS | all backends | `NATS_URL` | `nats://nats:4222` |
| MinIO | all backends | `AWS_ENDPOINT_URL` | `http://minio:9000` |
| MinIO | all backends | `AWS_ACCESS_KEY_ID` | `minioadmin` |
| MinIO | all backends | `AWS_SECRET_ACCESS_KEY` | `minioadmin` |
| MinIO | all backends | `AWS_DEFAULT_REGION` | `us-east-1` |
| MinIO | all backends | `AWS_S3_FORCE_PATH_STYLE` | `true` |
| Mailpit | all backends | `SMTP_HOST` | `mailpit` |
| Mailpit | all backends | `SMTP_PORT` | `1025` |

Laravel overrides (in addition to or replacing the above):

| When This Is Selected | Variable | Laravel Value |
|-----------------------|----------|---------------|
| MariaDB | `DB_CONNECTION` | `mysql` |
| MariaDB | `DB_DATABASE` | `${DB_NAME}` |
| MariaDB | `DB_USERNAME` | `${DB_USER}` |
| PostgreSQL | `DB_CONNECTION` | `pgsql` |
| PostgreSQL | `DB_DATABASE` | `${DB_NAME}` |
| PostgreSQL | `DB_USERNAME` | `${DB_USER}` |
| Redis | `REDIS_HOST` | `redis` |
| Redis | `REDIS_PORT` | `6379` |
| Redis | `CACHE_DRIVER` | `redis` |
| Redis | `SESSION_DRIVER` | `redis` |
| Redis | `QUEUE_CONNECTION` | `redis` |
| MinIO | `AWS_ENDPOINT` | `http://minio:9000` |
| MinIO | `AWS_USE_PATH_STYLE_ENDPOINT` | `true` |
| MinIO | `FILESYSTEM_DISK` | `s3` |
| Mailpit | `MAIL_MAILER` | `smtp` |
| Mailpit | `MAIL_HOST` | `mailpit` |
| Mailpit | `MAIL_PORT` | `1025` |

---

## 5. Resource Estimation

### 5.1 Per-Service Resource Usage

All measurements are approximate, based on official images and typical development workloads.

| Service | Image | Compressed Image Size | Idle RAM | Light Load RAM | Startup Time | Notes |
|---------|-------|----------------------|----------|----------------|--------------|-------|
| **cert-gen** | eclipse-temurin:17-alpine | ~170 MB | 0 (exits) | 0 (exits) | ~3s | Run-once container |
| **nginx** (web) | nginx:alpine | ~20 MB | ~5 MB | ~15 MB | ~1s | |
| **Node.js** (Express) | node:20-alpine | ~130 MB | ~50 MB | ~100 MB | ~2s | Depends on app size |
| **Go** (Air) | golang:1.22-alpine | ~250 MB | ~20 MB | ~50 MB | ~3s | Initial build ~10s |
| **PHP** (Laravel/FPM) | php:8.3-fpm-alpine | ~80 MB | ~30 MB | ~80 MB | ~5s | Plus composer install |
| **Python** (FastAPI/uvicorn) | python:3.12-slim | ~120 MB | ~40 MB | ~100 MB | ~3s | Depends on deps |
| **Rust** (cargo-watch) | rust:1.77-slim | ~500 MB | ~30 MB | ~300 MB+ | ~30-60s | First compile is heavy |
| **Vite** (frontend) | node:20-alpine | ~130 MB | ~60 MB | ~120 MB | ~3s | HMR adds overhead |
| **PostgreSQL** | postgres:16-alpine | ~80 MB | ~30 MB | ~60 MB | ~3s | |
| **MariaDB** | mariadb:10.11 | ~120 MB | ~80 MB | ~150 MB | ~5s | |
| **Redis** | redis:alpine | ~15 MB | ~5 MB | ~20 MB | ~1s | Very lightweight |
| **NATS** | nats:latest | ~10 MB | ~10 MB | ~25 MB | ~1s | Extremely lightweight |
| **NATS** (with JetStream) | nats:latest | ~10 MB | ~15 MB | ~50 MB | ~1s | JetStream adds memory for streams |
| **MinIO** | minio/minio:latest | ~150 MB | ~100 MB | ~200 MB | ~3s | |
| **Mailpit** | axllent/mailpit:latest | ~15 MB | ~15 MB | ~30 MB | ~1s | |
| **WireMock** | wiremock/wiremock:latest | ~200 MB | ~150 MB | ~200 MB | ~5s | Java-based, high baseline |
| **Prometheus** | prom/prometheus:latest | ~80 MB | ~60 MB | ~120 MB | ~3s | Grows with retention |
| **Grafana** | grafana/grafana:latest | ~120 MB | ~80 MB | ~150 MB | ~5s | |
| **Dozzle** | amir20/dozzle:latest | ~15 MB | ~20 MB | ~40 MB | ~1s | Go binary, lightweight |
| **Adminer** | adminer:latest | ~25 MB | ~15 MB | ~30 MB | ~2s | PHP, lightweight |
| **Swagger UI** | swaggerapi/swagger-ui | ~25 MB | ~10 MB | ~20 MB | ~1s | Nginx serving static files |
| **Playwright** (tester) | mcr.microsoft.com/playwright:v1.52.0-noble | ~1.5 GB | ~50 MB | ~500 MB+ | ~1s (idle) | Large image; high RAM during test runs |
| **test-dashboard** | busybox:latest | ~2 MB | ~2 MB | ~2 MB | ~1s | As simple as it gets |

### 5.2 Aggregate Resource Usage by Preset

| Preset | Total Image Size (compressed) | Idle RAM | Light Load RAM | First Cold Boot | Warm Start |
|--------|------------------------------|----------|----------------|-----------------|------------|
| **minimal** (Node+nginx) | ~350 MB | ~110 MB | ~200 MB | ~30s (pull) | ~5s |
| **minimal** (Go+nginx) | ~470 MB | ~80 MB | ~150 MB | ~35s (pull) | ~8s |
| **spa-api** (Vite+Go+PG) | ~1.2 GB | ~400 MB | ~700 MB | ~60s (pull) | ~12s |
| **spa-api** (Vite+Node+PG) | ~1.1 GB | ~420 MB | ~750 MB | ~55s (pull) | ~10s |
| **api-only** (Node+PG+Redis) | ~600 MB | ~300 MB | ~500 MB | ~40s (pull) | ~8s |
| **api-only** (Go+PG+Redis) | ~700 MB | ~270 MB | ~450 MB | ~45s (pull) | ~10s |
| **event-driven** (Go+PG+NATS+Redis) | ~720 MB | ~320 MB | ~550 MB | ~45s (pull) | ~10s |
| **data-pipeline** (Python+PG+NATS+MinIO) | ~700 MB | ~450 MB | ~800 MB | ~50s (pull) | ~12s |
| **content-platform** (PHP+MariaDB+Redis+MinIO+Mailpit) | ~700 MB | ~500 MB | ~850 MB | ~55s (pull) | ~15s |
| **full-stack** (Vite+Go+PG+Redis+Prom+Grafana+Dozzle) | ~1.6 GB | ~900 MB | ~1500 MB | ~90s (pull) | ~20s |

### 5.3 Disk Usage (Volumes)

| Volume Type | Typical Size | Notes |
|-------------|-------------|-------|
| PostgreSQL data | 50-200 MB (dev) | Grows with data |
| MariaDB data | 100-300 MB (dev) | InnoDB tablespace |
| Redis data | <10 MB (dev) | In-memory primarily |
| NATS JetStream data | 10-100 MB (dev) | Depends on stream retention |
| MinIO data | 100 MB - 10 GB | Depends on uploads |
| Go modules cache | 100-500 MB | Shared across projects if named properly |
| Node modules (anonymous) | 200-800 MB | Per project |
| Python venv/packages | 100-500 MB | Depends on ML libraries; can be 2+ GB with PyTorch |
| Prometheus data | 100-500 MB | Depends on retention period |
| Grafana data | <50 MB | Dashboards and config |
| Rust target directory | 500 MB - 5 GB | Compilation artifacts; can be very large |
| Playwright browsers | ~1.5 GB | Chromium, Firefox, WebKit |

### 5.4 System Requirements

| Preset | Minimum RAM | Recommended RAM | Minimum Disk (images+volumes) | Notes |
|--------|-------------|-----------------|-------------------------------|-------|
| **minimal** | 4 GB | 8 GB | 2 GB | Works on most machines |
| **spa-api** | 8 GB | 16 GB | 5 GB | Common laptop minimum |
| **api-only** | 4 GB | 8 GB | 3 GB | |
| **event-driven** | 4 GB | 8 GB | 3 GB | |
| **data-pipeline** | 8 GB | 16 GB | 5-15 GB | MinIO data can be large |
| **content-platform** | 8 GB | 16 GB | 4 GB | |
| **full-stack** | 16 GB | 32 GB | 8 GB | Observability stack is heavy |

---

## 6. Implementation Considerations

### 6.1 Port Allocation Strategy

With the expanded catalog, port collisions are inevitable. Here is a complete port allocation map:

| Port Range | Category | Assigned Ports |
|------------|----------|----------------|
| 1025 | Services (SMTP) | Mailpit SMTP (internal only) |
| 3000-3999 | Backend apps | Node.js Express: 3000, Go: 3000 |
| 4222 | Services (messaging) | NATS client |
| 5173 | Frontend apps | Vite dev server |
| 5432 | Databases | PostgreSQL |
| 3306 | Databases | MariaDB |
| 6379 | Services (cache) | Redis |
| 8000 | Backend apps | Python/FastAPI |
| 8025 | Services (email UI) | Mailpit UI |
| 8080, 8443 | Infrastructure | Nginx HTTP, HTTPS |
| 8080 | Backend apps | Rust |
| 8082 | Tooling | Test dashboard |
| 8083 | Tooling | Adminer |
| 8084 | Tooling | Swagger UI |
| 8222 | Services (monitoring) | NATS monitor |
| 9000 | Services (storage) | MinIO API |
| 9001 | Services (storage UI) | MinIO Console |
| 9090 | Observability | Prometheus |
| 3001 | Observability | Grafana |
| 9999 | Observability | Dozzle |

**Known collisions**:
- Go (3000) and Node.js (3000): resolved by the fact that only one backend is usually selected, or multi-app support assigns different service names.
- MinIO API (9000) and PHP-FPM (9000): PHP-FPM port is internal only (nginx proxies to it), MinIO's 9000 is host-mapped. No actual collision in practice, but confusing. Consider moving MinIO API host-mapping to 9002.
- Rust (8080) and Nginx HTTP (8080): Nginx uses 8080 as the host port; Rust uses 8080 as the container port. Different namespaces, no collision. But if the user wants to access the Rust server directly (bypassing nginx), they need a different host port.

**Collision prevention logic for `generate.sh`**:
```bash
# Build a list of all host-mapped ports
# Check for duplicates
# If collision, increment the lower-priority service's port
```

### 6.2 Multi-App Support

The current architecture assumes a single `app` service. With Vite added as another `app` category item, the generator needs to support multiple `app` services:

- The `app` category has `"selection": "multi"` in the manifest, so multiple items can be selected.
- Each selected app needs its own service name: `vite`, `go`, `node`, `python`, etc. (not all named `app`).
- Dependencies and wiring need to reference the correct service name.

This is the largest architectural change needed. The current `APP_SERVICE` variable in `generate.sh` is singular. It needs to become an array or loop.

### 6.3 NATS Service Template

Recommended NATS service template:

```yaml
  nats:
    image: nats:latest
    container_name: ${PROJECT_NAME}-nats
    ports:
      - "${NATS_CLIENT_PORT}:4222"
      - "${NATS_MONITOR_PORT}:8222"
    command: "--jetstream --store_dir /data/jetstream -m 8222"
    volumes:
      - ${PROJECT_NAME}-nats-data:/data
    networks:
      - ${PROJECT_NAME}-internal
    healthcheck:
      test: ["CMD", "nats-server", "--signal", "ldm"]
      interval: 5s
      timeout: 3s
      retries: 10
```

**Note on healthcheck**: NATS does not have a built-in health endpoint. The `--signal ldm` command (lame duck mode check) returns 0 if the server is running. Alternatively, use `wget -qO- http://localhost:8222/healthz` if the monitoring port is enabled.

Updated healthcheck using the monitor endpoint (more reliable):
```yaml
    healthcheck:
      test: ["CMD-SHELL", "wget -qO- http://localhost:8222/healthz || exit 1"]
      interval: 5s
      timeout: 3s
      retries: 10
```

### 6.4 MinIO Service Template

Recommended MinIO service template:

```yaml
  minio:
    image: minio/minio:latest
    container_name: ${PROJECT_NAME}-minio
    ports:
      - "${MINIO_API_PORT}:9000"
      - "${MINIO_CONSOLE_PORT}:9001"
    environment:
      MINIO_ROOT_USER: minioadmin
      MINIO_ROOT_PASSWORD: minioadmin
    command: server /data --console-address ":9001"
    volumes:
      - ${PROJECT_NAME}-minio-data:/data
    networks:
      - ${PROJECT_NAME}-internal
    healthcheck:
      test: ["CMD", "mc", "ready", "local"]
      interval: 10s
      timeout: 3s
      retries: 5
```

**Note on healthcheck**: The `mc ready local` command is available in MinIO images and checks if the server is ready. Alternatively, use `curl -sf http://localhost:9000/minio/health/live`.

Updated healthcheck (more portable):
```yaml
    healthcheck:
      test: ["CMD-SHELL", "curl -sf http://localhost:9000/minio/health/live || exit 1"]
      interval: 10s
      timeout: 3s
      retries: 5
```

### 6.5 Adminer Service Template

```yaml
  db-ui:
    image: adminer:latest
    container_name: ${PROJECT_NAME}-db-ui
    ports:
      - "${ADMINER_PORT}:8080"
    environment:
      ADMINER_DEFAULT_SERVER: db
    networks:
      - ${PROJECT_NAME}-internal
    depends_on:
      db:
        condition: service_healthy
    healthcheck:
      test: ["CMD-SHELL", "wget -qO- http://localhost:8080/ || exit 1"]
      interval: 10s
      timeout: 3s
      retries: 5
```

### 6.6 Swagger UI Service Template

```yaml
  swagger-ui:
    image: swaggerapi/swagger-ui:latest
    container_name: ${PROJECT_NAME}-swagger-ui
    ports:
      - "${SWAGGER_PORT}:8080"
    environment:
      SWAGGER_JSON_URL: http://app:${APP_PORT}/openapi.json
    networks:
      - ${PROJECT_NAME}-internal
    healthcheck:
      test: ["CMD-SHELL", "wget -qO- http://localhost:8080/ || exit 1"]
      interval: 10s
      timeout: 3s
      retries: 5
```

**Note**: The `SWAGGER_JSON_URL` needs auto-wiring to the correct backend hostname and port. This is a cross-category wiring scenario.

### 6.7 Vite Frontend Template

```yaml
  vite:
    build:
      context: ${FRONTEND_SOURCE}
      dockerfile: Dockerfile
    container_name: ${PROJECT_NAME}-vite
    ports:
      - "${VITE_PORT}:5173"
    volumes:
      - ${FRONTEND_SOURCE}:/app
      - /app/node_modules
    working_dir: /app
    environment:
      - VITE_API_PROXY_TARGET=${PROXY_TARGET}
    networks:
      - ${PROJECT_NAME}-internal
    healthcheck:
      test: ["CMD-SHELL", "wget -qO- http://localhost:5173/ || exit 1"]
      interval: 5s
      timeout: 3s
      retries: 10
```

Corresponding Dockerfile:
```dockerfile
FROM node:20-alpine
WORKDIR /app
COPY package*.json ./
RUN npm ci
COPY . .
CMD ["npx", "vite", "--host", "0.0.0.0"]
```

The `--host 0.0.0.0` flag is critical -- without it, Vite only listens on localhost inside the container, making it unreachable from other containers and the host.

### 6.8 Python/FastAPI Template

```yaml
  app:
    build:
      context: ${APP_SOURCE}
      dockerfile: Dockerfile
    container_name: ${PROJECT_NAME}-app
    volumes:
      - ${APP_SOURCE}:/app
      - ${PROJECT_NAME}-certs:/certs:ro
    working_dir: /app
    environment:
      - PYTHONUNBUFFERED=1
      - PORT=8000
      - REQUESTS_CA_BUNDLE=/certs/ca.crt
      - DB_HOST=db
      - DB_PORT=${DB_PORT}
      - DB_NAME=${DB_NAME}
      - DB_USER=${DB_USER}
      - DB_PASSWORD=${DB_PASSWORD}
      - DATABASE_URL=postgresql://${DB_USER}:${DB_PASSWORD}@db:${DB_PORT}/${DB_NAME}
    depends_on:
      cert-gen:
        condition: service_completed_successfully
    networks:
      - ${PROJECT_NAME}-internal
```

Corresponding Dockerfile:
```dockerfile
FROM python:3.12-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY . .
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000", "--reload"]
```

**Note**: `PYTHONUNBUFFERED=1` ensures print statements and log output appear immediately in Docker logs rather than being buffered.

### 6.9 Rust Template

```yaml
  app:
    build:
      context: ${APP_SOURCE}
      dockerfile: Dockerfile
    container_name: ${PROJECT_NAME}-app
    volumes:
      - ${APP_SOURCE}:/app
      - ${PROJECT_NAME}-cargo-registry:/usr/local/cargo/registry
      - ${PROJECT_NAME}-cargo-target:/app/target
      - ${PROJECT_NAME}-certs:/certs:ro
    working_dir: /app
    environment:
      - RUST_LOG=debug
      - PORT=8080
      - SSL_CERT_FILE=/certs/ca.crt
      - DB_HOST=db
      - DB_PORT=${DB_PORT}
      - DB_NAME=${DB_NAME}
      - DB_USER=${DB_USER}
      - DB_PASSWORD=${DB_PASSWORD}
      - DATABASE_URL=postgres://${DB_USER}:${DB_PASSWORD}@db:${DB_PORT}/${DB_NAME}
    depends_on:
      cert-gen:
        condition: service_completed_successfully
    networks:
      - ${PROJECT_NAME}-internal
```

**Important**: Rust needs two named volumes for caching: `cargo-registry` (downloaded crates) and `target` (compilation artifacts). Without these, every container restart triggers a full recompile, which takes minutes.

Corresponding Dockerfile:
```dockerfile
FROM rust:1.77-slim
RUN apt-get update && apt-get install -y pkg-config libssl-dev && rm -rf /var/lib/apt/lists/*
RUN cargo install cargo-watch
WORKDIR /app
COPY . .
CMD ["cargo", "watch", "-x", "run"]
```

### 6.10 Prometheus Dynamic Scrape Configuration

When a backend is selected alongside Prometheus, the Prometheus config needs a scrape target for the backend. The current `prometheus.yml` only scrapes itself.

Proposed approach: generate the Prometheus config dynamically (like docker-compose.yml) rather than using a static file.

Add to `core/compose/generate.sh`:
```bash
# Generate prometheus.yml if Prometheus is in EXTRAS
if [[ ",${EXTRAS}," == *",prometheus,"* ]]; then
    PROM_CONFIG="${OUTPUT_DIR}/prometheus.yml"
    cat > "${PROM_CONFIG}" <<PROMCFG
global:
  scrape_interval: 15s
  evaluation_interval: 15s

scrape_configs:
  - job_name: 'prometheus'
    static_configs:
      - targets: ['localhost:9090']

  - job_name: 'app'
    static_configs:
      - targets: ['app:${APP_PORT}']
    metrics_path: /metrics
PROMCFG
fi
```

Then mount the generated config instead of the static template:
```yaml
    volumes:
      - ${OUTPUT_DIR}/prometheus.yml:/etc/prometheus/prometheus.yml:ro
```

---

## Appendix A: Docker Compose Service Names

For reference, here is the mapping of catalog items to Docker Compose service names. These names are used as Docker DNS hostnames within the container network.

| Catalog Item | Service Name | Hostname |
|--------------|-------------|----------|
| `node-express` | `app` | `app` |
| `go` | `app` | `app` |
| `php-laravel` | `app` | `app` |
| `python-fastapi` | `app` | `app` |
| `rust` | `app` | `app` |
| `vite` | `vite` | `vite` |
| `postgres` | `db` | `db` |
| `mariadb` | `db` | `db` |
| `redis` | `redis` | `redis` |
| `nats` | `nats` | `nats` |
| `minio` | `minio` | `minio` |
| `mailpit` | `mailpit` | `mailpit` |
| `wiremock` | `wiremock` | `wiremock` |
| `prometheus` | `prometheus` | `prometheus` |
| `grafana` | `grafana` | `grafana` |
| `dozzle` | `dozzle` | `dozzle` |
| `db-ui` (Adminer) | `db-ui` | `db-ui` |
| `swagger-ui` | `swagger-ui` | `swagger-ui` |
| `qa` | `tester` | `tester` |
| `qa-dashboard` | `test-dashboard` | `test-dashboard` |
| nginx | `web` | `web` |
| cert-gen | `cert-gen` | `cert-gen` |

## Appendix B: Image Versions and Update Cadence

| Image | Recommended Tag | Update Cadence | Breaking Change Risk |
|-------|----------------|----------------|---------------------|
| `postgres` | `16-alpine` | Major every ~2 years | Low (stable) |
| `mariadb` | `10.11` | Major every ~2 years | Low (LTS) |
| `redis` | `alpine` (latest) | Frequent, backward compatible | Low |
| `nats` | `latest` | Frequent, backward compatible | Low |
| `minio/minio` | `latest` | Frequent | Medium (API stable, console changes) |
| `node` | `20-alpine` | LTS every 2 years | Medium (even-numbered = LTS) |
| `python` | `3.12-slim` | Minor every year | Low |
| `rust` | `1.77-slim` | Every 6 weeks | Low (stability guarantee) |
| `golang` | `1.22-alpine` | Every 6 months | Low (compatibility promise) |
| `php` | `8.3-fpm-alpine` | Minor every year | Low |
| `nginx` | `alpine` | Frequent | Low |
| `prom/prometheus` | `latest` | Monthly | Low |
| `grafana/grafana` | `latest` | Monthly | Low |
| `adminer` | `latest` | Infrequent | Low |
| `swaggerapi/swagger-ui` | `latest` | Monthly | Low |
| `wiremock/wiremock` | `latest` | Monthly | Low |
| `axllent/mailpit` | `latest` | Monthly | Low |

**Recommendation**: Pin major versions for databases and language runtimes. Use `latest` for stateless tooling (Adminer, Swagger UI, Dozzle) where breaking changes are rare and auto-updates provide security fixes.
