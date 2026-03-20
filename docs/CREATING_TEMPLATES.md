# Creating App Templates

This guide walks through creating a new app template -- for example, adding Rust, Python/FastAPI, or any other language. It also covers frontend templates.

## What a template is

A template is a directory in `templates/apps/` that defines:

1. How to build the app container (Dockerfile)
2. How to wire the container into the docker-compose stack (service.yml)
3. Optionally, file-watcher config for live reload
4. Optionally, VS Code devcontainer config

```
templates/apps/my-language/
├── Dockerfile                # REQUIRED: container build instructions
├── service.yml               # REQUIRED: docker-compose service definition
├── .devcontainer/
│   └── devcontainer.json     # OPTIONAL: VS Code integration
└── (language-specific config) # OPTIONAL: .air.toml, cargo-watch, nodemon, etc.
```

## Step-by-step: creating a Rust template

### Step 1: Create the directory

```bash
mkdir -p templates/apps/rust/.devcontainer
```

### Step 2: Write the Dockerfile

The Dockerfile must:
- Install the language toolchain
- Set up file-watching for live reload (for compiled languages)
- Expose port 3000 (or 9000 for PHP-FPM)
- Copy and install dependencies
- Set a default CMD

Here is the actual Rust Dockerfile (`templates/apps/rust/Dockerfile`):

```dockerfile
FROM rust:1.83-slim

# System dependencies for common crates (openssl, database drivers)
RUN apt-get update && apt-get install -y --no-install-recommends \
    pkg-config libssl-dev ca-certificates wget \
    && rm -rf /var/lib/apt/lists/*

# cargo-watch for live reload on file changes
RUN cargo install cargo-watch

WORKDIR /app

# Copy dependency files first (layer caching)
COPY Cargo.toml Cargo.lock* ./
# Create a dummy main.rs so cargo can resolve/download dependencies
RUN mkdir -p src && echo 'fn main() {}' > src/main.rs \
    && cargo build 2>/dev/null || true \
    && rm -rf src

COPY . .

# NOTE: The DevStack CA cert is mounted at /certs/ca.crt at runtime (not build time).
# Rust trusts it via SSL_CERT_FILE=/certs/ca.crt set in service.yml.
# For apps that need to reach both mocked and real HTTPS endpoints, add this to init.sh:
#   cp /certs/ca.crt /usr/local/share/ca-certificates/devstack-ca.crt && update-ca-certificates

EXPOSE 3000

# cargo-watch rebuilds and runs on file changes
CMD ["cargo", "watch", "-x", "run"]
```

**Key detail: dependency caching.** The dummy `main.rs` trick lets `cargo build` download and compile all dependencies during the Docker build. When you change your source code, the cached dependency layer is reused -- only your code gets recompiled. Without this, every source change triggers a full dependency rebuild.

### Step 3: Write service.yml

The service.yml defines how this container fits into the docker-compose stack.

Here is the actual Rust template (`templates/apps/rust/service.yml`):

```yaml
  app:
    build:
      context: ${APP_SOURCE}
      dockerfile: Dockerfile
    container_name: ${PROJECT_NAME}-app
    volumes:
      - ${APP_SOURCE}:/app
      - ${PROJECT_NAME}-certs:/certs:ro
      - ${PROJECT_NAME}-cargo-registry:/usr/local/cargo/registry
      - ${PROJECT_NAME}-cargo-target:/app/target
    working_dir: /app
    environment:
      - RUST_LOG=debug
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

**Critical rules:**

- Service name must be `app` (the Caddy config generator expects this).
- Use `${VARIABLE}` placeholders for values from project.env.
- Mount the app source and certs volume.
- Connect to the project network.

**Critical: the `cargo-target` volume.** The `${PROJECT_NAME}-cargo-target:/app/target` volume is essential for Rust. Without it, every container restart triggers a full recompile of all dependencies (5-30 minutes). The named volume persists the compiled artifacts between restarts.

**Important:** Named volumes (like `${PROJECT_NAME}-cargo-registry`) must be prefixed with `${PROJECT_NAME}` so they're properly namespaced and cleaned up on `./devstack.sh stop`.

### Step 4: Register cache volumes in the compose generator

If your app template uses named cache volumes (like the Rust cargo volumes or a Python pip cache), add a case to the volume case statement in `core/compose/generate.sh` (around lines 170-186):

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
    my-language)                          # <-- add your case
        APP_VOLUMES="
  ${PROJECT_NAME}-my-cache:"
        ;;
esac
```

