# Adding Services

DevStrap comes with several extras: redis, mailpit, nats, minio, and observability tools. This guide covers enabling them, configuring ports, creating entirely new services, and registering them in the manifest.

## Enable a built-in extra

Edit `project.env`:

```env
EXTRAS=redis,mailpit,nats
```

Restart:

```bash
./devstack.sh stop && ./devstack.sh start
```

### Built-in extras and their ports

| Service | What it does | Exposed port(s) | Access URL |
|---------|-------------|-----------------|------------|
| redis | Cache / queue / session store | None (internal only) | `redis://redis:6379` from app |
| mailpit | Catches all outgoing SMTP email | `${MAILPIT_PORT}` (default 8025) | http://localhost:8025 |
| nats | High-performance messaging with JetStream | `${NATS_PORT}` (default 4222), `${NATS_MONITOR_PORT}` (default 8222) | `nats://nats:4222` from app, http://localhost:8222 monitoring |
| minio | S3-compatible object storage | `${MINIO_PORT}` (default 9000), `${MINIO_CONSOLE_PORT}` (default 9001) | `http://minio:9000` from app, http://localhost:9001 console |
| prometheus | Metrics collection | `${PROMETHEUS_PORT}` (default 9090) | http://localhost:9090 |
| grafana | Metrics dashboards | `${GRAFANA_PORT}` (default 3001) | http://localhost:3001 |
| dozzle | Real-time container log viewer | `${DOZZLE_PORT}` (default 9999) | http://localhost:9999 |
| db-ui | Database browser (Adminer) | `${ADMINER_PORT}` (default 8083) | http://localhost:8083 |
| swagger-ui | OpenAPI spec viewer | `${SWAGGER_PORT}` (default 8084) | http://localhost:8084 |

Redis has no exposed port by default because your app connects to it internally via the Docker network hostname `redis`. If you need to inspect Redis from your machine, add a `ports:` entry to the template.

## Add a new service from scratch

This section walks through every step needed to add a brand-new service to DevStrap. We use NATS and MinIO as real examples since they were recently added.

### Step 1: Create the template directory

```bash
mkdir -p templates/extras/my-service
```

### Step 2: Write service.yml

This is the core of the template. Here is the actual NATS template (`templates/extras/nats/service.yml`):

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

And here is the actual MinIO template (`templates/extras/minio/service.yml`):

```yaml
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
2. **Network must be `${PROJECT_NAME}-internal`** -- this puts the service on the shared Docker network where all other services can reach it.
3. **Include a healthcheck** -- other services can then depend on this service being healthy. The compose generator automatically adds `depends_on` entries for extras.
4. **Indentation**: the service name (e.g., `nats:`) must be indented with 2 spaces (it's nested under `services:` in the final compose file).
5. **Use port variables** (e.g., `${NATS_PORT}`) instead of hardcoded port numbers -- this allows users to override ports via `project.env` and avoids port collisions.

### Step 3: Add a volume sidecar (if your service needs named volumes)

If your service.yml references a named volume (like `${PROJECT_NAME}-nats-data`), create a `volumes.yml` file alongside the service.yml. This tells the compose generator to register the volume in the top-level `volumes:` block.

`templates/extras/nats/volumes.yml`:

```yaml
  ${PROJECT_NAME}-nats-data:
```

`templates/extras/minio/volumes.yml`:

```yaml
  ${PROJECT_NAME}-minio-data:
```

The compose generator (`core/compose/generate.sh`) automatically detects and processes `volumes.yml` files. When a `volumes.yml` exists for an extra, it appends the volume declarations to the generated compose file's `volumes:` section. Each line in volumes.yml is a top-level named volume declaration with `${PROJECT_NAME}` substitution applied.

Without the volumes.yml file, Docker Compose will error because the volume is referenced but never declared.

**Alternative: bind mount.** If you prefer not to use named volumes, use a bind mount instead:

```yaml
volumes:
  - ${DEVSTACK_DIR}/data/my-service:/data
```

Bind mounts don't need a volumes.yml sidecar but won't be cleaned up by `./devstack.sh stop`.

### Step 4: Add port variables

If your service exposes ports to the host, use variables instead of hardcoded numbers. This requires changes in three places:

**4a. Add sed substitution in compose generator** (`core/compose/generate.sh`):

Find the extras template processing loop (around lines 103-120) and add your variable to the sed pipeline:

```bash
sed "s|\${MY_SERVICE_PORT}|${MY_SERVICE_PORT:-7777}|g" | \
```

**4b. Add default value in `generate_from_bootstrap`** (`devstack.sh`):

In the `generate_from_bootstrap` function, add a local variable with the default port value:

```bash
local my_service_port=7777
```

And add the override extraction if the payload provides one:

```bash
if printf '%s\n' "${payload}" | jq -e '.selections.services["my-service"].overrides.port' &>/dev/null; then
    my_service_port=$(printf '%s\n' "${payload}" | jq -r '.selections.services["my-service"].overrides.port')
