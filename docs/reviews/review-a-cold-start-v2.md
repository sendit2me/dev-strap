# Review A: Cold Start (v2) -- Code Review Without Bootstrap Document

**Reviewer**: Claude Opus 4.6 (1M context), cold start
**Date**: 2026-03-21
**Method**: Static code analysis only. Started from `devstack.sh`, explored outward. Did not read `CLAUDE.md` or `docs/AI_BOOTSTRAP.md`.
**Lines read**: ~4,500 lines of shell, ~500 lines of YAML templates, ~200 lines of JS, ~250 lines of JSON config, plus Playwright specs and docs.

---

## Understanding Summary

**What this system does.** DevStrap is a code generator that produces Docker Compose-based development environments with transparent HTTPS mock interception. The core trick: Docker network aliases resolve mocked domain names (e.g., `api.stripe.com`) to a Caddy reverse proxy, which terminates TLS with a locally-generated CA certificate and forwards requests to WireMock. The app makes real HTTPS calls to external APIs; infrastructure intercepts them, not application code. This eliminates `if (isDev)` conditional paths.

**Two systems, one repo.** The repository contains two distinct systems tangled together. The "factory" (`devstack.sh` at root, 2101 lines) reads `project.env`, runs generators in `core/`, and assembles everything into `.generated/`. The "product" (`product/devstack.sh`, 1009 lines) is what gets copied into a bootstrapped project -- it uses Docker Compose `include:` with per-service YAML files under `services/`, generates Caddyfile and WireMock definitions at runtime, and has a different `stop` semantic (non-destructive by default, `--clean` for full teardown). The factory's `init` command creates a product directory, copies templates, writes `project.env`, and assembles `docker-compose.yml` with includes. The factory can also run directly (Workflow B in the review prompt) using its own generators, which produce a monolithic compose file.

**Mock interception flow.** The `mocks/` directory is the source of truth. Each subdirectory has a `domains` file (one hostname per line) and a `mappings/` directory (WireMock JSON stubs). Generators read all `mocks/*/domains` to: (1) add DNS aliases to the Caddy container in Docker Compose, (2) add domain site blocks in the Caddyfile that reverse-proxy to WireMock on port 8080, and (3) feed domains to `certs/generate.sh` which creates a CA and server cert with SANs covering all mocked domains. The app container trusts the CA via `NODE_EXTRA_CA_CERTS` (Node.js), `SSL_CERT_FILE` (Go, Python, Rust), or system CA store (PHP). WireMock receives plain HTTP from Caddy and matches against its mappings.

---

## What Worked (Static Analysis)

Since I cannot run Docker containers, I trace through the code to predict what would happen.

