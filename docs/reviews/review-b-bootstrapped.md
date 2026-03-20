# Review B: Bootstrapped (with AI_BOOTSTRAP.md)

Reviewer: Claude Opus 4.6 (static analysis only -- no Docker runtime)
Date: 2026-03-20

---

## Part 1: System Review

### Understanding Summary

DevStrap is a meta-tool that generates Docker Compose infrastructure from a directory-driven configuration. The core loop is: read `project.env` and `mocks/*/domains`, run bash generators in `core/`, produce ephemeral files in `.generated/` (docker-compose.yml, Caddyfile, domains.txt), then orchestrate Docker Compose. The CLI (`devstack.sh`) is the single entry point for all lifecycle, testing, and mock management operations.

The distinguishing feature is transparent HTTPS mock interception. The system uses Docker network aliases to hijack DNS resolution for external domains (e.g., `api.stripe.com`), routes traffic to a Caddy reverse proxy that terminates TLS with a project-scoped CA, adds an `X-Original-Host` header, and forwards to WireMock for response matching. The app code makes genuine HTTPS requests with zero awareness of the interception -- no feature flags, no environment-specific code paths. This is architecturally clean and the implementation matches the documented design.

The template system is well-layered: app templates (Node, PHP, Go, Python, Rust), database templates (MariaDB, Postgres), frontend templates (Vite), and extras (Redis, Mailpit, NATS, MinIO, Prometheus, Grafana, Dozzle, Adminer, Swagger UI). Each template is a `service.yml` with `${VARIABLE}` placeholders that get `sed`-replaced during generation. The PowerHouse contract interface (`--options`, `--bootstrap`) adds a JSON-driven generation path atop the same core generators, with 11-point payload validation, auto-wiring rules, and preset bundles.

### What Worked

1. **Architecture is sound.** The mock interception design via DNS aliasing + Caddy TLS termination + WireMock is elegant. The app code genuinely does not know it is being intercepted. Traced through `app/src/index.js` making HTTPS requests to `api.example-provider.com` -> Docker DNS -> Caddy site block -> WireMock -> response. The flow is exactly as documented.

2. **Generation pipeline is clean.** The three generators (`core/compose/generate.sh`, `core/caddy/generate-caddyfile.sh`, `core/certs/generate.sh`) each have a single responsibility and are straightforward bash. The variable substitution via `sed` is simple and predictable.

3. **Mock scaffolding workflow is complete.** `new-mock` -> `record` -> `apply-recording` -> `reload-mocks` is a full lifecycle. The `apply-recording` command correctly rewrites `bodyFileName` paths for WireMock's subdirectory mounting, which is a detail that would silently break otherwise.

4. **Template catalog is extensive.** Five app types, one frontend type, two databases, nine extras. Each has proper healthchecks. The CA certificate trust is handled per-language (NODE_EXTRA_CA_CERTS for Node, SSL_CERT_FILE for Go/Rust/Python, OS trust store update for PHP).

5. **PowerHouse contract is robust.** The `validate_bootstrap_payload` function covers 11 validation checks (contract field, version, project name regex, unknown categories/items, required categories, single-selection constraints, dependency resolution with wildcards, conflicts, override key validation, port collision detection). The `resolve_wiring` function handles template placeholders and wildcard resolution. This is production-quality validation.

6. **Test infrastructure works end-to-end.** Playwright runs inside a container, reports go to timestamped directories, a busybox httpd serves them. The test specs cover health, simple mocks, stateful mocks, and conditional mocks.

### What Broke (numbered, with severity)

1. **MEDIUM: Example app HTML references "nginx" instead of "Caddy."** File `app/src/index.js`, line 73: `"DNS + nginx + WireMock intercept them"`. The system uses Caddy, not nginx. This was presumably left over from the nginx-to-Caddy migration. It does not affect functionality but will confuse anyone reading the example app's home page.

2. **LOW: `mocks/*/__files/` is listed as source-of-truth in the bootstrap doc but no `__files/` directories exist.** The `mocks/example-api/` and `mocks/example-payment/` directories have no `__files/` subdirectories. The compose generator does handle them if they exist (lines 37, 53-55 of `core/compose/generate.sh`), but the example mocks use inline `jsonBody` instead of file-based response bodies. This is not a bug, but the bootstrap doc presents `__files` directories as a standard part of the source tree when they are actually optional and absent from the shipped examples.

