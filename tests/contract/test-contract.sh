#!/bin/bash
# =============================================================================
# Contract Interface Tests
# =============================================================================
# Tests --options and --bootstrap against the DEVSTRAP-POWERHOUSE-CONTRACT.
# Run from the dev-strap root: bash tests/contract/test-contract.sh
# Requires: jq, Docker (for generation tests only)
# =============================================================================

set -uo pipefail

DEVSTACK_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
FIXTURES="${DEVSTACK_DIR}/tests/contract/fixtures"
PASS=0
FAIL=0
TOTAL=0

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# ── Test helpers ──────────────────────────────────────────────────────────

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    TOTAL=$((TOTAL + 1))
    if [ "${expected}" = "${actual}" ]; then
        printf '  %bPASS%b  %s\n' "${GREEN}" "${NC}" "${desc}"
        PASS=$((PASS + 1))
    else
        printf '  %bFAIL%b  %s\n' "${RED}" "${NC}" "${desc}"
        printf '         expected: %s\n' "${expected}"
        printf '         actual:   %s\n' "${actual}"
        FAIL=$((FAIL + 1))
    fi
}

assert_json() {
    local desc="$1" json="$2" jq_expr="$3"
    TOTAL=$((TOTAL + 1))
    if printf '%s\n' "${json}" | jq -e "${jq_expr}" &>/dev/null; then
        printf '  %bPASS%b  %s\n' "${GREEN}" "${NC}" "${desc}"
        PASS=$((PASS + 1))
    else
        printf '  %bFAIL%b  %s\n' "${RED}" "${NC}" "${desc}"
        printf '         jq expression: %s\n' "${jq_expr}"
        FAIL=$((FAIL + 1))
    fi
}

assert_json_eq() {
    local desc="$1" json="$2" jq_expr="$3" expected="$4"
    TOTAL=$((TOTAL + 1))
    local actual
    actual=$(printf '%s\n' "${json}" | jq -r "${jq_expr}" 2>/dev/null)
    if [ "${expected}" = "${actual}" ]; then
        printf '  %bPASS%b  %s\n' "${GREEN}" "${NC}" "${desc}"
        PASS=$((PASS + 1))
    else
        printf '  %bFAIL%b  %s\n' "${RED}" "${NC}" "${desc}"
        printf '         expected: %s\n' "${expected}"
        printf '         actual:   %s\n' "${actual}"
        FAIL=$((FAIL + 1))
    fi
}

# Run bootstrap, capture stdout (JSON) and exit code. Stderr discarded.
run_bootstrap() {
    "${DEVSTACK_DIR}/devstack.sh" --bootstrap --config "$1" 2>/dev/null
}

run_bootstrap_exit() {
    local code=0
    "${DEVSTACK_DIR}/devstack.sh" --bootstrap --config "$1" >/dev/null 2>/dev/null || code=$?
    printf '%s' "${code}"
}

# ── State management for generation tests ─────────────────────────────────

# Track whether project.env existed before tests
HAD_PROJECT_ENV=false
BACKUP_PROJECT_ENV=""

save_state() {
    if [ -f "${DEVSTACK_DIR}/project.env" ]; then
        HAD_PROJECT_ENV=true
        BACKUP_PROJECT_ENV=$(cat "${DEVSTACK_DIR}/project.env")
    fi
}

restore_state() {
    # Restore project.env
    if [ "${HAD_PROJECT_ENV}" = true ]; then
        printf '%s' "${BACKUP_PROJECT_ENV}" > "${DEVSTACK_DIR}/project.env"
    else
        rm -f "${DEVSTACK_DIR}/project.env"
    fi

    # Clean generated artifacts
    rm -rf "${DEVSTACK_DIR}/.generated"
    rm -rf "${DEVSTACK_DIR}/.devcontainer"
}

# ══════════════════════════════════════════════════════════════════════════
# --options tests
# ══════════════════════════════════════════════════════════════════════════

printf '\nContract Interface Tests\n========================\n\n'
printf '=== --options (DISCOVER) ===\n'

options_output=$("${DEVSTACK_DIR}/devstack.sh" --options 2>/dev/null)

# Schema envelope
assert_json_eq "contract is devstrap-options" "${options_output}" '.contract' "devstrap-options"
assert_json_eq "version is 1"                "${options_output}" '.version'  "1"