| # | Test | Predicted Result | Notes |
|---|------|------------------|-------|
| 1 | `./devstack.sh start` (Workflow B, factory mode) | **PASS** | Calls `cmd_generate` then `docker compose up`. Generators read `project.env` and `mocks/*/domains`. The compose file is monolithic, assembled in `.generated/`. |
| 2 | Health endpoint `/health` | **PASS** | Express app serves `{ status: "ok", timestamp: "..." }` on port 3000; Caddy proxies from 8080/8443. |
| 3 | Simple mock GET `/api/items` | **PASS** | App calls `api.example-provider.com:443/v1/items` -> DNS alias -> Caddy -> WireMock -> `simple-get.json` returns items. |
| 4 | Stateful mock POST `/api/checkout` + 2x GET `/api/checkout/status` | **PASS** | WireMock scenario "payment-checkout-flow" transitions Started->Pending->Processing->Started. Tests expect pending, processing, complete. Mapping 03 resets to "Started" for idempotent test runs. |
| 5 | Conditional mock `/api/charge` | **PASS** | Priority 1 mapping matches amounts >= 10000 (regex `[1-9][0-9]{4,}`), priority 5 is the fallback. |
| 6 | `./devstack.sh test` | **PASS** (6 tests) | Playwright runs inside `tester` container against `https://web:443`. Tests check `intercepted: true`, mock data, state transitions. |
| 7 | `./devstack.sh mocks` | **PASS** | Iterates `mocks/*/`, reads domains and mapping names. |
| 8 | `./devstack.sh new-mock stripe api.stripe.com` | **PASS** | Creates directory, domains file, example mapping. |
| 9 | `./devstack.sh reload-mocks` | **PASS** | POSTs to WireMock `/__admin/mappings/reset`, reports count. |
| 10 | `./devstack.sh generate` | **PASS** | Writes Caddyfile, docker-compose.yml, domains.txt to `.generated/`. |
| 11 | `./devstack.sh init --preset api-only` | **PROBABLY PASS** | Manifest lookup, category walking, generate_from_bootstrap. Requires `jq`. Scaffolds product directory with services/*.yml files. |
| 12 | `./devstack.sh verify-mocks` | **PASS** | Runs wget from inside app container to each mocked domain on HTTPS, checks for HTTP response. Treats 404 from WireMock as success (route works, just no mapping for `/`). |
| 13 | `./devstack.sh --options` | **PASS** | Pretty-prints `contract/manifest.json`. |
| 14 | Contract tests (`test-contract.sh`) | **MOSTLY PASS** | Comprehensive validation of payload checks 1-11. Tests run against devstack.sh directly. |

---

## What Broke (Bugs, Issues, Confusing Behavior)

### Critical

**1. Hardcoded `devstack-*` names in templates break non-default project names.**
Severity: **CRITICAL**
All service templates use hardcoded volume and network names: `devstack-internal`, `devstack-certs`, `devstack-db-data`, `devstack-go-modules`, etc. The factory compose generator (`core/compose/generate.sh`) performs `sed` replacement for `${PROJECT_NAME}` but does NOT replace `devstack-internal` or `devstack-certs`. These appear literally in the template YAML.

In the factory workflow, this does not break because the generator inlines the app service template into a monolithic compose file and writes the network section with `${PROJECT_NAME}-internal`. Docker Compose resolves volume/network references at the project level, and since the templates declare volumes like `devstack-certs:` and the generator also declares `${PROJECT_NAME}-certs:`, there is actually a name mismatch -- the templates reference `devstack-certs` but the generated compose declares `${PROJECT_NAME}-certs`.

However, this works when `PROJECT_NAME=myproject` because Docker Compose prefixes volume names with the project name. But the templates' volume declarations at the bottom (e.g., `volumes:\n  devstack-certs:`) are embedded in the service template snippet that gets cat'd into the monolithic file. The generator writes its own volume section (line 435: `${PROJECT_NAME}-certs:`) which is a different name from `devstack-certs:`. This creates orphaned volume references.

In the product workflow (bootstrapped projects), the templates use Docker Compose `include:`, and each service file declares its own volumes. Here, `devstack-internal` and `devstack-certs` are literal names that match the network/volume names in `docker-compose.yml`. The product compose file declares `networks: devstack-internal:` (line 1829 of `devstack.sh`). So the product pathway actually works correctly with these hardcoded names -- but only because the network is always called `devstack-internal` regardless of `PROJECT_NAME`.

The root problem: the factory and product use different naming conventions. Factory uses `${PROJECT_NAME}-*`, product uses `devstack-*`. This creates confusion and makes the factory pathway fragile.

**2. `${DB_CONNECTION}` is never substituted in the PHP-Laravel template.**
Severity: **CRITICAL (PHP-Laravel users)**
File: `templates/apps/php-laravel/service.yml`, line 14: `DB_CONNECTION=${DB_CONNECTION}`
The factory compose generator's sed pipeline (lines 195-202 of `core/compose/generate.sh`) replaces `PROJECT_NAME`, `APP_SOURCE`, `DB_TYPE`, `DB_PORT`, `DB_NAME`, `DB_USER`, `DB_PASSWORD`, `DB_ROOT_PASSWORD` -- but NOT `DB_CONNECTION`. The literal string `${DB_CONNECTION}` will appear in the generated compose file's environment section.

Docker Compose will try to resolve this from the host environment, where it is almost certainly unset, resulting in an empty string. Laravel needs this set to `mysql` or `pgsql` to connect to the database. A PHP-Laravel project bootstrapped via the factory workflow will have a broken database connection.

The product pathway handles this differently: it writes a `services/database.env` file with `DB_CONNECTION=mysql|pgsql` (line 1736 of `devstack.sh`), but the app service template itself still references `${DB_CONNECTION}` directly in its environment block, and it is unclear if this env file is made available to the app service.

### High

**3. Prometheus and Grafana templates have broken volume paths in bootstrapped products.**
Severity: **HIGH**
File: `templates/extras/prometheus/service.yml`, line 8: `./templates/extras/prometheus/prometheus.yml:/etc/prometheus/prometheus.yml:ro`
File: `templates/extras/grafana/service.yml`, line 13: `./templates/extras/grafana/provisioning:/etc/grafana/provisioning:ro`

These paths are relative to the repo root and reference the dev-strap source tree structure. In a bootstrapped product, these paths do not exist. The `generate_from_bootstrap` function (lines 1648-1654 of `devstack.sh`) copies `prometheus.yml` to `${dest}/services/prometheus.yml` and `provisioning/` to `${dest}/services/grafana-provisioning/`, but the service templates still reference `./templates/extras/prometheus/prometheus.yml` and `./templates/extras/grafana/provisioning`. These mounts will fail with file-not-found errors.

**4. Factory `stop` is unconditionally destructive -- deletes all volumes.**
Severity: **HIGH**
File: `devstack.sh`, line 210: `down -v --remove-orphans`
The factory's `cmd_stop` always runs `docker compose down -v`, which deletes all volumes including the database. There is no `--clean` flag or non-destructive stop. The product runtime has this distinction (`stop` preserves volumes, `stop --clean` deletes them), but the factory does not. The README says "stop removes everything" as if this is a feature, but it is hostile to iterative development.

The README's commands section and help text both describe `stop` as "clean slate," but the product runtime's `stop` has different semantics (non-destructive by default). A developer who learns the factory `stop` behavior will be surprised when the product `stop` preserves volumes, or vice versa.

**5. Factory `record` uses wrong Docker network name.**
Severity: **HIGH**
File: `devstack.sh`, line 583: `--network "${PROJECT_NAME}_${PROJECT_NAME}-internal"`
File: `product/devstack.sh`, line 781: `--network "${PROJECT_NAME}_devstack-internal"`

The factory `record` command constructs the Docker network name as `${PROJECT_NAME}_${PROJECT_NAME}-internal` (e.g., `myproject_myproject-internal`). This is the Docker Compose default naming: `{project_name}_{network_name}`. Since the factory generates the network as `${PROJECT_NAME}-internal` and uses `-p ${PROJECT_NAME}`, the actual Docker network name would be `myproject_myproject-internal`. This appears correct for the factory.

The product uses `devstack-internal` as the network name, so the Docker network is `${PROJECT_NAME}_devstack-internal`. This is also correct for the product.

However, the naming divergence between factory and product is itself a problem -- copy-pasting commands between contexts will fail silently.

**6. Auto-wiring writes env vars to project.env but app templates do not reference them.**
Severity: **HIGH**
The wiring system resolves rules like `app.*.redis_url -> redis://redis:6379` and writes `REDIS_URL=redis://redis:6379` to `project.env`. But none of the app service templates (node-express, go, python-fastapi, rust, php-laravel) include `REDIS_URL`, `NATS_URL`, or `S3_ENDPOINT` in their environment sections. The wiring produces dead configuration that the app container never sees.

For the product pathway, `project.env` is symlinked as `.env`, and Docker Compose reads `.env` for variable substitution. But the templates need `- REDIS_URL=${REDIS_URL}` in their environment blocks for this to propagate to the container. None do.

### Medium

**7. WireMock mapping subdirectory mounting may cause matching failures.**
Severity: **MEDIUM**
The compose generator mounts mock mappings as subdirectories: `mocks/example-api/mappings -> /home/wiremock/mappings/example-api`. WireMock's default behavior scans `/home/wiremock/mappings/` recursively, so subdirectories work. However, this means ALL mocks share a single WireMock instance with no namespace isolation. If two mocks define the same URL path (e.g., both have `/v1/status`), WireMock will load both mappings and serve whichever has higher priority (or non-deterministically if priorities are equal). There is no warning or detection for this.

**8. `cmd_stop` does not clean `mocks/*/recordings/` directories.**
Severity: **MEDIUM**
File: `devstack.sh`, lines 219-224. The factory `stop` cleans test results and playwright node_modules but not recording directories, which may be root-owned (created by the recorder container). The product `stop --clean` does clean them via `_clean_recordings()`, but the factory lacks this.

**9. `apply-recording` lists only `mapping-*.json` files but WireMock may create different filenames.**
Severity: **MEDIUM**
File: `devstack.sh`, line 693: `for f in "${mock_dir}/mappings"/mapping-*.json`
The listing after apply only looks for files matching the glob `mapping-*.json`. WireMock's recorder names files like `<method>-<url-hash>.json` or `mapping-<sequence>.json` depending on the version. If the filenames don't match the glob, the "Applied N recordings" listing will show nothing even though files were correctly copied.

**10. Empty `domains` file silently produces an empty cert SAN list.**
Severity: **MEDIUM**
If a mock directory exists with a `domains` file that is empty or whitespace-only, the domain collection loop will skip it (the `[ -z "${domain}" ] && continue` guard). This means the mock directory is visible in `./devstack.sh mocks` but produces no DNS alias, no Caddyfile site block, and no cert SAN. The mock is silently non-functional. There is no validation or warning.

**11. Vite frontend healthcheck hardcodes port 5173.**
Severity: **MEDIUM**
File: `templates/frontends/vite/service.yml`, line 21: `test: ["CMD", "wget", "--spider", "-q", "http://localhost:5173/"]`
If the user overrides the frontend port, the healthcheck will fail because it still checks port 5173.

**12. The `simple-post.json` mapping uses `"transformers": ["response-template"]` but WireMock also has `--global-response-templating`.**
Severity: **LOW**
The compose generator passes `--global-response-templating` to WireMock, which enables response templating globally. The `transformers` field in the mapping is therefore redundant (but not harmful). However, if someone copies this pattern thinking `transformers` is required, they'll add unnecessary boilerplate.

### Low

**13. `APP_SOURCE` path handling inconsistency.**
Severity: **LOW**
`project.env` has `APP_SOURCE=./app`. The compose generator resolves this to an absolute path: `APP_SOURCE_ABS="${DEVSTACK_DIR}/${APP_SOURCE#./}"` (line 83). The `#./` strips the leading `./`. But if `APP_SOURCE` does not start with `./` (e.g., `APP_SOURCE=app` or `APP_SOURCE=/absolute/path`), this produces either a correct or doubled path. No validation.

