# Shim vs Parent Audit — 2026-05-08

Audit of `product/devstack.sh` (shim, 1076 lines) against the parent
`devstack.sh` (2254 lines) and the canonical generators
`core/compose/generate.sh` and `core/caddy/generate-caddyfile.sh`.

## Summary
- Total findings: 13
- Critical (likely runtime breakage): 5
- Notable (subtle bugs / dropped features / drift): 6
- Cosmetic (style / non-functional): 2

The four already-known regressions surfaced by the cycle-3 wire-test are
covered in findings 1–4. Findings 5–13 are new.

## Findings

### Finding 1: WireMock `__files/` mount missing
- **Severity**: critical
- **Files**: shim `product/devstack.sh:374-380`; canonical `core/compose/generate.sh:30,53-56,333`
- **What's different**: The canonical generator builds `WIREMOCK_FILES_VOLUMES` for every `mocks/<name>/__files/` directory and mounts each at `/home/wiremock/__files/<name>` so `bodyFileName` references resolve. The shim's `generate_wiremock_service` only iterates and mounts `mappings/`; `__files/` is never bind-mounted.
- **Impact**: Any mock that ships response bodies as separate files (the path the `apply-recording` command produces — shim line 921 explicitly creates `${mock_dir}/__files`) returns empty/404 because WireMock can't find the body file at request time.
- **Suggested fix**: Mirror the `if [ -d "${mock_dir}__files" ]` branch from `core/compose/generate.sh` lines 53-56 inside `generate_wiremock_service`.

### Finding 2: `set -a` env wrap missing around project.env
- **Severity**: critical
- **Files**: shim `product/devstack.sh:77-83`; parent `devstack.sh:52-59` (also no wrap, but parent runs the canonical generators which do their own sourcing in subshells)
- **What's different**: `load_config()` does a bare `source "${PROJECT_DIR}/project.env"`. Without `set -a` the variables stay shell-local; subsequent `docker compose -p "${PROJECT_NAME}" up` and the inline `cat <<CADDY_SVC` heredocs that contain `\${PROJECT_NAME}`, `\${HTTP_PORT}`, etc. depend on these being in the process environment (compose interpolation) or in the current shell (heredoc expansion).
- **Impact**: Heredoc-emitted YAML with literal `${PROJECT_NAME}` placeholders will be left unexpanded for compose to resolve from `.env`, but compose itself reads `.env` only from the current dir — which works only if the user runs the shim from `${PROJECT_DIR}`. Any indirection (e.g. exec'ing devstack.sh via absolute path) breaks variable interpolation in services.
- **Suggested fix**: Wrap the source in `set -a; source "${PROJECT_DIR}/project.env"; set +a` so every config var is exported.

### Finding 3: Static `app_source` mount (no override) for non-PHP, non-FE branches
- **Severity**: notable
- **Files**: shim `product/devstack.sh:294-307`; canonical `core/compose/generate.sh:83-88,194-202`
- **What's different**: Canonical compose generator computes `APP_SOURCE_ABS` from `${APP_SOURCE}` and substitutes it into the app template, so consumers can point `APP_SOURCE` at any host path. The shim only injects `${APP_SOURCE:-./app}` for `php-laravel` (line 300); the FE and default branches assume the app service definition was pre-baked elsewhere with a hardcoded mount.
- **Impact**: Consumers who set `APP_SOURCE=./backend` (or anything other than the bake-time default) will see code from the wrong path mounted into the app container — unless the static `services/app.yml` file dropped at bootstrap already templated `${APP_SOURCE}` correctly. This leaves the override/bake-time contract implicit.
- **Suggested fix**: Document that `services/app.yml` must use `${APP_SOURCE:-./app}` at compose-interpolation time, or have the shim regenerate it from a template.

### Finding 4: BFF-aware Caddy routing (resolved in shim — verify it stays)
- **Severity**: notable (regression watch)
- **Files**: shim `product/devstack.sh:185-213`; canonical `core/caddy/generate-caddyfile.sh:86-119`
- **What's different**: Both branches now route `${FRONTEND_API_PREFIX:-/api}/*` to `frontend:${FRONTEND_PORT}` when `FRONTEND_BFF=true`, else to `app:3000`. Shim parity with canonical confirmed. **However**: the canonical Caddyfile generator combines `localhost:80, localhost:443, ${PROJECT_NAME}.local:80, ${PROJECT_NAME}.local:443` into one site block (line 100), which Caddy 2 rejects when `auto_https off` is set globally — the shim correctly splits HTTP and HTTPS into separate blocks (lines 195-211).
- **Impact**: The canonical generator at HEAD will crash Caddy at startup with "server listening on [:80] is HTTP, but attempts to configure TLS connection policies." The shim's split is the correct pattern; the canonical needs the same fix.
- **Suggested fix**: Port the shim's HTTP-redir + HTTPS-with-TLS split back into `core/caddy/generate-caddyfile.sh`. This is "parent regression vs shim", inverse of the usual direction.

### Finding 5: Network name mismatch — `devstack-internal` vs `${PROJECT_NAME}-internal`
- **Severity**: critical
- **Files**: shim `product/devstack.sh:339,341,394,856`; canonical `core/compose/generate.sh:250,305,338,398,413,425`
- **What's different**: Canonical generator names the network `${PROJECT_NAME}-internal` everywhere (so it's project-scoped: `${PROJECT_NAME}_${PROJECT_NAME}-internal` after compose mangling). Shim hard-codes the literal string `devstack-internal`. The shim's `cmd_record` then has to compute `--network "${PROJECT_NAME}_devstack-internal"` (line 856) to match.
- **Impact**: If two devstack-managed projects run on the same host, both register `devstack-internal` as their internal network. Compose namespacing (`${PROJECT_NAME}_devstack-internal`) keeps them separate, so this works — but it's a divergence from the canonical naming and any external script (deven harness, eval rig, etc.) that targets `${PROJECT_NAME}-internal` will fail to find the network.
- **Suggested fix**: Pick one. Recommend aligning shim with canonical (`${PROJECT_NAME}-internal`) and updating the static service yamls accordingly.

