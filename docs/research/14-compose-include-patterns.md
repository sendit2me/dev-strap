# Docker Compose Include Patterns for dev-strap

> **Date**: 2026-03-21
> **Covers**: Compose `include` directive, YAML anchors/aliases/extensions, variable interpolation across includes, network merging, the mock DNS alias problem, practical file structure, restart trade-offs
> **Source files studied**: `core/compose/generate.sh`, `core/caddy/generate-caddyfile.sh`, `devstack.sh`, all `templates/*/service.yml`, Docker Compose specification, Docker documentation
> **Web sources**: Docker Compose spec (compose-spec/spec.md), Docker Docs (include, variable-interpolation, fragments, extensions), docker/compose#10841

---

## Table of Contents

1. [Docker Compose `include` Directive](#1-docker-compose-include-directive)
2. [YAML Anchors, Aliases, and Extensions](#2-yaml-anchors-aliases-and-extensions)
3. [Variable Interpolation Across Includes](#3-variable-interpolation-across-includes)
4. [Networks Across Includes](#4-networks-across-includes)
5. [The Mock DNS Alias Problem](#5-the-mock-dns-alias-problem)
6. [Practical File Structure](#6-practical-file-structure)
7. [Restart Trade-offs](#7-restart-trade-offs)
8. [Complete Example Files](#8-complete-example-files)

---

## 1. Docker Compose `include` Directive

### Version requirements

- **Docker Compose v2.20.0+** (released July 2023)
- **Docker Desktop 4.22+**
- Part of the Compose Specification (not a version-specific feature)

The `include` directive is a top-level element in the Compose file. It is NOT part of the older `version: "3.x"` schemas. Files using `include` should omit the `version` key entirely (the Compose Specification does not use it).

### Short syntax

```yaml
include:
  - services/app.yml
  - services/database.yml
  - services/redis.yml
```

Each path is resolved relative to the Compose file that contains the `include` directive.

### Long syntax

```yaml
include:
  - path: services/app.yml
    project_directory: .
    env_file: ./project.env
  - path:
      - services/caddy-base.yml
      - services/caddy-overrides.yml
    env_file:
      - ./project.env
      - ./local.env
```

Long syntax options:

| Field               | Purpose                                                        |
|---------------------|----------------------------------------------------------------|
| `path`              | Single file or list of files to merge (like `-f` stacking)     |
| `project_directory` | Working directory for resolving relative paths in the included file. Defaults to the directory containing the included file. |
| `env_file`          | `.env` file(s) for variable interpolation within the included file. Can override the default `.env` resolution. |

### How `include` works

1. Each included file loads as its own Compose application model
2. Relative paths inside the included file resolve from its own directory (or `project_directory` if set)
3. All resources (services, networks, volumes, configs, secrets) are copied into the main model
4. **Conflict rule**: Compose errors if any resource name in an included file conflicts with a resource already defined (in the root file or another include). This is strict -- even identical definitions are treated as conflicts.
5. Include is recursive -- an included file can have its own `include` section

### Cross-file `depends_on`

Once all included files are loaded, the merged model is a single flat namespace. Services CAN reference other services from different included files in their `depends_on`:

```yaml
# services/app.yml
services:
  app:
    depends_on:
      db:
        condition: service_healthy    # db is defined in services/database.yml
      cert-gen:
        condition: service_completed_successfully  # cert-gen is in services/cert-gen.yml
```

This works because `depends_on` is validated against the merged model, not against the individual file.

### `.env` file resolution for included files

This is the critical detail for dev-strap:

- By default, each included file resolves `${VAR}` from a `.env` file in its own directory (the directory containing the included `.yml` file)
- If no `.env` exists in that directory, variables are unresolved (Compose warns or errors)
- The long syntax `env_file` field overrides this, pointing included files at a specific env file
- Shell environment variables always take precedence over `.env` files

For dev-strap, we have two clean options:

**Option A: Symlink** -- Place a symlink `services/.env -> ../project.env` so that included files in `services/` automatically resolve variables from `project.env`.

**Option B: Long syntax** -- Use the long-form include with explicit `env_file`:
```yaml
include:
  - path: services/app.yml
    env_file: ./project.env
```

**Option C: project_directory** -- Set `project_directory` to the project root:
```yaml
include:
  - path: services/app.yml
    project_directory: .
```

This causes the included file's relative paths AND `.env` resolution to use the project root.

**Recommendation: Option C** (`project_directory: .`). This is the cleanest approach because:
- No symlinks to maintain
- Variable resolution comes from `./project.env` (the project root `.env`)
- Relative paths in service files (volume mounts etc.) resolve from the project root, which is what we want
- Every include line looks the same

### Limitations

- No globbing: `include: services/*.yml` is NOT supported. Each file must be listed explicitly.
- No conditional includes: you cannot conditionally include files based on environment variables.
- Each file must be a valid standalone Compose file (it gets parsed independently first).

---

## 2. YAML Anchors, Aliases, and Extensions

### Anchors and aliases

YAML anchors (`&name`) define a reusable block. Aliases (`*name`) reference it:

```yaml
services:
  app:
    networks: &app-network
      - devstack-internal
  redis:
    networks: *app-network
```

The merge key (`<<:`) allows partial overrides:

```yaml
x-healthcheck: &default-healthcheck
  interval: 5s
  timeout: 3s
  retries: 10

services:
  redis:
    healthcheck:
      <<: *default-healthcheck
      test: ["CMD", "redis-cli", "ping"]
  db:
    healthcheck:
      <<: *default-healthcheck
      test: ["CMD-SHELL", "pg_isready -U ${DB_USER}"]
      retries: 20  # override the default
```

### Per-document limitation

**Anchors and aliases are per-YAML-document.** They CANNOT span across `include` files. This is a fundamental YAML specification constraint, not a Docker Compose limitation.

This means:
- Anchors defined in the root `docker-compose.yml` are NOT available in `services/app.yml`
- Each included file is a separate YAML document, parsed independently
- You cannot define `x-healthcheck: &hc` in the root and use `*hc` in an included file

**Impact on dev-strap**: Each service file must be fully self-contained. No shared anchors. This is actually fine -- our service files are already self-contained templates.

### Extension fields (`x-` prefix)

Any top-level key starting with `x-` is ignored by Compose. Combined with anchors, this enables DRY patterns within a single file:

```yaml
x-common-env: &common-env
  environment:
    - SSL_CERT_FILE=/certs/ca.crt
    - PROJECT_NAME=${PROJECT_NAME}

services:
  app:
    <<: *common-env
    image: my-app:latest
  worker:
    <<: *common-env
    image: my-worker:latest
```

Extensions can also be nested within services:

```yaml
services:
  webapp:
    image: example/webapp
    x-custom-metadata: "for internal tooling"
```

### Multiple anchor merge

You can merge from multiple anchors:

```yaml
x-env: &default-env
  FOO: BAR
x-logging: &default-logging
  driver: json-file
  options:
    max-size: "10m"

services:
  app:
    environment:
      <<: [*default-env]
    logging:
      <<: *default-logging
```

### Relevance to dev-strap

Since anchors cannot span includes, and our service files are meant to be independent, extensions are useful WITHIN individual service files but not for cross-file sharing. The main compose file has no services of its own to share anchors with.

**Conclusion**: Extensions/anchors are a nice-to-have within complex individual service files (e.g., a Prometheus+Grafana combined file), but they do not change our architecture.

---

## 3. Variable Interpolation Across Includes

### How `${VAR}` resolves

Docker Compose resolves `${VAR}` references in YAML files before parsing them into the application model. The resolution order (highest to lowest precedence):

1. **Shell environment** (exported variables in the caller's shell)
2. **`--env-file` CLI argument** (if passed to `docker compose`)
3. **`.env` file in the project directory** (auto-loaded)

### Syntax variants

| Syntax                  | Behavior                                                    |
|-------------------------|-------------------------------------------------------------|
| `${VAR}`                | Substitute value; error if unset                            |
| `${VAR:-default}`       | Use value if set and non-empty; otherwise use `default`     |
| `${VAR-default}`        | Use value if set (even if empty); otherwise use `default`   |
| `${VAR:?error message}` | Use value if set and non-empty; otherwise error with message|
| `${VAR?error message}`  | Use value if set; otherwise error with message              |
| `${VAR:+replacement}`   | Use `replacement` if VAR is set and non-empty               |

### What this means for dev-strap service files

Current templates use `${PROJECT_NAME}`, `${DB_USER}`, etc. These are currently substituted by `sed` in `core/compose/generate.sh` at generation time. In the new architecture:

- Service files keep `${VAR}` references as-is (no sed, no envsubst)
- Docker Compose resolves them at `docker compose up` time from `project.env`
- The file `project.env` is loaded as the `.env` file (either by naming convention or `--env-file`)

**Example**: The current `templates/extras/redis/service.yml` already works as-is:

```yaml
services:
  redis:
    image: redis:alpine
    container_name: ${PROJECT_NAME}-redis
    networks:
      - ${PROJECT_NAME}-internal
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 5s
      timeout: 3s
      retries: 10
```

No changes needed. Docker Compose resolves `${PROJECT_NAME}` from `project.env`.

### Handling `env_file` at the service level vs compose-level

There are two different `env_file` concepts:

1. **Service-level `env_file`**: Loads variables INTO the container's environment at runtime
   ```yaml
   services:
     app:
       env_file: ./project.env  # Variables available inside the container
   ```

2. **Compose-level `.env`**: Resolves `${VAR}` references in the YAML file itself (interpolation)
   ```yaml
   # .env or --env-file
   PROJECT_NAME=myapp
   # Then in compose:
   container_name: ${PROJECT_NAME}-app  # Becomes "myapp-app"
   ```

For dev-strap, we need BOTH:
- Compose-level interpolation to resolve service names, container names, network names
- Service-level `env_file` to pass database credentials etc. into containers

### The `project.env` naming problem

Docker Compose auto-loads `.env` (literally that filename) from the project directory. Our file is called `project.env`, not `.env`. Options:

**Option A: Rename to `.env`**
- Pro: Zero configuration, Compose auto-loads it
- Con: Hidden file, easy to miss. `.env` has conventions (gitignored, secrets) that don't apply here.

**Option B: Use `--env-file project.env` on every `docker compose` call**
- Pro: Explicit, works with any filename
- Con: Every compose command in devstack.sh needs the flag

**Option C: Symlink `.env -> project.env`**
- Pro: Compose auto-loads, file is visible as `project.env`
- Con: Extra symlink to maintain

**Recommendation: Option B** -- use `--env-file project.env`. The product's `devstack.sh` wraps all `docker compose` calls anyway, so adding one flag is trivial. This keeps the explicit `project.env` name that the project already uses.

```bash
DC="docker compose --env-file project.env -f docker-compose.yml -p ${PROJECT_NAME}"
$DC up -d
$DC logs -f
$DC down
```

---

## 4. Networks Across Includes

### How networks merge

When using `include`, networks follow the same conflict rule as all resources:

- If the root file defines `networks: { devstack-internal: ... }` and an included file also defines `networks: { devstack-internal: ... }`, Compose reports a conflict error -- even if the definitions are identical.
- This is a known behavior (docker/compose#10841), not a bug. It is by design.

### The solution: define the network ONCE

The network must be defined in exactly one place. Services in other files reference it by name without redefining it.

**Pattern 1: Network in root compose file only**

```yaml
# docker-compose.yml (root)
include:
  - path: services/app.yml
    project_directory: .
  - path: services/redis.yml
    project_directory: .

networks:
  devstack-internal:
    driver: bridge
```

```yaml
# services/app.yml -- references network but does NOT define it
services:
  app:
    networks:
      - devstack-internal
# No 'networks:' top-level section here
```

This works because Compose validates the merged model. The service references `devstack-internal`, which exists in the root file's `networks:` section.

**Pattern 2: Network in a shared commons file**

```yaml
# services/commons.yml
networks:
  devstack-internal:
    driver: bridge
```

```yaml
# docker-compose.yml
include:
  - services/commons.yml
  - path: services/app.yml
    project_directory: .
```

This is the pattern recommended by the Docker team for complex setups. For dev-strap, Pattern 1 is simpler since the root file already needs to exist.

### Network aliases

Network aliases are set per-service, not per-network. They work normally across includes:

```yaml
# services/caddy.yml
services:
  web:
    networks:
      devstack-internal:
        aliases:
          - myproject.local
          - api.stripe.com
          - api.sendgrid.com
```

The aliases are part of the service definition, not the network definition. No conflict.

### Impact on dev-strap

- Define `networks:` section in root `docker-compose.yml` only
- All service files reference the network name without defining it
- The network name should be simple (not `${PROJECT_NAME}-internal`) since it lives in one place
- But we CAN use `${PROJECT_NAME}-internal` with interpolation -- the root file defines it once:

```yaml
# docker-compose.yml
networks:
  ${PROJECT_NAME}-internal:
    driver: bridge
    ipam:
      config:
        - subnet: ${NETWORK_SUBNET}
```

And every service file references `${PROJECT_NAME}-internal` -- Compose resolves the same variable everywhere from the same `.env` file.

---

## 5. The Mock DNS Alias Problem

### The problem

Caddy acts as a DNS interceptor by holding network aliases for mocked domains. When the app container resolves `api.stripe.com`, Docker's internal DNS returns the caddy container's IP because caddy has `api.stripe.com` as a network alias.

Currently, the compose generator reads `mocks/*/domains` at generation time and builds the alias list dynamically:

```yaml
# Generated in core/compose/generate.sh
web:
  networks:
    myproject-internal:
      aliases:
        - myproject.local
        - api.stripe.com      # from mocks/stripe/domains
        - api.sendgrid.com    # from mocks/sendgrid/domains
```

In the new architecture, service files are static (no generation). But the alias list is inherently dynamic -- it depends on what mock directories exist.

### Why this is unique

Every other service file is static:
- `services/app.yml` -- always the same for a given app type
- `services/database.yml` -- always the same for a given db type
- `services/redis.yml` -- always the same
- `services/wiremock.yml` -- mostly static (volume mounts are dynamic, but see below)

Only the caddy service has configuration that depends on the filesystem state at runtime.

### Solution: generate `caddy.yml` at start time

The caddy service file (`services/caddy.yml`) is the ONE file that gets generated at start time, alongside the Caddyfile. Everything else is static.

This is acceptable because:
1. The Caddyfile already needs generation (reads `mocks/*/domains` for site blocks)
2. The `domains.txt` for cert-gen already needs generation
3. These three things (caddy.yml, Caddyfile, domains.txt) all derive from the same source (`mocks/*/domains`)
4. It is a small, focused generation (~30 lines of output)

### What gets generated at start time

```
mocks/*/domains
    |
    v
+---+---+
|       |
v       v
caddy/Caddyfile          services/caddy.yml          caddy/domains.txt
(site blocks for         (network aliases for         (SANs for cert-gen)
 each mock domain)        DNS interception)
```

### The WireMock volume mount problem

WireMock also has dynamic configuration -- its volume mounts depend on which `mocks/*/mappings` directories exist. However, we can solve this statically:

```yaml
# services/wiremock.yml
services:
  wiremock:
    image: wiremock/wiremock:latest
    volumes:
      - ./mocks:/home/wiremock/mocks:ro
    command: >
      --port 8080
      --root-dir /home/wiremock/mocks
      --verbose
      --global-response-templating
```

Mount the entire `mocks/` directory and let WireMock discover mappings from subdirectories. This eliminates the per-mock volume mount generation.

If WireMock's built-in directory structure does not support this directly, we can mount individual directories using a consistent pattern. But the simplest approach is a single `./mocks` mount.

**Update after investigation**: WireMock expects mappings at `__files/` and `mappings/` under its root-dir. Our current structure (`mocks/<name>/mappings/`) does not match. Two options:

1. Restructure mocks to match WireMock's expectations (breaking change)
2. Keep generating the wiremock volume mounts at start time (alongside caddy.yml)

Option 2 is simpler. The start-time generation produces `services/caddy.yml` and `services/wiremock.yml` -- both are "dynamic" service files, both are small.

---

## 6. Practical File Structure

### Product directory layout

```
my-app/
├── docker-compose.yml          # Root: includes + network + volumes
├── project.env                 # All configuration variables
├── services/
│   ├── cert-gen.yml            # Static -- certificate generation one-shot
│   ├── app.yml                 # Static -- chosen app type (e.g., Go)
│   ├── database.yml            # Static -- chosen database (e.g., PostgreSQL)
│   ├── redis.yml               # Static -- chosen extra service
│   ├── caddy.yml               # GENERATED at start time (dynamic aliases)
│   ├── wiremock.yml            # GENERATED at start time (dynamic mounts)
│   ├── tester.yml              # Static -- Playwright test runner
│   └── test-dashboard.yml      # Static -- test results web UI
├── caddy/
│   ├── Caddyfile               # GENERATED at start time (from mocks/*/domains)
│   └── domains.txt             # GENERATED at start time (for cert SANs)
├── certs/
│   └── generate.sh             # Static -- cert generation script
├── mocks/
│   ├── stripe/
│   │   ├── domains
│   │   └── mappings/*.json
│   └── sendgrid/
│       ├── domains
│       └── mappings/*.json
├── app/
│   ├── Dockerfile
│   ├── init.sh
│   └── src/
├── frontend/                   # Only if frontend was selected
│   ├── Dockerfile
│   └── src/
├── tests/
│   ├── playwright/
│   └── results/
└── devstack.sh                 # Lightweight runtime script
```

### Root docker-compose.yml

```yaml
# docker-compose.yml
# Assembled by dev-strap factory. Static include list.
# Only caddy.yml and wiremock.yml are regenerated at start time.

include:
  - path: services/cert-gen.yml
    project_directory: .
  - path: services/app.yml
    project_directory: .
  - path: services/database.yml
    project_directory: .
  - path: services/redis.yml
    project_directory: .
  - path: services/caddy.yml
    project_directory: .
  - path: services/wiremock.yml
    project_directory: .
  - path: services/tester.yml
    project_directory: .
  - path: services/test-dashboard.yml
    project_directory: .

networks:
  ${PROJECT_NAME}-internal:
    driver: bridge
    ipam:
      config:
        - subnet: ${NETWORK_SUBNET}

volumes:
  ${PROJECT_NAME}-certs:
  ${PROJECT_NAME}-db-data:
  ${PROJECT_NAME}-go-modules:
```

### Example static service file: `services/database.yml`

```yaml
# services/database.yml -- PostgreSQL
# Deployed by dev-strap factory. Do not edit unless you know what you are doing.

services:
  db:
    image: postgres:16-alpine
    container_name: ${PROJECT_NAME}-db
    environment:
      POSTGRES_DB: ${DB_NAME}
      POSTGRES_USER: ${DB_USER}
      POSTGRES_PASSWORD: ${DB_PASSWORD}
    volumes:
      - ${PROJECT_NAME}-db-data:/var/lib/postgresql/data
    networks:
      - ${PROJECT_NAME}-internal
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${DB_USER} -d ${DB_NAME}"]
      interval: 5s
      timeout: 3s
      retries: 20
```

Note: this is identical to the current `templates/databases/postgres/service.yml`, with one key difference -- the `volumes:` top-level section is NOT included here. It is in the root `docker-compose.yml`. The service references the volume by name, and Compose resolves it from the merged model.

### Example generated service file: `services/caddy.yml`

```yaml
# services/caddy.yml -- GENERATED at start time
# Regenerated from mocks/*/domains by devstack.sh start

services:
  web:
    image: caddy:2-alpine
    container_name: ${PROJECT_NAME}-web
    ports:
      - "${HTTP_PORT}:80"
      - "${HTTPS_PORT}:443"
    volumes:
      - ./caddy/Caddyfile:/etc/caddy/Caddyfile:ro
      - ${PROJECT_NAME}-certs:/certs:ro
      - ./tests/results:/srv/test-results:ro
    depends_on:
      cert-gen:
        condition: service_completed_successfully
      app:
        condition: service_started
    networks:
      ${PROJECT_NAME}-internal:
        aliases:
          - ${PROJECT_NAME}.local
          - api.stripe.com
          - api.sendgrid.com
    healthcheck:
      test: ["CMD", "wget", "--spider", "-q", "http://127.0.0.1/"]
      interval: 5s
      timeout: 3s
      retries: 20
```

The aliases list is populated from `mocks/*/domains` at generation time. This is the only dynamic part.

---

## 7. Restart Trade-offs

### What needs restart vs hot-reload

| Change                          | Action required          | Why                                         |
|---------------------------------|--------------------------|---------------------------------------------|
| Mock mapping JSON changed       | `reload-mocks` (hot)     | WireMock `__admin/mappings/reset` reloads    |
| New mock domain added           | Full restart             | Needs new DNS alias + Caddyfile site block + cert SAN |
| Mock domain removed             | Full restart             | Same reason                                 |
| `project.env` value changed     | Full restart             | Compose re-interpolates all service files    |
| App source code changed         | Hot-reload (automatic)   | Volume-mounted, app watches for changes      |
| Frontend source changed         | Hot-reload (automatic)   | Vite HMR via volume mount                   |
| Service file manually edited    | `docker compose up -d`   | Compose detects config changes               |
| Caddyfile manually edited       | `docker compose exec web caddy reload` | Caddy supports hot config reload |

### Non-destructive restart

The product's `devstack.sh` should implement:

```
stop        = docker compose stop (NOT down -v)
stop --clean = docker compose down -v --remove-orphans
restart     = stop + start (preserves volumes)
```

Key insight: `docker compose stop` halts containers without removing them or their volumes. `docker compose down` (without `-v`) removes containers and networks but preserves volumes. `docker compose down -v` removes everything including volumes.

For `restart`, the sequence is:
1. `docker compose down` (remove containers/networks, keep volumes)
2. Regenerate caddy.yml, Caddyfile, domains.txt
3. `docker compose up -d`

This preserves database data, cert caches, module caches across restarts.

---

## 8. Complete Example Files

### Scenario: Go backend + PostgreSQL + Redis + WireMock (Stripe + SendGrid mocks) + Vite frontend

#### `project.env`

```bash
PROJECT_NAME=myapp
NETWORK_SUBNET=172.28.0.0/24

APP_TYPE=go
APP_SOURCE=./app
APP_INIT_SCRIPT=./app/init.sh

FRONTEND_TYPE=vite
FRONTEND_SOURCE=./frontend
FRONTEND_PORT=5173
FRONTEND_API_PREFIX=/api

HTTP_PORT=8080
HTTPS_PORT=8443
TEST_DASHBOARD_PORT=8082

DB_TYPE=postgres
DB_NAME=myapp
DB_USER=myapp
DB_PASSWORD=secret
DB_ROOT_PASSWORD=root

# Auto-wiring
REDIS_URL=redis://redis:6379
API_BASE=/api
```

#### `docker-compose.yml`

```yaml
include:
  - path: services/cert-gen.yml
    project_directory: .
  - path: services/app.yml
    project_directory: .
  - path: services/frontend.yml
    project_directory: .
  - path: services/database.yml
    project_directory: .
  - path: services/redis.yml
    project_directory: .
  - path: services/caddy.yml
    project_directory: .
  - path: services/wiremock.yml
    project_directory: .
  - path: services/tester.yml
    project_directory: .
  - path: services/test-dashboard.yml
    project_directory: .

networks:
  ${PROJECT_NAME}-internal:
    driver: bridge
    ipam:
      config:
        - subnet: ${NETWORK_SUBNET}

volumes:
  ${PROJECT_NAME}-certs:
  ${PROJECT_NAME}-db-data:
  ${PROJECT_NAME}-go-modules:
```

#### `services/cert-gen.yml`

```yaml
services:
  cert-gen:
    image: alpine:3
    container_name: ${PROJECT_NAME}-cert-gen
    volumes:
      - ${PROJECT_NAME}-certs:/certs
      - ./certs/generate.sh:/scripts/generate.sh:ro
      - ./caddy/domains.txt:/config/domains.txt:ro
    environment:
      - PROJECT_NAME=${PROJECT_NAME}
    entrypoint: ["sh", "-c", "apk add --no-cache openssl >/dev/null 2>&1 && sh /scripts/generate.sh"]
    networks:
      - ${PROJECT_NAME}-internal
```

#### `services/app.yml`

```yaml
services:
  app:
    build:
      context: ./app
      dockerfile: Dockerfile
    container_name: ${PROJECT_NAME}-app
    volumes:
      - ./app:/app
      - ${PROJECT_NAME}-go-modules:/go/pkg/mod
      - ${PROJECT_NAME}-certs:/certs:ro
    working_dir: /app
    environment:
      - GO_ENV=development
      - PORT=3000
      - SSL_CERT_FILE=/certs/ca.crt
      - DB_HOST=db
      - DB_PORT=5432
      - DB_NAME=${DB_NAME}
      - DB_USER=${DB_USER}
      - DB_PASSWORD=${DB_PASSWORD}
      - REDIS_URL=${REDIS_URL}
    depends_on:
      cert-gen:
        condition: service_completed_successfully
      db:
        condition: service_healthy
    networks:
      - ${PROJECT_NAME}-internal
```

#### `services/frontend.yml`

```yaml
services:
  frontend:
    build:
      context: ./frontend
      dockerfile: Dockerfile
    container_name: ${PROJECT_NAME}-frontend
    volumes:
      - ./frontend:/app
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

#### `services/database.yml`

```yaml
services:
  db:
    image: postgres:16-alpine
    container_name: ${PROJECT_NAME}-db
    environment:
      POSTGRES_DB: ${DB_NAME}
      POSTGRES_USER: ${DB_USER}
      POSTGRES_PASSWORD: ${DB_PASSWORD}
    volumes:
      - ${PROJECT_NAME}-db-data:/var/lib/postgresql/data
    networks:
      - ${PROJECT_NAME}-internal
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${DB_USER} -d ${DB_NAME}"]
      interval: 5s
      timeout: 3s
      retries: 20
```

#### `services/redis.yml`

```yaml
services:
  redis:
    image: redis:alpine
    container_name: ${PROJECT_NAME}-redis
    networks:
      - ${PROJECT_NAME}-internal
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 5s
      timeout: 3s
      retries: 10
```

#### `services/caddy.yml` (GENERATED at start time)

```yaml
# GENERATED by devstack.sh start -- do not edit manually
# Regenerated from mocks/*/domains on every start

services:
  web:
    image: caddy:2-alpine
    container_name: ${PROJECT_NAME}-web
    ports:
      - "${HTTP_PORT}:80"
      - "${HTTPS_PORT}:443"
    volumes:
      - ./caddy/Caddyfile:/etc/caddy/Caddyfile:ro
      - ${PROJECT_NAME}-certs:/certs:ro
      - ./tests/results:/srv/test-results:ro
    depends_on:
      cert-gen:
        condition: service_completed_successfully
      app:
        condition: service_started
      frontend:
        condition: service_started
    networks:
      ${PROJECT_NAME}-internal:
        aliases:
          - ${PROJECT_NAME}.local
          - api.stripe.com
          - api.sendgrid.com
    healthcheck:
      test: ["CMD", "wget", "--spider", "-q", "http://127.0.0.1/"]
      interval: 5s
      timeout: 3s
      retries: 20
```

#### `services/wiremock.yml` (GENERATED at start time)

```yaml
# GENERATED by devstack.sh start -- do not edit manually
# Regenerated from mocks/*/domains on every start

services:
  wiremock:
    image: wiremock/wiremock:latest
    container_name: ${PROJECT_NAME}-wiremock
    command: >
      --port 8080
      --verbose
      --global-response-templating
    volumes:
      - ./mocks/stripe/mappings:/home/wiremock/mappings/stripe:ro
      - ./mocks/sendgrid/mappings:/home/wiremock/mappings/sendgrid:ro
      - ./mocks/stripe/__files:/home/wiremock/__files/stripe:ro
      - ./mocks/sendgrid/__files:/home/wiremock/__files/sendgrid:ro
      - ${PROJECT_NAME}-certs:/home/wiremock/certs:ro
    depends_on:
      cert-gen:
        condition: service_completed_successfully
    networks:
      - ${PROJECT_NAME}-internal
    healthcheck:
      test: ["CMD", "wget", "-qO", "/dev/null", "http://localhost:8080/__admin/"]
      interval: 5s
      timeout: 3s
      retries: 10
```

#### `services/tester.yml`

```yaml
services:
  tester:
    image: mcr.microsoft.com/playwright:v1.52.0-noble
    container_name: ${PROJECT_NAME}-tester
    working_dir: /tests
    volumes:
      - ./tests/playwright:/tests
      - ./tests/results:/results
      - ${PROJECT_NAME}-certs:/certs:ro
    environment:
      - BASE_URL=https://web:443
      - NODE_EXTRA_CA_CERTS=/certs/ca.crt
      - PLAYWRIGHT_HTML_REPORT=/results/report
    depends_on:
      web:
        condition: service_healthy
    entrypoint: ["tail", "-f", "/dev/null"]
    networks:
      - ${PROJECT_NAME}-internal
```

#### `services/test-dashboard.yml`

```yaml
services:
  test-dashboard:
    image: busybox:latest
    container_name: ${PROJECT_NAME}-test-dashboard
    ports:
      - "${TEST_DASHBOARD_PORT}:8080"
    volumes:
      - ./tests/results:/results:ro
    working_dir: /results
    command: httpd -f -p 8080 -h /results
    networks:
      - ${PROJECT_NAME}-internal
```

#### `caddy/Caddyfile` (GENERATED at start time)

```caddyfile
{
    auto_https off
}

# Application server (frontend + backend, path-based routing)
localhost:80, localhost:443, myapp.local:80, myapp.local:443 {
    tls /certs/server.crt /certs/server.key

    handle /api/* {
        reverse_proxy app:3000
    }

    handle_path /test-results/* {
        root * /srv/test-results
        file_server browse
        header Access-Control-Allow-Origin *
        header Cache-Control "no-cache, no-store"
    }

    handle {
        reverse_proxy frontend:5173
    }
}

# Mock API Proxy -- intercepts HTTPS to mocked external services
# Domains: api.stripe.com, api.sendgrid.com
api.stripe.com:443, api.sendgrid.com:443 {
    tls /certs/server.crt /certs/server.key

    reverse_proxy wiremock:8080 {
        header_up X-Original-Host {http.request.host}
        header_up X-Real-IP {remote_host}
        header_up X-Forwarded-Proto {scheme}
    }
}
```

---

## Summary of Key Decisions

| Question | Answer |
|----------|--------|
| How do variables scope across includes? | Each included file resolves from its own `.env` or from `project_directory`'s `.env`. Use `project_directory: .` to point all files at the project root. |
| Do networks propagate to included services? | No. Define the network ONCE in the root compose file. Services reference it by name. |
| Do volumes merge? | Named volumes must be defined once (in root). Services reference them by name. |
| Can depends_on cross files? | Yes. The merged model is flat. |
| What Docker Compose version? | v2.20.0+ (no `version:` key in the file). |
| Can anchors span includes? | No. YAML per-document limitation. Each file is self-contained. |
| What about dynamic service files? | `caddy.yml` and `wiremock.yml` are generated at start time. Everything else is static. |
| How to load `project.env`? | Use `--env-file project.env` on all `docker compose` calls. |