**14. Test results URL assumes test-dashboard is running.**
Severity: **LOW**
After tests run, the output prints URLs like `http://localhost:${TEST_DASHBOARD_PORT}/${run_id}/report/index.html`. If the test-dashboard container is not running (e.g., in a product that did not select `qa-dashboard`), these URLs go nowhere. No conditional check.

**15. The `code-up.sh` and `claude-resume.sh` scripts are in the repo root with no documentation.**
Severity: **LOW**
These are personal/development scripts that should not be in the repository. `code-up.sh` is 80 bytes, `claude-resume.sh` is 52 bytes. They appear to be developer convenience scripts.

---

## Documentation Accuracy

### README.md

| Claim | Accurate? | Details |
|-------|-----------|---------|
| "Only Docker required" | **Yes** | The factory requires `jq` for `init`/`--options`/`--bootstrap`, but the product runtime requires only Docker. |
| "`stop` removes everything" | **Factory: Yes. Product: No.** | Factory `stop` always does `down -v`. Product `stop` preserves volumes. README does not distinguish between these. |
| "`restart` -- Stop and start (clean rebuild)" | **Factory: Yes. Product: No.** | Product `restart` passes flags through to `stop`, so `restart` alone preserves volumes. Only `restart --clean` is destructive. |
| "Auto-wiring... sets REDIS_URL" | **Partially true** | The wiring resolver writes `REDIS_URL` to `project.env`, but no template reads it into the container environment. |
| Architecture diagram shows `[App] --HTTPS--> [Caddy]` | **Slightly misleading** | The app does not send HTTPS to Caddy. The app sends HTTPS to `api.stripe.com:443`, which Docker DNS resolves to the Caddy container's IP. Caddy terminates TLS. The diagram is correct in spirit but the arrow label suggests a direct connection. |
| Ports in catalog tables | **Mostly correct** | Redis 6379 is correct but the service template does not expose it to the host (no `ports:` section). NATS and MinIO do expose ports. |
| "6/6 tests pass" | **Correct** | 4 spec files with 6 tests total (2 health, 1 simple mock, 1 stateful, 2 conditional). |
| QUICKSTART.md: "`./devstack.sh stop` -- Tear down everything" | **Only for factory** | Product `stop` is non-destructive. |

