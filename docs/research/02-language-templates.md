# Language Template Research: Python (FastAPI) and Rust

Research findings for adding Python (FastAPI) and Rust app templates to dev-strap.
All recommendations are informed by the existing patterns in `templates/apps/node-express/`,
`templates/apps/go/`, and `templates/apps/php-laravel/`, plus `core/compose/generate.sh`
and `core/nginx/generate-conf.sh`.

---

## Table of Contents

1. [Python (FastAPI)](#1-python-fastapi)
2. [Rust](#2-rust)
3. [Generator Changes Required](#3-generator-changes-required)
4. [Cross-Cutting Concerns](#4-cross-cutting-concerns)
5. [Framework Comparison Notes](#5-framework-comparison-notes)
6. [Implementation Checklist](#6-implementation-checklist)

---

## 1. Python (FastAPI)

### 1.1 Base Image: `python:3.12-slim` (Recommended)

| Criterion | `python:3.12-slim` | `python:3.12-alpine` |
|-----------|-------------------|---------------------|
| Base OS | Debian Bookworm (glibc) | Alpine (musl libc) |
| Image size | ~150 MB | ~50 MB |
| Binary wheel support | Full — pip installs prebuilt wheels | Partial — many wheels need compilation |
| Build tools needed | Rarely | Often (gcc, musl-dev, libffi-dev) |
| C extension compat | Excellent | Problematic (numpy, pandas, psycopg2, lxml) |
| DNS behavior | Standard glibc resolver | musl resolver has subtle differences |
| `update-ca-certificates` | Available via `ca-certificates` package | Available via `apk add ca-certificates` |
| Debugging tools | More available by default | Minimal |

**Recommendation: `python:3.12-slim`**

The size advantage of Alpine is negated once you install build dependencies for C extensions.
Python wheels on PyPI are built against glibc (manylinux). With Alpine, pip must compile from
source, adding minutes to builds and requiring gcc/musl-dev. The slim variant is the standard
choice for production and development Python containers.

For forward-looking consideration: Python 3.13 is stable (released Oct 2024) and 3.14 is in
beta. The template should use `python:3.12-slim` initially but note the upgrade path. The
Dockerfile should pin the minor version (3.12, not 3) so upgrades are intentional.

### 1.2 Package Management: `uv` (Recommended)

| Tool | Install speed | Lock file | Docker layer caching | Virtual env handling | Maturity |
|------|--------------|-----------|---------------------|---------------------|----------|
| pip + requirements.txt | Baseline | Manual freeze | Good (COPY requirements.txt first) | Manual or none | Very mature |
| poetry | 2-5x slower than pip | poetry.lock | Awkward (needs pyproject.toml + poetry.lock) | Managed | Mature |
| uv | 10-100x faster than pip | uv.lock | Excellent (COPY pyproject.toml + uv.lock first) | Managed | Production-ready since 2024 |

**Recommendation: `uv`** with pip fallback support.

uv (by Astral, the ruff team) is the modern standard for Python packaging. It is written in
Rust, installs packages 10-100x faster than pip, handles virtual environments transparently,
and has excellent Docker integration patterns. It replaces pip, pip-tools, virtualenv, and
pyenv in a single binary.

However, many existing Python projects still use `requirements.txt`. The Dockerfile should
support both patterns: detect `pyproject.toml` (uv/poetry) or fall back to `requirements.txt`
(pip).

**uv Docker pattern:**
```dockerfile
# Install uv (single binary, no dependencies)
COPY --from=ghcr.io/astral-sh/uv:latest /uv /uvx /usr/local/bin/

# Copy dependency files first for layer caching
COPY pyproject.toml uv.lock* ./

# Install dependencies into the project virtual environment
RUN uv sync --frozen --no-install-project 2>/dev/null || \
    ([ -f requirements.txt ] && uv pip install --system -r requirements.txt) || true
```

Key uv Docker considerations:
- `--frozen` prevents uv from updating the lock file during install
- `--no-install-project` installs only dependencies, not the project itself (for layer caching)
- `uv sync` respects pyproject.toml + uv.lock; fallback to `uv pip install` for requirements.txt
- uv caches in `~/.cache/uv` — this should be a named volume for faster rebuilds
- In dev mode, `uv run` automatically finds/creates the virtualenv

### 1.3 File Watcher: `uvicorn --reload` (Recommended)

| Option | How it works | Pros | Cons |
|--------|-------------|------|------|
| `uvicorn --reload` | Built-in to uvicorn, uses watchfiles internally | Zero extra deps, just works | Only watches Python files by default |
| `watchfiles` (standalone) | External file watcher, can run any command | Watches all file types | Extra dependency, more config |

**Recommendation: `uvicorn --reload`**

Uvicorn's built-in `--reload` flag uses `watchfiles` internally (it's a dependency of uvicorn).
This gives you the same file-watching behavior with zero additional setup. It watches `.py`
files by default, which is what you want for a FastAPI app. The `--reload-dir` flag can
restrict the watch scope if needed.

For non-FastAPI Python apps that don't use uvicorn, `watchfiles` can be used as a standalone
watcher: `watchfiles "python main.py" ./src`. But within the dev-strap context, FastAPI +
uvicorn --reload is the simplest path.

### 1.4 CA Certificate Strategy

Python has a fragmented SSL certificate landscape. Different HTTP libraries look at
different environment variables.

| Library | Env var checked | Notes |
|---------|----------------|-------|
| `requests` | `REQUESTS_CA_BUNDLE`, then `CURL_CA_BUNDLE` | Most popular HTTP library |
| `httpx` | `SSL_CERT_FILE` (via Python ssl module) | Modern async HTTP |
| `urllib3` | `REQUESTS_CA_BUNDLE`, `CURL_CA_BUNDLE` | Used internally by requests |
| `aiohttp` | `SSL_CERT_FILE` (via Python ssl module) | Popular async HTTP |
| `certifi` | N/A — has its own bundle | Used by requests as default |
| Python `ssl` module | `SSL_CERT_FILE`, `SSL_CERT_DIR` | Standard library |

**Recommendation: Set both `REQUESTS_CA_BUNDLE` and `SSL_CERT_FILE`**

```yaml
environment:
  - REQUESTS_CA_BUNDLE=/certs/ca.crt    # requests, urllib3, httpx (sometimes)
  - SSL_CERT_FILE=/certs/ca.crt         # Python ssl module, aiohttp, httpx
  - CURL_CA_BUNDLE=/certs/ca.crt        # curl CLI, some libraries check this
```

This three-variable approach covers every major Python HTTP library. `REQUESTS_CA_BUNDLE`
handles the requests ecosystem (by far the most common). `SSL_CERT_FILE` handles the standard
library ssl module and libraries that use it directly (httpx, aiohttp). `CURL_CA_BUNDLE` is
belt-and-suspenders for edge cases and the curl CLI inside the container.

An alternative is to install the CA into the system trust store at runtime (like PHP does):
```bash
cp /certs/ca.crt /usr/local/share/ca-certificates/devstack-ca.crt
update-ca-certificates
```
This covers everything but requires `ca-certificates` package and must run at container start
(init.sh or entrypoint), not build time. The env var approach is simpler and matches the
Node/Go pattern. Use env vars as the primary strategy, with a note in the init.sh template
about the OS trust store approach as a fallback.

### 1.5 Volume Caching Strategy

Python creates several cacheable artifacts:

| Cache | Default location | Size | Purpose |
|-------|-----------------|------|---------|
| pip cache | `~/.cache/pip` | 50-500 MB | Downloaded wheel/sdist cache |
| uv cache | `~/.cache/uv` | 50-500 MB | Downloaded package cache |
| virtualenv | `/app/.venv` or `~/.local` | 20-200 MB | Installed packages |
| `__pycache__` | Scattered in source tree | Small | Bytecode cache |

**Recommendation:**
- Named volume for pip/uv cache: `${PROJECT_NAME}-python-cache:/root/.cache`
- Do NOT volume-mount the virtualenv separately — it lives inside `/app/.venv` which is
  already covered by the source mount (`${APP_SOURCE}:/app`).
- `__pycache__` does not need special handling — it's small and lives in the source tree.
- Set `PYTHONDONTWRITEBYTECODE=1` to skip `__pycache__` generation entirely in dev
  (avoids permission issues and unnecessary file noise).

The named volume for the cache directory means `uv sync` / `pip install` can reuse downloaded
packages across container rebuilds, dramatically speeding up dependency installation.

### 1.6 Port: 3000 (Recommended)

Uvicorn's convention is port 8000, but dev-strap's nginx generator proxies all non-PHP apps
to `app:3000`. Using port 3000 avoids any nginx generator changes and matches the existing
Go and Node patterns.

Uvicorn fully supports `--port 3000`. The CMD in the Dockerfile and the `PORT=3000`
environment variable make this explicit.

### 1.7 Draft Dockerfile

```dockerfile
# templates/apps/python-fastapi/Dockerfile
FROM python:3.12-slim

# uv for fast dependency management
COPY --from=ghcr.io/astral-sh/uv:latest /uv /uvx /usr/local/bin/

# System dependencies for common Python packages (psycopg2, mysqlclient, etc.)
RUN apt-get update && apt-get install -y --no-install-recommends \
    gcc libpq-dev default-libmysqlclient-dev pkg-config \
    ca-certificates curl \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Install dependencies first (layer caching)
# Supports both uv (pyproject.toml) and pip (requirements.txt) workflows
COPY pyproject.toml uv.lock* requirements.txt* ./
RUN if [ -f pyproject.toml ]; then \
        uv sync --frozen --no-install-project 2>/dev/null || true; \
    elif [ -f requirements.txt ]; then \
        uv pip install --system --no-cache-dir -r requirements.txt; \
    fi

# Copy source
COPY . .

# NOTE: The DevStack CA cert is mounted at /certs/ca.crt at runtime (not build time).
# Python trusts it via REQUESTS_CA_BUNDLE and SSL_CERT_FILE set in service.yml.
# For OS-level trust (e.g., subprocess calls), add this to init.sh:
#   cp /certs/ca.crt /usr/local/share/ca-certificates/devstack-ca.crt && update-ca-certificates

EXPOSE 3000

# uvicorn with --reload for live development
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "3000", "--reload"]
```

**Layer caching notes:**
- `COPY --from=ghcr.io/astral-sh/uv:latest` is a multi-stage copy — uv is a single
  static binary, so this adds ~30 MB and zero dependencies.
- The dependency install layer is cached until `pyproject.toml`, `uv.lock`, or
  `requirements.txt` changes.
- System dependencies (gcc, libpq-dev, etc.) are installed before app deps because they
  change less frequently.
- The `2>/dev/null || true` pattern matches the existing Go and PHP templates — graceful
  failure when no dependency files exist yet (fresh project).

**Non-root user consideration:**
The existing dev-strap templates (Node, Go, PHP) all run as root inside the container.
This is standard for development containers — non-root adds complexity with volume
permissions (the host-mounted `/app` directory is owned by the host user's UID).
Recommendation: keep root for consistency, add a comment noting that production Dockerfiles
should use a non-root user.

### 1.8 Draft service.yml

```yaml
# templates/apps/python-fastapi/service.yml
  app:
    build:
      context: ${APP_SOURCE}
      dockerfile: Dockerfile
    container_name: ${PROJECT_NAME}-app
    volumes:
      - ${APP_SOURCE}:/app
      - ${PROJECT_NAME}-python-cache:/root/.cache
      - ${PROJECT_NAME}-certs:/certs:ro
    working_dir: /app
    environment:
      - PYTHONUNBUFFERED=1
      - PYTHONDONTWRITEBYTECODE=1
      - PORT=3000
      - REQUESTS_CA_BUNDLE=/certs/ca.crt
      - SSL_CERT_FILE=/certs/ca.crt
      - CURL_CA_BUNDLE=/certs/ca.crt
      - DB_HOST=db
      - DB_PORT=${DB_PORT}
      - DB_NAME=${DB_NAME}
      - DB_USER=${DB_USER}
      - DB_PASSWORD=${DB_PASSWORD}
    depends_on:
      cert-gen:
        condition: service_completed_successfully
    networks:
      - ${PROJECT_NAME}-internal
```

**Key details:**
- `PYTHONUNBUFFERED=1` — ensures print() and log output appears immediately in
  `./devstack.sh logs app` without buffering.
- `PYTHONDONTWRITEBYTECODE=1` — prevents `__pycache__/` directories cluttering the
  host-mounted source directory.
- Three CA cert env vars cover the entire Python HTTP library ecosystem.
- Named volume `${PROJECT_NAME}-python-cache` caches pip/uv downloads across rebuilds.
- DB vars use `DB_HOST`, `DB_PORT`, `DB_NAME`, `DB_USER`, `DB_PASSWORD` matching the
  Node/Go pattern (individual vars, not a connection string). The connection string is
  the app's responsibility to construct.

### 1.9 Init Script Pattern

```bash
#!/bin/sh
# init.sh for Python (FastAPI)

echo "[init] Installing Python dependencies..."
cd /app

if [ -f pyproject.toml ]; then
    uv sync 2>/dev/null || pip install -e ".[dev]" 2>/dev/null || true
elif [ -f requirements.txt ]; then
    uv pip install --system -r requirements.txt 2>/dev/null || \
        pip install -r requirements.txt 2>/dev/null || true
fi

echo "[init] Python initialization complete."
```

The init script mirrors the Node pattern (`npm install`) — it ensures dependencies are
installed even if the container was rebuilt. The `uv sync` fallback to `pip install`
handles projects that haven't adopted uv yet.

### 1.10 Manifest Entry

```json
"python-fastapi": {
  "label": "Python (FastAPI)",
  "description": "FastAPI with uvicorn hot reload",
  "defaults": { "port": 3000 }
}
```

This goes into `contract/manifest.json` under `categories.app.items`.

---

## 2. Rust

### 2.1 Base Image: `rust:1.83-slim` (Recommended)

| Criterion | `rust:1.83-slim` | `rust:1.83-alpine` |
|-----------|-----------------|-------------------|
| Base OS | Debian Bookworm (glibc) | Alpine (musl libc) |
| Image size | ~850 MB | ~750 MB |
| Binary linking | Dynamic (glibc) | Static (musl) |
| Crate compat | Full — all crates work | Most work, some have musl issues |
| C library bindings | Standard, well-tested | Occasional issues (openssl, ring) |
| Debug symbols | Full support | Some tooling gaps |
| `pkg-config` / system libs | Standard apt packages | apk equivalents, sometimes different names |
| `openssl` / TLS | `libssl-dev` works everywhere | `openssl-dev` with musl, may need `openssl-sys` feature flags |

**Recommendation: `rust:1.83-slim`**

The size difference is negligible (~100 MB) because the Rust toolchain itself is ~700 MB.
The glibc base avoids musl-related compilation issues with crates that link against C
libraries (openssl, libpq, libmysqlclient, ring, etc.). For production, you would cross-compile
to musl for static binaries, but for dev containers, glibc is the path of least friction.

**Version note:** Rust 1.83 is used in the example, but the template should document that
the version can be bumped to any stable release. Rust has a 6-week release cycle, so the
Dockerfile version will need periodic updates.

### 2.2 File Watcher: `cargo-watch` (Recommended)

| Tool | Purpose | Maturity | Overhead |
|------|---------|----------|----------|
| `cargo-watch` | Runs `cargo build`/`cargo run` on file changes | Very mature, widely used | Minimal — just watches files |
| `cargo-leptos` | Full-stack Rust (Leptos framework) watcher | Framework-specific | Leptos only |
| `systemfd` + `listenfd` | Socket handoff for zero-downtime reloads | Mature but niche | Requires app code changes |
| `bacon` | TUI for running cargo commands on change | Newer alternative | Requires terminal |

**Recommendation: `cargo-watch`**

`cargo-watch` is the established standard for Rust file-watching in development. It runs
any cargo command on file changes with debouncing and filtering. The typical dev command is:

```bash
cargo watch -x run
# or with more control:
cargo watch -w src -x 'run -- --port 3000'
```

`systemfd` + `listenfd` enable zero-downtime reloads by passing the listening socket to the
new process. This is elegant but requires the application to use the `listenfd` crate, which
couples the dev infrastructure to the app code. Not appropriate for a general-purpose template.

`cargo-leptos` is specific to the Leptos full-stack framework and not general-purpose.

`bacon` is a newer TUI tool that is nice interactively but doesn't work well in a headless
Docker container (no TTY).

### 2.3 CA Certificate Strategy

| TLS Backend | Env var | Notes |
|-------------|---------|-------|
| `rustls` (pure Rust) | `SSL_CERT_FILE` | Reads PEM bundle from this path |
| `native-tls` (links OpenSSL) | `SSL_CERT_FILE` | OpenSSL reads this env var |
| `openssl` crate | `SSL_CERT_FILE` | Direct OpenSSL binding |

**Recommendation: `SSL_CERT_FILE=/certs/ca.crt`**

This single env var works for both major TLS backends in the Rust ecosystem:
- `rustls` (used by `reqwest` with `rustls-tls` feature, `hyper-rustls`, etc.) reads
  `SSL_CERT_FILE` to load additional CA certificates.
- `native-tls` / `openssl` (used by `reqwest` with `native-tls` feature) reads
  `SSL_CERT_FILE` through OpenSSL's standard env var handling.

This matches the Go template's approach exactly. One env var covers all cases.

**Caveat:** `SSL_CERT_FILE` replaces the default certificate bundle — it does not add to it.
If the app needs to trust both the DevStack CA and public CAs, the init.sh should concatenate
them:
```bash
cat /etc/ssl/certs/ca-certificates.crt /certs/ca.crt > /tmp/combined-ca.crt
export SSL_CERT_FILE=/tmp/combined-ca.crt
```
Or better, install the DevStack CA into the OS trust store:
```bash
cp /certs/ca.crt /usr/local/share/ca-certificates/devstack-ca.crt
update-ca-certificates
```

For the service.yml, use `SSL_CERT_FILE=/certs/ca.crt` as the default (matches Go), with
the init.sh containing the `update-ca-certificates` approach as an alternative. The
`SSL_CERT_FILE` approach is simpler and sufficient for most use cases where the app only
talks to mocked services.

**Important nuance:** In Go, `SSL_CERT_FILE` works cleanly because Go's crypto/tls reads
it and falls back to the system store. In Rust with `rustls`, `SSL_CERT_FILE` is the ONLY
source of trusted CAs — there is no fallback. If the Rust app needs to reach real public
HTTPS endpoints (not just mocked ones), the combined-cert or `update-ca-certificates`
approach is required. The init.sh should handle this by default.

### 2.4 Volume Caching Strategy (Critical)

Rust compile caches are the single biggest challenge for Rust in Docker. A typical project's
`target/` directory is 1-10 GB. Without caching, every container restart means a full
recompile (5-30 minutes for a real project).

| Cache | Default location | Size | Purpose |
|-------|-----------------|------|---------|
| Cargo registry | `/usr/local/cargo/registry` | 100-500 MB | Downloaded crate sources |
| Cargo git | `/usr/local/cargo/git` | 50-200 MB | Git-based dependencies |
| Build cache (`target/`) | `/app/target` | 1-10 GB | Compiled artifacts, intermediates |

**Recommendation: Three named volumes**

```yaml
volumes:
  - ${APP_SOURCE}:/app
  - ${PROJECT_NAME}-cargo-registry:/usr/local/cargo/registry
  - ${PROJECT_NAME}-cargo-target:/app/target
  - ${PROJECT_NAME}-certs:/certs:ro
```

- **`cargo-registry`**: Caches downloaded crate sources. Without this, `cargo build`
  re-downloads all dependencies on every container rebuild.
- **`cargo-target`**: This is the critical one. The `target/` directory contains all
  compiled artifacts. Without this volume, every container restart means a full recompile.
  With it, incremental compilation works across restarts.

**Why `target/` must be a named volume, not part of the bind mount:**
The app source is bind-mounted from the host (`${APP_SOURCE}:/app`). If `target/` were
part of this bind mount, it would:
1. Sync 1-10 GB to the host filesystem (slow on macOS/Windows due to filesystem translation)
2. Pollute the host with Linux-compiled artifacts (useless on host, confusing for IDEs)
3. Cause filesystem performance issues (Docker bind mount I/O for millions of small files)

A named volume for `target/` keeps it inside Docker's storage driver, which is much faster
for the random I/O patterns of compilation. The tradeoff: `target/` is not visible on the
host, but this is a feature, not a bug.

**Compile time considerations for dev workflow:**
- First compile after `devstack.sh start`: 2-30 minutes depending on dependencies.
  The `cargo-target` volume means this only happens once until the volume is deleted.
- Incremental compiles (after editing a source file): 2-30 seconds. `cargo-watch`
  triggers these automatically.
- Adding a new dependency to Cargo.toml: 1-5 minutes for the new crate + its transitive
  deps. Previously compiled crates are cached in `target/`.
- `devstack.sh stop` with volume cleanup: The named volumes are deleted. Next start will
  be a fresh compile. Consider documenting a `devstack.sh stop --keep-volumes` option or
  similar for Rust users who want to preserve build caches.

### 2.5 Port: 3000 (Matches nginx default)

All non-PHP apps use port 3000 in dev-strap. The Rust app should listen on 3000.
The CMD and PORT env var make this explicit.

Common Rust web frameworks default to different ports but all support configuration:
- Actix Web: defaults to 8080, configurable via `HttpServer::bind("0.0.0.0:3000")`
- Axum: no default, you specify in `TcpListener::bind("0.0.0.0:3000")`
- Rocket: defaults to 8000, configurable via `ROCKET_PORT=3000`

### 2.6 Draft Dockerfile

```dockerfile
# templates/apps/rust/Dockerfile
FROM rust:1.83-slim

# System dependencies for common crates (openssl, database drivers)
RUN apt-get update && apt-get install -y --no-install-recommends \
    pkg-config libssl-dev libpq-dev default-libmysqlclient-dev \
    ca-certificates curl \
    && rm -rf /var/lib/apt/lists/*

# cargo-watch for live reload on file changes
RUN cargo install cargo-watch

WORKDIR /app

# Copy dependency files first (layer caching)
COPY Cargo.toml Cargo.lock* ./
# Create a dummy main.rs so cargo can resolve/download dependencies
RUN mkdir -p src && echo 'fn main() { println!("placeholder"); }' > src/main.rs
RUN cargo build 2>/dev/null || true
RUN rm -rf src

# Copy source
COPY . .

# NOTE: The DevStack CA cert is mounted at /certs/ca.crt at runtime (not build time).
# Rust trusts it via SSL_CERT_FILE=/certs/ca.crt set in service.yml.
# For apps that need to reach both mocked and real HTTPS endpoints, add this to init.sh:
#   cp /certs/ca.crt /usr/local/share/ca-certificates/devstack-ca.crt && update-ca-certificates

EXPOSE 3000

# cargo-watch rebuilds and runs on file changes
CMD ["cargo", "watch", "-x", "run"]
```

**Layer caching strategy:**
The dummy `main.rs` trick is the standard Rust Docker pattern. It allows `cargo build` to
download and compile all dependencies during the image build. When source code changes,
only the final `COPY . .` layer is invalidated — dependencies are already compiled in the
cached layer. This can save 5-30 minutes per rebuild.

However, in dev-strap's architecture, the source is bind-mounted at runtime, so the Docker
build step is primarily about having the toolchain and cargo-watch ready. The `cargo-target`
named volume provides the persistent incremental compile cache.

**Image size note:**
The `rust:1.83-slim` image is ~850 MB. Adding cargo-watch adds ~50 MB. This is large
compared to Node (~200 MB) or Go (~350 MB), but unavoidable — the Rust compiler is big.
This is a dev image, not a production image.

### 2.7 Draft service.yml

```yaml
# templates/apps/rust/service.yml
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
      - RUST_BACKTRACE=1
      - PORT=3000
      - SSL_CERT_FILE=/certs/ca.crt
      - DB_HOST=db
      - DB_PORT=${DB_PORT}
      - DB_NAME=${DB_NAME}
      - DB_USER=${DB_USER}
      - DB_PASSWORD=${DB_PASSWORD}
    depends_on:
      cert-gen:
        condition: service_completed_successfully
    networks:
      - ${PROJECT_NAME}-internal
```

**Key details:**
- `RUST_LOG=debug` — enables the `env_logger`/`tracing` ecosystem logging. Almost all
  Rust web frameworks use this.
- `RUST_BACKTRACE=1` — shows full backtraces on panics. Essential for dev.
- Two named volumes for cargo caches (registry + target). Both must be declared in
  the compose generator's volumes section.
- `SSL_CERT_FILE=/certs/ca.crt` matches the Go template's approach.

### 2.8 Init Script Pattern

```bash
#!/bin/sh
# init.sh for Rust

echo "[init] Setting up Rust project..."
cd /app

# Trust the DevStack CA cert in the OS store
# (needed if the app reaches both mocked and real HTTPS endpoints)
if [ -f /certs/ca.crt ]; then
    cp /certs/ca.crt /usr/local/share/ca-certificates/devstack-ca.crt
    update-ca-certificates 2>/dev/null
fi

# Pre-build to warm the compile cache (runs in background to not block startup)
echo "[init] Triggering initial build (this may take a few minutes for new projects)..."
cargo build 2>&1 | tail -1

echo "[init] Rust initialization complete."
```

The init script for Rust is different from Python/Node because the "dependency install" step
is `cargo build`, which both downloads and compiles crates. The first build is slow but
subsequent builds use the `cargo-target` volume cache.

The `update-ca-certificates` call is included by default for Rust because `SSL_CERT_FILE`
replaces (not appends to) the system trust store with rustls. If the app talks to real HTTPS
endpoints in addition to mocked ones, it needs the system CAs too.

### 2.9 Manifest Entry

```json
"rust": {
  "label": "Rust",
  "description": "Rust with cargo-watch live reload",
  "defaults": { "port": 3000 }
}
```

---

## 3. Generator Changes Required

Adding Python and Rust templates requires changes to `core/compose/generate.sh` for
app-type-specific volume declarations.

### 3.1 Changes to `core/compose/generate.sh`

The "App-type-specific volumes" section (lines 147-151) currently only handles Go:

```bash
# Current code:
APP_VOLUMES=""
if [ "${APP_TYPE}" = "go" ]; then
    APP_VOLUMES="
  ${PROJECT_NAME}-go-modules:"
fi
```

**Required change:**

```bash
APP_VOLUMES=""
case "${APP_TYPE}" in
    go)
        APP_VOLUMES="
  ${PROJECT_NAME}-go-modules:"
        ;;
    python-fastapi)
        APP_VOLUMES="
  ${PROJECT_NAME}-python-cache:"
        ;;
    rust)
        APP_VOLUMES="
  ${PROJECT_NAME}-cargo-registry:
  ${PROJECT_NAME}-cargo-target:"
        ;;
esac
```

This uses a `case` statement instead of an `if` chain, which is cleaner as more languages
are added. The named volumes are appended to the `volumes:` section of the generated
docker-compose.yml.

### 3.2 Changes to `core/nginx/generate-conf.sh`

**No changes required.** The nginx generator already handles this correctly:
- PHP-Laravel gets the FastCGI proxy block (to `app:9000`)
- "Everything else" gets the HTTP reverse proxy block (to `app:3000`)

Python and Rust both use port 3000, so they fall into the "everything else" path. The
comment on line 123 already anticipates this: `# Proxy-based apps (Node, Go, Rust, etc.)`.

### 3.3 Changes to `contract/manifest.json`

Add both entries under `categories.app.items`:

```json
"python-fastapi": {
  "label": "Python (FastAPI)",
  "description": "FastAPI with uvicorn hot reload",
  "defaults": { "port": 3000 }
},
"rust": {
  "label": "Rust",
  "description": "Rust with cargo-watch live reload",
  "defaults": { "port": 3000 }
}
```

### 3.4 Changes to `project.env` comment

Update the comment on the `APP_TYPE` line:
```
# Type must match a directory in templates/apps/ (php-laravel, go, node-express, python-fastapi, rust)
```

### 3.5 Changes to `DB_PORT` derivation

The compose generator's `DB_PORT` derivation (lines 138-142) works for both new languages
without changes — it already handles postgres (5432) and mariadb (3306) with a mariadb
default.

---

## 4. Cross-Cutting Concerns

### 4.1 Database Connection Strings

Each language ecosystem has its own convention for database connection configuration.
Dev-strap currently passes individual env vars (`DB_HOST`, `DB_PORT`, `DB_NAME`, `DB_USER`,
`DB_PASSWORD`). This is correct — the app constructs the connection string.

| Language | PostgreSQL driver | MySQL/MariaDB driver | Connection string format |
|----------|------------------|---------------------|------------------------|
| **Node.js** | `pg` | `mysql2` | Individual vars or `DATABASE_URL=postgres://user:pass@host:5432/db` |
| **Go** | `pgx`, `lib/pq` | `go-sql-driver/mysql` | `user:pass@tcp(host:3306)/db` or `postgres://user:pass@host:5432/db` |
| **PHP** | `pdo_pgsql` | `pdo_mysql` | Framework handles it (config/database.php) |
| **Python** | `psycopg2`, `asyncpg` | `pymysql`, `aiomysql` | `postgresql://user:pass@host:5432/db` or `mysql+pymysql://user:pass@host:3306/db` |
| **Rust** | `tokio-postgres`, `sqlx` | `mysql_async`, `sqlx` | `postgres://user:pass@host:5432/db` or `mysql://user:pass@host:3306/db` |

**Recommendation:** Keep passing individual env vars as done today. This is the most flexible
approach — every language can construct its preferred connection string format from the parts.
Adding a pre-constructed `DATABASE_URL` is tempting but problematic:
- The format differs by driver (`mysql://` vs `mysql+pymysql://` vs `mariadb://`)
- Some drivers want individual parameters, not a URL
- The app-type-specific service.yml can include a `DATABASE_URL` that uses the right format
  for that language, if desired

For Python and Rust specifically, adding a `DATABASE_URL` in the service.yml is reasonable
because SQLAlchemy (Python) and sqlx (Rust) both strongly prefer connection URLs. But it
should be in addition to the individual vars, not replacing them:

```yaml
# Python service.yml addition (optional)
- DATABASE_URL=mysql+pymysql://${DB_USER}:${DB_PASSWORD}@db:${DB_PORT}/${DB_NAME}

# Rust service.yml addition (optional)
- DATABASE_URL=mysql://${DB_USER}:${DB_PASSWORD}@db:${DB_PORT}/${DB_NAME}
```

**Concern:** The `DB_TYPE` determines the scheme (`mysql://` vs `postgres://`), but the
compose generator does not currently construct `DATABASE_URL`. This would need conditional
logic per `APP_TYPE` x `DB_TYPE` combination. Recommendation: defer this to a later
iteration. Document that the app should read the individual vars and construct its own URL,
or add `DATABASE_URL` to the app's own `.env` file.

### 4.2 Redis Connections

Redis is an extra service (`templates/extras/redis/service.yml`). When enabled, the Redis
container is named `${PROJECT_NAME}-redis` and available at hostname `redis` on the internal
network.

| Language | Popular Redis client | Connection |
|----------|---------------------|------------|
| **Node.js** | `ioredis`, `redis` | `redis://redis:6379` |
| **Go** | `go-redis/redis` | `redis:6379` |
| **PHP** | `predis`, phpredis ext | `redis:6379` (config in .env) |
| **Python** | `redis-py`, `aioredis` | `redis://redis:6379` |
| **Rust** | `redis-rs` | `redis://redis:6379` |

All languages connect the same way — the hostname `redis` resolves within the Docker network.
The service.yml templates should include `REDIS_URL=redis://redis:6379` when Redis is a
likely companion. However, since Redis is an optional extra, adding `REDIS_URL` to every
template creates noise for users who don't use Redis.

**Recommendation:** Do not add `REDIS_URL` to the base service.yml. Instead, document it in
the template's README or init.sh comments. If Redis auto-detection is desired later, the
compose generator could conditionally inject `REDIS_URL` when `EXTRAS` contains `redis`.

### 4.3 Environment Variable Conventions by Ecosystem

| Env var | Python | Rust | Purpose |
|---------|--------|------|---------|
| `PORT` | Yes | Yes | App listen port |
| `DB_HOST`, `DB_PORT`, etc. | Yes | Yes | Database connection |
| `DATABASE_URL` | SQLAlchemy convention | sqlx convention | Full connection URL |
| `REDIS_URL` | Common | Common | Redis connection |
| `LOG_LEVEL` / `RUST_LOG` | `LOG_LEVEL` or `LOGLEVEL` | `RUST_LOG` | Logging verbosity |
| `DEBUG` / `RUST_BACKTRACE` | `DEBUG=1` (Django) | `RUST_BACKTRACE=1` | Debug mode |
| `SECRET_KEY` | Django/Flask convention | N/A | App secret |
| `PYTHONUNBUFFERED` | Yes | N/A | Disable stdout buffering |
| `PYTHONDONTWRITEBYTECODE` | Yes | N/A | Skip __pycache__ |
| `RUST_LOG` | N/A | Yes | tracing/env_logger filter |
| `RUST_BACKTRACE` | N/A | Yes | Panic backtrace |

### 4.4 WireMock Mock Interception Compatibility

The WireMock mock interception pattern works identically for all languages because it
operates at the DNS + TLS level:

1. App makes HTTPS request to `api.example.com`
2. Docker DNS resolves it to the nginx container (network alias)
3. Nginx terminates TLS (using the DevStack CA cert)
4. Nginx proxies to WireMock

The only language-specific concern is CA trust (covered in sections 1.4 and 2.3 above).
Once the app trusts the DevStack CA, mock interception is transparent.

| Language | CA trust mechanism | Works out of the box? |
|----------|-------------------|----------------------|
| **Node.js** | `NODE_EXTRA_CA_CERTS` (additive) | Yes |
| **Go** | `SSL_CERT_FILE` (additive, falls back to system) | Yes |
| **PHP** | `update-ca-certificates` (OS trust store) | Yes |
| **Python** | `REQUESTS_CA_BUNDLE` + `SSL_CERT_FILE` | Yes |
| **Rust** | `SSL_CERT_FILE` (replaces system store with rustls) | Mostly — see caveat below |

**Rust caveat:** With `rustls`, `SSL_CERT_FILE` replaces the entire trust store. If the
Rust app needs to reach both mocked domains and real public HTTPS endpoints, the init.sh
must install the DevStack CA into the OS trust store and NOT set `SSL_CERT_FILE`. Or,
concatenate the DevStack CA with the system bundle. The init.sh template addresses this.

---

## 5. Framework Comparison Notes

### 5.1 Python Frameworks

| Framework | Type | When to use | Template name |
|-----------|------|-------------|---------------|
| **FastAPI** | Async API | New APIs, microservices, high-performance | `python-fastapi` |
| **Django** | Full-stack | Admin panels, CMS, data-heavy apps, ORM-centric | `python-django` (future) |
| **Flask** | Micro | Simple APIs, prototypes | Not worth a template — use FastAPI |

**FastAPI (recommended first template):**
- Built on Starlette (ASGI) + Pydantic
- Automatic OpenAPI/Swagger documentation
- Native async support
- Uvicorn as the ASGI server (with --reload for dev)
- Type hints drive request validation
- Excellent for API-first development
- Init script: `pip install -r requirements.txt` or `uv sync`

**Django (potential future template):**
- Batteries-included (ORM, admin, auth, migrations, templates)
- Uses WSGI by default (gunicorn), ASGI with Django Channels
- Needs additional Dockerfile setup: `python manage.py collectstatic`, `migrate`
- Init script would run: `python manage.py migrate --no-input`
- Different project structure: `manage.py` at root, apps as subdirectories
- Would need a different file watcher: `python manage.py runserver 0.0.0.0:3000` has
  built-in reload
- Template name: `python-django`
- Port: 3000 (override Django's default 8000)

**Flask is not worth a separate template** — FastAPI is strictly better for new projects.
Flask users can use the FastAPI template and swap uvicorn for gunicorn/flask.

### 5.2 Rust Frameworks

| Framework | Type | When to use | Ecosystem size |
|-----------|------|-------------|----------------|
| **Axum** | Async API | New projects, tokio ecosystem | Growing fast, backed by tokio team |
| **Actix Web** | Async API | High-performance APIs | Mature, large ecosystem |
| **Rocket** | Full-featured | Rapid prototyping | Mature but slower evolution |

**A single `rust` template works for all three** because they all:
- Compile to a single binary
- Listen on a configurable port
- Use `cargo build` / `cargo watch`
- Share the same dependency management (Cargo.toml/Cargo.lock)

The Dockerfile and service.yml are identical regardless of which framework is used. The
only difference is in the app code itself, which is outside dev-strap's scope.

If framework-specific templates are ever needed, the differentiators would be:
- **Axum**: No special template needs. Standard cargo-watch.
- **Actix Web**: Same as Axum.
- **Rocket**: Needs `ROCKET_PORT=3000` and `ROCKET_ADDRESS=0.0.0.0` env vars in service.yml.
  But this is minor enough to document rather than create a separate template.

### 5.3 Database Driver Packages to Pre-Install

**Python (`python:3.12-slim`):**

The Dockerfile should install system libraries for the most common database drivers:
```dockerfile
RUN apt-get update && apt-get install -y --no-install-recommends \
    gcc \
    libpq-dev \                     # psycopg2 (PostgreSQL)
    default-libmysqlclient-dev \    # mysqlclient (MySQL/MariaDB)
    pkg-config \                    # required by mysqlclient build
    && rm -rf /var/lib/apt/lists/*
```

Python database drivers:
| Database | Sync driver | Async driver | System dep |
|----------|------------|-------------|------------|
| PostgreSQL | `psycopg2-binary` | `asyncpg` | `libpq-dev` (for psycopg2 from source) |
| MySQL/MariaDB | `pymysql` (pure Python) | `aiomysql` | None (pure Python) |
| MySQL/MariaDB | `mysqlclient` (C ext) | N/A | `default-libmysqlclient-dev` |
| SQLite | Built-in `sqlite3` | `aiosqlite` | None |

Note: `psycopg2-binary` includes its own libpq and does not need `libpq-dev`. Only the
source build of `psycopg2` needs it. Including `libpq-dev` covers both cases.

For FastAPI projects, `pymysql` (pure Python, no system deps) is often preferred over
`mysqlclient` (C extension). The Dockerfile includes the system deps anyway because
they are needed by many other packages.

**Rust (`rust:1.83-slim`):**

The Dockerfile should install system libraries for native TLS and database drivers:
```dockerfile
RUN apt-get update && apt-get install -y --no-install-recommends \
    pkg-config \
    libssl-dev \              # openssl-sys crate (required by many HTTP/TLS crates)
    libpq-dev \               # diesel/postgres crates
    default-libmysqlclient-dev \  # diesel/mysql crates
    && rm -rf /var/lib/apt/lists/*
```

Rust database crates:
| Database | ORM | Raw driver | System dep |
|----------|-----|-----------|------------|
| PostgreSQL | `diesel` (pg), `sea-orm` | `tokio-postgres`, `sqlx` | `libpq-dev` (for diesel), none for sqlx (pure Rust) |
| MySQL/MariaDB | `diesel` (mysql) | `mysql_async`, `sqlx` | `default-libmysqlclient-dev` (for diesel), none for sqlx |
| SQLite | `diesel` (sqlite) | `rusqlite`, `sqlx` | `libsqlite3-dev` |

Note: `sqlx` with the `rustls` feature requires zero system libraries — it's pure Rust.
`diesel` requires the C libraries for each database backend. Including both sets of deps
in the Dockerfile covers all cases.

### 5.4 Testing Frameworks

**Python:**
| Framework | Type | Integration |
|-----------|------|-------------|
| `pytest` | Unit + integration | De facto standard, excellent plugin ecosystem |
| `pytest-asyncio` | Async test support | Required for testing async FastAPI endpoints |
| `httpx` | HTTP test client | FastAPI's recommended test client (`TestClient`) |
| `pytest-cov` | Coverage | Coverage reporting |

Recommended test stack for FastAPI: `pytest` + `pytest-asyncio` + `httpx` (via FastAPI's
`TestClient`).

**Rust:**
| Framework | Type | Integration |
|-----------|------|-------------|
| Built-in `#[test]` | Unit tests | Part of the language, zero setup |
| Built-in integration tests | Integration tests | `tests/` directory, zero setup |
| `tokio::test` | Async tests | For testing async handlers |
| `reqwest` | HTTP client for e2e | For testing running servers |

Rust's built-in testing is excellent and requires no additional dependencies. `cargo test`
runs all tests. `cargo watch -x test` runs them on file changes.

### 5.5 DevContainer Configuration

**Python:**
```json
{
    "name": "DevStack App (Python)",
    "dockerComposeFile": ["../../../.generated/docker-compose.yml"],
    "service": "app",
    "workspaceFolder": "/app",
    "customizations": {
        "vscode": {
            "extensions": [
                "ms-python.python",
                "ms-python.vscode-pylance",
                "charliermarsh.ruff",
                "ms-playwright.playwright"
            ],
            "settings": {
                "python.defaultInterpreterPath": "/usr/local/bin/python",
                "python.analysis.typeCheckingMode": "basic",
                "[python]": {
                    "editor.defaultFormatter": "charliermarsh.ruff",
                    "editor.formatOnSave": true
                }
            }
        }
    }
}
```

**Rust:**
```json
{
    "name": "DevStack App (Rust)",
    "dockerComposeFile": ["../../../.generated/docker-compose.yml"],
    "service": "app",
    "workspaceFolder": "/app",
    "customizations": {
        "vscode": {
            "extensions": [
                "rust-lang.rust-analyzer",
                "vadimcn.vscode-lldb",
                "tamasfe.even-better-toml",
                "ms-playwright.playwright"
            ],
            "settings": {
                "rust-analyzer.cargo.buildScripts.enable": true,
                "rust-analyzer.check.command": "clippy"
            }
        }
    }
}
```

---

## 6. Implementation Checklist

### Python (FastAPI) Template

1. [ ] Create `templates/apps/python-fastapi/Dockerfile` (section 1.7)
2. [ ] Create `templates/apps/python-fastapi/service.yml` (section 1.8)
3. [ ] Create `templates/apps/python-fastapi/.devcontainer/devcontainer.json` (section 5.5)
4. [ ] Update `core/compose/generate.sh` — add `python-fastapi` case for `APP_VOLUMES` (section 3.1)
5. [ ] Update `contract/manifest.json` — add `python-fastapi` to `categories.app.items` (section 3.3)
6. [ ] Update `project.env` comment to list `python-fastapi` (section 3.4)
7. [ ] Create sample app in `app/` with `main.py` + `requirements.txt` for testing
8. [ ] Test: `APP_TYPE=python-fastapi ./devstack.sh start` then `curl http://localhost:8080/health`
9. [ ] Test mock interception: `./devstack.sh shell app` then `python -c "import requests; print(requests.get('https://<mocked-domain>/test').text)"`
10. [ ] Run `./devstack.sh test`

### Rust Template

1. [ ] Create `templates/apps/rust/Dockerfile` (section 2.6)
2. [ ] Create `templates/apps/rust/service.yml` (section 2.7)
3. [ ] Create `templates/apps/rust/.devcontainer/devcontainer.json` (section 5.5)
4. [ ] Update `core/compose/generate.sh` — add `rust` case for `APP_VOLUMES` (section 3.1)
5. [ ] Update `contract/manifest.json` — add `rust` to `categories.app.items` (section 3.3)
6. [ ] Update `project.env` comment to list `rust` (section 3.4)
7. [ ] Create sample app in `app/` with `Cargo.toml` + `src/main.rs` for testing
8. [ ] Test: `APP_TYPE=rust ./devstack.sh start` then `curl http://localhost:8080/health`
9. [ ] Test mock interception: `./devstack.sh shell app` then `curl -k https://<mocked-domain>/test`
10. [ ] Run `./devstack.sh test`
11. [ ] Verify `cargo-target` and `cargo-registry` volumes persist across `devstack.sh restart`

### Shared

1. [ ] Update `docs/CREATING_TEMPLATES.md` — add Python and Rust to the CA cert table
2. [ ] Update `docs/AI_BOOTSTRAP.md` — add Python and Rust to the CA cert section (pitfall #4)
3. [ ] Consider adding `devstack.sh stop --keep-volumes` for Rust users (large compile cache)

---

## Appendix A: File Tree After Implementation

```
templates/apps/
├── go/
│   ├── Dockerfile
│   └── service.yml
├── node-express/
│   ├── Dockerfile
│   └── service.yml
├── php-laravel/
│   ├── Dockerfile
│   └── service.yml
├── python-fastapi/          # NEW
│   ├── Dockerfile
│   ├── service.yml
│   └── .devcontainer/
│       └── devcontainer.json
└── rust/                    # NEW
    ├── Dockerfile
    ├── service.yml
    └── .devcontainer/
        └── devcontainer.json
```

## Appendix B: Named Volumes Summary

| APP_TYPE | Named volumes (besides certs) | Approximate size |
|----------|-------------------------------|-----------------|
| `node-express` | (none — node_modules excluded via anonymous volume) | N/A |
| `go` | `${PROJECT_NAME}-go-modules` | 100-500 MB |
| `php-laravel` | (none) | N/A |
| `python-fastapi` | `${PROJECT_NAME}-python-cache` | 50-500 MB |
| `rust` | `${PROJECT_NAME}-cargo-registry`, `${PROJECT_NAME}-cargo-target` | 1-10 GB combined |

## Appendix C: SSL_CERT_FILE Behavior Differences

This is a subtle but important difference that affects template design:

| Language | SSL_CERT_FILE behavior | Safe to use alone? |
|----------|----------------------|-------------------|
| **Node.js** | N/A — uses `NODE_EXTRA_CA_CERTS` which ADDS to system store | Yes |
| **Go** | Falls back to system store if SSL_CERT_FILE is not set; when set, it is the only source | Mostly — Go still checks system paths |
| **Rust (rustls)** | REPLACES the entire trust store — no system fallback | Only if app only talks to mocked services |
| **Rust (native-tls)** | Passes through to OpenSSL which respects system store | Yes |
| **Python (requests)** | `REQUESTS_CA_BUNDLE` REPLACES certifi's bundle | Only if app only talks to mocked services |
| **Python (ssl module)** | `SSL_CERT_FILE` REPLACES system store | Only if app only talks to mocked services |

This is why the Rust and Python init.sh templates include `update-ca-certificates` — it
installs the DevStack CA into the OS trust store alongside public CAs, so the app can reach
both mocked and real HTTPS endpoints without the env vars replacing the trust store.
