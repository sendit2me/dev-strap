# Adding Services

How to add a new service to the dev-strap catalog.

## Overview

Adding a service means:
1. Create a template in `templates/extras/<name>/`
2. Register it in `contract/manifest.json`
3. Wire it into the assembly logic if needed

## Step 1: Create the service template

```bash
mkdir -p templates/extras/my-service
```

Write `templates/extras/my-service/service.yml`. This must be a standalone Docker Compose fragment with a `services:` top-level key:

```yaml
services:
  my-service:
    image: my-service:latest
    container_name: ${PROJECT_NAME}-my-service
    ports:
      - "${MY_SERVICE_PORT}:7777"
    volumes:
      - devstack-my-service-data:/data
    networks:
      - devstack-internal
    healthcheck:
      test: ["CMD", "wget", "--spider", "-q", "http://127.0.0.1:7777/health"]
      interval: 5s
      timeout: 3s
      retries: 10

volumes:
  devstack-my-service-data:
```

### Template rules

- **`services:` top-level key is required** -- Docker Compose `include` needs it
- **Literal volume names** -- use `devstack-my-service-data`, not `${PROJECT_NAME}-my-service-data` (Compose doesn't interpolate YAML keys)
- **Declare volumes** -- list all named volumes in the service file's `volumes:` section
- **Include a healthcheck** -- enables startup ordering via `depends_on`
- **Join `devstack-internal` network** -- all services must be on the shared network
- **Use port variables** -- `${MY_SERVICE_PORT}:7777` lets users override via `project.env`

### Real examples

**NATS** (`templates/extras/nats/service.yml`):

```yaml
services:
  nats:
    image: nats:2-alpine
    container_name: ${PROJECT_NAME}-nats
    command: "--jetstream --store_dir /data --http_port 8222"
    ports:
      - "${NATS_PORT}:4222"
      - "${NATS_MONITOR_PORT}:8222"
    volumes:
      - devstack-nats-data:/data
    networks:
      - devstack-internal
    healthcheck:
      test: ["CMD", "wget", "--spider", "-q", "http://127.0.0.1:8222/healthz"]
      interval: 5s
      timeout: 3s
      retries: 10

volumes:
  devstack-nats-data:
```

**Redis** (`templates/extras/redis/service.yml`):

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

Redis has no `ports:` because apps connect internally via `redis://redis:6379`. No host exposure needed.

## Step 2: Register in manifest.json

Add the service to `contract/manifest.json` under the appropriate category (`services`, `tooling`, or `observability`):

```json
"my-service": {
  "label": "My Service",
  "description": "What it does in one sentence",
  "defaults": { "port": 7777 },
  "requires": ["app.*"]
}
```

Manifest fields:

| Field | Purpose | Example |
|-------|---------|---------|
| `label` | Human-readable name | `"NATS"` |
| `description` | Short description | `"High-performance messaging with JetStream"` |
| `defaults` | Default port(s) and settings | `{ "client_port": 4222, "monitor_port": 8222 }` |
| `requires` | Dependencies (wildcards OK) | `["app.*"]` -- requires any app template |
| `conflicts` | Incompatible items | `["services.other-mq"]` |

## Step 3: Wire into assembly logic

The factory's `generate_from_bootstrap()` in `devstack.sh` handles extras automatically -- it copies any template from `templates/extras/` that matches a selected service name. Most services need no special assembly logic.

If your service uses port variables (like `${MY_SERVICE_PORT}`), add these to the assembly:

### Add port defaults and overrides

In `generate_from_bootstrap()`, add a local variable with the default port:

```bash
local my_service_port=7777
```

Add override extraction:

```bash
if printf '%s\n' "${payload}" | jq -e '.selections.services["my-service"].overrides.port' &>/dev/null; then
    my_service_port=$(printf '%s\n' "${payload}" | jq -r '.selections.services["my-service"].overrides.port')
fi
```

Add to the conditional port vars section that appends to `project.env`:

```bash
if printf '%s\n' "${payload}" | jq -e '.selections.services["my-service"]' &>/dev/null; then
    printf 'MY_SERVICE_PORT=%s\n' "${my_service_port}"
fi
```

### Add config files (if needed)

If your service needs config files (like `prometheus.yml`), add copy logic:

```bash
if [ -f "${DEVSTACK_DIR}/templates/extras/${extra}/my-config.yml" ]; then
    mkdir -p "${dest}/config"
    cp "${DEVSTACK_DIR}/templates/extras/${extra}/my-config.yml" "${dest}/config/my-config.yml"
fi
```

## Step 4: Add auto-wiring rules (optional)

If your service should automatically inject connection info into the app, add a wiring rule to `contract/manifest.json`:

```json
{
  "when": ["app.*", "services.my-service"],
  "set": "app.*.my_service_url",
  "template": "http://my-service:7777"
}
```

When both conditions are met, the factory writes `MY_SERVICE_URL=http://my-service:7777` to `project.env`.

Real examples:

```json
{ "when": ["app.*", "services.redis"],  "set": "app.*.redis_url",    "template": "redis://redis:6379" }
{ "when": ["app.*", "services.nats"],   "set": "app.*.nats_url",     "template": "nats://nats:4222" }
{ "when": ["app.*", "services.minio"],  "set": "app.*.s3_endpoint",  "template": "http://minio:9000" }
```

## Step 5: Test

```bash
# Bootstrap a project with your service
./devstack.sh --bootstrap '{"project":"test","selections":{"app":{"go":{}},"services":{"my-service":{}}}}'

# Inspect the output
ls test/services/
cat test/project.env

# Start and verify
cd test/ && ./devstack.sh start
./devstack.sh status
```

Verify:
- The container starts and becomes healthy
- Ports are accessible from the host
- The app can reach the service on the internal network

## Tooling items vs extras

Some items in the manifest `tooling` category are backed by extras templates (e.g., `db-ui`, `swagger-ui`). They work the same way -- the factory copies their template from `templates/extras/`.

Certain tooling items get special treatment in the factory CLI:
- `qa`, `qa-dashboard`, `wiremock`, `devcontainer` -- handled by dedicated logic, excluded from the extras copy loop

If your new service is "just a container with a web UI," put it in the appropriate manifest category and create the template in `templates/extras/`. It flows through automatically.

## Built-in services reference

| Service | Internal hostname | Default port(s) |
|---------|------------------|-----------------|
| redis | `redis` | 6379 (internal only) |
| mailpit | `mailpit` | 1025 (SMTP), 8025 (UI) |
| nats | `nats` | 4222 (client), 8222 (monitor) |
| minio | `minio` | 9000 (API), 9001 (console) |
| prometheus | `prometheus` | 9090 |
| grafana | `grafana` | 3001 |
| dozzle | -- | 9999 |
| db-ui | -- | 8083 |
| swagger-ui | -- | 8084 |

## Checklist

- [ ] Create `templates/extras/<name>/service.yml` with `services:` key, literal volume names, healthcheck, `devstack-internal` network
- [ ] Declare named volumes in the service file's `volumes:` section
- [ ] Add to `contract/manifest.json` (items, defaults, requires, conflicts)
- [ ] Add port defaults and overrides in `generate_from_bootstrap()` (if port variables used)
- [ ] Add auto-wiring rule (if service needs to inject connection info into app)
- [ ] Bootstrap a test project with the new service and verify it works
- [ ] Run `bash tests/contract/test-contract.sh` to verify contract tests pass