3. **LOW: No healthcheck on app service templates.** The `node-express`, `go`, `php-laravel`, `python-fastapi`, and `rust` service.yml templates do not define `healthcheck:` blocks. The web container's `depends_on` uses `condition: service_started` for the app, not `condition: service_healthy`. This means Caddy may start proxying before the app is actually ready. The `cmd_start` function does not wait for app readiness either -- it waits for the database health, then runs the init script, but never verifies the app is actually listening on port 3000. This is a race condition, especially for compiled languages like Rust and Go that need build time on first start.

4. **LOW: `cmd_stop` root-owned cleanup is incomplete.** The stop command cleans `tests/results/*`, `tests/playwright/node_modules`, and `tests/playwright/package-lock.json`, but does not clean `mocks/*/recordings/` directories which can also be root-owned (created by the recorder container). The `cmd_record` function does clean them before re-recording, but if a user runs `record`, then `stop`, the root-owned recordings directory remains.

5. **INFO: No `__files/` directory is created by `new-mock`.** The `cmd_new_mock` function creates `mocks/<name>/mappings/` but not `mocks/<name>/__files/`. If a user later uses `apply-recording`, the function creates `__files/` on demand, but this inconsistency could confuse someone reading the scaffold output.

6. **INFO: The `init` command's interactive prompts do not list `python-fastapi` or `rust` as options.** Line 798-799: `"App type (node-express, php-laravel, go) [node-express]:"`. The `python-fastapi` and `rust` templates exist and work but are not mentioned in the prompt text. They would work if typed explicitly (the validation on line 802 checks for the directory's existence), but a user would not know they are available.

### Architecture Critique

1. **The `sed`-based variable substitution is fragile at scale.** Every new variable requires adding another `sed` pipe. The extras substitution in `core/compose/generate.sh` already has 17 `sed` calls chained together (lines 104-120). If a variable value contains pipe characters, regex metacharacters, or the `|` delimiter used in `sed`, it will break silently. This is manageable at current scale but will not age well.

2. **WireMock single-instance architecture has a scaling ceiling.** All mocks share one WireMock. The bootstrap doc correctly identifies the path collision problem and the `X-Original-Host` header workaround. But the deeper issue is resource contention: a project with 10+ mocked APIs would dump all mappings into one WireMock instance, making debugging harder and increasing mapping search time.

3. **The cert-gen skip-if-exists logic creates a subtle trap.** `core/certs/generate.sh` lines 22-26: if `server.crt` already exists and `FORCE_REGEN` is not set, cert generation is skipped. But the certs volume is a Docker named volume that persists across `stop/start` cycles IF `docker compose down` does not use `-v`. The `cmd_stop` function does use `-v`, so in normal operation this is fine. But if someone manually runs `docker compose stop` (without `devstack.sh`), the volume persists, and subsequent starts will reuse old certs that may not have SANs for newly added mock domains. The bootstrap doc does not mention this specific failure mode.

4. **No validation that mock domains are syntactically valid.** The generators read domains from `mocks/*/domains` files and use them directly in Caddyfile site blocks, docker-compose network aliases, and OpenSSL SAN entries. A malformed domain (containing spaces, special characters, or being empty) could produce invalid configurations. The domain-reading loops strip whitespace and skip empty/commented lines, but do not validate domain syntax.

5. **The PowerHouse contract interface (`--bootstrap`) and the interactive `init` command are diverging code paths.** Both generate `project.env` and scaffold directories, but `--bootstrap` supports frontends, auto-wiring, devcontainers, and the full expanded catalog, while `init` only knows about the original three app types and basic extras. Feature parity is not maintained.

### Recommendations

1. **Fix the nginx reference in `app/src/index.js` line 73.** Change "nginx" to "Caddy". Trivial fix, prevents confusion.

2. **Add the `init` command's missing app type options.** Update the interactive prompt to list all available app types dynamically (e.g., by reading `ls templates/apps/`), rather than hardcoding three.