Without this registration, Docker Compose will error because the volume is referenced in service.yml but never declared in the top-level `volumes:` section.

### Available placeholder variables

| Variable | Replaced with | Example |
|----------|--------------|---------|
| `${PROJECT_NAME}` | project.env `PROJECT_NAME` | `my-saas-app` |
| `${APP_SOURCE}` | Absolute path to app source | `/home/user/devstack/app` |
| `${DB_TYPE}` | project.env `DB_TYPE` | `mariadb` |
| `${DB_PORT}` | Derived from DB_TYPE (3306/5432) | `5432` |
| `${DB_NAME}` | project.env `DB_NAME` | `my_saas_app` |
| `${DB_USER}` | project.env `DB_USER` | `app` |
| `${DB_PASSWORD}` | project.env `DB_PASSWORD` | `secret` |
| `${DB_ROOT_PASSWORD}` | project.env `DB_ROOT_PASSWORD` | `root` |

### Trusting the mock CA certificate

For HTTPS mock interception to work, your app must trust the DevStack CA certificate. The cert is at `/certs/ca.crt` inside the container (mounted from the certs volume at runtime -- not available during Docker build). How to trust it depends on the language:

| Language | Environment variable(s) | Notes |
|----------|------------------------|-------|
| Node.js | `NODE_EXTRA_CA_CERTS=/certs/ca.crt` | Built-in Node support |
| Go | `SSL_CERT_FILE=/certs/ca.crt` | Built-in Go support |
| Rust | `SSL_CERT_FILE=/certs/ca.crt` | Works with rustls and native-tls |
| Python | `REQUESTS_CA_BUNDLE=/certs/ca.crt`, `SSL_CERT_FILE=/certs/ca.crt`, `CURL_CA_BUNDLE=/certs/ca.crt` | Triple env var: covers `requests`, `httpx`/`aiohttp` (via OpenSSL), and `curl` subprocess calls |
| Java | Import into JKS keystore | Use `keytool` in Dockerfile |
| PHP | Update OS trust store | `update-ca-certificates` in Dockerfile |

**Python note:** Python has the most complex CA setup because different HTTP libraries read different environment variables. The shipped `python-fastapi` template sets all three to be safe:

```yaml
environment:
  - REQUESTS_CA_BUNDLE=/certs/ca.crt
  - SSL_CERT_FILE=/certs/ca.crt
  - CURL_CA_BUNDLE=/certs/ca.crt
```

For PHP and Java, the CA cert is mounted at runtime (not available at build time), so trust it in your `init.sh`:

```bash
# init.sh -- for PHP
cp /certs/ca.crt /usr/local/share/ca-certificates/devstack-ca.crt
update-ca-certificates
```

**Do NOT** try to `COPY /certs/ca.crt` in the Dockerfile -- the certs volume doesn't exist during the Docker build, only at runtime.

### Port convention

The Caddy config generator (`core/caddy/generate-caddyfile.sh`) uses the `APP_TYPE` to decide how to route:

- **`php-laravel`**: Routes via FastCGI to `app:9000`
- **Everything else**: Routes via HTTP reverse proxy to `app:3000`

If your app listens on a different port, either:
1. Make your app listen on port 3000 (recommended -- change the app, not the infra)
2. Edit `core/caddy/generate-caddyfile.sh` to add your app type's port

### Step 5: Add devcontainer config (optional)

```json
// templates/apps/rust/.devcontainer/devcontainer.json
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
                "ms-playwright.playwright"
            ],
            "settings": {
                "rust-analyzer.cargo.buildScripts.enable": true
            }
        }
    }
}
```

### Step 6: Add to manifest

Register the new app type in `contract/manifest.json` under `categories.app.items`:

