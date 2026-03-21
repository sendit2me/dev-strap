# Development Guide

How to work on the dev-strap factory.

## Project structure

```
dev-strap/
├── devstack.sh                 # Factory CLI (--options, --bootstrap, init)
├── contract/
│   └── manifest.json           # Catalog source of truth
├── templates/
│   ├── apps/                   # App templates (one per language)
│   │   ├── node-express/       # Dockerfile + service.yml
│   │   ├── php-laravel/
│   │   ├── go/
│   │   ├── python-fastapi/
│   │   └── rust/
│   ├── frontends/
│   │   └── vite/
│   ├── databases/
│   │   ├── postgres/
│   │   └── mariadb/
│   ├── extras/                 # Service templates
│   │   ├── redis/
│   │   ├── mailpit/
│   │   ├── nats/
│   │   ├── minio/
│   │   ├── prometheus/
│   │   ├── grafana/
│   │   ├── dozzle/
│   │   ├── db-ui/
│   │   └── swagger-ui/
│   └── common/                 # Always-included templates
│       ├── cert-gen.yml
│       ├── tester.yml
│       └── test-dashboard.yml
├── product/                    # Files shipped to users
│   ├── devstack.sh             # Product runtime CLI
│   ├── certs/generate.sh
│   └── .gitignore
├── core/                       # Generator scripts (factory-side)
│   ├── caddy/generate-caddyfile.sh
│   ├── certs/generate.sh
│   └── compose/generate.sh
├── tests/
│   └── contract/
│       ├── test-contract.sh    # Contract test suite
│       └── fixtures/           # Test payloads
└── docs/
```

## Testing

### Contract tests

The primary test suite validates the `--options` and `--bootstrap` contract:

```bash
bash tests/contract/test-contract.sh
```

This runs fast (no Docker needed for most tests). It validates:
- `--options` returns valid JSON matching the manifest
- `--bootstrap` validates payloads correctly (required fields, dependencies, conflicts, port collisions)
- Generation produces the expected output files

Run this after any change to `devstack.sh` or `contract/manifest.json`.

### Testing a template change

Template changes need a full bootstrap + inspection:

```bash
# Bootstrap a project with the changed template
./devstack.sh --bootstrap '{"project":"test-go","selections":{"app":{"go":{}}}}'

# Inspect the output
ls test-go/services/
cat test-go/docker-compose.yml
cat test-go/project.env

# Start it
cd test-go/ && ./devstack.sh start

# Verify
./devstack.sh status
curl http://localhost:8080/

# Clean up
./devstack.sh stop --clean
cd .. && rm -rf test-go/
```

### Testing assembly logic

To test changes to `generate_from_bootstrap()`:

```bash
# Test with different selection combinations
./devstack.sh --bootstrap '{"project":"t1","selections":{"app":{"go":{}},"database":{"postgres":{}},"services":{"redis":{}}}}'
./devstack.sh --bootstrap '{"project":"t2","selections":{"app":{"python-fastapi":{}},"frontend":{"vite":{}},"database":{"mariadb":{}}}}'

# Inspect outputs
diff <(cat t1/project.env) <(cat t2/project.env)
diff <(cat t1/docker-compose.yml) <(cat t2/docker-compose.yml)

# Clean up
rm -rf t1/ t2/
```

### Test fixtures

Contract test fixtures live in `tests/contract/fixtures/`. Each fixture is a JSON file representing a `--bootstrap` payload for a specific scenario:

- `port-conflict-*.json` -- port collision detection
- `valid-with-frontend*.json` -- frontend configuration
- `valid-with-observability.json` -- observability stack
- `conflict-payload.json` -- conflict detection
- `missing-wildcard-dep*.json` -- wildcard dependency resolution

To add a new fixture:

1. Create a JSON file in `tests/contract/fixtures/`
2. Add corresponding assertions in `test-contract.sh`
3. Run the tests: `bash tests/contract/test-contract.sh`

## Common development tasks

### Adding a new service to the catalog

See [ADDING_SERVICES.md](ADDING_SERVICES.md).

### Creating a new app template

See [CREATING_TEMPLATES.md](CREATING_TEMPLATES.md).

### Modifying the factory CLI

1. Edit `devstack.sh`
2. Update the `case` statement in `main()` if adding a command
3. Update help text
4. Run `bash tests/contract/test-contract.sh`
5. Bootstrap a test project to verify

### Modifying the product runtime

1. Edit `product/devstack.sh`
2. Bootstrap a test project to get a fresh copy
3. Test the change in the bootstrapped project
4. Do NOT test by editing a previously bootstrapped product directly

### Changing the manifest

1. Edit `contract/manifest.json`
2. If adding items: create the corresponding template in `templates/`
3. If adding wiring rules: verify the rule fires correctly by bootstrapping a project with the co-selected items and checking `project.env`
4. Run `bash tests/contract/test-contract.sh`

## Key functions in devstack.sh

| Function | Purpose |
|----------|---------|
| `cmd_init()` | Interactive wizard -- walks user through categories |
| `cmd_options()` | Returns manifest as JSON for PowerHouse |
| `cmd_bootstrap()` | Validates payload, calls `generate_from_bootstrap()` |
| `validate_bootstrap()` | 11-check validation pipeline |
| `resolve_wiring()` | Evaluates wiring rules against selections |
| `generate_from_bootstrap()` | Core assembly -- copies templates, writes config, assembles compose |

## Variable substitution

Templates use `${VAR}` for Docker Compose native interpolation. Variables resolve from `project.env` (symlinked as `.env`) at runtime.

Do NOT use:
- sed substitution
- envsubst
- Any build-time variable replacement

Exception: port variables in extras templates (like `${NATS_PORT}`) are written to `project.env` at assembly time, then resolved by Compose at runtime.

## Debugging

### Inspect assembly output

```bash
./devstack.sh --bootstrap '...'
cat test/docker-compose.yml     # See include directives
ls test/services/               # See which templates were copied
cat test/project.env            # See all configuration
```

### Validate compose syntax

```bash
cd test/ && docker compose config --quiet
```

### Check wiring resolution

```bash
grep "Auto-wiring" test/project.env
```
