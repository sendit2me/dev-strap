# Creating App Templates

This guide walks through creating a new app template — for example, adding Rust, Python/FastAPI, or any other language.

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

```dockerfile
# templates/apps/rust/Dockerfile
FROM rust:1.79-slim

# Install cargo-watch for live reload
RUN cargo install cargo-watch

# System deps your app might need
RUN apt-get update && apt-get install -y pkg-config libssl-dev && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Copy dependency files first (layer caching)
COPY Cargo.toml Cargo.lock* ./
# Create a dummy main.rs so cargo can resolve dependencies
RUN mkdir src && echo 'fn main() {}' > src/main.rs
RUN cargo build 2>/dev/null || true
RUN rm -rf src

# Copy source
COPY . .

EXPOSE 3000

# cargo-watch rebuilds on file changes
CMD ["cargo", "watch", "-x", "run"]
```

### Step 3: Write service.yml

The service.yml defines how this container fits into the docker-compose stack. **Critical rules:**

- Service name must be `app` (the nginx generator expects this)
- Use `${VARIABLE}` placeholders for values from project.env
- Mount the app source and certs volume
- Connect to the project network

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
      - ${PROJECT_NAME}-certs:/certs:ro
    working_dir: /app
    environment:
      - RUST_LOG=debug
      - PORT=3000
      - SSL_CERT_FILE=/certs/ca.crt
      - DATABASE_URL=mysql://${DB_USER}:${DB_PASSWORD}@db:3306/${DB_NAME}
    depends_on:
      cert-gen:
        condition: service_completed_successfully
    networks:
      - ${PROJECT_NAME}-internal
```

**Important:** Named volumes (like `${PROJECT_NAME}-cargo-registry`) must be prefixed with `${PROJECT_NAME}` so they're properly namespaced and cleaned up on `./devstack.sh stop`. If you need additional volumes, declare them in the compose generator's volumes section (`core/compose/generate.sh`).

### Available placeholder variables

| Variable | Replaced with | Example |
|----------|--------------|---------|
| `${PROJECT_NAME}` | project.env `PROJECT_NAME` | `my-saas-app` |
| `${APP_SOURCE}` | Absolute path to app source | `/home/user/devstack/app` |
| `${DB_TYPE}` | project.env `DB_TYPE` | `mariadb` |
| `${DB_NAME}` | project.env `DB_NAME` | `my_saas_app` |
| `${DB_USER}` | project.env `DB_USER` | `app` |
| `${DB_PASSWORD}` | project.env `DB_PASSWORD` | `secret` |
| `${DB_ROOT_PASSWORD}` | project.env `DB_ROOT_PASSWORD` | `root` |

### Trusting the mock CA certificate

For HTTPS mock interception to work, your app must trust the DevStack CA certificate. The cert is at `/certs/ca.crt` inside the container. How to trust it depends on the language:

| Language | Environment variable | Notes |
|----------|---------------------|-------|
| Node.js | `NODE_EXTRA_CA_CERTS=/certs/ca.crt` | Built-in Node support |
| Go | `SSL_CERT_FILE=/certs/ca.crt` | Built-in Go support |
| Rust | `SSL_CERT_FILE=/certs/ca.crt` | Works with rustls and native-tls |
| Python | `REQUESTS_CA_BUNDLE=/certs/ca.crt` | For the `requests` library |
| Java | Import into JKS keystore | Use `keytool` in Dockerfile |
| PHP | Update OS trust store | `update-ca-certificates` in Dockerfile |

For PHP and Java, the CA cert is mounted at runtime (not available at build time), so trust it in your `init.sh`:

```bash
# init.sh — for PHP
cp /certs/ca.crt /usr/local/share/ca-certificates/devstack-ca.crt
update-ca-certificates
```

**Do NOT** try to `COPY /certs/ca.crt` in the Dockerfile — the certs volume doesn't exist during the Docker build, only at runtime.

### Port convention

The nginx config generator uses the `APP_TYPE` to decide how to route:

- **`php-laravel`**: Routes via FastCGI to `app:9000`
- **Everything else**: Routes via HTTP proxy to `app:3000`

If your app listens on a different port, either:
1. Make your app listen on port 3000 (recommended — change the app, not the infra)
2. Edit `core/nginx/generate-conf.sh` to add your app type's port

### Step 4: Add devcontainer config (optional)

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

### Step 5: Use it

```env
# project.env
APP_TYPE=rust
APP_SOURCE=./my-rust-app
```

```bash
./devstack.sh stop && ./devstack.sh start
```

## Template for Python/FastAPI

Here's a complete template for reference:

**Dockerfile:**

```dockerfile
FROM python:3.12-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY . .

EXPOSE 3000

# uvicorn with reload for live development
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "3000", "--reload"]
```

**service.yml:**

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
      - PORT=3000
      - REQUESTS_CA_BUNDLE=/certs/ca.crt
      - DATABASE_URL=mysql+pymysql://${DB_USER}:${DB_PASSWORD}@db:3306/${DB_NAME}
    depends_on:
      cert-gen:
        condition: service_completed_successfully
    networks:
      - ${PROJECT_NAME}-internal
```

## Testing your template

1. Set `APP_TYPE` to your template name in project.env
2. Create a minimal app in `APP_SOURCE` with at least a Dockerfile and a health endpoint
3. Run `./devstack.sh start`
4. Verify: `curl http://localhost:8080/health`
5. Verify mock interception: `./devstack.sh shell` then `curl -k https://api.example-provider.com/v1/items`
6. Run: `./devstack.sh test`

If the health endpoint responds and the mock URL returns WireMock data, your template is working.