```json
"rust": {
  "label": "Rust",
  "description": "Rust with cargo-watch live reload",
  "defaults": { "port": 3000 }
}
```

### Step 7: Use it

```env
# project.env
APP_TYPE=rust
APP_SOURCE=./my-rust-app
```

```bash
./devstack.sh stop && ./devstack.sh start
```

## Example: Python/FastAPI Template

The Python/FastAPI template is a shipped template. Here are the actual files.

**Dockerfile** (`templates/apps/python-fastapi/Dockerfile`):

```dockerfile
FROM python:3.12-slim

# uv for fast dependency management
COPY --from=ghcr.io/astral-sh/uv:latest /uv /usr/local/bin/uv

# CA certificates package (needed for update-ca-certificates in init)
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Install dependencies first (layer caching)
COPY requirements.txt* pyproject.toml* ./
RUN if [ -f requirements.txt ]; then uv pip install --system -r requirements.txt; \
    elif [ -f pyproject.toml ]; then uv pip install --system -e .; fi

# Don't COPY app source -- it's volume-mounted in dev

# NOTE: The DevStack CA cert is mounted at /certs/ca.crt at runtime (not build time).
# Python trusts it via REQUESTS_CA_BUNDLE and SSL_CERT_FILE set in service.yml.
# For OS-level trust (e.g., subprocess calls), add this to init.sh:
#   cp /certs/ca.crt /usr/local/share/ca-certificates/devstack-ca.crt && update-ca-certificates

EXPOSE 3000

# uvicorn with --reload for live development
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "3000", "--reload"]
```

**Key differences from the Rust template:**
- Uses `uv` (from Astral) instead of pip for fast dependency installs.
- Supports both `requirements.txt` and `pyproject.toml` for dependency specification.
- Does NOT copy app source (volume-mounted in dev mode).
- Installs `ca-certificates` package for OS-level CA trust.

**service.yml** (`templates/apps/python-fastapi/service.yml`):