### ARCHITECTURE.md

| Claim | Accurate? | Details |
|-------|-----------|---------|
| Directory structure diagram | **Outdated** | Does not show `product/`, `prototype/`, `templates/common/`, `templates/frontends/`. Missing `contract/`. |
| "Path routing: /api/* -> app, /* -> frontend" | **Conditionally correct** | This routing only exists when `FRONTEND_TYPE` is set. With the default `node-express` app (no frontend), all traffic goes to `app:3000`. |
| System diagram | **Mostly correct** | Does not show the cert-gen -> certs volume -> Caddy/App trust chain clearly. |

### Docs that reference `stop` behavior

Inconsistent across docs. QUICKSTART.md, README.md, and the factory help text all say `stop` is destructive. The product runtime has `stop --clean` for destructive and plain `stop` for non-destructive. This will confuse users who move from the factory workflow to a bootstrapped project.

---

## Architecture Critique

### 1. Two systems pretending to be one

The most significant architectural problem is that the factory and product are intertwined in a single 2101-line shell script. The factory `devstack.sh` contains:
- Generator scripts for the factory workflow (`core/caddy/generate-caddyfile.sh`, `core/compose/generate.sh`)
- The `init` command that scaffolds a product
- The `--bootstrap` contract interface
- All runtime commands (`start`, `stop`, `test`, etc.) that work in factory mode
- Validation, wiring resolution, and project assembly functions