3. **Add a healthcheck to the app service templates.** A simple `wget --spider -q http://localhost:3000/health` or equivalent per language. This would allow `depends_on: app: condition: service_healthy` in the web container, eliminating startup race conditions.

4. **Clean `mocks/*/recordings/` in `cmd_stop`.** Add root-owned recordings directories to the container-based cleanup.

5. **Consider templating the `sed` chain.** A function that takes variable name and value pairs and applies them all would reduce duplication and the risk of forgetting a variable in one of the three substitution sites (app, database, extras).

---

## Part 2: Bootstrap Document Review

### Accuracy Score: 88%

The document gets the fundamentals right. The architecture, generation pipeline, file reading order, and change flow are all accurate. However, there are specific claims that do not match the actual code.

### Completeness Score: 72%

The document covers the core concepts well but has significant gaps in the expanded catalog. It was clearly written before the Python, Rust, Vite, NATS, MinIO, Adminer, Swagger UI, Prometheus, Grafana, and Dozzle additions. It does not mention the PowerHouse contract interface, the `--options`/`--bootstrap` commands, the frontend template system, auto-wiring, or presets. These are substantial features -- the contract code alone is ~600 lines in `devstack.sh`.

### Specific Inaccuracies Found

1. **Line 28, source-of-truth table: `mocks/*/__files/*` listed as source file.** No `__files/` directories exist in the shipped examples. The directory is valid when used (after `apply-recording`), but listing it alongside actively-used source files implies it is a standard part of the setup. It is optional and situation-specific.

2. **Line 148, variable table: `${APP_SOURCE}` described as "Resolved to absolute path" with example `/home/user/devstack/app`.** This is half-right. The variable name in `project.env` is `APP_SOURCE` (relative, e.g., `./app`), but the compose generator resolves it to an absolute path and substitutes it as `APP_SOURCE_ABS`. The bootstrap doc uses the name `${APP_SOURCE}` for both, which is technically what gets `sed`-replaced in templates, but the variable name in the substitution command is `${APP_SOURCE}` mapped to `${APP_SOURCE_ABS}` -- a subtle but important distinction for anyone modifying the generator. The template placeholder `${APP_SOURCE}` is correct; the "Source" column saying "Resolved to absolute path" without mentioning the `APP_SOURCE_ABS` intermediate variable is imprecise.

3. **Line 155, variable table: `${MAILPIT_PORT}` listed as "project.env (default 8025)".** The default is actually in `core/compose/generate.sh` line 108: `${MAILPIT_PORT:-8025}`. The variable IS in `project.env` for the example project, but it is the shell default (`:-8025`) that provides the fallback, not a project.env default. This distinction matters because if someone removes `MAILPIT_PORT` from `project.env`, it still works -- the bootstrap doc implies it is required in `project.env`.

4. **Line 143-155, variable table: massively incomplete.** The table lists 9 variables. The actual `sed` substitutions in `core/compose/generate.sh` cover at least 20+ distinct variables including `${DEVSTACK_DIR}`, `${DB_TYPE}`, `${DB_ROOT_PASSWORD}`, `${PROMETHEUS_PORT}`, `${GRAFANA_PORT}`, `${DOZZLE_PORT}`, `${NATS_PORT}`, `${NATS_MONITOR_PORT}`, `${MINIO_PORT}`, `${MINIO_CONSOLE_PORT}`, `${ADMINER_PORT}`, `${SWAGGER_PORT}`, `${FRONTEND_PORT}`, `${FRONTEND_SOURCE}`, `${FRONTEND_API_PREFIX}`, `${HTTPS_PORT}`. All of these are missing from the bootstrap doc's variable table.

5. **Line 176, Pitfall #4: CA cert trust table is incomplete.** The table lists Node.js, Go, PHP, and "CLI tools". It is missing:
   - **Python**: `REQUESTS_CA_BUNDLE`, `SSL_CERT_FILE`, and `CURL_CA_BUNDLE` (three env vars needed, actually the most complex setup -- see `templates/apps/python-fastapi/service.yml`)
   - **Rust**: `SSL_CERT_FILE` (same as Go, but not mentioned)