# Categories exist
assert_json "has app category"      "${options_output}" '.categories.app'
assert_json "has database category" "${options_output}" '.categories.database'
assert_json "has services category" "${options_output}" '.categories.services'
assert_json "has tooling category"  "${options_output}" '.categories.tooling'

# Category metadata
assert_json_eq "app is single select"     "${options_output}" '.categories.app.selection'      "single"
assert_json_eq "app is required"          "${options_output}" '.categories.app.required'       "true"
assert_json_eq "database is single"       "${options_output}" '.categories.database.selection'  "single"
assert_json_eq "database is optional"     "${options_output}" '.categories.database.required'   "false"
assert_json_eq "services is multi"        "${options_output}" '.categories.services.selection'  "multi"
assert_json_eq "tooling is multi"         "${options_output}" '.categories.tooling.selection'   "multi"

# App items (3 app types matching templates/apps/)
assert_json "has node-express"  "${options_output}" '.categories.app.items["node-express"]'
assert_json "has php-laravel"   "${options_output}" '.categories.app.items["php-laravel"]'
assert_json "has go"            "${options_output}" '.categories.app.items.go'
assert_json_eq "app item count is 5" "${options_output}" '.categories.app.items | keys | length' "5"

# Database items (2 matching templates/databases/)
assert_json "has postgres"  "${options_output}" '.categories.database.items.postgres'
assert_json "has mariadb"   "${options_output}" '.categories.database.items.mariadb'
assert_json_eq "db item count is 2" "${options_output}" '.categories.database.items | keys | length' "2"

# Service items
assert_json "has redis"   "${options_output}" '.categories.services.items.redis'
assert_json "has mailpit" "${options_output}" '.categories.services.items.mailpit'

# Tooling items (4)
assert_json "has qa"           "${options_output}" '.categories.tooling.items.qa'
assert_json "has qa-dashboard" "${options_output}" '.categories.tooling.items["qa-dashboard"]'
assert_json "has wiremock"     "${options_output}" '.categories.tooling.items.wiremock'
assert_json "has devcontainer" "${options_output}" '.categories.tooling.items.devcontainer'

# Defaults
assert_json_eq "node-express port=3000" "${options_output}" '.categories.app.items["node-express"].defaults.port' "3000"
assert_json_eq "php-laravel port=9000"  "${options_output}" '.categories.app.items["php-laravel"].defaults.port'  "9000"
assert_json_eq "go port=3000"           "${options_output}" '.categories.app.items.go.defaults.port'              "3000"
assert_json_eq "postgres port=5432"     "${options_output}" '.categories.database.items.postgres.defaults.port'   "5432"
assert_json_eq "mariadb port=3306"      "${options_output}" '.categories.database.items.mariadb.defaults.port'    "3306"
assert_json_eq "redis port=6379"        "${options_output}" '.categories.services.items.redis.defaults.port'      "6379"
assert_json_eq "mailpit smtp=1025"      "${options_output}" '.categories.services.items.mailpit.defaults.smtp_port' "1025"
assert_json_eq "mailpit ui=8025"        "${options_output}" '.categories.services.items.mailpit.defaults.ui_port'   "8025"
assert_json_eq "wiremock port=8443"     "${options_output}" '.categories.tooling.items.wiremock.defaults.port'     "8443"
assert_json_eq "qa-dashboard port=8082" "${options_output}" '.categories.tooling.items["qa-dashboard"].defaults.port' "8082"

# Items with no defaults should not have the key
assert_json "qa has no defaults"          "${options_output}" '.categories.tooling.items.qa | has("defaults") | not'
assert_json "devcontainer has no defaults" "${options_output}" '.categories.tooling.items.devcontainer | has("defaults") | not'

# Observability category
assert_json "has observability category" "${options_output}" '.categories.observability'
assert_json_eq "observability is multi"  "${options_output}" '.categories.observability.selection' "multi"
assert_json "has prometheus"             "${options_output}" '.categories.observability.items.prometheus'
assert_json "has grafana"                "${options_output}" '.categories.observability.items.grafana'
assert_json "has dozzle"                 "${options_output}" '.categories.observability.items.dozzle'
assert_json_eq "prometheus port=9090"    "${options_output}" '.categories.observability.items.prometheus.defaults.port' "9090"
assert_json_eq "grafana port=3001"       "${options_output}" '.categories.observability.items.grafana.defaults.port'    "3001"
assert_json_eq "dozzle port=9999"        "${options_output}" '.categories.observability.items.dozzle.defaults.port'     "9999"