### Finding 6: `cmd_start` doesn't fail on `docker compose up` failure
- **Severity**: critical
- **Files**: shim `product/devstack.sh:449-450`; parent `devstack.sh:104-114`
- **What's different**: Parent splits build and up into two `docker compose` invocations and checks the build's exit code (`if ! docker compose ... build; then exit 1; fi`). Shim does `docker compose -p "${PROJECT_NAME}" up --build -d` and ignores the exit code (since `set -e` only catches simple commands and this is a single statement that always returns 0 when `up` partially succeeds).
- **Impact**: A failed Dockerfile build still hits the "Waiting for cert-gen" / health-check loops, swallows another 60s of timeouts, and finally prints "DevStack is running" even though no containers came up. False-positive runs ensue.
- **Suggested fix**: Capture the exit code: `if ! docker compose -p "${PROJECT_NAME}" up --build -d; then log_err "Build/start failed"; exit 1; fi`.

### Finding 7: WireMock not in app's `depends_on`
- **Severity**: notable
- **Files**: shim has no central compose; canonical `core/compose/generate.sh:299-313`
- **What's different**: In the canonical compose, the `web` (Caddy) service depends on `cert-gen` + `app` + (conditionally) `db`/`frontend`. Neither parent nor shim makes the web container depend on WireMock when there are mocked domains. But the canonical generator at least co-creates both services in one place; the shim splits caddy (always generated) from wiremock (conditionally generated) — and `caddy.yml` has no `wiremock` in `depends_on`.
- **Impact**: On a cold start, Caddy comes up before WireMock is ready and the first few mock-domain requests get connection-refused / 502 until WireMock's healthcheck passes ~5–15s later. Tests started immediately after `cmd_start` returns will see flaky failures on mock endpoints.
- **Suggested fix**: In `generate_caddy_service`, when `services/wiremock.yml` exists, append `wiremock: { condition: service_healthy }` to `extra_depends`.

### Finding 8: Prism awareness asymmetric
- **Severity**: notable
- **Files**: shim `product/devstack.sh:259-270,309-319`; canonical `core/caddy/generate-caddyfile.sh` has no prism block; canonical `core/compose/generate.sh` has no prism alias either
- **What's different**: The shim adds a `mock.${PROJECT_NAME}.local` Caddy site for Prism and a network alias for it, *if* `services/prism.yml` exists. The canonical generators don't — Prism is bootstrapped via `templates/extras/prism/service.yml` and its routing is whatever that template defines.
- **Impact**: Bootstraps that include Prism via the template will get a working service container but no Caddy frontend or DNS alias — so consumers can only reach Prism by its container name, not via `mock.<project>.local`. Inconsistent UX with the shim's promise.
- **Suggested fix**: Either add the prism site/alias to `core/caddy/generate-caddyfile.sh` and `core/compose/generate.sh`, or document that the prism subdomain is shim-only.

### Finding 9: `cert-gen` and `tester`/`test-dashboard` not generated by shim
- **Severity**: notable
- **Files**: shim `product/devstack.sh:333-337,390-393` (referenced in depends_on); canonical `core/compose/generate.sh:236-251,381-414`
- **What's different**: Both `caddy.yml` and `wiremock.yml` declare `depends_on: cert-gen: condition: service_completed_successfully`, and `cmd_test` (line 590) execs into `tester`. None of these services are generated by the shim — they must be baked into the static `services/` files at bootstrap time.
- **Impact**: Hard implicit contract: if the bootstrap step fails to drop `services/cert-gen.yml`, `services/tester.yml`, or `services/test-dashboard.yml` into the project, the shim's regenerated `caddy.yml` will reference an undefined service and compose will refuse to start with "service 'cert-gen' is undefined." There is no shim-side check.
- **Suggested fix**: Have `cmd_start` validate the presence of `services/cert-gen.yml` (and `tester` if `cmd_test` is going to be reachable) before `docker compose up`, with a clear error pointing back at bootstrap.