Meanwhile, `product/devstack.sh` (1009 lines) duplicates most of the runtime commands with slightly different behavior (e.g., `stop --clean`, different network naming, compose-include instead of monolithic). Changes to one are not automatically reflected in the other.

### 2. Template variable substitution is fragile

The generator uses a chain of `sed` commands to replace `${VAR}` placeholders in templates. This approach:
- Is not declarative -- you must remember to add a new `sed` line for each new variable
- Fails silently if a variable is missing from the sed chain (the literal `${VAR}` remains)
- Cannot handle complex values (paths with special characters would break the sed)
- Is duplicated: the extras pipeline has its own sed chain separate from the app pipeline, separate from the database pipeline

Using `envsubst` or a proper templating approach would eliminate entire categories of bugs.

### 3. All mocks share a single WireMock instance

Every mock directory's mappings are mounted as subdirectories of a single WireMock's `/home/wiremock/mappings/`. This means:
- No namespace isolation -- URL path conflicts across mocks are silent
- All stateful scenarios share global state
- No way to reset one mock without resetting all
- No per-mock recording or debugging

### 4. The contract manifest describes capabilities that are not wired through

The `manifest.json` has rich metadata -- `requires`, `defaults`, `wiring` rules -- but much of it is cosmetic:
- Wiring rules produce env vars that no template consumes (REDIS_URL, NATS_URL, S3_ENDPOINT)
- `requires` dependencies are validated but not enforced at generation time
- `defaults` include `port` values that the templates sometimes hardcode differently

### 5. No validation of generated output

After the generators run, there is no validation that the produced docker-compose.yml is valid YAML, that all referenced images exist, that volume/network references are consistent, or that port bindings do not conflict with the host. The first feedback the user gets is at `docker compose build` or `docker compose up` time, which produces opaque Docker errors.

### 6. Cert regeneration is expensive and unconditional (factory)

The factory's cert-gen container runs on every `start`. It installs OpenSSL (`apk add --no-cache openssl`), generates a CA and server cert, every time. The product's `certs/generate.sh` has domain-change detection (compares SANs), but the factory's `core/certs/generate.sh` only checks `if [ -f "${CERT_DIR}/server.crt" ]` -- it skips regeneration if certs exist but does NOT check if domains changed. So adding a new mock domain in the factory workflow requires `FORCE_REGEN=1` or deleting the certs volume, neither of which is documented.

Wait -- actually, the factory does `docker compose down -v` on every `stop`, which deletes the certs volume. So next `start` always regenerates. This is correct but wasteful.

### 7. The `prototype/` directory is unexplained

A `prototype/` directory exists with minimal compose, .env, app Dockerfile, mocks, and services. It appears to be a manually constructed example of the product output format, used for development/testing of the include-based compose approach. It is not referenced by any code and has no documentation. It is clutter.

---

## Recommendations (Priority Ordered)

### Fix Now (blocks correctness)

1. **Fix `DB_CONNECTION` substitution for PHP-Laravel.** Add `sed "s|\${DB_CONNECTION}|${db_connection}|g"` to the app template sed pipeline in `core/compose/generate.sh`. Derive `db_connection` from `DB_TYPE` the same way `generate_from_bootstrap` does (lines 1725-1729). This is a one-line fix that prevents a broken-on-first-use experience for PHP users.