# Dependencies
assert_json "redis requires app.*"            "${options_output}" '.categories.services.items.redis.requires | index("app.*") != null'
assert_json "qa-dashboard requires tooling.qa" "${options_output}" '.categories.tooling.items["qa-dashboard"].requires | index("tooling.qa") != null'
assert_json "grafana requires prometheus"      "${options_output}" '.categories.observability.items.grafana.requires | index("observability.prometheus") != null'

# Frontend category
assert_json "has frontend category" "${options_output}" '.categories.frontend'
assert_json_eq "frontend is single" "${options_output}" '.categories.frontend.selection' "single"
assert_json_eq "frontend is optional" "${options_output}" '.categories.frontend.required' "false"
assert_json "has vite" "${options_output}" '.categories.frontend.items.vite'

# New app items
assert_json "has python-fastapi" "${options_output}" '.categories.app.items["python-fastapi"]'
assert_json "has rust" "${options_output}" '.categories.app.items.rust'

# New service items
assert_json "has nats" "${options_output}" '.categories.services.items.nats'
assert_json "has minio" "${options_output}" '.categories.services.items.minio'

# New tooling items
assert_json "has db-ui" "${options_output}" '.categories.tooling.items["db-ui"]'
assert_json "has swagger-ui" "${options_output}" '.categories.tooling.items["swagger-ui"]'

# Presets
assert_json "has presets"           "${options_output}" '.presets'
assert_json "has spa-api preset"    "${options_output}" '.presets["spa-api"]'
assert_json "has api-only preset"   "${options_output}" '.presets["api-only"]'
assert_json "has full-stack preset" "${options_output}" '.presets["full-stack"]'
assert_json "has data-pipeline preset" "${options_output}" '.presets["data-pipeline"]'
assert_json_eq "spa-api has prompts" "${options_output}" '.presets["spa-api"].prompts | length' "1"
assert_json_eq "spa-api prompts app" "${options_output}" '.presets["spa-api"].prompts[0]' "app"
assert_json_eq "data-pipeline has no prompts" "${options_output}" '.presets["data-pipeline"].prompts // [] | length' "0"
assert_json_eq "preset count is 4"  "${options_output}" '.presets | keys | length' "4"

# Wiring rules
assert_json "has wiring"          "${options_output}" '.wiring'
assert_json_eq "wiring rule count" "${options_output}" '.wiring | length' "6"
assert_json_eq "first wiring targets vite proxy" "${options_output}" '.wiring[0].set' "frontend.vite.proxy_target"

# ══════════════════════════════════════════════════════════════════════════
# --bootstrap validation tests
# ══════════════════════════════════════════════════════════════════════════

printf '\n=== --bootstrap validation ===\n'

# ── Envelope checks ──────────────────────────────────────────────────────

# INVALID_CONTRACT
result=$(run_bootstrap "${FIXTURES}/invalid-contract.json")
assert_json "INVALID_CONTRACT" "${result}" '.errors[] | select(.code == "INVALID_CONTRACT")'
assert_eq "INVALID_CONTRACT: non-zero exit" "1" "$(run_bootstrap_exit "${FIXTURES}/invalid-contract.json")"

# INVALID_VERSION
result=$(run_bootstrap "${FIXTURES}/invalid-version.json")
assert_json "INVALID_VERSION" "${result}" '.errors[] | select(.code == "INVALID_VERSION")'

# INVALID_PROJECT_NAME
result=$(run_bootstrap "${FIXTURES}/invalid-project-name.json")
assert_json_eq "error status" "${result}" '.status' "error"
assert_json "INVALID_PROJECT_NAME" "${result}" '.errors[] | select(.code == "INVALID_PROJECT_NAME")'
assert_eq "INVALID_PROJECT_NAME: non-zero exit" "1" "$(run_bootstrap_exit "${FIXTURES}/invalid-project-name.json")"

# ── Category / item checks ───────────────────────────────────────────────