```yaml
  app:
    build:
      context: ${APP_SOURCE}
      dockerfile: Dockerfile
    container_name: ${PROJECT_NAME}-app
    volumes:
      - ${APP_SOURCE}:/app
      - ${PROJECT_NAME}-certs:/certs:ro
      - ${PROJECT_NAME}-python-cache:/root/.cache
    working_dir: /app
    environment:
      - PYTHONUNBUFFERED=1
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
- The `python-cache` volume persists pip/uv download caches between restarts.
- `PYTHONUNBUFFERED=1` ensures logs appear in real time (Python buffers stdout by default).
- Triple CA env vars cover `requests`, `httpx`/`aiohttp`, and `curl` subprocess calls.

## Frontend templates

Frontend templates live in `templates/frontends/` and define a separate dev server that runs alongside the backend. Caddy handles path-based routing between frontend and backend.

### How frontend routing works

When a frontend is configured (`FRONTEND_TYPE` in project.env), the Caddy config generator creates path-based routing:

- Requests matching `${FRONTEND_API_PREFIX}/*` (default: `/api/*`) are proxied to the backend (`app:3000`).
- All other requests are proxied to the frontend dev server (`frontend:5173`).
- Test results are still served at `/test-results/`.

### Creating a frontend template

Frontend templates use the same structure as app templates but live in `templates/frontends/`:

```
templates/frontends/my-frontend/
├── Dockerfile    # REQUIRED: container build instructions
└── service.yml   # REQUIRED: docker-compose service definition
```

Here is the actual Vite template.

**Dockerfile** (`templates/frontends/vite/Dockerfile`):

```dockerfile
FROM node:22-alpine

WORKDIR /app

# Install dependencies first (layer caching)
COPY package*.json ./
RUN npm install

# Don't COPY source -- volume-mounted in dev

# Vite dev server
EXPOSE 5173

# --host 0.0.0.0: required for Docker (listen on all interfaces)
CMD ["npx", "vite", "--host", "0.0.0.0"]
```

**service.yml** (`templates/frontends/vite/service.yml`):

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
    environment:
      - NODE_ENV=development
      - CHOKIDAR_USEPOLLING=true
      - NODE_EXTRA_CA_CERTS=/certs/ca.crt
      - VITE_API_BASE=${FRONTEND_API_PREFIX}
      - VITE_HMR_PORT=${HTTPS_PORT}
    depends_on:
      cert-gen:
        condition: service_completed_successfully
    networks:
      - ${PROJECT_NAME}-internal
```

**Critical rules for frontend templates:**

1. **Service name must be `frontend`** -- the compose generator and Caddy config generator use this name.
2. **Use `${FRONTEND_SOURCE}`** instead of `${APP_SOURCE}` for the source directory.
3. **Use `${FRONTEND_API_PREFIX}`** to pass the API path prefix to the frontend (so it can build API URLs).
4. **Anonymous volume `/app/node_modules`** prevents the host volume mount from clobbering node_modules installed during the Docker build.
5. **`CHOKIDAR_USEPOLLING=true`** is needed for file watching to work reliably inside Docker containers.

### Frontend-specific variables

| Variable | Replaced with | Example |
|----------|--------------|---------|
| `${FRONTEND_SOURCE}` | Absolute path to frontend source | `/home/user/devstack/frontend` |
| `${FRONTEND_API_PREFIX}` | API path prefix (default `/api`) | `/api` |
| `${HTTPS_PORT}` | HTTPS port for HMR | `8443` |
| `${PROJECT_NAME}` | Project name | `my-saas-app` |

### Using a frontend

```env
# project.env
FRONTEND_TYPE=vite
FRONTEND_SOURCE=./frontend
FRONTEND_PORT=5173
FRONTEND_API_PREFIX=/api
```

The `generate_from_bootstrap` function handles frontend scaffolding automatically -- it copies the Dockerfile from the template and creates a minimal `package.json` in the frontend directory.

## Testing your template

1. Set `APP_TYPE` to your template name in project.env
2. Create a minimal app in `APP_SOURCE` with at least a Dockerfile and a health endpoint
3. Run `./devstack.sh start`
4. Verify: `curl http://localhost:8080/health`
5. Verify mock interception: `./devstack.sh shell` then `curl -k https://api.example-provider.com/v1/items`
6. Run: `./devstack.sh test`

If the health endpoint responds and the mock URL returns WireMock data, your template is working.

## Checklist: adding a new app template

- [ ] Create directory: `templates/apps/<name>/`
- [ ] Write `Dockerfile` with dependency caching, file watcher, port 3000 (or 9000 for PHP-FPM), and CA cert notes
- [ ] Write `service.yml` with service name `app`, `${PROJECT_NAME}` prefix, certs volume, network, and CA cert env vars
- [ ] Add cache volume case to `core/compose/generate.sh` (around lines 170-186) if the language needs persistent caches
- [ ] Add CA certificate env var(s) in service.yml (see per-language table above)
- [ ] Add manifest entry to `contract/manifest.json` under `categories.app.items`
- [ ] Add devcontainer config (optional): `templates/apps/<name>/.devcontainer/devcontainer.json`
- [ ] Test: set `APP_TYPE=<name>`, run `./devstack.sh start`, verify health endpoint
- [ ] Verify mock interception: `./devstack.sh shell` then `curl -k https://<mocked-domain>/...`
- [ ] Run `./devstack.sh test` -- all tests must pass

## Checklist: adding a new frontend template

- [ ] Create directory: `templates/frontends/<name>/`
- [ ] Write `Dockerfile` with dependency install, dev server on the expected port, `--host 0.0.0.0`
- [ ] Write `service.yml` with service name `frontend`, `${FRONTEND_SOURCE}`, `${FRONTEND_API_PREFIX}`, certs volume, network
- [ ] Add manifest entry to `contract/manifest.json` under `categories.frontend.items`
- [ ] Test: set `FRONTEND_TYPE=<name>`, set `FRONTEND_SOURCE=./frontend`, run `./devstack.sh start`
- [ ] Verify: frontend accessible at `http://localhost:8080/`, API routed through `${FRONTEND_API_PREFIX}/*`
- [ ] Verify HMR: edit a frontend source file and confirm the browser updates without a full reload
- [ ] Run `./devstack.sh test` -- all tests must pass