fi
```

Then include it in the project.env template within the same function:

```bash
MY_SERVICE_PORT=${my_service_port}
```

**4c. Add to project.env template:**

Users who write project.env by hand need a documented variable:

```env
MY_SERVICE_PORT=7777
```

### Step 5: Add the manifest entry

Register your service in `contract/manifest.json` so that the PowerHouse contract and bootstrap system know about it. Add it to the appropriate category under `categories.services.items`:

```json
"my-service": {
  "label": "My Service",
  "description": "What it does in one sentence",
  "defaults": { "port": 7777 },
  "requires": ["app.*"]
}
```

**Manifest fields:**

| Field | Purpose | Example |
|-------|---------|---------|
| `label` | Human-readable name | `"NATS"` |
| `description` | Short description | `"High-performance messaging with JetStream streaming"` |
| `defaults` | Default port(s) and settings | `{ "client_port": 4222, "monitor_port": 8222 }` |
| `requires` | Dependencies (wildcard OK) | `["app.*"]` means "requires any app template" |
| `conflicts` | Incompatible items | `["services.other-mq"]` |

### Step 6: Add auto-wiring rules (optional)

If your service should automatically inject connection info into the app, add a wiring rule to the `wiring` array in `contract/manifest.json`:

```json
{
  "when": ["app.*", "services.my-service"],
  "set": "app.*.my_service_url",
  "template": "http://my-service:7777"
}
```

Real examples from the codebase:

```json
{
  "when": ["app.*", "services.nats"],
  "set": "app.*.nats_url",
  "template": "nats://nats:4222"
},
{
  "when": ["app.*", "services.minio"],
  "set": "app.*.s3_endpoint",
  "template": "http://minio:9000"
}
```

When both items in the `when` array are selected, the `generate_from_bootstrap` function resolves the template and writes it as an environment variable to project.env. The variable name is derived from the last segment of the `set` key (e.g., `nats_url` becomes `NATS_URL`).

### Step 7: Enable and verify

```env
EXTRAS=redis,my-service
```

```bash
./devstack.sh stop && ./devstack.sh start
./devstack.sh status
```

## Tooling items that use extras templates

Some items in the manifest `tooling` category map directly to extras templates rather than being special-cased in the CLI. For example, `db-ui` and `swagger-ui` are in the `tooling` category of the manifest but live in `templates/extras/` as regular service templates.

How it works: the `generate_from_bootstrap` function in `devstack.sh` builds the `EXTRAS` list by merging services, observability, and tooling selections -- but it excludes certain special-cased tooling items:

```bash
extras=$(printf '%s\n' "${payload}" | jq -r '
    [(.selections.services // {} | keys[]),
     (.selections.observability // {} | keys[]),
     (.selections.tooling // {} | keys[] | select(. != "qa" and . != "qa-dashboard" and . != "wiremock" and . != "devcontainer"))] | join(",")')
```

This means:
- `qa`, `qa-dashboard`, `wiremock`, and `devcontainer` are handled by dedicated logic in `devstack.sh` (they're not extras templates).
- Everything else from `tooling` (like `db-ui`, `swagger-ui`) flows into the `EXTRAS` comma-separated list and is processed as a regular extras template from `templates/extras/`.

If you're adding a new tooling item that is just a Docker container with a web UI, put it in the `tooling` category of the manifest and create the template in `templates/extras/`. It will be included automatically. If it needs special CLI handling, add it to the exclusion filter above.

## Exposing ports to your machine

Every `ports:` entry in a service.yml follows the format:

```yaml
ports:
  - "HOST_PORT:CONTAINER_PORT"
```

- **HOST_PORT** = the port on your machine (localhost)
- **CONTAINER_PORT** = the port inside the container

Use variables for the host port so users can override them:

```yaml
ports:
  - "${NATS_PORT}:4222"
  - "${NATS_MONITOR_PORT}:8222"
```

### Accessing services without exposed ports

Services without `ports:` are still reachable from **inside** the Docker network. Any container can connect using the service name as hostname:

```
From app container:
  redis://redis:6379        works (internal network)
  nats://nats:4222          works (internal network)
  http://minio:9000         works (internal network)

From your machine:
  redis://localhost:6379    not exposed (no ports: entry)
```

To make a service accessible from your machine, add a `ports:` entry.

### Avoiding port conflicts

If you get `port is already allocated`, either:
1. Change the host port variable in `project.env` (e.g., `NATS_PORT=4223`)
2. Stop whatever's using that port on your machine
3. Use `./devstack.sh stop` to ensure no old containers are lingering

The contract validation system detects port collisions between default ports at bootstrap time. If you add a new service, make sure its default ports don't overlap with existing defaults in the manifest.

## Connecting your app to a new service

After adding a service, your app needs to know about it. Add environment variables to your app's service.yml:

```yaml
# templates/apps/node-express/service.yml
environment:
  - NATS_URL=nats://nats:4222
  - S3_ENDPOINT=http://minio:9000
  - S3_ACCESS_KEY=minioadmin
  - S3_SECRET_KEY=minioadmin
  - REDIS_URL=redis://redis:6379
  - SMTP_HOST=mailpit
  - SMTP_PORT=1025
```

Key pattern: **use the service name as the hostname**. Docker's internal DNS resolves `nats` to the NATS container, `minio` to the MinIO container, etc.

For automatic wiring via the manifest (see Step 6 above), these environment variables are resolved and written to project.env instead of being hardcoded in service.yml templates.

## Making your app depend on a new service

The compose generator automatically adds `depends_on` entries for every enabled extra, keyed on `service_healthy`. This means if your extra has a healthcheck (and it should), the app won't start until the service is healthy.

If you need to override this behavior or add extra conditions, you can add explicit dependency entries in your app's service.yml:

```yaml
depends_on:
  cert-gen:
    condition: service_completed_successfully
  nats:
    condition: service_healthy
  minio:
    condition: service_healthy
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
      - "${ELASTICSEARCH_PORT}:9200"
    environment:
      - discovery.type=single-node
      - xpack.security.enabled=false
      - "ES_JAVA_OPTS=-Xms256m -Xmx256m"
    volumes:
      - ${PROJECT_NAME}-elasticsearch-data:/usr/share/elasticsearch/data
    networks:
      - ${PROJECT_NAME}-internal
    healthcheck:
      test: ["CMD-SHELL", "curl -f http://localhost:9200/_cluster/health || exit 1"]
      interval: 10s
      timeout: 5s
      retries: 20
```

`templates/extras/elasticsearch/volumes.yml`:

```yaml
  ${PROJECT_NAME}-elasticsearch-data:
```

Add sed substitution in `core/compose/generate.sh` extras loop:

```bash
sed "s|\${ELASTICSEARCH_PORT}|${ELASTICSEARCH_PORT:-9200}|g" | \
```

Add to `contract/manifest.json` under `categories.services.items`:

```json
"elasticsearch": {
  "label": "Elasticsearch",
  "description": "Full-text search and analytics engine",
  "defaults": { "port": 9200 },
  "requires": ["app.*"]
}
```

Add wiring rule:

```json
{
  "when": ["app.*", "services.elasticsearch"],
  "set": "app.*.elasticsearch_url",
  "template": "http://elasticsearch:9200"
}
```

Enable it:

```env
EXTRAS=redis,elasticsearch
ELASTICSEARCH_PORT=9200
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
| `${MAILPIT_PORT}` | project.env (default 8025) | `8025` |
| `${NATS_PORT}` | project.env (default 4222) | `4222` |
| `${NATS_MONITOR_PORT}` | project.env (default 8222) | `8222` |
| `${MINIO_PORT}` | project.env (default 9000) | `9000` |
| `${MINIO_CONSOLE_PORT}` | project.env (default 9001) | `9001` |
| `${PROMETHEUS_PORT}` | project.env (default 9090) | `9090` |
| `${GRAFANA_PORT}` | project.env (default 3001) | `3001` |
| `${DOZZLE_PORT}` | project.env (default 9999) | `9999` |
| `${ADMINER_PORT}` | project.env (default 8083) | `8083` |
| `${SWAGGER_PORT}` | project.env (default 8084) | `8084` |
| `${DEVSTACK_DIR}` | Resolved at generation time | `/home/user/devstack` |
| `${APP_SOURCE}` | Resolved to absolute path | `/home/user/devstack/app` |

## Checklist: adding a new service from scratch

Use this checklist to make sure you haven't missed anything:

- [ ] Create directory: `templates/extras/<name>/`
- [ ] Write `service.yml` with `${PROJECT_NAME}` prefix, healthcheck, and `${PROJECT_NAME}-internal` network
- [ ] Write `volumes.yml` if the service uses named volumes
- [ ] Add port variable(s) (e.g., `${MY_PORT}`) to `service.yml` instead of hardcoded ports
- [ ] Add sed substitution for port variable(s) to `core/compose/generate.sh` (extras loop, around lines 103-120)
- [ ] Add default port value and override extraction in `devstack.sh` `generate_from_bootstrap` function
- [ ] Add port variable to the project.env template in `generate_from_bootstrap`
- [ ] Add manifest entry to `contract/manifest.json` under the appropriate category (`services`, `tooling`, or `observability`)
- [ ] Add wiring rule to `contract/manifest.json` `wiring` array (if auto-connection to app is needed)
- [ ] If a tooling item, verify it is NOT in the jq exclusion filter in `generate_from_bootstrap` (only `qa`, `qa-dashboard`, `wiremock`, `devcontainer` should be excluded)
- [ ] Test: enable in `EXTRAS`, run `./devstack.sh stop && ./devstack.sh start`, check `./devstack.sh status`
- [ ] Verify: the container is healthy, ports are accessible from the host, and the app can reach the service on the internal network
- [ ] Update the "Built-in extras and their ports" table in this document