# UNKNOWN_CATEGORY
result=$(run_bootstrap "${FIXTURES}/unknown-category.json")
assert_json "UNKNOWN_CATEGORY" "${result}" '.errors[] | select(.code == "UNKNOWN_CATEGORY")'

# UNKNOWN_ITEM
result=$(run_bootstrap "${FIXTURES}/unknown-item.json")
assert_json "UNKNOWN_ITEM" "${result}" '.errors[] | select(.code == "UNKNOWN_ITEM")'

# MISSING_REQUIRED
result=$(run_bootstrap "${FIXTURES}/missing-required.json")
assert_json "MISSING_REQUIRED" "${result}" '.errors[] | select(.code == "MISSING_REQUIRED")'

# MISSING_REQUIRED from empty selections
result=$(run_bootstrap "${FIXTURES}/empty-selections.json")
assert_json "MISSING_REQUIRED (empty selections)" "${result}" '.errors[] | select(.code == "MISSING_REQUIRED")'

# INVALID_SINGLE_SELECT
result=$(run_bootstrap "${FIXTURES}/invalid-single-select.json")
assert_json "INVALID_SINGLE_SELECT" "${result}" '.errors[] | select(.code == "INVALID_SINGLE_SELECT")'

# ── Dependency checks ────────────────────────────────────────────────────

# MISSING_DEPENDENCY — specific (qa-dashboard without qa)
result=$(run_bootstrap "${FIXTURES}/missing-dependency.json")
assert_json "MISSING_DEPENDENCY (specific)" "${result}" '.errors[] | select(.code == "MISSING_DEPENDENCY")'

# Wildcard dep satisfied (redis with app selected — no error expected)
result=$(run_bootstrap "${FIXTURES}/missing-wildcard-dep.json")
assert_json "wildcard dep satisfied (no MISSING_DEPENDENCY)" "${result}" \
    '(.errors // [] | map(select(.code == "MISSING_DEPENDENCY")) | length) == 0'

# Wildcard dep FAILS (redis without any app — should error)
result=$(run_bootstrap "${FIXTURES}/missing-wildcard-dep-fail.json")
assert_json "MISSING_DEPENDENCY (wildcard: app.*)" "${result}" '.errors[] | select(.code == "MISSING_DEPENDENCY")'
# Should also produce MISSING_REQUIRED for app
assert_json "also MISSING_REQUIRED for app" "${result}" '.errors[] | select(.code == "MISSING_REQUIRED")'

# ── Conflict check (using test-only manifest) ────────────────────────────