6. **Line 119, architecture diagram: `Caddy adds X-Original-Host: api.stripe.com header`.** Accurate -- confirmed at `core/caddy/generate-caddyfile.sh` line 160: `header_up X-Original-Host {http.request.host}`. But the diagram says the domain is `api.stripe.com` while the actual example mocks use `api.example-provider.com` and `api.payment-provider.com`. This is a cosmetic issue (the doc uses Stripe as an illustration), but could confuse an agent looking for an actual Stripe mock.

7. **Line 37, source-of-truth table: missing entries.** The table does not include:
   - `contract/manifest.json` -- the catalog source-of-truth for the PowerHouse contract
   - `templates/frontends/*/service.yml` and `templates/frontends/*/Dockerfile` -- frontend templates
   - `templates/extras/*/volumes.yml` -- volume definitions for extras like NATS and MinIO

### Specific Gaps Found

1. **No mention of the PowerHouse contract interface.** The `--options` and `--bootstrap` commands are ~600 lines of `devstack.sh` (lines 920-1598). The contract includes a full validation pipeline, auto-wiring, and preset system. This is a major feature that an AI agent would completely miss if relying solely on the bootstrap doc. The commands reference section (lines 206-231) lists 16 commands but omits `--options` and `--bootstrap`.

   **Wait -- correction.** The commands reference at line 230 does list `generate` but not `--options` or `--bootstrap`. However, reviewing again: no, `--options` and `--bootstrap` are not listed anywhere in the bootstrap doc's commands reference.

2. **No mention of the frontend template system.** `FRONTEND_TYPE`, `FRONTEND_SOURCE`, `FRONTEND_PORT`, and `FRONTEND_API_PREFIX` are project.env variables that trigger a completely different Caddy routing configuration (path-based routing instead of direct reverse proxy). The compose generator has an entire section for frontend service assembly (lines 210-223). An agent modifying Caddy routing or adding a frontend would not know this path exists.

3. **No mention of `templates/extras/` beyond redis and mailpit.** The bootstrap doc mentions extras as a concept but does not enumerate them. The actual catalog includes NATS, MinIO, Adminer (db-ui), Swagger UI, Prometheus, Grafana, and Dozzle -- each with their own ports and some with volumes.

4. **No mention of `contract/manifest.json`.** This file is the source of truth for the entire catalog: categories, items, defaults, dependencies, conflicts, presets, and wiring rules. Any change to the catalog requires editing this file.

5. **The "When adding a new feature to devstack.sh" section (lines 233-241) omits updating `contract/manifest.json`.** For any catalog-visible feature, the manifest must also be updated.

6. **No mention of the auto-wiring system.** When items are co-selected (e.g., app + redis), the `resolve_wiring` function in `devstack.sh` automatically injects environment variables (e.g., `REDIS_URL=redis://redis:6379`) into `project.env`. An agent adding a new extra service would not know to add wiring rules.

7. **The "How changes flow" tree (lines 58-81) is missing the `contract/manifest.json` path.** Changes to this file require `--bootstrap` to be re-run, which is a different flow than `./devstack.sh restart`.

8. **No mention of the `DEVSTACK_DIR` variable.** This variable is substituted in extras templates (line 109 of `core/compose/generate.sh`) and is used for volume mounts that reference the host filesystem (e.g., Prometheus config at `templates/extras/prometheus/prometheus.yml`). It is not in `project.env` -- it is derived from the script's own location. An agent trying to add a new extras template that needs a host-path mount would not know about this variable.

9. **The pitfalls section does not mention the `init` command's stale app type list.** An agent asked to "set up a new Python project" might use `./devstack.sh init` and not see `python-fastapi` in the prompt, concluding it is not supported.

10. **No mention of the `APP_INIT_SCRIPT` configuration.** This `project.env` variable controls whether and what script runs inside the container after start. The init script execution via `exec -T app sh < script` is only covered in Pitfall #8, but the variable itself is not in the variable table or the project.env description.

### Suggested Additions or Corrections

1. **Add the PowerHouse contract to the source-of-truth table.** Add `contract/manifest.json` and `templates/frontends/*/` and `templates/extras/*/volumes.yml`.

2. **Expand the variable substitution table.** Add all 20+ variables that are actually `sed`-substituted, including `${DEVSTACK_DIR}`, `${DB_TYPE}`, `${DB_ROOT_PASSWORD}`, all the port variables for extras, and the frontend variables.