### Finding 10: DB health-wait uses `ps --format json | grep` instead of inspect
- **Severity**: notable
- **Files**: shim `product/devstack.sh:457-475`; parent `devstack.sh:122-144`
- **What's different**: Parent gates the DB-wait on `[ "${DB_TYPE}" != "none" ]` (DB_TYPE is required in its env contract). Shim instead pipes `docker compose ps --format json | grep '"Service":"db"'` to detect a DB service. The grep is fragile (newline-delimited JSON vs JSON-array format varies between compose versions; field order in the rendered JSON is also not guaranteed).
- **Impact**: On compose v2.24+ the `ps --format json` output is one JSON object per service per line, which works; but on some CI images and on macOS Docker Desktop the output is a single JSON array, where `grep '"Service":"db"'` may match (since substring) but is order-dependent. False-negatives skip the DB-wait silently and the app starts before the DB is ready.
- **Suggested fix**: Either source `DB_TYPE` from project.env (matching parent), or use `docker compose config --services | grep -qx db`.

### Finding 11: `cmd_test` skips the "is the stack running" pre-check
- **Severity**: notable
- **Files**: shim `product/devstack.sh:571-610`; parent `devstack.sh:233-279`
- **What's different**: Parent checks `[ ! -f "${GENERATED_DIR}/docker-compose.yml" ]` and aborts with "DevStack is not running. Run start first." The shim removed this check (no GENERATED_DIR concept) and goes straight to `docker compose ... exec -T tester`.
- **Impact**: If a user runs `./devstack.sh test` before `start`, compose returns a confusing error like "service 'tester' is not running" with no remediation hint. Same applies to `cmd_logs`, `cmd_status`, `cmd_shell`, `cmd_reload_mocks`, `cmd_verify_mocks`, `cmd_apply_recording`.
- **Suggested fix**: Add a one-line `_require_running()` helper that does `docker compose -p "${PROJECT_NAME}" ps --quiet | grep -q .` and call it at the top of these commands.

### Finding 12: Mock `bodyFileName` apply doesn't validate JSON
- **Severity**: notable
- **Files**: shim `product/devstack.sh:927-943`; parent `devstack.sh:662-689` (same logic)
- **What's different**: Both versions inline a sed rewrite: `sed "s|\"bodyFileName\" *: *\"|\"bodyFileName\" : \"${MOCK_NAME}/|"`. This is regex-based JSON munging and breaks if the recorded JSON has any of: `bodyFileName` already containing a slash, `bodyFileName` on the same line as another key, escaped quotes, or `\"bodyFileName\"` inside a string value.
- **Impact**: Malformed mappings post-apply will cause WireMock to silently skip them (or worse, accept them and 500 on the matching request). Recording-replay flow degrades silently.
- **Suggested fix**: Use `jq` for the rewrite (since it's already a hard dependency of the parent's contract path; the shim could opt-in if jq is present and fall back to sed otherwise).

### Finding 13: Validation accepts negative / out-of-range ports
- **Severity**: cosmetic
- **Files**: shim `product/devstack.sh:97-103`
- **What's different**: `validate_config` only checks `[0-9]+` for HTTP_PORT/HTTPS_PORT. Doesn't check the value is in 1..65535, doesn't check HTTP_PORT != HTTPS_PORT, doesn't validate any of the other port vars (FRONTEND_PORT, TEST_DASHBOARD_PORT, MAILPIT_PORT, etc.) that consumers can set.
- **Impact**: A typo'd `HTTP_PORT=99999` reaches docker, which gives a less-helpful error. Low-impact.
- **Suggested fix**: Tighten the regex and add range check; iterate over a wider set of port vars.

---

## Notes on findings *not* in this audit

- **Identical behavior verified** in: `cmd_mocks` (same listing logic), `cmd_new_mock` (same scaffold template), `cmd_record` (same recorder invocation modulo network name in finding 5), `cmd_verify_mocks` (same probe logic), Caddyfile mock-domain-block format.
- **Parent-only features intentionally absent from shim** (correct shedding, not regressions): `cmd_init`, `cmd_contract_options`, `cmd_contract_bootstrap`, `validate_bootstrap_payload`, `resolve_wiring`, `generate_from_bootstrap`, the manifest-driven walks. These belong to the factory side.