# Run validation directly with the test manifest to verify CONFLICT logic
conflict_errors=$(jq -n \
    --slurpfile p "${FIXTURES}/conflict-payload.json" \
    --slurpfile m "${FIXTURES}/manifest-with-conflict.json" \
    '$p[0] as $payload | $m[0] as $manifest |
     [] |
     reduce (($payload.selections // {}) | to_entries[]) as $ce (.;
         if ($manifest.categories | has($ce.key)) then
             reduce (($ce.value // {}) | keys[]) as $item (.;
                 if ($manifest.categories[$ce.key].items | has($item)) then
                     reduce (($manifest.categories[$ce.key].items[$item].conflicts // [])[]) as $conflict (.;
                         ($conflict | split(".")) as $parts |
                         if ((($payload.selections // {})[$parts[0]] // {}) | has($parts[1])) then
                             . + [{code:"CONFLICT",
                                   message:"Items \"\($ce.key).\($item)\" and \"\($conflict)\" conflict"}]
                         else . end
                     )
                 else . end
             )
         else . end
     )')
assert_json "CONFLICT detected" "${conflict_errors}" '. | length > 0'
assert_json "CONFLICT code present" "${conflict_errors}" '.[] | select(.code == "CONFLICT")'

# ── Override checks ──────────────────────────────────────────────────────

# INVALID_OVERRIDE
result=$(run_bootstrap "${FIXTURES}/invalid-override.json")
assert_json "INVALID_OVERRIDE" "${result}" '.errors[] | select(.code == "INVALID_OVERRIDE")'

# ── Port collision checks ─────────────────────────────────────────────────

# Check 11: port collision on defaults (node-express + go both default to 3000)
result=$(run_bootstrap "${FIXTURES}/port-conflict-default.json")
assert_json "PORT_CONFLICT (default)" "${result}" '.errors[] | select(.code == "PORT_CONFLICT")'
assert_json_eq "PORT_CONFLICT mentions port 3000" "${result}" \
    '.errors[] | select(.code == "PORT_CONFLICT") | .message | test("3000")' "true"

# Check 11: port collision via override (node-express overridden to 5432 = postgres default)
result=$(run_bootstrap "${FIXTURES}/port-conflict-override.json")
assert_json_eq "PORT_CONFLICT (override): exactly 1 error" "${result}" '.errors | length' "1"
assert_json_eq "PORT_CONFLICT (override): code" "${result}" '.errors[0].code' "PORT_CONFLICT"
assert_json_eq "PORT_CONFLICT (override): mentions port 5432" "${result}" \
    '.errors[0].message | test("5432")' "true"

# Check 11: override resolves collision (go port overridden to 3001 — no conflict)
result=$(run_bootstrap "${FIXTURES}/port-conflict-resolved.json")
assert_json "PORT_CONFLICT resolved: no port conflict" "${result}" \
    '(.errors // [] | map(select(.code == "PORT_CONFLICT")) | length) == 0'

# ── Edge cases ───────────────────────────────────────────────────────────

# Null category value should not crash (null = no items = OK for optional categories)
result=$(run_bootstrap "${FIXTURES}/null-category-value.json")
assert_json "null category: does not crash" "${result}" '.contract == "devstrap-result"'
assert_json "null category: returns valid status" "${result}" '.status == "ok" or .status == "error"'

# Multiple errors returned at once
result=$(run_bootstrap "${FIXTURES}/multiple-errors.json")
error_count=$(printf '%s\n' "${result}" | jq '.errors | length')
assert_eq "returns multiple errors at once" "true" "$([ "${error_count}" -gt 1 ] && echo true || echo false)"
assert_json "includes INVALID_PROJECT_NAME" "${result}" '.errors[] | select(.code == "INVALID_PROJECT_NAME")'
assert_json "includes UNKNOWN_CATEGORY"     "${result}" '.errors[] | select(.code == "UNKNOWN_CATEGORY")'
assert_json "includes MISSING_REQUIRED"     "${result}" '.errors[] | select(.code == "MISSING_REQUIRED")'

# Stdin mode
result=$(run_bootstrap "-" < "${FIXTURES}/missing-required.json")
assert_json "stdin mode works" "${result}" '.errors[] | select(.code == "MISSING_REQUIRED")'

# Contract envelope on error responses
result=$(run_bootstrap "${FIXTURES}/missing-required.json")
assert_json_eq "error has contract field" "${result}" '.contract' "devstrap-result"
assert_json_eq "error has version field"  "${result}" '.version'  "1"
assert_json_eq "error has status=error"   "${result}" '.status'   "error"

# ── CLI error handling ───────────────────────────────────────────────────

# --bootstrap with no --config
result=$("${DEVSTACK_DIR}/devstack.sh" --bootstrap 2>/dev/null)
assert_json "no --config: INVALID_ARGS" "${result}" '.errors[] | select(.code == "INVALID_ARGS")'

# --config with nonexistent file
result=$(run_bootstrap "/nonexistent/path/config.json")
assert_json "missing file: INVALID_ARGS" "${result}" '.errors[] | select(.code == "INVALID_ARGS")'

# Invalid JSON input
result=$(run_bootstrap "${FIXTURES}/invalid-json.txt")
assert_json "invalid JSON: INVALID_JSON" "${result}" '.errors[] | select(.code == "INVALID_JSON")'

# ══════════════════════════════════════════════════════════════════════════
# --bootstrap generation tests (require Docker)
# ══════════════════════════════════════════════════════════════════════════

printf '\n=== --bootstrap generation ===\n'

if ! command -v docker &>/dev/null || ! docker compose version &>/dev/null 2>&1; then
    printf '  %bSKIP%b  Generation tests require Docker — skipping\n' "${YELLOW}" "${NC}"
else
    # Save state before generation tests
    save_state
    trap restore_state EXIT

    # ── Test 1: Full valid payload (node-express) ─────────────────────────

    rm -rf "${DEVSTACK_DIR}/.generated"

    result=$("${DEVSTACK_DIR}/devstack.sh" --bootstrap --config "${FIXTURES}/valid-payload.json" 2>/dev/null)
    gen_exit=$?

    assert_eq "exits 0 on valid payload" "0" "${gen_exit}"
    assert_json_eq "status is ok"               "${result}" '.status'   "ok"
    assert_json_eq "contract is devstrap-result" "${result}" '.contract' "devstrap-result"
    assert_json_eq "version is 1"               "${result}" '.version'  "1"
    assert_json     "has project_dir"            "${result}" '.project_dir'
    assert_json_eq "project_dir format"          "${result}" '.project_dir' "./test-project"
    assert_json     "has services"               "${result}" '.services'
    assert_json     "has commands"               "${result}" '.commands'
    assert_json_eq "commands.start"              "${result}" '.commands.start' "./devstack.sh start"
    assert_json_eq "commands.stop"               "${result}" '.commands.stop'  "./devstack.sh stop"
    assert_json_eq "commands.test"               "${result}" '.commands.test'  "./devstack.sh test"
    assert_json_eq "commands.logs"               "${result}" '.commands.logs'  "./devstack.sh logs"

    # Resolved services in response
    assert_json_eq "node-express port resolved"  "${result}" '.services["node-express"].port' "3000"
    assert_json_eq "postgres port resolved"      "${result}" '.services.postgres.port'        "5432"
    assert_json_eq "redis port resolved"         "${result}" '.services.redis.port'           "6379"
    assert_json_eq "qa is empty object"          "${result}" '.services.qa | keys | length'   "0"
    assert_json_eq "qa-dashboard port resolved"  "${result}" '.services["qa-dashboard"].port'  "8082"
    assert_json_eq "wiremock port resolved"      "${result}" '.services.wiremock.port'         "8443"

    # Generated files
    assert_eq "project.env created"         "true" "$([ -f "${DEVSTACK_DIR}/project.env" ] && echo true || echo false)"
    assert_eq "docker-compose.yml created"  "true" "$([ -f "${DEVSTACK_DIR}/.generated/docker-compose.yml" ] && echo true || echo false)"
    assert_eq "nginx.conf created"          "true" "$([ -f "${DEVSTACK_DIR}/.generated/nginx.conf" ] && echo true || echo false)"
    assert_eq "app/Dockerfile created"      "true" "$([ -f "${DEVSTACK_DIR}/app/Dockerfile" ] && echo true || echo false)"
    assert_eq "app/init.sh created"         "true" "$([ -f "${DEVSTACK_DIR}/app/init.sh" ] && echo true || echo false)"
    assert_eq "mocks/ created (wiremock)"   "true" "$([ -d "${DEVSTACK_DIR}/mocks" ] && echo true || echo false)"

    # Verify project.env content
    assert_eq "PROJECT_NAME correct" "true" "$(grep -q 'PROJECT_NAME=test-project' "${DEVSTACK_DIR}/project.env" && echo true || echo false)"
    assert_eq "APP_TYPE correct"     "true" "$(grep -q 'APP_TYPE=node-express'     "${DEVSTACK_DIR}/project.env" && echo true || echo false)"
    assert_eq "DB_TYPE correct"      "true" "$(grep -q 'DB_TYPE=postgres'          "${DEVSTACK_DIR}/project.env" && echo true || echo false)"
    assert_eq "EXTRAS correct"       "true" "$(grep -q 'EXTRAS=redis'              "${DEVSTACK_DIR}/project.env" && echo true || echo false)"

    # Verify docker-compose is valid YAML
    compose_valid="false"
    if docker compose -f "${DEVSTACK_DIR}/.generated/docker-compose.yml" config --quiet 2>/dev/null; then
        compose_valid="true"
    fi
    assert_eq "docker-compose.yml is valid" "true" "${compose_valid}"

    # ── Test 2: Overrides ─────────────────────────────────────────────────

    rm -rf "${DEVSTACK_DIR}/.generated"

    result=$("${DEVSTACK_DIR}/devstack.sh" --bootstrap --config "${FIXTURES}/valid-with-overrides.json" 2>/dev/null)
    gen_exit=$?

    assert_eq "overrides: exits 0"                     "0"    "${gen_exit}"
    assert_json_eq "overrides: node-express port=4000"  "${result}" '.services["node-express"].port' "4000"
    assert_json_eq "overrides: qa-dashboard port=9001"  "${result}" '.services["qa-dashboard"].port' "9001"
    assert_json_eq "overrides: wiremock port=9443"      "${result}" '.services.wiremock.port'        "9443"
    assert_json_eq "overrides: mariadb default port=3306" "${result}" '.services.mariadb.port'       "3306"
    assert_eq "overrides: HTTPS_PORT=9443"          "true" "$(grep -q 'HTTPS_PORT=9443'          "${DEVSTACK_DIR}/project.env" && echo true || echo false)"
    assert_eq "overrides: TEST_DASHBOARD_PORT=9001" "true" "$(grep -q 'TEST_DASHBOARD_PORT=9001' "${DEVSTACK_DIR}/project.env" && echo true || echo false)"

    # ── Test 3: Minimal valid (app only, nothing else) ────────────────────

    rm -rf "${DEVSTACK_DIR}/.generated"

    result=$("${DEVSTACK_DIR}/devstack.sh" --bootstrap --config "${FIXTURES}/minimal-valid.json" 2>/dev/null)
    gen_exit=$?

    assert_eq "minimal: exits 0"                "0"    "${gen_exit}"
    assert_json_eq "minimal: status ok"          "${result}" '.status'   "ok"
    assert_json_eq "minimal: only node-express"  "${result}" '.services | keys | length' "1"
    assert_json_eq "minimal: node-express port"  "${result}" '.services["node-express"].port' "3000"
    assert_eq "minimal: DB_TYPE=none" "true" "$(grep -q 'DB_TYPE=none' "${DEVSTACK_DIR}/project.env" && echo true || echo false)"

    # ── Test 4: PHP app type ──────────────────────────────────────────────

    rm -rf "${DEVSTACK_DIR}/.generated"

    result=$("${DEVSTACK_DIR}/devstack.sh" --bootstrap --config "${FIXTURES}/valid-payload-php.json" 2>/dev/null)
    gen_exit=$?

    assert_eq "php: exits 0"             "0"    "${gen_exit}"
    assert_json_eq "php: status ok"       "${result}" '.status' "ok"
    assert_eq "php: APP_TYPE=php-laravel" "true" "$(grep -q 'APP_TYPE=php-laravel' "${DEVSTACK_DIR}/project.env" && echo true || echo false)"
    assert_eq "php: Dockerfile created"   "true" "$([ -f "${DEVSTACK_DIR}/app/Dockerfile" ] && echo true || echo false)"

    # ── Test 5: Go app type ───────────────────────────────────────────────

    rm -rf "${DEVSTACK_DIR}/.generated"

    result=$("${DEVSTACK_DIR}/devstack.sh" --bootstrap --config "${FIXTURES}/valid-payload-go.json" 2>/dev/null)
    gen_exit=$?

    assert_eq "go: exits 0"          "0"    "${gen_exit}"
    assert_json_eq "go: status ok"    "${result}" '.status' "ok"
    assert_eq "go: APP_TYPE=go"       "true" "$(grep -q 'APP_TYPE=go' "${DEVSTACK_DIR}/project.env" && echo true || echo false)"

    # ── Test 6: Devcontainer generation ───────────────────────────────────

    rm -rf "${DEVSTACK_DIR}/.generated"
    rm -rf "${DEVSTACK_DIR}/.devcontainer"

    result=$("${DEVSTACK_DIR}/devstack.sh" --bootstrap --config "${FIXTURES}/valid-with-devcontainer.json" 2>/dev/null)
    gen_exit=$?

    assert_eq "devcontainer: exits 0"               "0"    "${gen_exit}"
    assert_eq "devcontainer: .devcontainer/ created" "true" "$([ -d "${DEVSTACK_DIR}/.devcontainer" ] && echo true || echo false)"

    # ── Test 7: Observability (prometheus + grafana + dozzle) ─────────────

    rm -rf "${DEVSTACK_DIR}/.generated"

    result=$("${DEVSTACK_DIR}/devstack.sh" --bootstrap --config "${FIXTURES}/valid-with-observability.json" 2>/dev/null)
    gen_exit=$?

    assert_eq "obs: exits 0"                  "0"    "${gen_exit}"
    assert_json_eq "obs: status ok"            "${result}" '.status'                   "ok"
    assert_json_eq "obs: prometheus port"      "${result}" '.services.prometheus.port'  "9090"
    assert_json_eq "obs: grafana port"         "${result}" '.services.grafana.port'     "3001"
    assert_json_eq "obs: dozzle port"          "${result}" '.services.dozzle.port'      "9999"

    # Verify services appear in generated compose
    assert_eq "obs: prometheus in compose" "true" \
        "$(grep -q 'container_name.*-prometheus' "${DEVSTACK_DIR}/.generated/docker-compose.yml" && echo true || echo false)"
    assert_eq "obs: grafana in compose" "true" \
        "$(grep -q 'container_name.*-grafana' "${DEVSTACK_DIR}/.generated/docker-compose.yml" && echo true || echo false)"
    assert_eq "obs: dozzle in compose" "true" \
        "$(grep -q 'container_name.*-dozzle' "${DEVSTACK_DIR}/.generated/docker-compose.yml" && echo true || echo false)"

    # Verify ports in compose
    assert_eq "obs: prometheus port in compose" "true" \
        "$(grep -q '9090:9090' "${DEVSTACK_DIR}/.generated/docker-compose.yml" && echo true || echo false)"
    assert_eq "obs: grafana port in compose" "true" \
        "$(grep -q '3001:3000' "${DEVSTACK_DIR}/.generated/docker-compose.yml" && echo true || echo false)"
    assert_eq "obs: dozzle port in compose" "true" \
        "$(grep -q '9999:8080' "${DEVSTACK_DIR}/.generated/docker-compose.yml" && echo true || echo false)"

    # Verify EXTRAS in project.env includes observability items
    assert_eq "obs: EXTRAS has prometheus" "true" \
        "$(grep -q 'EXTRAS=.*prometheus' "${DEVSTACK_DIR}/project.env" && echo true || echo false)"
    assert_eq "obs: EXTRAS has grafana" "true" \
        "$(grep -q 'EXTRAS=.*grafana' "${DEVSTACK_DIR}/project.env" && echo true || echo false)"
    assert_eq "obs: EXTRAS has dozzle" "true" \
        "$(grep -q 'EXTRAS=.*dozzle' "${DEVSTACK_DIR}/project.env" && echo true || echo false)"

    # Verify compose validates
    obs_compose_valid="false"
    if docker compose -f "${DEVSTACK_DIR}/.generated/docker-compose.yml" config --quiet 2>/dev/null; then
        obs_compose_valid="true"
    fi
    assert_eq "obs: docker-compose.yml is valid" "true" "${obs_compose_valid}"

    # Verify grafana requires prometheus (validation)
    grafana_only_result=$("${DEVSTACK_DIR}/devstack.sh" --bootstrap --config - 2>/dev/null <<'PAYLOAD'
{"contract":"devstrap-bootstrap","version":"1","project":"dep-test","selections":{"app":{"node-express":{}},"observability":{"grafana":{}}}}
PAYLOAD
    )
    assert_json "obs: grafana requires prometheus" "${grafana_only_result}" \
        '.errors[] | select(.code == "MISSING_DEPENDENCY")'

    # ── Cleanup (trap handles restore_state) ──────────────────────────────
fi

# ══════════════════════════════════════════════════════════════════════════
# Regression: existing commands unaffected
# ══════════════════════════════════════════════════════════════════════════

printf '\n=== Regression ===\n'

help_output=$("${DEVSTACK_DIR}/devstack.sh" help 2>/dev/null)
assert_eq "help command works"     "true" "$(printf '%s' "${help_output}" | grep -q 'start' && echo true || echo false)"
assert_eq "help shows --options"   "true" "$(printf '%s' "${help_output}" | grep -q '\-\-options' && echo true || echo false)"
assert_eq "help shows --bootstrap" "true" "$(printf '%s' "${help_output}" | grep -q '\-\-bootstrap' && echo true || echo false)"

# ══════════════════════════════════════════════════════════════════════════
# Summary
# ══════════════════════════════════════════════════════════════════════════

printf '\n========================\n'
printf 'Total: %d  Pass: %d  Fail: %d\n' "${TOTAL}" "${PASS}" "${FAIL}"
if [ ${FAIL} -eq 0 ]; then
    printf '%bAll tests passed.%b\n' "${GREEN}" "${NC}"
else
    printf '%b%d test(s) failed.%b\n' "${RED}" "${FAIL}" "${NC}"
    exit 1
fi