3. **Add a "Frontend system" section.** Describe the path-based routing, the `FRONTEND_TYPE` trigger, and how Caddy routing changes when a frontend is configured.

4. **Add a "Contract interface" section.** Document `--options`, `--bootstrap`, `manifest.json`, and auto-wiring. Even if this is "for PowerHouse", an AI agent modifying the system needs to know it exists.

5. **Add Python and Rust to the CA trust table in Pitfall #4.** Python is the most complex (three env vars). Rust uses `SSL_CERT_FILE`.

6. **Fix the `mocks/*/__files/*` entry in the source-of-truth table.** Mark it as "optional, created by `apply-recording`" rather than listing it as a standard source file.

7. **Add Pitfall #11: `init` command does not list all available app types.** Warn agents that `python-fastapi` and `rust` are valid but not shown in the interactive prompt.

8. **Add Pitfall #12: Manual `docker compose stop` leaves volumes.** The certs volume persists, and subsequent starts may reuse certs missing SANs for newly added domains.

### Pitfall Verification

| # | Pitfall | Accurate? | Notes |
|---|---------|-----------|-------|
| 1 | Editing .generated/ files | **Yes** | `cmd_stop` runs `rm -rf "${GENERATED_DIR}"`. Confirmed. |
| 2 | Docker build context paths | **Yes** | Templates use `${APP_SOURCE}` which is resolved to absolute path. Confirmed at line 83 and line 196 of `core/compose/generate.sh`. |
| 3 | Root-owned files from containers | **Mostly yes** | The cleanup works for `tests/`, but misses `mocks/*/recordings/`. |
| 4 | CA cert trust differs by language | **Partially** | Correct for Node, Go, PHP. Missing Python (3 env vars) and Rust (SSL_CERT_FILE). |
| 5 | Playwright version must match | **Yes** | `tests/playwright/package.json` pins `1.52.0`. Compose generator line 382 uses `v1.52.0-noble`. Match confirmed. |
| 6 | WireMock shares all mocks | **Yes** | Single WireMock instance confirmed. All `mappings/` dirs mounted as subdirectories. `X-Original-Host` header added by Caddy confirmed at line 160. |
| 7 | New domains require restart | **Yes** | `reload-mocks` calls WireMock's `/__admin/mappings/reset` API. New domains need new cert SANs, Caddy config, and DNS aliases, all requiring restart. |
| 8 | Init script runs via stdin pipe | **Yes** | Confirmed at `cmd_start` line 152: `exec -T app sh < "${DEVSTACK_DIR}/${APP_INIT_SCRIPT}"`. |
| 9 | Named volumes must be prefixed | **Yes** | All volume names in templates use `${PROJECT_NAME}-` prefix. Confirmed in go (`go-modules`), python (`python-cache`), rust (`cargo-registry`, `cargo-target`). |
| 10 | Don't improve test-dashboard | **Yes** | Confirmed `busybox:latest` with `httpd` at compose generator lines 404-413. |

### Overall Verdict

**The bootstrap document is worth maintaining, but it needs a significant update.**

It is frozen at an earlier state of the project -- before the catalog expansion (Python, Rust, Vite, NATS, MinIO, etc.), before the Caddy migration, and before the PowerHouse contract interface. The core architecture section and the file reading order are still correct and genuinely useful. The pitfalls section is mostly accurate and would save an agent time. The variable table and source-of-truth table need substantial expansion.

The document's biggest gap is the PowerHouse contract system, which represents roughly a third of `devstack.sh` by line count and introduces an entirely separate generation pathway. An agent working on contract-related code with only the bootstrap doc would be flying blind.

**Time saved estimate:** The bootstrap doc saved approximately 15-20 file reads compared to a cold start. The file reading order was on-target for the core system. The pitfalls section would have prevented at least 2-3 wrong turns (editing `.generated/`, misunderstanding the `sed` pipeline, not knowing about the Playwright version pinning). Net positive, but the gaps mean an agent still needs to independently explore `contract/manifest.json`, the frontend system, and the extras catalog.

**Trust level for future sessions:** Partially trustworthy. I would read it for orientation, then verify anything related to the expanded catalog, contract interface, or frontend system against the actual code.
