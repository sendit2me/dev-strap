# Adding Services

DevStack comes with Redis and Mailpit as extras. This guide covers enabling them, configuring ports, and creating entirely new services.

## Enable a built-in extra

Edit `project.env`:

```env
EXTRAS=redis,mailpit
```

Restart:

```bash
./devstack.sh stop && ./devstack.sh start
```

### Built-in extras and their ports

| Service | What it does | Exposed port | Access URL |
|---------|-------------|--------------|------------|
| redis | Cache / queue / session store | None (internal only) | `redis://redis:6379` from app |
| mailpit | Catches all outgoing SMTP email | 8025 | http://localhost:8025 |

Redis has no exposed port by default because your app connects to it internally via the Docker network hostname `redis`. If you need to inspect Redis from your machine, see "Exposing a port" below.

## Add a new service from scratch

Let's say you need MinIO (S3-compatible object storage).

### Step 1: Create the template directory

```bash
mkdir -p templates/extras/minio
```

### Step 2: Write service.yml

Create `templates/extras/minio/service.yml`:

```yaml
  minio:
    image: minio/minio:latest
    container_name: ${PROJECT_NAME}-minio
    command: server /data --console-address ":9001"
    ports:
      - "9000:9000"
      - "9001:9001"
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

**Important rules for service.yml:**

1. **Use `${PROJECT_NAME}`** for container names, volumes, and network references. These get replaced with your project name at generation time.
2. **Network must be `${PROJECT_NAME}-internal`** — this puts the service on the shared Docker network where all other services can reach it.
3. **Include a healthcheck** — other services can then depend on this service being healthy.
4. **Indentation**: the service name (e.g., `minio:`) must be indented with 2 spaces (it's nested under `services:` in the final compose file).

### Step 3: Enable it in project.env

```env
EXTRAS=redis,minio
```

### Step 4: If your service needs a named volume

If your service.yml references a new volume (like `${PROJECT_NAME}-minio-data`), you need to register it. Currently, the compose generator automatically creates volumes for the database (`${PROJECT_NAME}-db-data`) and certs (`${PROJECT_NAME}-certs`).

For additional volumes, add them to the end of `core/compose/generate.sh` in the volumes section:

```bash
# In the COMPOSE_FOOTER section, add your volume:
volumes:
  ${PROJECT_NAME}-certs:${DB_VOLUMES}
  ${PROJECT_NAME}-minio-data:    # <-- add this
```

Or, simpler: just use a bind mount in your service.yml instead of a named volume:

```yaml
volumes:
  - ${DEVSTACK_DIR}/data/minio:/data
```

### Step 5: Restart and verify

```bash
./devstack.sh stop && ./devstack.sh start
./devstack.sh status
```

You should see `myproject-minio` running. Access the MinIO console at `http://localhost:9001`.

## Exposing ports to your machine

Every `ports:` entry in a service.yml follows the format:

```yaml
ports:
  - "HOST_PORT:CONTAINER_PORT"
```

- **HOST_PORT** = the port on your machine (localhost)
- **CONTAINER_PORT** = the port inside the container

Examples:

```yaml
# Redis CLI accessible from your machine on port 6380
ports:
  - "6380:6379"

# PostgreSQL admin on port 5433 (avoiding conflict with local postgres)
ports:
  - "5433:5432"

# Web UI on port 3001
ports:
  - "3001:3000"
```

### Accessing services without exposed ports

Services without `ports:` are still reachable from **inside** the Docker network. Any container can connect using the service name as hostname:

```
From app container:
  redis://redis:6379        ✅ works (internal network)
  mysql://db:3306           ✅ works (internal network)
  http://wiremock:8080      ✅ works (internal network)

From your machine:
  redis://localhost:6379    ❌ not exposed
  mysql://localhost:3306    ❌ not exposed
```

To make a service accessible from your machine, add a `ports:` entry.

### Avoiding port conflicts

If you get `port is already allocated`, either:
1. Change the HOST_PORT in the service template
2. Stop whatever's using that port on your machine
3. Use `./devstack.sh stop` to ensure no old containers are lingering

## Connecting your app to a new service

After adding a service, your app needs to know about it. Add environment variables to your app's service.yml:

```yaml
# templates/apps/node-express/service.yml
environment:
  - MINIO_ENDPOINT=http://minio:9000
  - MINIO_ACCESS_KEY=minioadmin
  - MINIO_SECRET_KEY=minioadmin
  - REDIS_URL=redis://redis:6379
  - SMTP_HOST=mailpit
  - SMTP_PORT=1025
```

Key pattern: **use the service name as the hostname**. Docker's internal DNS resolves `minio` to the MinIO container, `redis` to the Redis container, etc.

## Making your app depend on a new service

If your app needs a service to be healthy before it starts, add a dependency. Currently, the compose generator hardcodes depends_on for `cert-gen` and `db`. For additional dependencies, add them to the app's service.yml:

```yaml
# templates/apps/node-express/service.yml
depends_on:
  cert-gen:
    condition: service_completed_successfully
  db:
    condition: service_healthy
  redis:
    condition: service_healthy      # <-- add this
  minio:
    condition: service_healthy      # <-- and this
```

## Complete example: adding Elasticsearch

```bash
mkdir -p templates/extras/elasticsearch
```

`templates/extras/elasticsearch/service.yml`:

```yaml
  elasticsearch:
    image: elasticsearch:8.13.0
    container_name: ${PROJECT_NAME}-elasticsearch
    ports:
      - "9200:9200"
    environment:
      - discovery.type=single-node
      - xpack.security.enabled=false
      - "ES_JAVA_OPTS=-Xms256m -Xmx256m"
    networks:
      - ${PROJECT_NAME}-internal
    healthcheck:
      test: ["CMD-SHELL", "curl -f http://localhost:9200/_cluster/health || exit 1"]
      interval: 10s
      timeout: 5s
      retries: 20
```

Enable it:

```env
EXTRAS=redis,elasticsearch
```

Connect from your app:

```
From your app container: http://elasticsearch:9200
From your machine:       http://localhost:9200
```

## Variable substitution reference

These variables are available in all service.yml templates:

| Variable | Source | Example value |
|----------|--------|---------------|
| `${PROJECT_NAME}` | project.env | `my-saas-app` |
| `${DB_NAME}` | project.env | `my_saas_app` |
| `${DB_USER}` | project.env | `app` |
| `${DB_PASSWORD}` | project.env | `secret` |
| `${DB_ROOT_PASSWORD}` | project.env | `root` |