2. **Fix Prometheus/Grafana volume paths in templates.** Change the volume mounts from `./templates/extras/prometheus/prometheus.yml` to a path that works in both factory and product contexts. The product `generate_from_bootstrap` copies these files to `services/prometheus.yml` and `services/grafana-provisioning/`, so the templates should reference `./services/prometheus.yml` and `./services/grafana-provisioning/`. For the factory pathway, the generator would need to handle this differently (or use absolute paths).

3. **Wire auto-wired env vars into app templates.** Add environment entries for `REDIS_URL`, `NATS_URL`, `S3_ENDPOINT` to each app template's service.yml, guarded by `${REDIS_URL:-}` syntax so they are harmless when unset.

### Fix Soon (prevents confusion)

4. **Unify `stop` semantics between factory and product.** Either add `--clean` flag to the factory `stop` (making it non-destructive by default like the product), or clearly document the behavioral difference. Currently, a user who learns one workflow will be burned by the other.

5. **Replace sed-chain templating with envsubst.** This eliminates the entire class of "forgot to add a sed for this variable" bugs. Write all template variables to a single env file, then run `envsubst` on each template. This is a medium-effort refactor with high payoff.

6. **Add validation for empty or malformed `domains` files.** In `cmd_generate` (or the domain collection loop), warn if a mock directory's domains file is empty, has no valid entries, or contains whitespace-only lines.

7. **Clean up `mocks/*/recordings/` in factory `cmd_stop`.** Port the `_clean_recordings()` function from the product runtime.

### Fix Eventually

8. **Reduce duplication between factory and product devstack.sh.** The product runtime is a near-copy of the factory's runtime commands with different paths and naming. Consider extracting shared functions into a library file, or generating the product runtime from the factory code.

9. **Add generated output validation.** After assembling docker-compose.yml, run `docker compose config` (dry-run validation) to catch YAML errors, missing images, or volume/network mismatches before attempting to build.

10. **Document the `prototype/` directory or remove it.** It appears to be a development artifact.

11. **Add per-mock URL conflict detection.** When loading mappings from multiple mock directories, check for URL path collisions and warn the user.

### Fine As-Is

- The overall architecture (DNS aliases + Caddy + WireMock) is clever and solves the problem well.
- The contract/manifest system for presets and validation is well-designed and thoroughly tested.
- The Playwright test setup with containerized runner and test-dashboard is solid.
- The mock recording/playback workflow (record -> review -> apply-recording -> reload-mocks) is well thought out.
- The example app effectively demonstrates all three mock patterns (simple, stateful, conditional).
- The domain collection loop correctly handles comments and blank lines.

---

## Confusion Log

Things that confused me during review and took extra investigation:

1. **Why are there two `devstack.sh` files?** The root one is 2101 lines, `product/devstack.sh` is 1009 lines. It took reading `generate_from_bootstrap` to understand that `product/devstack.sh` is copied into bootstrapped projects. This is a significant architectural concept that is nowhere explained in any user-facing doc (only in research docs I was told to ignore).

2. **What is `prototype/`?** Undocumented directory with minimal compose setup. Appears to be a development testbed for the include-based compose approach.

3. **Why do templates use `devstack-*` names instead of `${PROJECT_NAME}-*`?** This initially looked like a critical bug (volume/network names would not match). After tracing through both factory and product pathways, I concluded: in the factory, the sed pipeline replaces `${PROJECT_NAME}` but not `devstack-*`, which means templates' network/volume references are literal `devstack-*` strings in the generated output -- but the compose file's network section declares `${PROJECT_NAME}-internal`. In the product, the compose file declares `devstack-internal` and all templates reference `devstack-internal`, so it works. The names are inconsistent between pathways but each pathway is internally consistent.

4. **`EXTRAS` vs categories in manifest.json.** The `project.env` file has `EXTRAS=redis` (comma-separated list). The manifest has categories: `services`, `tooling`, `observability`. The `generate_from_bootstrap` function merges services + observability + (some) tooling into the `extras` variable. But in the factory workflow (running from `project.env`), only the `EXTRAS` field is used, and there is no mapping from manifest categories to extras. The factory pathway and the contract pathway handle extras differently.

5. **Where does the factory compose generator get its extras sed pipeline?** Lines 100-120 of `core/compose/generate.sh` have a massive sed pipeline for extras that includes every possible port variable (`PROMETHEUS_PORT`, `GRAFANA_PORT`, `DOZZLE_PORT`, `NATS_PORT`, etc.). This is brittle -- adding a new extra requires updating this pipeline. The product pathway avoids this by using Docker Compose `include:` with `project_directory: .` and env_file references.
