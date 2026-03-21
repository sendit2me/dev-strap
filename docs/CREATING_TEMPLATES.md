# Creating Templates

How to add a new app template or frontend template to the dev-strap catalog.

## What a template is

A template is a directory in `templates/apps/` (or `templates/frontends/`) containing:

1. `service.yml` -- a standalone Docker Compose fragment (must have `services:` key)
2. `Dockerfile` -- container build instructions
3. Optionally: `.devcontainer/devcontainer.json`, file-watcher config, etc.

```
templates/apps/my-language/
├── Dockerfile                # REQUIRED
├── service.yml               # REQUIRED
└── .devcontainer/            # OPTIONAL
    └── devcontainer.json
```

## Template rules

### service.yml must be a standalone compose fragment

Every service file must have a `services:` top-level key. Docker Compose `include` requires this:

```yaml
services:
  app:
    build:
      context: ${APP_SOURCE}
      dockerfile: Dockerfile
    container_name: ${PROJECT_NAME}-app
    # ...
```

### Use literal volume and network names

Docker Compose does not interpolate variables in YAML key positions. Volume and network names must be literal:

```yaml
# CORRECT -- literal names
volumes:
  devstack-certs:
  devstack-go-modules:

networks:
  - devstack-internal
```

```yaml
# WRONG -- variables in key positions don't work
volumes:
  ${PROJECT_NAME}-certs:
```

### Declare volumes in the service file

Each service file must declare its own volumes in a top-level `volumes:` section:

```yaml
services:
  app:
    volumes:
      - ${APP_SOURCE}:/app
      - devstack-go-modules:/go/pkg/mod
      - devstack-certs:/certs:ro

volumes:
  devstack-go-modules:
  devstack-certs:
```

### Include a healthcheck

Other services depend on healthchecks for startup ordering:

```yaml
    healthcheck:
      test: ["CMD", "wget", "--spider", "-q", "http://localhost:3000/"]
      interval: 5s
      timeout: 3s
      retries: 30
```

### Join the devstack-internal network

```yaml
    networks:
      - devstack-internal
```

### Use env_file for wiring variables

If the container needs variables from `project.env` (database credentials, wiring URLs):

```yaml
    env_file: project.env
```

### Use ${VAR} for compose-interpolated values

Templates use `${VAR}` for values resolved from `project.env` at runtime. This is native Docker Compose interpolation -- no sed, no envsubst:

```yaml
    container_name: ${PROJECT_NAME}-app
    environment:
      - DB_HOST=db
      - DB_PORT=${DB_PORT}
```

## Example: Go app template

This is the actual Go template (`templates/apps/go/service.yml`):

```yaml
services:
  app:
    build:
      context: ${APP_SOURCE}
      dockerfile: Dockerfile
    container_name: ${PROJECT_NAME}-app
    env_file: project.env
    volumes:
      - ${APP_SOURCE}:/app
      - devstack-go-modules:/go/pkg/mod
      - devstack-certs:/certs:ro
    working_dir: /app
    environment:
      - GO_ENV=development
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
    healthcheck:
      test: ["CMD", "wget", "--spider", "-q", "http://localhost:3000/"]
      interval: 5s
      timeout: 3s
      retries: 30
    networks:
      - devstack-internal

volumes:
  devstack-go-modules:
  devstack-certs:
```

## Example: Redis extras template

This is the actual Redis template (`templates/extras/redis/service.yml`):

```yaml
services:
  redis:
    image: redis:alpine
    container_name: ${PROJECT_NAME}-redis
    networks:
      - devstack-internal
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 5s
      timeout: 3s
      retries: 10
```

## CA certificate trust

Mock interception requires the app to trust the DevStack CA at `/certs/ca.crt` (mounted from `devstack-certs` volume at runtime):

| Language | Environment variable(s) |
|----------|------------------------|
| Node.js | `NODE_EXTRA_CA_CERTS=/certs/ca.crt` |
| Go | `SSL_CERT_FILE=/certs/ca.crt` |
| Rust | `SSL_CERT_FILE=/certs/ca.crt` |
| Python | `REQUESTS_CA_BUNDLE=/certs/ca.crt`, `SSL_CERT_FILE=/certs/ca.crt`, `CURL_CA_BUNDLE=/certs/ca.crt` |
| PHP | `update-ca-certificates` in init script |

The cert is available at runtime only (volume mount), not during Docker build. Do not `COPY /certs/ca.crt` in the Dockerfile.

## Port convention

Caddy routes based on `APP_TYPE`:
- `php-laravel`: FastCGI to `app:9000`
- Everything else: HTTP reverse proxy to `app:3000`

Make new templates listen on port 3000 unless there's a protocol-specific reason not to.

## Dockerfile guidelines

- Install the language toolchain
- Set up file-watching for live reload (compiled languages)
- Use dependency caching (copy dependency files first, install, then copy source)
- Expose port 3000 (or 9000 for PHP-FPM)
- Set a default `CMD`

Example dependency caching for Rust:

```dockerfile
# Copy dependency files first (layer caching)
COPY Cargo.toml Cargo.lock* ./
RUN mkdir -p src && echo 'fn main() {}' > src/main.rs \
    && cargo build 2>/dev/null || true && rm -rf src
COPY . .
```

## Frontend templates

Frontend templates live in `templates/frontends/` and use these conventions:

- Service name must be `frontend`
- Use `${FRONTEND_SOURCE}` for the source directory
- Use `${FRONTEND_API_PREFIX}` for the API path prefix
- Caddy routes `${FRONTEND_API_PREFIX}/*` to backend, everything else to frontend

Example (actual Vite template, `templates/frontends/vite/service.yml`):

```yaml
services:
  frontend:
    build:
      context: ${FRONTEND_SOURCE}
      dockerfile: Dockerfile
    container_name: ${PROJECT_NAME}-frontend
    volumes:
      - ${FRONTEND_SOURCE}:/app
      - /app/node_modules
      - devstack-certs:/certs:ro
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
      - devstack-internal

volumes:
  devstack-certs:
```

## Registering in the manifest

Add the new template to `contract/manifest.json` under the appropriate category:

```json
"my-language": {
  "label": "My Language",
  "description": "My Language with live reload",
  "defaults": { "port": 3000 }
}
```

## Testing your template

1. Bootstrap a project with your template:
   ```bash
   ./devstack.sh --bootstrap '{"project":"test","selections":{"app":{"my-language":{}}}}'
   ```
2. Inspect the product: `ls test/services/`
3. Start it: `cd test/ && ./devstack.sh start`
4. Verify health: `curl http://localhost:8080/`
5. Verify mock interception: `./devstack.sh shell` then `curl -k https://api.example.com/v1/status`

## Checklist: new app template

- [ ] Create `templates/apps/<name>/Dockerfile` with dependency caching, file watcher, port 3000
- [ ] Create `templates/apps/<name>/service.yml` with `services:` key, literal volume names, healthcheck, `devstack-internal` network
- [ ] Declare all named volumes in the service file's `volumes:` section
- [ ] Add CA cert env var(s) in service.yml
- [ ] Register in `contract/manifest.json` under `categories.app.items`
- [ ] Optionally add `.devcontainer/devcontainer.json`
- [ ] Bootstrap a test project and verify it starts

## Checklist: new frontend template

- [ ] Create `templates/frontends/<name>/Dockerfile`
- [ ] Create `templates/frontends/<name>/service.yml` with service name `frontend`, `${FRONTEND_SOURCE}`, `devstack-internal` network
- [ ] Register in `contract/manifest.json` under `categories.frontend.items`
- [ ] Bootstrap with frontend selected and verify path-based routing
