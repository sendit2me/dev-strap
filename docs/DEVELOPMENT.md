# Development Workflow

How to actually develop code inside DevStack. Two approaches — choose what fits your workflow.

## Approach 1: Edit on host, run in container (recommended for most)

This is the simplest setup. You edit files with any editor on your machine. The source directory is volume-mounted into the container, so changes appear instantly.

### How it works

```
Your machine                          Docker container
──────────────                        ────────────────
app/src/index.js  ──(volume mount)──▶ /app/src/index.js
      │                                      │
  You edit here                        Container runs here
  (VS Code, vim,                       (Node watches for changes,
   Sublime, etc.)                       auto-restarts)
```

### For interpreted languages (Node, PHP, Python)

Changes are immediate. Save a file, the container picks it up:

- **Node.js**: The Dockerfile uses `node --watch` which auto-restarts on file changes
- **PHP/Laravel**: PHP-FPM re-reads files on every request — no restart needed
- **Python**: Use `--reload` flag with your framework (Flask, FastAPI, etc.)

### For compiled languages (Go, Rust)

A file-watcher inside the container recompiles on change:

- **Go**: The template includes [Air](https://github.com/air-verse/air) which watches `.go` files and rebuilds automatically. Config is in `.air.toml`.
- **Rust**: The template includes `cargo-watch` which watches `.rs` files and rebuilds automatically via `CMD ["cargo", "watch", "-x", "run"]`. The `cargo-target` named volume persists compiled artifacts between restarts, avoiding 5-30 minute full recompiles.

Typical rebuild cycle: save file -> ~1-2 seconds -> new binary running.

### Accessing the container shell

When you need to run commands inside the container (install a package, run a migration, debug something):

```bash
# Default: shell into the app container
./devstack.sh shell

# Shell into any service
./devstack.sh shell db
./devstack.sh shell redis
./devstack.sh shell wiremock
```

This drops you into a bash (or sh) shell inside the running container, with the full language toolchain available:

```bash
# Inside the app container:
npm install some-package        # Node
go get some/module              # Go
composer require some/package   # PHP
pip install some-package        # Python
cargo add some-crate            # Rust
```

### Viewing logs

```bash
# All services
./devstack.sh logs

# Just your app
./devstack.sh logs app

# Just Caddy (useful for debugging routing)
./devstack.sh logs web

# Just WireMock (useful for debugging mock responses)
./devstack.sh logs wiremock
```

## Approach 2: VS Code Dev Containers (full IDE inside container)

This gives you the full VS Code experience — IntelliSense, debugging, extensions — running inside the container. Your VS Code connects to the container as if it were a remote machine.

### Setup

1. Install the [Dev Containers extension](https://marketplace.visualstudio.com/items?itemName=ms-vscode-remote.remote-containers) in VS Code.

2. Start the stack:
   ```bash
   ./devstack.sh start
   ```

3. Copy the `.devcontainer/` directory from your app template into your app source:
   ```bash
   cp -r templates/apps/node-express/.devcontainer/ app/.devcontainer/
   ```

4. Edit `app/.devcontainer/devcontainer.json` to point at the generated compose file:
   ```json
   {
       "name": "My Project",
       "dockerComposeFile": ["../../.generated/docker-compose.yml"],
       "service": "app",
       "workspaceFolder": "/app",
       "customizations": {
           "vscode": {
               "extensions": [
                   "dbaeumer.vscode-eslint",
                   "esbenp.prettier-vscode"
               ]
           }
       }
   }
   ```

   **Important**: The `dockerComposeFile` path is relative to the `.devcontainer/` directory. Adjust based on where your `.devcontainer/` lives.

5. In VS Code: `Ctrl+Shift+P` → "Dev Containers: Attach to Running Container" → select your app container.

### What you get

- Full IntelliSense / LSP (the language server runs inside the container with all deps available)
- Integrated terminal is inside the container
- Debugging (breakpoints, step-through) works against the containerized runtime
- Extensions run inside the container (linters, formatters, language tools)
- File changes are still instant (volume mount)

### When to use this

- You need IDE features like autocomplete, go-to-definition, or debugging
- You're working on a compiled language and want IDE-integrated build errors
- You want a single-window experience (no switching between editor and terminal)

### When NOT to use this

- Quick edits — Approach 1 is faster to start
- You prefer vim/neovim/Sublime/other editors
- You're just running tests or checking logs

## Working with the database

### Connecting from your app

Your app connects using the Docker-internal hostname `db`:

```
Host:     db
Port:     3306 (MariaDB) or 5432 (Postgres)
Database: (from DB_NAME in project.env)
User:     (from DB_USER in project.env)
Password: (from DB_PASSWORD in project.env)
```

### Connecting from your machine

The database port is not exposed by default. To connect from a GUI tool (TablePlus, DBeaver, etc.), add a port mapping to the database template:

Edit `templates/databases/mariadb/service.yml`:

```yaml
  db:
    image: mariadb:10.11
    container_name: ${PROJECT_NAME}-db
    ports:
      - "3306:3306"          # <-- add this line
    environment:
      ...
```

Then restart. Connect your GUI tool to `localhost:3306`.

### Running migrations and queries

```bash
# Shell into the app container and run your framework's migration tool
./devstack.sh shell
php artisan migrate              # Laravel
npx prisma migrate deploy        # Prisma
npx knex migrate:latest          # Knex
go run ./cmd/migrate up          # Go custom

# Or shell into the database directly
./devstack.sh shell db
mariadb -u root -proot my_saas_app
# or
psql -U app -d my_saas_app
```

### Database is ephemeral

`./devstack.sh stop` removes the database volume. Next `start` creates a fresh database. Your `init.sh` script should handle migrations and seeding so the database is always ready.

This is intentional — it prevents "works on my machine" issues caused by hand-tweaked data.

## Working with mocked APIs

Your app code calls external APIs normally. DevStack intercepts them transparently.

```javascript
// This code is identical in dev and production:
const response = await fetch('https://api.stripe.com/v1/charges', {
    method: 'POST',
    headers: { 'Authorization': 'Bearer sk-test-key' },
    body: JSON.stringify({ amount: 2500 })
});
```

In DevStack, this HTTPS request goes to Caddy (via DNS alias) -> WireMock -> mock response.
In production, it goes to the real Stripe API.

No `if (isDev)` flags. No environment-switching logic.

### Iterating on mock responses

You don't need a full restart to change mock responses:

```bash
# Edit a mapping
vim mocks/stripe/mappings/create-charge.json

# Hot-reload (takes effect immediately)
./devstack.sh reload-mocks
```

A full restart (`./devstack.sh restart`) is only needed when adding a **new domain**.

### Recording from a real API

If you're integrating a new API and don't know the response format:

```bash
./devstack.sh new-mock stripe api.stripe.com   # scaffold
./devstack.sh restart                            # pick up domain
./devstack.sh record stripe                      # proxy to real API, Ctrl+C when done
./devstack.sh apply-recording stripe             # apply captured mappings
```

See [ADDING_MOCKS.md](ADDING_MOCKS.md#recording-real-api-responses) for the full workflow.

### Debugging mock interception

If a mock isn't being hit:

```bash
# Check WireMock received the request
./devstack.sh shell wiremock
wget -qO- http://localhost:8080/__admin/requests

# Check what mappings are loaded
wget -qO- http://localhost:8080/__admin/mappings

# Check Caddy is routing correctly
./devstack.sh logs web

# Test the mock directly from inside the app container
./devstack.sh shell
curl -k https://api.stripe.com/v1/charges -X POST -d '{"amount":2500}'
```

See [TROUBLESHOOTING.md](TROUBLESHOOTING.md) for common issues.

## File structure conventions

### Where your code lives

```
devstack/
├── app/                    # Your application source code
│   ├── Dockerfile          # REQUIRED: how to build your container
│   ├── init.sh             # REQUIRED: runs on container start
│   ├── .env                # OPTIONAL: app-specific env file
│   ├── package.json        # Language-specific dependency file
│   └── src/                # Your actual source code
│       └── ...
│
├── frontend/               # Your frontend source (if FRONTEND_TYPE is set)
│   ├── Dockerfile          # REQUIRED: how to build the frontend container
│   ├── package.json        # Frontend dependencies
│   └── src/                # Frontend source code
│       └── ...
│
├── mocks/                  # Your mock definitions
│   └── ...
│
├── tests/
│   ├── playwright/         # E2E test specs
│   │   └── ...
│   └── contract/           # Contract validation test fixtures
│       └── fixtures/       # JSON payloads for bootstrap testing
│           └── ...
│
├── project.env             # Your project configuration
└── ...                     # DevStack internals (don't edit unless creating templates)
```

### DevStack internals file tree

```
devstack/
├── core/
│   ├── caddy/
│   │   └── generate-caddyfile.sh    # Generates .generated/Caddyfile from mocks/*/domains + project.env
│   ├── certs/
│   │   └── generate.sh             # Generates TLS certs (CA + server) with SANs for mocked domains
│   └── compose/
│       └── generate.sh             # Assembles .generated/docker-compose.yml from templates
│
├── contract/
│   └── manifest.json               # Catalog of all available items, presets, and wiring rules
│
├── templates/
│   ├── apps/                        # App templates (one per language/framework)
│   │   ├── node-express/
│   │   ├── php-laravel/
│   │   ├── go/
│   │   ├── python-fastapi/
│   │   └── rust/
│   ├── databases/                   # Database templates
│   │   ├── postgres/
│   │   └── mariadb/
│   ├── extras/                      # Extra service templates
│   │   ├── redis/
│   │   ├── mailpit/
│   │   ├── nats/
│   │   ├── minio/
│   │   ├── prometheus/
│   │   ├── grafana/
│   │   ├── dozzle/
│   │   ├── db-ui/
│   │   └── swagger-ui/
│   └── frontends/                   # Frontend dev server templates
│       └── vite/
│
├── .generated/                      # AUTO-GENERATED (never edit)
│   ├── docker-compose.yml
│   ├── Caddyfile
│   └── domains.txt
│
├── devstack.sh                      # CLI entrypoint
└── project.env                      # Project configuration
```

### What you edit vs. what's generated

| Edit freely | Generated (don't edit) |
|-------------|----------------------|
| `project.env` | `.generated/*` |
| `app/*` | |
| `frontend/*` | |
| `mocks/*` | |
| `tests/playwright/*` | |
| `templates/*` (when creating templates) | |
| `core/*` (when modifying generators) | |
| `contract/manifest.json` (when adding items to catalog) | |

## Architecture components

### Caddy (reverse proxy)

Caddy serves as the web server and reverse proxy (`web` container). It handles:

- **App routing**: Proxies HTTP requests to `app:3000` (or FastCGI to `app:9000` for PHP).
- **Frontend routing**: When a frontend is configured, routes `${FRONTEND_API_PREFIX}/*` to the backend and everything else to the frontend dev server.
- **Mock interception**: Terminates TLS for mocked domains and proxies to WireMock, adding `X-Original-Host` headers.
- **Test results**: Serves static HTML test reports at `/test-results/`.

Config is generated by `core/caddy/generate-caddyfile.sh` and written to `.generated/Caddyfile`.

### Wiring system

The wiring system in `contract/manifest.json` auto-generates environment variables when certain items are selected together. For example, when both `app.*` and `services.redis` are selected, the system writes `REDIS_URL=redis://redis:6379` to project.env.

Wiring rules:

```json
{
  "when": ["app.*", "services.redis"],
  "set": "app.*.redis_url",
  "template": "redis://redis:6379"
}
```

- `when`: Array of item selectors (wildcards OK). All must be present in selections.
- `set`: The output variable path. Last segment becomes the env var name (uppercased).
- `template`: The value to write. Can reference other item properties.

See `contract/manifest.json` for all defined wiring rules.

### Contract validation

The `--bootstrap` flow validates payloads against the manifest before generating anything. Validation checks:

- Required categories have selections
- Single-select categories don't have multiple items
- Referenced items exist in the manifest
- Dependencies (`requires`) are satisfied (wildcard patterns like `app.*` match any app selection)
- Conflicts are not violated
- Port collisions between default ports are detected

Test fixtures in `tests/contract/fixtures/` cover these scenarios:
- `port-conflict-default.json` / `port-conflict-override.json` / `port-conflict-resolved.json` -- port collision detection and resolution
- `valid-with-frontend.json` / `valid-with-frontend-full.json` -- frontend configuration
- `valid-with-observability.json` -- observability stack
- `conflict-payload.json` / `manifest-with-conflict.json` -- conflict detection
- `missing-wildcard-dep.json` / `missing-wildcard-dep-fail.json` -- wildcard dependency resolution

## AI-assisted development

DevStack is designed to work with AI coding agents (Claude Code, Cursor, Copilot, etc.):

1. **The agent edits files on your machine** (in `app/src/`, `frontend/src/`, `mocks/`, `tests/`)
2. **Changes appear in the container** instantly (volume mount)
3. **The agent runs tests** via `./devstack.sh test`
4. **Test results are structured** (JSON + HTML + screenshots) -- the agent can parse failures
5. **The agent can shell into containers** via `./devstack.sh shell` for debugging

The key principle: the agent never needs to install anything on your machine. Everything runs in containers.
