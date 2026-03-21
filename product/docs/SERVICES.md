# Managing Services

## Understanding Your Stack

Your infrastructure is defined by the files in `services/`:

```bash
ls services/
# app.yml  caddy.yml  cert-gen.yml  database.yml  redis.yml  wiremock.yml
```

Each file is a self-contained Docker Compose fragment. The root `docker-compose.yml` includes them:

```yaml
include:
  - path: services/cert-gen.yml
    project_directory: .
  - path: services/app.yml
    project_directory: .
  - path: services/database.yml
    project_directory: .
    env_file: services/database.env
  - path: services/redis.yml
    project_directory: .
```

Adding a service = dropping a file in `services/` and adding an include line.
Removing a service = deleting the file and the include line.

## Adding a Service

### Step-by-step

1. Get the service YAML file (from the [dev-strap template catalog](https://github.com/sendit2me/dev-strap/tree/main/templates/extras) or write your own)
2. Place it in `services/`
3. Add an include line to `docker-compose.yml`
4. Add any required environment variables to `project.env`
5. Restart: `./devstack.sh restart`

### Example: Adding MinIO (S3-compatible object storage)

**1. Create `services/minio.yml`:**

```yaml
services:
  minio:
    image: minio/minio:latest
    container_name: ${PROJECT_NAME}-minio
    command: server /data --console-address ":9001"
    ports:
      - "${MINIO_PORT}:9000"
      - "${MINIO_CONSOLE_PORT}:9001"
    environment:
      MINIO_ROOT_USER: minioadmin
      MINIO_ROOT_PASSWORD: minioadmin
    volumes:
      - devstack-minio-data:/data
    networks:
      - devstack-internal
    healthcheck:
      test: ["CMD", "mc", "ready", "local"]
      interval: 5s
      timeout: 3s
      retries: 10

volumes:
  devstack-minio-data:
```

**2. Add to `docker-compose.yml`:**

```yaml
include:
  # ... existing includes ...
  - path: services/minio.yml
    project_directory: .
```

**3. Add port variables to `project.env`:**

```env
MINIO_PORT=9000
MINIO_CONSOLE_PORT=9001
```

**4. Restart:**

```bash
./devstack.sh restart
```

MinIO is now available at `http://localhost:9000` (API) and `http://localhost:9001` (console). Other containers reach it at `minio:9000` using the Docker network.

## Removing a Service

1. Remove the include line from `docker-compose.yml`
2. Delete the service file from `services/`
3. Remove related env vars from `project.env` (optional -- unused variables are harmless)
4. Restart with `--clean` to remove orphaned volumes:

```bash
./devstack.sh restart --clean
```

## Configuring a Service

### Ports

Change host-mapped ports in `project.env`:

```env
HTTP_PORT=9080
HTTPS_PORT=9443
```

Then restart: `./devstack.sh restart`

### Service-specific config

Some services have dedicated env files (`services/database.env`). Edit those for service-specific settings.

### Advanced changes

Edit the service YAML file directly. You have full control over the Docker Compose service definition -- image version, volumes, environment variables, resource limits, etc.

Docker Compose resolves `${VAR}` from `.env` (which symlinks to `project.env`) at runtime.

## Service Communication

All services share the `devstack-internal` Docker network:

- Use **service names as hostnames**: `redis`, `db`, `app`, `wiremock`, `web`, `minio`
- **Internal ports** (container-to-container): use the port the service listens on inside the container (e.g., Redis listens on `6379`, PostgreSQL on `5432`)
- **Exposed ports** (host-mapped): defined in `ports:` in the service YAML, controlled by variables in `project.env`

Example -- your app connecting to Redis:

```
# Inside the container network
redis://redis:6379

# From your host machine
redis://localhost:${REDIS_PORT}
```

## Writing Your Own Service

A minimal service YAML:

```yaml
services:
  myservice:
    image: myimage:latest
    container_name: ${PROJECT_NAME}-myservice
    networks:
      - devstack-internal
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8080/health"]
      interval: 5s
      timeout: 3s
      retries: 10
```

Requirements:

- **`services:` top-level key** -- Docker Compose `include` requires this
- **Join `devstack-internal` network** -- so other services can reach it by hostname
- **Container name uses `${PROJECT_NAME}` prefix** -- avoids conflicts between projects
- **Healthcheck** -- so `./devstack.sh status` reports meaningful health state

Optional but recommended:

- **Named volumes** for persistent data (declare them under a `volumes:` top-level key in the same file)
- **`depends_on` with `condition`** when the service needs another to be ready first
- **`${VAR}` for ports** so users can change them in `project.env` without editing YAML

## Generated Services

Two service files are regenerated on every `./devstack.sh start`:

- **`services/caddy.yml`** -- rebuilt because mock domain DNS aliases must match `mocks/*/domains`
- **`services/wiremock.yml`** -- rebuilt because mock mapping volume mounts must match `mocks/*/mappings`

Do not edit these files manually. Changes will be overwritten on next start. To change Caddy or WireMock behavior, edit mock definitions in `mocks/` or Caddy routing logic via the Caddyfile generator in `devstack.sh`.

All other service files in `services/` are static and yours to edit freely.

## Available Service Templates

The [dev-strap repository](https://github.com/sendit2me/dev-strap) maintains a catalog of ready-to-use service templates:

- **Databases**: PostgreSQL, MariaDB
- **Caching/messaging**: Redis, NATS
- **Storage**: MinIO (S3-compatible)
- **Email**: Mailpit
- **Observability**: Prometheus, Grafana, Dozzle
- **Dev tools**: Adminer (database UI), Swagger UI

Browse the templates at `templates/extras/` in the dev-strap repo. Each contains a `service.yml` you can copy directly into your `services/` directory.
