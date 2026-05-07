#!/bin/bash
# =============================================================================
# DevStack CLI
# =============================================================================
# A container-first development environment with transparent mock interception.
#
# Usage:
#   ./devstack.sh start          Start the full stack (generates config, builds, runs)
#   ./devstack.sh stop           Stop and remove all containers + volumes (clean slate)
#   ./devstack.sh test [filter]  Run Playwright tests inside container
#   ./devstack.sh shell [svc]    Drop into a shell in a running container (default: app)
#   ./devstack.sh status         Show running containers and their health
#   ./devstack.sh logs [svc]     Tail logs for a service (default: all)
#   ./devstack.sh generate       Regenerate config without starting (for inspection)
#   ./devstack.sh mocks          List all configured mock services and domains
#
# Prerequisites: Docker and Docker Compose (v2)
# =============================================================================

set -euo pipefail

DEVSTACK_DIR="$(cd "$(dirname "$0")" && pwd)"
GENERATED_DIR="${DEVSTACK_DIR}/.generated"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

log()      { echo -e "${BLUE}[devstack]${NC} $*"; }
log_ok()   { echo -e "${GREEN}[devstack]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[devstack]${NC} $*"; }
log_err()  { echo -e "${RED}[devstack]${NC} $*"; }

check_docker() {
    if ! command -v docker &>/dev/null; then
        log_err "Docker is not installed. Install Docker first: https://docs.docker.com/get-docker/"
        exit 1
    fi
    if ! docker compose version &>/dev/null; then
        log_err "Docker Compose v2 is required. Update Docker: https://docs.docker.com/compose/install/"
        exit 1
    fi
}

load_config() {
    if [ ! -f "${DEVSTACK_DIR}/project.env" ]; then
        log_err "project.env not found in ${DEVSTACK_DIR}"
        log_err "Copy from project.env.example and configure for your project."
        exit 1
    fi
    source "${DEVSTACK_DIR}/project.env"
}

# ---------------------------------------------------------------------------
# Generate all config from directory structure
# ---------------------------------------------------------------------------
cmd_generate() {
    log "Generating configuration from directory structure..."

    mkdir -p "${GENERATED_DIR}"

    # 1. Generate Caddyfile
    log "Generating Caddyfile..."
    bash "${DEVSTACK_DIR}/core/caddy/generate-caddyfile.sh"

    # 2. Generate docker-compose.yml
    log "Generating docker-compose.yml..."
    bash "${DEVSTACK_DIR}/core/compose/generate.sh"

    log_ok "Configuration generated in ${GENERATED_DIR}/"
    log "  - Caddyfile"
    log "  - docker-compose.yml"
    log "  - domains.txt"
}

# ---------------------------------------------------------------------------
# Start
# ---------------------------------------------------------------------------
cmd_start() {
    log "Starting DevStack for ${PROJECT_NAME}..."

    # Ensure test results directory exists
    mkdir -p "${DEVSTACK_DIR}/tests/results"

    # Generate all config
    cmd_generate

    # Ensure app source directory exists
    if [ ! -d "${DEVSTACK_DIR}/${APP_SOURCE}" ]; then
        log_warn "App source directory '${APP_SOURCE}' not found."
        log_warn "Creating it with a placeholder. Add your application code there."
        mkdir -p "${DEVSTACK_DIR}/${APP_SOURCE}"
    fi

    # Build and start
    log "Building containers..."
    if ! docker compose -f "${GENERATED_DIR}/docker-compose.yml" \
        -p "${PROJECT_NAME}" \
        build; then
        log_err "Docker build failed. Check your Dockerfile and app source."
        exit 1
    fi

    log "Starting services..."
    docker compose -f "${GENERATED_DIR}/docker-compose.yml" \
        -p "${PROJECT_NAME}" \
        up -d

    # Wait for cert-gen to complete
    log "Waiting for certificate generation..."
    docker compose -f "${GENERATED_DIR}/docker-compose.yml" \
        -p "${PROJECT_NAME}" \
        wait cert-gen 2>/dev/null || true

    # Wait for database health
    if [ "${DB_TYPE}" != "none" ]; then
        log "Waiting for database (${DB_TYPE})..."
        local retries=0
        local max_retries=30
        while [ $retries -lt $max_retries ]; do
            if docker compose -f "${GENERATED_DIR}/docker-compose.yml" \
                -p "${PROJECT_NAME}" \
                exec -T db true 2>/dev/null; then

                local health
                health=$(docker inspect --format='{{.State.Health.Status}}' "${PROJECT_NAME}-db" 2>/dev/null || echo "unknown")
                if [ "${health}" = "healthy" ]; then
                    break
                fi
            fi
            retries=$((retries + 1))
            sleep 2
        done
        if [ $retries -ge $max_retries ]; then
            log_warn "Database health check timed out — continuing anyway"
        fi
    fi

    # Run init script if configured — pipe the script content into the container
    # This works regardless of where the app source is mounted (/app, /var/www/html, etc.)
    if [ -n "${APP_INIT_SCRIPT:-}" ] && [ -f "${DEVSTACK_DIR}/${APP_INIT_SCRIPT}" ]; then
        log "Running app init script..."
        docker compose -f "${GENERATED_DIR}/docker-compose.yml" \
            -p "${PROJECT_NAME}" \
            exec -T app sh < "${DEVSTACK_DIR}/${APP_INIT_SCRIPT}" || \
        log_warn "Init script failed — check './devstack.sh logs app' for details"
    fi

    # Print summary
    echo ""
    log_ok "============================================="
    log_ok " DevStack is running: ${PROJECT_NAME}"
    log_ok "============================================="
    echo ""
    log "Application:     http://localhost:${HTTP_PORT}"
    log "Application SSL: https://localhost:${HTTPS_PORT}"
    log "Test Dashboard:  http://localhost:${TEST_DASHBOARD_PORT}"

    # List mocked services
    local mock_count=0
    if [ -d "${DEVSTACK_DIR}/mocks" ]; then
        for mock_dir in "${DEVSTACK_DIR}"/mocks/*/; do
            [ -d "${mock_dir}" ] || continue
            [ -f "${mock_dir}domains" ] || continue
            mock_count=$((mock_count + 1))
        done
    fi
    if [ $mock_count -gt 0 ]; then
        echo ""
        log "Mocked services (${mock_count}):"
        for mock_dir in "${DEVSTACK_DIR}"/mocks/*/; do
            [ -d "${mock_dir}" ] || continue
            [ -f "${mock_dir}domains" ] || continue
            local name=$(basename "${mock_dir}")
            local domains=$(cat "${mock_dir}domains" | tr '\n' ', ' | sed 's/,$//')
            log "  ${CYAN}${name}${NC} → ${domains}"
        done
    fi

    if [ "${DB_TYPE}" != "none" ]; then
        echo ""
        log "Database (${DB_TYPE}): ${DB_NAME} (user: ${DB_USER})"
    fi

    echo ""
    log "Commands:"
    log "  ./devstack.sh test           Run tests"
    log "  ./devstack.sh shell          Shell into app container"
    log "  ./devstack.sh logs           Tail all logs"
    log "  ./devstack.sh stop           Stop and clean everything"
    echo ""
}

# ---------------------------------------------------------------------------
# Stop
# ---------------------------------------------------------------------------
cmd_stop() {
    log "Stopping DevStack..."

    if [ -f "${GENERATED_DIR}/docker-compose.yml" ]; then
        docker compose -f "${GENERATED_DIR}/docker-compose.yml" \
            -p "${PROJECT_NAME}" \
            down -v --remove-orphans 2>/dev/null || true
    else
        # Fallback: try to stop by project name
        docker compose -p "${PROJECT_NAME}" down -v --remove-orphans 2>/dev/null || true
    fi

    # Clean generated files
    rm -rf "${GENERATED_DIR}"

    # Clean test results and node_modules (may be root-owned from containers)
    if [ -d "${DEVSTACK_DIR}/tests/results" ] || [ -d "${DEVSTACK_DIR}/tests/playwright/node_modules" ]; then
        docker run --rm \
            -v "${DEVSTACK_DIR}/tests:/data" \
            alpine sh -c "rm -rf /data/results/* /data/playwright/node_modules /data/playwright/package-lock.json" 2>/dev/null || true
    fi

    log_ok "DevStack stopped. All containers, volumes, and generated files removed."
    log "Run './devstack.sh start' for a fresh stack."
}

# ---------------------------------------------------------------------------
# Test
# ---------------------------------------------------------------------------
cmd_test() {
    local filter="${1:-}"
    local run_id
    run_id="$(date +%Y%m%d-%H%M%S)"

    if [ ! -f "${GENERATED_DIR}/docker-compose.yml" ]; then
        log_err "DevStack is not running. Run './devstack.sh start' first."
        exit 1
    fi

    # Create run-specific results directory
    local results_dir="${DEVSTACK_DIR}/tests/results/${run_id}"
    mkdir -p "${results_dir}"

    log "Running tests (run: ${run_id})..."

    # Build the playwright command — install deps first, then run tests
    local pw_cmd="cd /tests && npm install --silent 2>/dev/null && npx playwright test"
    if [ -n "${filter}" ]; then
        pw_cmd="${pw_cmd} --grep '${filter}'"
        log "Filter: ${filter}"
    fi
    pw_cmd="${pw_cmd} --reporter=html,json"
    pw_cmd="${pw_cmd} --output=/results/${run_id}/artifacts"

    # Set environment for this run
    local exit_code=0
    docker compose -f "${GENERATED_DIR}/docker-compose.yml" \
        -p "${PROJECT_NAME}" \
        exec -T \
        -e PLAYWRIGHT_HTML_REPORT="/results/${run_id}/report" \
        -e PLAYWRIGHT_JSON_OUTPUT_FILE="/results/${run_id}/results.json" \
        tester bash -c "${pw_cmd}" || exit_code=$?

    echo ""
    if [ $exit_code -eq 0 ]; then
        log_ok "All tests passed."
    else
        log_err "Tests failed (exit code: ${exit_code})"
    fi

    log "Report:      http://localhost:${TEST_DASHBOARD_PORT}/${run_id}/report/index.html"
    log "Artifacts:   http://localhost:${TEST_DASHBOARD_PORT}/${run_id}/artifacts/"
    log "JSON:        http://localhost:${TEST_DASHBOARD_PORT}/${run_id}/results.json"

    return $exit_code
}

# ---------------------------------------------------------------------------
# Shell
# ---------------------------------------------------------------------------
cmd_shell() {
    local service="${1:-app}"

    if [ ! -f "${GENERATED_DIR}/docker-compose.yml" ]; then
        log_err "DevStack is not running. Run './devstack.sh start' first."
        exit 1
    fi

    log "Opening shell in '${service}' container..."

    # Try bash first, fall back to sh
    docker compose -f "${GENERATED_DIR}/docker-compose.yml" \
        -p "${PROJECT_NAME}" \
        exec "${service}" bash 2>/dev/null || \
    docker compose -f "${GENERATED_DIR}/docker-compose.yml" \
        -p "${PROJECT_NAME}" \
        exec "${service}" sh
}

# ---------------------------------------------------------------------------
# Status
# ---------------------------------------------------------------------------
cmd_status() {
    if [ ! -f "${GENERATED_DIR}/docker-compose.yml" ]; then
        log_warn "DevStack is not running (no generated config found)."
        return 0
    fi

    docker compose -f "${GENERATED_DIR}/docker-compose.yml" \
        -p "${PROJECT_NAME}" \
        ps --format "table {{.Name}}\t{{.Status}}\t{{.Ports}}"
}

# ---------------------------------------------------------------------------
# Logs
# ---------------------------------------------------------------------------
cmd_logs() {
    local service="${1:-}"

    if [ ! -f "${GENERATED_DIR}/docker-compose.yml" ]; then
        log_err "DevStack is not running. Run './devstack.sh start' first."
        exit 1
    fi

    if [ -n "${service}" ]; then
        docker compose -f "${GENERATED_DIR}/docker-compose.yml" \
            -p "${PROJECT_NAME}" \
            logs -f "${service}"
    else
        docker compose -f "${GENERATED_DIR}/docker-compose.yml" \
            -p "${PROJECT_NAME}" \
            logs -f
    fi
}

# ---------------------------------------------------------------------------
# Mocks — list configured mock services
# ---------------------------------------------------------------------------
cmd_mocks() {
    echo ""
    log "Configured mock services:"
    echo ""

    if [ ! -d "${DEVSTACK_DIR}/mocks" ]; then
        log_warn "No mocks directory found."
        return 0
    fi

    local count=0
    for mock_dir in "${DEVSTACK_DIR}"/mocks/*/; do
        [ -d "${mock_dir}" ] || continue
        local name=$(basename "${mock_dir}")
        local domains_file="${mock_dir}domains"
        local mappings_dir="${mock_dir}mappings"

        count=$((count + 1))
        echo -e "  ${CYAN}${name}${NC}"

        if [ -f "${domains_file}" ]; then
            echo "    Domains:"
            while IFS= read -r domain || [ -n "${domain}" ]; do
                domain=$(echo "${domain}" | tr -d '[:space:]')
                [ -z "${domain}" ] && continue
                [[ "${domain}" == \#* ]] && continue
                echo "      - ${domain}"
            done < "${domains_file}"
        else
            echo -e "    ${YELLOW}No domains file${NC}"
        fi

        if [ -d "${mappings_dir}" ]; then
            local mapping_count
            mapping_count=$(find "${mappings_dir}" -name "*.json" | wc -l)
            echo "    Mappings: ${mapping_count} JSON file(s)"

            # List mapping names from the JSON files
            for mapping in "${mappings_dir}"/*.json; do
                [ -f "${mapping}" ] || continue
                local mapping_name
                mapping_name=$(grep -o '"name"[[:space:]]*:[[:space:]]*"[^"]*"' "${mapping}" 2>/dev/null | head -1 | sed 's/"name"[[:space:]]*:[[:space:]]*"//;s/"$//')
                if [ -n "${mapping_name}" ]; then
                    echo "      - ${mapping_name}"
                else
                    echo "      - $(basename "${mapping}")"
                fi
            done
        else
            echo -e "    ${YELLOW}No mappings directory${NC}"
        fi
        echo ""
    done

    if [ $count -eq 0 ]; then
        log "No mock services configured."
        log "Create one: mkdir -p mocks/my-api/mappings && echo 'api.example.com' > mocks/my-api/domains"
    fi

    log "To add a mock:"
    log "  1. mkdir -p mocks/<name>/mappings"
    log "  2. echo 'api.domain.com' > mocks/<name>/domains"
    log "  3. Add WireMock JSON mappings to mocks/<name>/mappings/"
    log "  4. Run './devstack.sh restart'"
}

# ---------------------------------------------------------------------------
# Restart — convenience stop + start
# ---------------------------------------------------------------------------
cmd_restart() {
    cmd_stop
    cmd_start
}

# ---------------------------------------------------------------------------
# Reload Mocks — hot-reload WireMock mappings without full restart
# ---------------------------------------------------------------------------
cmd_reload_mocks() {
    if [ ! -f "${GENERATED_DIR}/docker-compose.yml" ]; then
        log_err "DevStack is not running. Run './devstack.sh start' first."
        exit 1
    fi

    log "Reloading mock mappings..."

    # Reset WireMock mappings from disk
    local response
    response=$(docker compose -f "${GENERATED_DIR}/docker-compose.yml" \
        -p "${PROJECT_NAME}" \
        exec -T wiremock wget -qO- --post-data='' \
        "http://localhost:8080/__admin/mappings/reset" 2>&1) || {
        log_err "Failed to reload mocks. Is WireMock running?"
        log "Try: ./devstack.sh status"
        return 1
    }

    # Show loaded mapping count
    local mappings_response count
    mappings_response=$(docker compose -f "${GENERATED_DIR}/docker-compose.yml" \
        -p "${PROJECT_NAME}" \
        exec -T wiremock wget -qO- \
        "http://localhost:8080/__admin/mappings" 2>/dev/null) || true
    count=$(echo "${mappings_response}" | grep -o '"total" *: *[0-9]*' | grep -o '[0-9]*' | head -1)
    count="${count:-0}"

    log_ok "Mock mappings reloaded (${count} mappings loaded)."
    log "Note: New domains require a full restart (./devstack.sh restart)"
}

# ---------------------------------------------------------------------------
# New Mock — scaffold a new mock service
# ---------------------------------------------------------------------------
cmd_new_mock() {
    local name="${1:-}"
    local domain="${2:-}"

    if [ -z "${name}" ]; then
        log_err "Usage: ./devstack.sh new-mock <name> <domain>"
        log "Example: ./devstack.sh new-mock stripe api.stripe.com"
        exit 1
    fi

    if [ -z "${domain}" ]; then
        log_err "Usage: ./devstack.sh new-mock <name> <domain>"
        log "Example: ./devstack.sh new-mock ${name} api.${name}.com"
        exit 1
    fi

    local mock_dir="${DEVSTACK_DIR}/mocks/${name}"

    if [ -d "${mock_dir}" ]; then
        log_err "Mock '${name}' already exists at ${mock_dir}"
        exit 1
    fi

    # Create directory structure
    mkdir -p "${mock_dir}/mappings"

    # Write domains file
    echo "${domain}" > "${mock_dir}/domains"

    # Write example mapping
    cat > "${mock_dir}/mappings/example.json" <<MOCK_EOF
{
    "name": "${name} — example endpoint",
    "request": {
        "method": "GET",
        "url": "/v1/status"
    },
    "response": {
        "status": 200,
        "headers": {
            "Content-Type": "application/json"
        },
        "jsonBody": {
            "service": "${name}",
            "status": "ok",
            "mocked": true
        }
    }
}
MOCK_EOF

    log_ok "Created mock '${name}' at mocks/${name}/"
    log "  Domain:  ${domain}"
    log "  Mapping: mocks/${name}/mappings/example.json"
    echo ""
    log "Next steps:"
    log "  1. Edit mocks/${name}/mappings/example.json (or add more mappings)"
    log "  2. Run './devstack.sh restart' to pick up the new domain"
    log "  After the first restart, use './devstack.sh reload-mocks' for mapping changes"
}

# ---------------------------------------------------------------------------
# Record — proxy to real API and capture responses as mock mappings
# ---------------------------------------------------------------------------
cmd_record() {
    local name="${1:-}"

    if [ -z "${name}" ]; then
        log_err "Usage: ./devstack.sh record <mock-name>"
        log ""
        log "Records real API responses and saves them as WireMock mappings."
        log "The mock must already exist (use './devstack.sh new-mock' first)."
        log ""
        log "Example:"
        log "  ./devstack.sh new-mock stripe api.stripe.com"
        log "  ./devstack.sh record stripe"
        log "  # Make requests through the app — real responses are captured"
        log "  # Press Ctrl+C to stop recording"
        log "  # Review, then apply: ./devstack.sh apply-recording stripe"
        exit 1
    fi

    local mock_dir="${DEVSTACK_DIR}/mocks/${name}"
    if [ ! -d "${mock_dir}" ]; then
        log_err "Mock '${name}' not found. Create it first:"
        log "  ./devstack.sh new-mock ${name} api.${name}.com"
        exit 1
    fi

    local domains_file="${mock_dir}/domains"
    if [ ! -f "${domains_file}" ]; then
        log_err "No domains file in mocks/${name}/. Add the domain to intercept."
        exit 1
    fi

    # Read the first domain as the proxy target
    local target_domain
    target_domain=$(head -1 "${domains_file}" | tr -d '[:space:]')
    if [ -z "${target_domain}" ]; then
        log_err "domains file is empty in mocks/${name}/"
        exit 1
    fi

    if [ ! -f "${GENERATED_DIR}/docker-compose.yml" ]; then
        log_err "DevStack is not running. Run './devstack.sh start' first."
        exit 1
    fi

    local record_dir="${mock_dir}/recordings"

    # Clean previous recordings (root-owned from container)
    if [ -d "${record_dir}" ]; then
        docker run --rm -v "${record_dir}:/data" alpine rm -rf /data/mappings /data/__files 2>/dev/null || true
    fi
    mkdir -p "${record_dir}/mappings" "${record_dir}/__files"

    log "Starting recording for '${name}' (proxying to https://${target_domain})..."
    log ""
    log "How it works:"
    log "  1. A temporary WireMock recorder proxies requests to the REAL ${target_domain}"
    log "  2. Make requests through your app as normal"
    log "  3. Press Ctrl+C when done — captured mappings are saved"
    log ""
    log_warn "This calls the REAL API. You need valid credentials and may incur costs."
    echo ""

    # Run a temporary WireMock container in record mode
    docker run --rm -it \
        --name "${PROJECT_NAME}-recorder" \
        --network "${PROJECT_NAME}_${PROJECT_NAME}-internal" \
        -v "${record_dir}/mappings:/home/wiremock/mappings" \
        -v "${record_dir}/__files:/home/wiremock/__files" \
        wiremock/wiremock:latest \
        --port 8080 \
        --proxy-all "https://${target_domain}" \
        --record-mappings \
        --verbose || true

    # Count captured mappings (use docker to read root-owned files)
    local captured
    captured=$(docker run --rm -v "${record_dir}:/data" alpine sh -c \
        'find /data/mappings -name "*.json" 2>/dev/null | wc -l' 2>/dev/null)
    captured=$(echo "${captured}" | tr -d '[:space:]')

    if [ "${captured}" -gt 0 ]; then
        echo ""
        log_ok "Recorded ${captured} mapping(s)."
        echo ""

        # List what was captured
        docker run --rm -v "${record_dir}:/data" alpine sh -c \
            'for f in /data/mappings/*.json; do echo "  - $(basename "$f")"; done' 2>/dev/null

        echo ""
        log "Next steps:"
        log "  1. Review recordings:        ls mocks/${name}/recordings/mappings/"
        log "  2. Apply to mock:            ./devstack.sh apply-recording ${name}"
        log "  3. Activate:                 ./devstack.sh reload-mocks  (or restart for new domains)"
        log ""
        log_warn "Review recordings before applying — they may contain API keys or tokens in headers."
    else
        echo ""
        log_warn "No mappings captured. Did you make requests while recording?"
        log "The recorder listens at http://${PROJECT_NAME}-recorder:8080 inside the Docker network."
        log "From another terminal: ./devstack.sh shell app"
        log "Then: wget -qO- http://${PROJECT_NAME}-recorder:8080/your/endpoint"
    fi
}

# ---------------------------------------------------------------------------
# Apply Recording — copy recorded mappings into the active mock
# ---------------------------------------------------------------------------
cmd_apply_recording() {
    local name="${1:-}"

    if [ -z "${name}" ]; then
        log_err "Usage: ./devstack.sh apply-recording <mock-name>"
        exit 1
    fi

    local mock_dir="${DEVSTACK_DIR}/mocks/${name}"
    local record_dir="${mock_dir}/recordings"

    if [ ! -d "${record_dir}/mappings" ]; then
        log_err "No recordings found for '${name}'."
        log "Run './devstack.sh record ${name}' first."
        exit 1
    fi

    # Count recordings
    local count
    count=$(docker run --rm -v "${record_dir}:/data" alpine sh -c \
        'find /data/mappings -name "*.json" 2>/dev/null | wc -l' 2>/dev/null)
    count=$(echo "${count}" | tr -d '[:space:]')

    if [ "${count}" -eq 0 ]; then
        log_warn "No recorded mappings to apply."
        exit 0
    fi

    log "Applying ${count} recording(s) to mocks/${name}/..."

    # Ensure target directories exist
    mkdir -p "${mock_dir}/mappings" "${mock_dir}/__files"

    # Copy mappings and __files, fix ownership to current user, and rewrite
    # bodyFileName paths to include the mock subdirectory (WireMock mounts
    # __files at /home/wiremock/__files/<name>/)
    docker run --rm \
        -v "${record_dir}:/src:ro" \
        -v "${mock_dir}:/dst" \
        -e "MOCK_NAME=${name}" \
        alpine sh -c '
            # Copy mappings — rewrite bodyFileName to include subdirectory
            for f in /src/mappings/*.json; do
                [ -f "$f" ] || continue
                fname=$(basename "$f")
                if grep -q "bodyFileName" "$f"; then
                    # Rewrite "bodyFileName": "body-xxx.json"
                    # to      "bodyFileName": "<mock_name>/body-xxx.json"
                    sed "s|\"bodyFileName\" *: *\"|\"bodyFileName\" : \"${MOCK_NAME}/|" "$f" \
                        > "/dst/mappings/${fname}"
                else
                    cp "$f" "/dst/mappings/${fname}"
                fi
            done

            # Copy response body files
            for f in /src/__files/*; do
                [ -f "$f" ] || continue
                cp "$f" "/dst/__files/$(basename "$f")"
            done

            # Fix ownership so host user can read/edit
            chown -R '"$(id -u):$(id -g)"' /dst/mappings/ /dst/__files/ 2>/dev/null || true
        '

    # List what was applied
    log_ok "Applied ${count} recording(s):"
    for f in "${mock_dir}/mappings"/mapping-*.json; do
        [ -f "${f}" ] || continue
        log "  - $(basename "${f}")"
    done

    echo ""

    # Clean up recordings
    docker run --rm -v "${record_dir}:/data" alpine rm -rf /data/mappings /data/__files 2>/dev/null || true
    rmdir "${record_dir}" 2>/dev/null || true

    log_ok "Recordings applied and cleaned up."

    # Reload if stack is running
    if [ -f "${GENERATED_DIR}/docker-compose.yml" ]; then
        log "Reloading mock mappings..."
        cmd_reload_mocks
    else
        log "Run './devstack.sh restart' to activate the new mappings."
    fi
}

# ---------------------------------------------------------------------------
# Verify Mocks — check all mocked domains are reachable from inside the app
# ---------------------------------------------------------------------------
cmd_verify_mocks() {
    if [ ! -f "${GENERATED_DIR}/docker-compose.yml" ]; then
        log_err "DevStack is not running. Run './devstack.sh start' first."
        exit 1
    fi

    log "Verifying mock interception..."
    echo ""

    local pass=0
    local fail=0

    for mock_dir in "${DEVSTACK_DIR}"/mocks/*/; do
        [ -d "${mock_dir}" ] || continue
        local domains_file="${mock_dir}domains"
        [ -f "${domains_file}" ] || continue
        local name=$(basename "${mock_dir}")

        while IFS= read -r domain || [ -n "${domain}" ]; do
            domain=$(echo "${domain}" | tr -d '[:space:]')
            [ -z "${domain}" ] && continue
            [[ "${domain}" == \#* ]] && continue

            # Try to reach the domain from inside the app container via HTTPS
            # --no-check-certificate: we're testing routing, not cert trust
            local http_code
            http_code=$(docker compose -f "${GENERATED_DIR}/docker-compose.yml" \
                -p "${PROJECT_NAME}" \
                exec -T app sh -c \
                "wget --no-check-certificate -qS --timeout=5 -O /dev/null https://${domain}/ 2>&1 | grep -o 'HTTP/[0-9.]* [0-9]*' | tail -1" 2>/dev/null) || true

            if echo "${http_code}" | grep -qE "HTTP.*[0-9]"; then
                local status_num
                status_num=$(echo "${http_code}" | grep -o '[0-9]*$')
                if [ "${status_num}" = "404" ]; then
                    echo -e "  ${GREEN}PASS${NC}  ${domain} (${name}) — routed to WireMock (404: no mapping for /)"
                else
                    echo -e "  ${GREEN}PASS${NC}  ${domain} (${name}) — HTTP ${status_num}"
                fi
                pass=$((pass + 1))
            else
                echo -e "  ${RED}FAIL${NC}  ${domain} (${name}) — not reachable"
                fail=$((fail + 1))
            fi
        done < "${domains_file}"
    done

    echo ""
    if [ $fail -eq 0 ]; then
        log_ok "All ${pass} mocked domain(s) verified."
    else
        log_err "${fail} domain(s) failed. ${pass} passed."
        log "Check: ./devstack.sh logs web (proxy routing)"
        log "Check: ./devstack.sh status (container health)"
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Init — scaffold a new project interactively
# ---------------------------------------------------------------------------
cmd_init() {
    # TTY guard — init must be interactive
    if [ ! -t 0 ]; then
        log_err "init requires an interactive terminal"
        exit 1
    fi

    require_jq

    local manifest="${DEVSTACK_DIR}/contract/manifest.json"
    if [ ! -f "${manifest}" ]; then
        log_err "Manifest file not found at contract/manifest.json"
        exit 1
    fi

    echo ""
    log "DevStack Project Setup"
    echo ""

    # ── 1. Parse flags ────────────────────────────────────────────────────
    local preset_name=""
    local preset=""
    if [ "${1:-}" = "--preset" ] && [ -n "${2:-}" ]; then
        preset_name="$2"
        preset=$(jq -r --arg p "${preset_name}" '.presets[$p] // empty' "${manifest}")
        if [ -z "${preset}" ]; then
            log_err "Unknown preset: ${preset_name}"
            log "Available presets:"
            jq -r '.presets | to_entries[] | "  \(.key): \(.value.description)"' "${manifest}"
            exit 1
        fi
        log "Using preset: $(printf '%s' "${preset}" | jq -r '.label') — $(printf '%s' "${preset}" | jq -r '.description')"
        echo ""
    fi

    # ── 2. Project name ───────────────────────────────────────────────────
    echo -n "  Project name [myproject]: "
    read -r input_name
    local project_name="${input_name:-myproject}"

    # Validate project name format
    if ! printf '%s' "${project_name}" | grep -qE '^[a-z][a-z0-9-]*$'; then
        log_err "Invalid project name '${project_name}'. Must match [a-z][a-z0-9-]*"
        exit 1
    fi

    # ── 3. Walk categories interactively ──────────────────────────────────

    # --- App type (required, single) ---
    local app_type=""
    # Check if preset pre-selects an app
    if [ -n "${preset}" ]; then
        app_type=$(printf '%s' "${preset}" | jq -r '.selections.app[0] // empty')
    fi

    if [ -z "${app_type}" ]; then
        echo ""
        echo "  Available app types:"
        for dir in "${DEVSTACK_DIR}/templates/apps"/*/; do
            [ -d "${dir}" ] || continue
            local app_name
            app_name=$(basename "${dir}")
            local app_label
            app_label=$(jq -r --arg a "${app_name}" '.categories.app.items[$a].label // $a' "${manifest}")
            echo "    - ${app_name}  (${app_label})"
        done
        echo -n "  App type [node-express]: "
        read -r input_app
        app_type="${input_app:-node-express}"
    else
        log "  App type (from preset): ${app_type}"
    fi

    # Validate app type
    if [ ! -d "${DEVSTACK_DIR}/templates/apps/${app_type}" ]; then
        log_err "Unknown app type '${app_type}'. Available:"
        for dir in "${DEVSTACK_DIR}/templates/apps"/*/; do
            [ -d "${dir}" ] || continue
            echo "  - $(basename "${dir}")"
        done
        exit 1
    fi

    # --- Frontend (optional, single) ---
    local frontend_type=""
    if [ -n "${preset}" ]; then
        frontend_type=$(printf '%s' "${preset}" | jq -r '.selections.frontend[0] // empty')
    fi

    if [ -z "${frontend_type}" ]; then
        # Only prompt if preset doesn't specify and there are templates available
        local has_frontends=false
        for dir in "${DEVSTACK_DIR}/templates/frontends"/*/; do
            [ -d "${dir}" ] || { continue; }
            has_frontends=true
            break
        done
        if [ "${has_frontends}" = true ]; then
            echo ""
            echo "  Available frontends (or 'none'):"
            for dir in "${DEVSTACK_DIR}/templates/frontends"/*/; do
                [ -d "${dir}" ] || continue
                local fe_name
                fe_name=$(basename "${dir}")
                local fe_label
                fe_label=$(jq -r --arg f "${fe_name}" '.categories.frontend.items[$f].label // $f' "${manifest}")
                echo "    - ${fe_name}  (${fe_label})"
            done
            echo -n "  Frontend [none]: "
            read -r input_frontend
            frontend_type="${input_frontend:-none}"
        else
            frontend_type="none"
        fi
    else
        log "  Frontend (from preset): ${frontend_type}"
    fi

    # --- Database (optional, single) ---
    local db_type=""
    if [ -n "${preset}" ]; then
        db_type=$(printf '%s' "${preset}" | jq -r '.selections.database[0] // empty')
    fi

    if [ -z "${db_type}" ]; then
        echo ""
        echo "  Available databases (or 'none'):"
        for dir in "${DEVSTACK_DIR}/templates/databases"/*/; do
            [ -d "${dir}" ] || continue
            local db_name
            db_name=$(basename "${dir}")
            local db_label
            db_label=$(jq -r --arg d "${db_name}" '.categories.database.items[$d].label // $d' "${manifest}")
            echo "    - ${db_name}  (${db_label})"
        done
        echo -n "  Database [postgres]: "
        read -r input_db
        db_type="${input_db:-postgres}"
    else
        log "  Database (from preset): ${db_type}"
    fi

    # --- Services (optional, multi) ---
    local selected_services=""
    if [ -n "${preset}" ]; then
        selected_services=$(printf '%s' "${preset}" | jq -r '(.selections.services // []) | join(",")')
    fi

    if [ -z "${selected_services}" ] && [ -z "${preset}" ]; then
        local available_services=""
        for svc in $(jq -r '.categories.services.items | keys[]' "${manifest}"); do
            if [ -d "${DEVSTACK_DIR}/templates/extras/${svc}" ]; then
                available_services="${available_services} ${svc}"
            fi
        done
        if [ -n "${available_services}" ]; then
            echo ""
            echo "  Available services (comma-separated, or 'none'):"
            for svc in ${available_services}; do
                local svc_label
                svc_label=$(jq -r --arg s "${svc}" '.categories.services.items[$s].label // $s' "${manifest}")
                local svc_desc
                svc_desc=$(jq -r --arg s "${svc}" '.categories.services.items[$s].description // ""' "${manifest}")
                echo "    - ${svc}  (${svc_label}: ${svc_desc})"
            done
            echo -n "  Services [none]: "
            read -r input_services
            selected_services="${input_services:-none}"
        fi
    elif [ -n "${selected_services}" ]; then
        log "  Services (from preset): ${selected_services}"
    fi

    # --- Tooling (optional, multi) ---
    local selected_tooling=""
    if [ -n "${preset}" ]; then
        selected_tooling=$(printf '%s' "${preset}" | jq -r '(.selections.tooling // []) | join(",")')
    fi

    if [ -z "${selected_tooling}" ] && [ -z "${preset}" ]; then
        local available_tooling=""
        for tool in $(jq -r '.categories.tooling.items | keys[]' "${manifest}"); do
            # tooling items live under templates/extras/ or are virtual (like qa, qa-dashboard, devcontainer)
            if [ -d "${DEVSTACK_DIR}/templates/extras/${tool}" ] || [ "${tool}" = "qa" ] || [ "${tool}" = "qa-dashboard" ] || [ "${tool}" = "devcontainer" ]; then
                available_tooling="${available_tooling} ${tool}"
            fi
        done
        if [ -n "${available_tooling}" ]; then
            echo ""
            echo "  Available tooling (comma-separated, or 'none'):"
            for tool in ${available_tooling}; do
                local tool_label
                tool_label=$(jq -r --arg t "${tool}" '.categories.tooling.items[$t].label // $t' "${manifest}")
                local tool_desc
                tool_desc=$(jq -r --arg t "${tool}" '.categories.tooling.items[$t].description // ""' "${manifest}")
                echo "    - ${tool}  (${tool_label}: ${tool_desc})"
            done
            echo -n "  Tooling [none]: "
            read -r input_tooling
            selected_tooling="${input_tooling:-none}"
        fi
    elif [ -n "${selected_tooling}" ]; then
        log "  Tooling (from preset): ${selected_tooling}"
    fi

    # --- Observability (optional, multi) ---
    local selected_observability=""
    if [ -n "${preset}" ]; then
        selected_observability=$(printf '%s' "${preset}" | jq -r '(.selections.observability // []) | join(",")')
    fi

    if [ -z "${selected_observability}" ] && [ -z "${preset}" ]; then
        local available_obs=""
        for obs in $(jq -r '.categories.observability.items | keys[]' "${manifest}"); do
            if [ -d "${DEVSTACK_DIR}/templates/extras/${obs}" ]; then
                available_obs="${available_obs} ${obs}"
            fi
        done
        if [ -n "${available_obs}" ]; then
            echo ""
            echo "  Available observability (comma-separated, or 'none'):"
            for obs in ${available_obs}; do
                local obs_label
                obs_label=$(jq -r --arg o "${obs}" '.categories.observability.items[$o].label // $o' "${manifest}")
                local obs_desc
                obs_desc=$(jq -r --arg o "${obs}" '.categories.observability.items[$o].description // ""' "${manifest}")
                echo "    - ${obs}  (${obs_label}: ${obs_desc})"
            done
            echo -n "  Observability [none]: "
            read -r input_obs
            selected_observability="${input_obs:-none}"
        fi
    elif [ -n "${selected_observability}" ]; then
        log "  Observability (from preset): ${selected_observability}"
    fi

    # ── 4. Build JSON payload ─────────────────────────────────────────────

    # Start with base payload
    local payload
    payload=$(jq -n \
        --arg project "${project_name}" \
        --arg app "${app_type}" \
        --arg frontend "${frontend_type}" \
        --arg db "${db_type}" \
        '{
            contract: "devstrap-bootstrap",
            version: "1",
            project: $project,
            selections: {
                app: { ($app): {} }
            }
        } |
        if $frontend != "none" and $frontend != "" then .selections.frontend = { ($frontend): {} } else . end |
        if $db != "none" and $db != "" then .selections.database = { ($db): {} } else . end'
    )

    # Add multi-select categories (services, tooling, observability)
    if [ -n "${selected_services}" ] && [ "${selected_services}" != "none" ]; then
        IFS=',' read -ra svc_list <<< "${selected_services}"
        for svc in "${svc_list[@]}"; do
            svc=$(printf '%s' "${svc}" | tr -d '[:space:]')
            [ -z "${svc}" ] && continue
            payload=$(printf '%s\n' "${payload}" | jq --arg s "${svc}" '.selections.services += { ($s): {} }')
        done
    fi

    if [ -n "${selected_tooling}" ] && [ "${selected_tooling}" != "none" ]; then
        IFS=',' read -ra tool_list <<< "${selected_tooling}"
        for tool in "${tool_list[@]}"; do
            tool=$(printf '%s' "${tool}" | tr -d '[:space:]')
            [ -z "${tool}" ] && continue
            payload=$(printf '%s\n' "${payload}" | jq --arg t "${tool}" '.selections.tooling += { ($t): {} }')
        done
    fi

    if [ -n "${selected_observability}" ] && [ "${selected_observability}" != "none" ]; then
        IFS=',' read -ra obs_list <<< "${selected_observability}"
        for obs in "${obs_list[@]}"; do
            obs=$(printf '%s' "${obs}" | tr -d '[:space:]')
            [ -z "${obs}" ] && continue
            payload=$(printf '%s\n' "${payload}" | jq --arg o "${obs}" '.selections.observability += { ($o): {} }')
        done
    fi

    # ── 5. Validate payload ───────────────────────────────────────────────
    echo ""
    local errors
    errors=$(validate_bootstrap_payload "${payload}" "${manifest}") || {
        log_err "Validation failed unexpectedly"
        exit 1
    }

    if [ "$(printf '%s\n' "${errors}" | jq 'length')" -gt 0 ]; then
        log_err "Invalid configuration:"
        printf '%s\n' "${errors}" | jq -r '.[] | "  [\(.code)] \(.message)"'
        exit 1
    fi

    # ── 6. Generate via bootstrap ─────────────────────────────────────────
    log "Generating project..."
    echo ""

    if ! generate_from_bootstrap "${payload}" "${manifest}"; then
        log_err "Generation failed — check output above for details"
        exit 1
    fi

    # ── 7. Display summary ────────────────────────────────────────────────
    echo ""
    log_ok "Project initialized: ${project_name}"
    echo ""

    local response
    response=$(build_bootstrap_response "${payload}" "${manifest}")

    log "Generated into: $(printf '%s\n' "${response}" | jq -r '.project_dir')"
    echo ""
    log "Services:"
    printf '%s\n' "${response}" | jq -r '.services | to_entries[] | "  \(.key)" + (if (.value | length) > 0 then " (" + (.value | to_entries | map("\(.key)=\(.value)") | join(", ")) + ")" else "" end)'
    echo ""
    log "Next steps:"
    printf '%s\n' "${response}" | jq -r '.commands | to_entries[] | "  \(.key): \(.value)"'
    echo ""
}

# ---------------------------------------------------------------------------
# Contract Interface — PowerHouse integration (--options, --bootstrap)
# See: DEVSTRAP-POWERHOUSE-CONTRACT.md
# ---------------------------------------------------------------------------

require_jq() {
    if ! command -v jq &>/dev/null; then
        cat <<'EOF'
{"contract":"devstrap-result","version":"1","status":"error","errors":[{"code":"MISSING_JQ","message":"jq is required for contract operations. Install: https://jqlang.github.io/jq/download/"}]}
EOF
        exit 1
    fi
}

# DISCOVER: Output the options manifest as JSON to stdout
cmd_contract_options() {
    local manifest="${DEVSTACK_DIR}/contract/manifest.json"
    if [ ! -f "${manifest}" ]; then
        cat <<'EOF'
{"contract":"devstrap-result","version":"1","status":"error","errors":[{"code":"INTERNAL_ERROR","message":"Manifest file not found at contract/manifest.json"}]}
EOF
        exit 1
    fi
    if ! jq '.' "${manifest}" 2>/dev/null; then
        cat <<'EOF'
{"contract":"devstrap-result","version":"1","status":"error","errors":[{"code":"INTERNAL_ERROR","message":"Manifest file contains invalid JSON"}]}
EOF
        exit 1
    fi
}

# BOOTSTRAP: Parse args, read payload, validate, generate, respond
cmd_contract_bootstrap() {
    local config_path=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --config)
                if [[ $# -lt 2 ]]; then
                    jq -n '{contract:"devstrap-result",version:"1",status:"error",
                            errors:[{code:"INVALID_ARGS",message:"--config requires a path or - for stdin"}]}'
                    exit 1
                fi
                config_path="$2"
                shift 2
                ;;
            *)
                jq -n --arg f "$1" \
                    '{contract:"devstrap-result",version:"1",status:"error",
                      errors:[{code:"INVALID_ARGS",message:"Unknown flag: \($f). Usage: devstack.sh --bootstrap --config <path|->"}]}'
                exit 1
                ;;
        esac
    done

    if [ -z "${config_path}" ]; then
        jq -n '{contract:"devstrap-result",version:"1",status:"error",
                errors:[{code:"INVALID_ARGS",message:"--config is required. Usage: devstack.sh --bootstrap --config <path|->"}]}'
        exit 1
    fi

    # Read payload from file or stdin
    local payload
    if [ "${config_path}" = "-" ]; then
        if [ -t 0 ]; then
            jq -n '{contract:"devstrap-result",version:"1",status:"error",
                    errors:[{code:"INVALID_ARGS",message:"--config - requires piped input, but stdin is a terminal"}]}'
            exit 1
        fi
        payload=$(cat)
    else
        if [ ! -f "${config_path}" ]; then
            jq -n --arg p "${config_path}" \
                '{contract:"devstrap-result",version:"1",status:"error",
                  errors:[{code:"INVALID_ARGS",message:"Config file not found: \($p)"}]}'
            exit 1
        fi
        payload=$(cat "${config_path}")
    fi

    # Validate JSON syntax (printf avoids echo interpreting flags like -n/-e)
    if ! printf '%s\n' "${payload}" | jq '.' &>/dev/null; then
        jq -n '{contract:"devstrap-result",version:"1",status:"error",
                errors:[{code:"INVALID_JSON",message:"Config file is not valid JSON"}]}'
        exit 1
    fi

    # Load manifest
    local manifest="${DEVSTACK_DIR}/contract/manifest.json"
    if [ ! -f "${manifest}" ]; then
        jq -n '{contract:"devstrap-result",version:"1",status:"error",
                errors:[{code:"INTERNAL_ERROR",message:"Manifest file not found"}]}'
        exit 1
    fi

    # Validate payload against manifest
    local errors
    errors=$(validate_bootstrap_payload "${payload}" "${manifest}") || {
        jq -n '{contract:"devstrap-result",version:"1",status:"error",
                errors:[{code:"INTERNAL_ERROR",message:"Validation failed unexpectedly"}]}'
        exit 1
    }

    if [ "$(printf '%s\n' "${errors}" | jq 'length')" -gt 0 ]; then
        jq -n --argjson errors "${errors}" \
            '{contract:"devstrap-result",version:"1",status:"error",errors:$errors}'
        exit 1
    fi

    # Validation passed — assemble product (no Docker needed, just file copying)

    # Generate environment (all log output to stderr, stdout reserved for JSON)
    if ! generate_from_bootstrap "${payload}" "${manifest}"; then
        jq -n '{contract:"devstrap-result",version:"1",status:"error",
                errors:[{code:"GENERATION_FAILED",message:"Environment generation failed — check stderr for details"}]}'
        exit 1
    fi

    # Output success response
    build_bootstrap_response "${payload}" "${manifest}"
}

# Validate bootstrap payload against manifest. Outputs JSON array of error objects.
# All eleven contract-specified checks are performed; ALL errors are collected.
validate_bootstrap_payload() {
    local payload="$1"
    local manifest_file="$2"

    jq -n --argjson p "${payload}" --slurpfile m "${manifest_file}" '
        $m[0] as $manifest |
        [] |

        # 1. contract field
        if ($p.contract // "") != "devstrap-bootstrap" then
            . + [{code:"INVALID_CONTRACT",
                  message:"Expected contract \"devstrap-bootstrap\", got \"\($p.contract // "null")\""}]
        else . end |

        # 2. version field
        if ($p.version // "") != "1" then
            . + [{code:"INVALID_VERSION",
                  message:"Expected version \"1\", got \"\($p.version // "null")\""}]
        else . end |

        # 3. project name
        if ($p.project // "" | test("^[a-z][a-z0-9-]*$") | not) then
            . + [{code:"INVALID_PROJECT_NAME",
                  message:"Invalid project name \"\($p.project // "")\". Must match [a-z][a-z0-9-]*"}]
        else . end |

        # 4. unknown categories
        reduce (($p.selections // {}) | keys[]) as $cat (.;
            if ($manifest.categories | has($cat) | not) then
                . + [{code:"UNKNOWN_CATEGORY",
                      message:"Unknown category \"\($cat)\""}]
            else . end
        ) |

        # 5. unknown items (only within known categories; // {} guards null values)
        reduce (($p.selections // {}) | to_entries[]) as $e (.;
            if ($manifest.categories | has($e.key)) then
                reduce (($e.value // {}) | keys[]) as $item (.;
                    if ($manifest.categories[$e.key].items | has($item) | not) then
                        . + [{code:"UNKNOWN_ITEM",
                              message:"Unknown item \"\($item)\" in category \"\($e.key)\""}]
                    else . end
                )
            else . end
        ) |

        # 6. required categories must have at least one selection
        reduce ($manifest.categories | to_entries[]) as $cat (.;
            if $cat.value.required and
               ((($p.selections // {})[$cat.key] // {}) | keys | length) == 0
            then
                . + [{code:"MISSING_REQUIRED",
                      message:"Category \"\($cat.key)\" requires at least one selection"}]
            else . end
        ) |

        # 7. single-selection categories must have at most one item
        reduce ($manifest.categories | to_entries[]) as $cat (.;
            if $cat.value.selection == "single" and
               ((($p.selections // {})[$cat.key] // {}) | keys | length) > 1
            then
                . + [{code:"INVALID_SINGLE_SELECT",
                      message:"Category \"\($cat.key)\" allows only one selection, got \((($p.selections // {})[$cat.key] // {}) | keys | length)"}]
            else . end
        ) |

        # 8. requires dependencies
        # Build flat list of all selected "category.item" references
        (($p.selections // {}) | to_entries | map(
            .key as $cat | (.value // {}) | keys | map("\($cat).\(.)")
        ) | flatten) as $selected |

        reduce (($p.selections // {}) | to_entries[]) as $ce (.;
            if ($manifest.categories | has($ce.key)) then
                reduce (($ce.value // {}) | keys[]) as $item (.;
                    if ($manifest.categories[$ce.key].items | has($item)) then
                        reduce (($manifest.categories[$ce.key].items[$item].requires // [])[]) as $dep (.;
                            if ($dep | endswith(".*")) then
                                # Wildcard: any item in the dependency category
                                ($dep | split(".")[0]) as $dep_cat |
                                if ((($p.selections // {})[$dep_cat] // {}) | keys | length) == 0 then
                                    . + [{code:"MISSING_DEPENDENCY",
                                          message:"Item \"\($ce.key).\($item)\" requires at least one item from category \"\($dep_cat)\""}]
                                else . end
                            else
                                # Specific item
                                if ($selected | index($dep)) == null then
                                    . + [{code:"MISSING_DEPENDENCY",
                                          message:"Item \"\($ce.key).\($item)\" requires \"\($dep)\""}]
                                else . end
                            end
                        )
                    else . end
                )
            else . end
        ) |

        # 9. conflicts
        reduce (($p.selections // {}) | to_entries[]) as $ce (.;
            if ($manifest.categories | has($ce.key)) then
                reduce (($ce.value // {}) | keys[]) as $item (.;
                    if ($manifest.categories[$ce.key].items | has($item)) then
                        reduce (($manifest.categories[$ce.key].items[$item].conflicts // [])[]) as $conflict (.;
                            ($conflict | split(".")) as $parts |
                            if ((($p.selections // {})[$parts[0]] // {}) | has($parts[1])) then
                                . + [{code:"CONFLICT",
                                      message:"Items \"\($ce.key).\($item)\" and \"\($conflict)\" conflict"}]
                            else . end
                        )
                    else . end
                )
            else . end
        ) |

        # 10. override keys must exist in item defaults
        reduce (($p.selections // {}) | to_entries[]) as $ce (.;
            if ($manifest.categories | has($ce.key)) then
                reduce (($ce.value // {}) | to_entries[]) as $ie (.;
                    if ($manifest.categories[$ce.key].items | has($ie.key)) then
                        reduce (($ie.value.overrides // {}) | keys[]) as $key (.;
                            if (($manifest.categories[$ce.key].items[$ie.key].defaults // {}) | has($key) | not) then
                                . + [{code:"INVALID_OVERRIDE",
                                      message:"Override key \"\($key)\" does not exist in defaults for \"\($ce.key).\($ie.key)\""}]
                            else . end
                        )
                    else . end
                )
            else . end
        ) |

        # 11. port collision detection
        ([($p.selections // {} | to_entries[]) as $ce |
          ($ce.value // {} | to_entries[]) as $ie |
          select($manifest.categories[$ce.key].items[$ie.key] // null | . != null) |
          ($manifest.categories[$ce.key].items[$ie.key].defaults // {}) as $defaults |
          ($ie.value.overrides // {}) as $overrides |
          ($defaults * $overrides) as $resolved |
          ($resolved | to_entries[]) as $kv |
          select($kv.key == "port" or ($kv.key | endswith("_port"))) |
          {item: "\($ce.key).\($ie.key)", port: ($kv.value | tostring)}
        ] | group_by(.port) | map(select(length > 1))) as $collisions |
        reduce ($collisions[]) as $group (.;
            . + [{code:"PORT_CONFLICT",
                  message:"Port \($group[0].port) conflict between \"\($group | map(.item) | join("\" and \""))\""}]
        )
    '
}

# Resolve wiring rules from the manifest against the bootstrap payload.
# Outputs a JSON object of { "category.item.key": "resolved_value", ... }
# User overrides always take precedence (wiring is skipped if the target
# already has a non-empty override).
resolve_wiring() {
    local payload="$1"
    local manifest_file="$2"

    jq -n --argjson p "${payload}" --slurpfile m "${manifest_file}" '
        $m[0] as $manifest |
        $p.selections as $sel |

        # Helper: collect selected items per category as {cat: [item_keys]}
        ($sel | to_entries | map({key: .key, value: (.value // {} | keys)})
            | from_entries) as $selected |

        # Helper: build resolved defaults (manifest defaults merged with overrides)
        # for each selected item → { "cat.item": { merged_defaults } }
        reduce ($sel | to_entries[] |
            .key as $cat |
            (.value // {}) | to_entries[] |
            .key as $item | .value as $s |
            {
                key: "\($cat).\($item)",
                value: (($manifest.categories[$cat].items[$item].defaults // {})
                        * ($s.overrides // {}))
            }
        ) as $entry ({}; . + {($entry.key): $entry.value}) as $resolved |

        # Process each wiring rule
        reduce ($manifest.wiring // [] | .[]) as $rule ({};
            # Check if all "when" conditions are satisfied
            ([$rule.when[] |
                if endswith(".*") then
                    # Wildcard: any item in that category is selected
                    (split(".")[0]) as $cat |
                    (($selected[$cat] // []) | length) > 0
                else
                    # Exact match: category.item must be selected
                    (split(".") | .[0]) as $cat |
                    (split(".") | .[1]) as $item |
                    (($selected[$cat] // []) | index($item) != null)
                end
            ] | all) as $match |

            if $match then
                # Parse the "set" target: "category.item.key"
                ($rule.set | split(".")) as $parts |
                ($parts[0]) as $tgt_cat |
                ($parts[1]) as $tgt_item_raw |

                # Resolve wildcard in the set target
                (if $tgt_item_raw == "*" then
                    (($selected[$tgt_cat] // []) | sort | .[0] // null)
                else $tgt_item_raw end) as $tgt_item |

                ($parts[2]) as $tgt_key |

                if $tgt_item == null then . else
                    # Check if user already set a non-empty override for this key
                    (($sel[$tgt_cat][$tgt_item].overrides // {})[$tgt_key] // null) as $user_val |

                    if $user_val != null and ($user_val | tostring) != "" then
                        # User override takes precedence — skip this rule
                        .
                    else
                        # Resolve the template string
                        # Resolve each {category.*} and {category.*.key} placeholder
                        # Use split/join instead of gsub to avoid regex interpretation
                        ($rule.template | reduce (
                            # Find all template placeholders
                            [scan("\\{[^}]+\\}")] | unique | .[]
                        ) as $placeholder (
                            .;
                            # Strip braces
                            ($placeholder | ltrimstr("{") | rtrimstr("}")) as $ref |
                            ($ref | split(".")) as $ref_parts |
                            ($ref_parts[0]) as $ref_cat |
                            ($ref_parts[1]) as $ref_item_raw |

                            # Resolve wildcard item reference
                            (if $ref_item_raw == "*" then
                                (($selected[$ref_cat] // []) | sort | .[0] // "")
                            else $ref_item_raw end) as $ref_item |

                            if ($ref_parts | length) == 2 then
                                # {category.*} or {category.item} → the item key itself
                                split($placeholder) | join($ref_item)
                            elif ($ref_parts | length) == 3 then
                                # {category.*.key} → the resolved default value for that key
                                ($ref_parts[2]) as $ref_key |
                                ($resolved["\($ref_cat).\($ref_item)"][$ref_key]
                                    // "" | tostring) as $val |
                                split($placeholder) | join($val)
                            else . end
                        )) as $resolved_value |

                        . + {("\($tgt_cat).\($tgt_item).\($tgt_key)"): $resolved_value}
                    end
                end
            else . end
        )
    '
}

# Generate a self-contained product directory from a validated bootstrap payload.
# All output goes to stderr; stdout is reserved for the JSON response.
generate_from_bootstrap() {
    local payload="$1"
    local manifest_file="$2"

    # ── 1. Extract selections from payload ────────────────────────────────
    # (printf avoids echo interpreting flags like -n/-e in edge cases)
    local project_name app_type db_type extras
    project_name=$(printf '%s\n' "${payload}" | jq -r '.project')
    app_type=$(printf '%s\n' "${payload}" | jq -r '.selections.app | keys[0]')
    db_type=$(printf '%s\n' "${payload}" | jq -r '.selections.database // {} | keys[0] // "none"')
    # Merge services + observability + extras-backed tooling into EXTRAS
    # (tooling items like qa, qa-dashboard, wiremock, devcontainer are special-cased below)
    extras=$(printf '%s\n' "${payload}" | jq -r '
        [(.selections.services // {} | keys[]),
         (.selections.observability // {} | keys[]),
         (.selections.tooling // {} | keys[] | select(. != "qa" and . != "qa-dashboard" and . != "wiremock" and . != "devcontainer"))] | join(",")')

    # Extract frontend type
    local frontend_type
    frontend_type=$(printf '%s\n' "${payload}" | jq -r '.selections.frontend // {} | keys[0] // "none"')

    local frontend_port=5173
    if printf '%s\n' "${payload}" | jq -e '.selections.frontend.vite.overrides.port' &>/dev/null; then
        frontend_port=$(printf '%s\n' "${payload}" | jq -r '.selections.frontend.vite.overrides.port')
    fi

    # ── 2. Derive ports ───────────────────────────────────────────────────
    local db_port=3306
    case "${db_type}" in
        postgres) db_port=5432 ;;
        mariadb)  db_port=3306 ;;
    esac

    local http_port=8080
    local https_port=8443
    local test_dashboard_port=8082
    local mailpit_port=8025
    local prometheus_port=9090
    local grafana_port=3001
    local dozzle_port=9999
    local adminer_port=8083
    local swagger_port=8084
    local prism_port=4010
    local prism_spec_path="openapi.yaml"
    local nats_port=4222
    local nats_monitor_port=8222
    local minio_port=9000
    local minio_console_port=9001

    if printf '%s\n' "${payload}" | jq -e '.selections.tooling.wiremock.overrides.port' &>/dev/null; then
        https_port=$(printf '%s\n' "${payload}" | jq -r '.selections.tooling.wiremock.overrides.port')
    fi
    if printf '%s\n' "${payload}" | jq -e '.selections.tooling["qa-dashboard"].overrides.port' &>/dev/null; then
        test_dashboard_port=$(printf '%s\n' "${payload}" | jq -r '.selections.tooling["qa-dashboard"].overrides.port')
    fi
    if printf '%s\n' "${payload}" | jq -e '.selections.services.mailpit.overrides.ui_port' &>/dev/null; then
        mailpit_port=$(printf '%s\n' "${payload}" | jq -r '.selections.services.mailpit.overrides.ui_port')
    fi
    if printf '%s\n' "${payload}" | jq -e '.selections.observability.prometheus.overrides.port' &>/dev/null; then
        prometheus_port=$(printf '%s\n' "${payload}" | jq -r '.selections.observability.prometheus.overrides.port')
    fi
    if printf '%s\n' "${payload}" | jq -e '.selections.observability.grafana.overrides.port' &>/dev/null; then
        grafana_port=$(printf '%s\n' "${payload}" | jq -r '.selections.observability.grafana.overrides.port')
    fi
    if printf '%s\n' "${payload}" | jq -e '.selections.observability.dozzle.overrides.port' &>/dev/null; then
        dozzle_port=$(printf '%s\n' "${payload}" | jq -r '.selections.observability.dozzle.overrides.port')
    fi
    if printf '%s\n' "${payload}" | jq -e '.selections.tooling["db-ui"].overrides.port' &>/dev/null; then
        adminer_port=$(printf '%s\n' "${payload}" | jq -r '.selections.tooling["db-ui"].overrides.port')
    fi
    if printf '%s\n' "${payload}" | jq -e '.selections.tooling["swagger-ui"].overrides.port' &>/dev/null; then
        swagger_port=$(printf '%s\n' "${payload}" | jq -r '.selections.tooling["swagger-ui"].overrides.port')
    fi
    if printf '%s\n' "${payload}" | jq -e '.selections.tooling.prism.overrides.port' &>/dev/null; then
        prism_port=$(printf '%s\n' "${payload}" | jq -r '.selections.tooling.prism.overrides.port')
    fi
    if printf '%s\n' "${payload}" | jq -e '.selections.tooling.prism.overrides.spec_path' &>/dev/null; then
        prism_spec_path=$(printf '%s\n' "${payload}" | jq -r '.selections.tooling.prism.overrides.spec_path')
    fi
    if printf '%s\n' "${payload}" | jq -e '.selections.services.nats.overrides.client_port' &>/dev/null; then
        nats_port=$(printf '%s\n' "${payload}" | jq -r '.selections.services.nats.overrides.client_port')
    fi
    if printf '%s\n' "${payload}" | jq -e '.selections.services.nats.overrides.monitor_port' &>/dev/null; then
        nats_monitor_port=$(printf '%s\n' "${payload}" | jq -r '.selections.services.nats.overrides.monitor_port')
    fi
    if printf '%s\n' "${payload}" | jq -e '.selections.services.minio.overrides.api_port' &>/dev/null; then
        minio_port=$(printf '%s\n' "${payload}" | jq -r '.selections.services.minio.overrides.api_port')
    fi
    if printf '%s\n' "${payload}" | jq -e '.selections.services.minio.overrides.console_port' &>/dev/null; then
        minio_console_port=$(printf '%s\n' "${payload}" | jq -r '.selections.services.minio.overrides.console_port')
    fi

    # ── 3. Determine destination directory ────────────────────────────────
    local dest="${DEVSTACK_DIR}/${project_name}"
    log "Assembling product in ${dest}/" >&2

    # ── 4. Create directory structure ─────────────────────────────────────
    mkdir -p "${dest}/services"
    mkdir -p "${dest}/caddy"
    mkdir -p "${dest}/certs"
    mkdir -p "${dest}/app"
    mkdir -p "${dest}/tests/playwright"
    mkdir -p "${dest}/tests/results"
    mkdir -p "${dest}/mocks"

    # ── 5. Copy product runtime files ─────────────────────────────────────
    log "Copying product runtime files..." >&2
    if [ -f "${DEVSTACK_DIR}/product/devstack.sh" ]; then
        cp "${DEVSTACK_DIR}/product/devstack.sh" "${dest}/devstack.sh"
        chmod +x "${dest}/devstack.sh"
    else
        log_warn "product/devstack.sh not found — product runtime will be incomplete" >&2
    fi

    if [ -f "${DEVSTACK_DIR}/product/certs/generate.sh" ]; then
        cp "${DEVSTACK_DIR}/product/certs/generate.sh" "${dest}/certs/generate.sh"
    else
        log_warn "product/certs/generate.sh not found" >&2
    fi

    if [ -f "${DEVSTACK_DIR}/product/.gitignore" ]; then
        cp "${DEVSTACK_DIR}/product/.gitignore" "${dest}/.gitignore"
    fi

    # Copy product documentation (AI agent guides, service management, troubleshooting)
    if [ -d "${DEVSTACK_DIR}/product/docs" ]; then
        mkdir -p "${dest}/docs"
        cp -r "${DEVSTACK_DIR}/product/docs/." "${dest}/docs/"
        log "  Copied product docs to docs/" >&2
    fi

    # Copy product CLAUDE.md (AI agent entry point)
    if [ -f "${DEVSTACK_DIR}/product/CLAUDE.md" ]; then
        cp "${DEVSTACK_DIR}/product/CLAUDE.md" "${dest}/CLAUDE.md"
        log "  Copied CLAUDE.md" >&2
    fi

    # ── 6. Copy common service templates ──────────────────────────────────
    log "Copying common service templates..." >&2
    for common_file in cert-gen.yml tester.yml test-dashboard.yml; do
        if [ -f "${DEVSTACK_DIR}/templates/common/${common_file}" ]; then
            cp "${DEVSTACK_DIR}/templates/common/${common_file}" "${dest}/services/${common_file}"
        else
            log_warn "templates/common/${common_file} not found" >&2
        fi
    done

    # ── 7. Copy selected service templates ────────────────────────────────
    log "Copying selected service templates..." >&2

    # App template
    if [ -f "${DEVSTACK_DIR}/templates/apps/${app_type}/service.yml" ]; then
        cp "${DEVSTACK_DIR}/templates/apps/${app_type}/service.yml" "${dest}/services/app.yml"
    fi
    if [ -f "${DEVSTACK_DIR}/templates/apps/${app_type}/Dockerfile" ]; then
        cp "${DEVSTACK_DIR}/templates/apps/${app_type}/Dockerfile" "${dest}/app/Dockerfile"
    fi

    # Database template (if selected)
    if [ "${db_type}" != "none" ]; then
        if [ -f "${DEVSTACK_DIR}/templates/databases/${db_type}/service.yml" ]; then
            cp "${DEVSTACK_DIR}/templates/databases/${db_type}/service.yml" "${dest}/services/database.yml"
        fi
    fi

    # Frontend template (if selected)
    if [ "${frontend_type}" != "none" ]; then
        mkdir -p "${dest}/frontend"
        if [ -f "${DEVSTACK_DIR}/templates/frontends/${frontend_type}/service.yml" ]; then
            cp "${DEVSTACK_DIR}/templates/frontends/${frontend_type}/service.yml" "${dest}/services/frontend.yml"
        fi
        if [ -f "${DEVSTACK_DIR}/templates/frontends/${frontend_type}/Dockerfile" ]; then
            cp "${DEVSTACK_DIR}/templates/frontends/${frontend_type}/Dockerfile" "${dest}/frontend/Dockerfile"
        fi
    fi

    # Extras templates (services + observability + tooling extras)
    IFS=',' read -ra extra_list <<< "${extras}"
    for extra in "${extra_list[@]}"; do
        extra=$(printf '%s' "${extra}" | tr -d '[:space:]')
        [ -z "${extra}" ] && continue
        if [ -f "${DEVSTACK_DIR}/templates/extras/${extra}/service.yml" ]; then
            cp "${DEVSTACK_DIR}/templates/extras/${extra}/service.yml" "${dest}/services/${extra}.yml"
            log "  Copied service: ${extra}" >&2
        fi
        # Copy extra config files to product config/ directory
        if [ -d "${DEVSTACK_DIR}/templates/extras/${extra}/provisioning" ]; then
            mkdir -p "${dest}/config/${extra}"
            cp -r "${DEVSTACK_DIR}/templates/extras/${extra}/provisioning" "${dest}/config/${extra}/provisioning"
            log "  Copied config: ${extra}/provisioning" >&2
        fi
        if [ -f "${DEVSTACK_DIR}/templates/extras/${extra}/prometheus.yml" ]; then
            mkdir -p "${dest}/config"
            cp "${DEVSTACK_DIR}/templates/extras/${extra}/prometheus.yml" "${dest}/config/prometheus.yml"
            log "  Copied config: prometheus.yml" >&2
        fi
    done

    # ── 8. Write project.env ──────────────────────────────────────────────
    log "Writing project.env..." >&2
    cat > "${dest}/project.env" <<ENV
# Project configuration
PROJECT_NAME=${project_name}
COMPOSE_PROJECT_NAME=${project_name}
NETWORK_SUBNET=172.28.0.0/24

# Application
APP_TYPE=${app_type}
APP_SOURCE=./app
APP_INIT_SCRIPT=./app/init.sh
FRONTEND_SOURCE=./frontend

# Ports
HTTP_PORT=${http_port}
HTTPS_PORT=${https_port}
TEST_DASHBOARD_PORT=${test_dashboard_port}

# Database
DB_TYPE=${db_type}
DB_PORT=${db_port}
DB_NAME=${project_name}
DB_USER=${project_name}
DB_PASSWORD=secret
DB_ROOT_PASSWORD=root

# Frontend
FRONTEND_TYPE=${frontend_type}
FRONTEND_PORT=${frontend_port}
FRONTEND_API_PREFIX=/api
ENV

    # Create .env symlink (Docker Compose reads .env by default)
    ln -sf project.env "${dest}/.env"

    # Append conditional port vars only when the service is selected
    {
        if printf '%s\n' "${payload}" | jq -e '.selections.services.mailpit' &>/dev/null; then
            printf 'MAILPIT_PORT=%s\n' "${mailpit_port}"
        fi
        if printf '%s\n' "${payload}" | jq -e '.selections.observability.prometheus' &>/dev/null; then
            printf 'PROMETHEUS_PORT=%s\n' "${prometheus_port}"
        fi
        if printf '%s\n' "${payload}" | jq -e '.selections.observability.grafana' &>/dev/null; then
            printf 'GRAFANA_PORT=%s\n' "${grafana_port}"
        fi
        if printf '%s\n' "${payload}" | jq -e '.selections.observability.dozzle' &>/dev/null; then
            printf 'DOZZLE_PORT=%s\n' "${dozzle_port}"
        fi
        if printf '%s\n' "${payload}" | jq -e '.selections.tooling["db-ui"]' &>/dev/null; then
            printf 'ADMINER_PORT=%s\n' "${adminer_port}"
        fi
        if printf '%s\n' "${payload}" | jq -e '.selections.tooling["swagger-ui"]' &>/dev/null; then
            printf 'SWAGGER_PORT=%s\n' "${swagger_port}"
        fi
        if printf '%s\n' "${payload}" | jq -e '.selections.tooling.prism' &>/dev/null; then
            printf 'PRISM_PORT=%s\n' "${prism_port}"
            printf 'PRISM_SPEC_PATH=%s\n' "${prism_spec_path}"
        fi
        if printf '%s\n' "${payload}" | jq -e '.selections.services.nats' &>/dev/null; then
            printf 'NATS_PORT=%s\n' "${nats_port}"
            printf 'NATS_MONITOR_PORT=%s\n' "${nats_monitor_port}"
        fi
        if printf '%s\n' "${payload}" | jq -e '.selections.services.minio' &>/dev/null; then
            printf 'MINIO_PORT=%s\n' "${minio_port}"
            printf 'MINIO_CONSOLE_PORT=%s\n' "${minio_console_port}"
        fi
    } >> "${dest}/project.env"

    # ── 9. Write per-service env files ────────────────────────────────────
    if [ "${db_type}" != "none" ]; then
        log "Writing database.env..." >&2
        local db_connection="mysql"
        case "${db_type}" in
            postgres) db_connection="pgsql" ;;
            mariadb)  db_connection="mysql" ;;
        esac

        cat > "${dest}/services/database.env" <<DBENV
DB_NAME=${project_name}
DB_USER=${project_name}
DB_PASSWORD=secret
DB_ROOT_PASSWORD=root
DB_CONNECTION=${db_connection}
DBENV
    fi

    # ── 10. Resolve wiring → append to project.env ────────────────────────
    local wiring_json
    wiring_json=$(resolve_wiring "${payload}" "${manifest_file}")

    if [ -n "${wiring_json}" ] && [ "${wiring_json}" != "{}" ]; then
        log "Resolving auto-wiring rules..." >&2

        local wiring_envs
        wiring_envs=$(printf '%s\n' "${wiring_json}" | jq -r '
            to_entries[] |
            (.key | split(".") | last | ascii_upcase) as $var |
            "\($var)=\(.value)"
        ')

        if [ -n "${wiring_envs}" ]; then
            {
                echo ""
                echo "# Auto-wiring (resolved from manifest rules)"
                printf '%s\n' "${wiring_envs}"
            } >> "${dest}/project.env"
            log "  Wrote wiring env vars to project.env" >&2
        fi
    fi

    # ── 11. Assemble docker-compose.yml ───────────────────────────────────
    log "Assembling docker-compose.yml..." >&2

    local includes=""

    # Always present: cert-gen
    includes="${includes}  - path: services/cert-gen.yml
    project_directory: .
"

    # Always present: app
    includes="${includes}  - path: services/app.yml
    project_directory: .
"

    # caddy.yml — generated at runtime by product devstack.sh
    includes="${includes}  - path: services/caddy.yml
    project_directory: .
"

    # Database (conditional)
    if [ "${db_type}" != "none" ]; then
        includes="${includes}  - path: services/database.yml
    project_directory: .
    env_file: services/database.env
"
    fi

    # Frontend (conditional)
    if [ "${frontend_type}" != "none" ]; then
        includes="${includes}  - path: services/frontend.yml
    project_directory: .
"
    fi

    # Extras
    IFS=',' read -ra extra_list <<< "${extras}"
    for extra in "${extra_list[@]}"; do
        extra=$(printf '%s' "${extra}" | tr -d '[:space:]')
        [ -z "${extra}" ] && continue
        includes="${includes}  - path: services/${extra}.yml
    project_directory: .
"
    done

    # Wiremock (generated at runtime by product devstack.sh — only if wiremock selected)
    if printf '%s\n' "${payload}" | jq -e '.selections.tooling.wiremock' &>/dev/null; then
        includes="${includes}  - path: services/wiremock.yml
    project_directory: .
"
    fi

    # Always present: tester
    includes="${includes}  - path: services/tester.yml
    project_directory: .
"

    # Always present: test-dashboard
    includes="${includes}  - path: services/test-dashboard.yml
    project_directory: .
"

    # Write the compose file
    cat > "${dest}/docker-compose.yml" <<COMPOSE
include:
${includes}
networks:
  devstack-internal:
    driver: bridge
    ipam:
      config:
        - subnet: \${NETWORK_SUBNET}
COMPOSE

    # ── 12. Scaffold mocks (if wiremock selected) ─────────────────────────
    if printf '%s\n' "${payload}" | jq -e '.selections.tooling.wiremock' &>/dev/null; then
        log "Scaffolding mock example..." >&2
        mkdir -p "${dest}/mocks/example-api/mappings"
        cat > "${dest}/mocks/example-api/domains" <<'MOCK_DOMAINS'
api.example.com
MOCK_DOMAINS
        cat > "${dest}/mocks/example-api/mappings/example.json" <<'MOCK_MAPPING'
{
    "name": "example-api — status endpoint",
    "request": {
        "method": "GET",
        "url": "/v1/status"
    },
    "response": {
        "status": 200,
        "headers": {
            "Content-Type": "application/json"
        },
        "jsonBody": {
            "service": "example-api",
            "status": "ok",
            "mocked": true
        }
    }
}
MOCK_MAPPING
    fi

    # ── 13. Scaffold tests ────────────────────────────────────────────────
    log "Scaffolding test infrastructure..." >&2
    cat > "${dest}/tests/playwright/package.json" <<'TEST_PKG'
{
  "name": "devstack-tests",
  "version": "1.0.0",
  "devDependencies": {
    "@playwright/test": "1.52.0"
  }
}
TEST_PKG
    cat > "${dest}/tests/playwright/playwright.config.ts" <<'TEST_CFG'
import { defineConfig } from '@playwright/test';

export default defineConfig({
    testDir: '.',
    testMatch: '**/*.spec.ts',
    timeout: 30000,
    retries: 0,
    workers: 1,
    use: {
        baseURL: process.env.BASE_URL || 'http://web',
        ignoreHTTPSErrors: true,
        screenshot: 'on',
    },
    reporter: [
        ['html', { outputFolder: process.env.PLAYWRIGHT_HTML_REPORT || '/results/report', open: 'never' }],
        ['json', { outputFile: process.env.PLAYWRIGHT_JSON_OUTPUT_FILE || '/results/results.json' }],
        ['list'],
    ],
    outputDir: '/results/artifacts',
});
TEST_CFG

    # ── 14. Create app/init.sh scaffold ───────────────────────────────────
    cat > "${dest}/app/init.sh" <<'INIT_SH'
#!/bin/sh
echo "[init] App initialization starting..."
# Add your setup steps here (install deps, run migrations, seed data)
echo "[init] Done."
INIT_SH
    chmod +x "${dest}/app/init.sh"

    # Create placeholder OpenAPI spec if swagger-ui is selected
    if printf '%s\n' "${payload}" | jq -e '.selections.tooling["swagger-ui"]' &>/dev/null; then
        mkdir -p "${dest}/app/docs"
        cat > "${dest}/app/docs/openapi.json" <<'SPEC'
{
  "openapi": "3.0.0",
  "info": {
    "title": "API",
    "version": "0.1.0"
  },
  "paths": {}
}
SPEC
        log "  Created app/docs/openapi.json placeholder" >&2
    fi

    # ── 15. Create frontend/package.json (if frontend selected) ───────────
    if [ "${frontend_type}" != "none" ]; then
        log "Scaffolding frontend directory..." >&2
        cat > "${dest}/frontend/package.json" <<FRONTPKG
{
  "name": "${project_name}-frontend",
  "private": true,
  "version": "0.0.0",
  "type": "module",
  "scripts": {
    "dev": "vite",
    "build": "vite build"
  },
  "devDependencies": {
    "vite": "^6.0.0"
  }
}
FRONTPKG
    fi

    # ── 16. Devcontainer (if selected) ────────────────────────────────────
    if printf '%s\n' "${payload}" | jq -e '.selections.tooling.devcontainer' &>/dev/null; then
        local devcontainer_src="${DEVSTACK_DIR}/templates/apps/${app_type}/.devcontainer"
        if [ -d "${devcontainer_src}" ]; then
            log "Copying devcontainer configuration..." >&2
            mkdir -p "${dest}/.devcontainer"
            cp -r "${devcontainer_src}/." "${dest}/.devcontainer/"
        fi
    fi

    log_ok "Product assembled in ${dest}/" >&2
    return 0
}

# Build the JSON success response: resolved services + commands + wiring
build_bootstrap_response() {
    local payload="$1"
    local manifest_file="$2"

    # Resolve wiring to include in the response
    local wiring_json
    wiring_json=$(resolve_wiring "${payload}" "${manifest_file}")
    if [ -z "${wiring_json}" ]; then
        wiring_json='{}'
    fi

    local project_name
    project_name=$(printf '%s\n' "${payload}" | jq -r '.project')

    jq -n --argjson p "${payload}" --slurpfile m "${manifest_file}" \
           --argjson wiring "${wiring_json}" \
           --arg project_dir "./${project_name}" '
        $m[0] as $manifest |

        # Resolved services: manifest defaults merged with user overrides
        ($p.selections | to_entries | map(
            .key as $cat |
            (.value // {}) | to_entries | map(
                .key as $item |
                .value as $sel |
                {
                    key: $item,
                    value: (
                        ($manifest.categories[$cat].items[$item].defaults // {}) *
                        ($sel.overrides // {})
                    )
                }
            )
        ) | flatten | from_entries) as $services |

        {
            contract: "devstrap-result",
            version: "1",
            status: "ok",
            project_dir: $project_dir,
            services: $services,
            commands: {
                start: "./devstack.sh start",
                stop: "./devstack.sh stop",
                test: "./devstack.sh test",
                logs: "./devstack.sh logs"
            }
        } + (if ($wiring | length) > 0 then {wiring: $wiring} else {} end)
    '
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    # Handle contract flags and init first — these do not require project.env
    case "${1:-}" in
        --options)
            require_jq
            cmd_contract_options
            exit $?
            ;;
        --bootstrap)
            require_jq
            shift
            cmd_contract_bootstrap "$@"
            exit $?
            ;;
        init)
            shift
            cmd_init "$@"
            exit $?
            ;;
    esac

    check_docker
    load_config

    local command="${1:-help}"
    shift 2>/dev/null || true

    case "${command}" in
        start)        cmd_start "$@" ;;
        stop)         cmd_stop "$@" ;;
        restart)      cmd_restart "$@" ;;
        test)         cmd_test "$@" ;;
        shell)        cmd_shell "$@" ;;
        status)       cmd_status "$@" ;;
        logs)         cmd_logs "$@" ;;
        generate)     cmd_generate "$@" ;;
        mocks)        cmd_mocks "$@" ;;
        reload-mocks)      cmd_reload_mocks "$@" ;;
        new-mock)          cmd_new_mock "$@" ;;
        record)            cmd_record "$@" ;;
        apply-recording)   cmd_apply_recording "$@" ;;
        verify-mocks)      cmd_verify_mocks "$@" ;;
        help|--help|-h)
            echo ""
            echo "DevStack — Container-first development with transparent mock interception"
            echo ""
            echo "Usage: ./devstack.sh <command> [options]"
            echo ""
            echo "Stack:"
            echo "  start                       Build and start the full stack"
            echo "  stop                        Stop and remove everything (clean slate)"
            echo "  restart                     Stop, then start (clean rebuild)"
            echo "  status                      Show container status and health"
            echo "  logs [service]              Tail logs (default: all services)"
            echo "  shell [service]             Shell into a container (default: app)"
            echo ""
            echo "Testing:"
            echo "  test [filter]               Run Playwright tests (optional grep filter)"
            echo ""
            echo "Mocks:"
            echo "  mocks                       List configured mock services and domains"
            echo "  new-mock <name> <domain>    Scaffold a new mock service"
            echo "  reload-mocks                Hot-reload mock mappings (no restart needed)"
            echo "  record <mock-name>          Record real API responses as mock mappings"
            echo "  apply-recording <mock-name> Apply recorded mappings into mock (with path fixup)"
            echo "  verify-mocks                Check all mocked domains are reachable"
            echo ""
            echo "Config:"
            echo "  init [--preset <name>]      Interactive project setup (or use a preset)"
            echo "  generate                    Regenerate config files without starting"
            echo "  help                        Show this help"
            echo ""
            echo "Contract (PowerHouse integration):"
            echo "  --options                   Output available options as JSON manifest"
            echo "  --bootstrap --config <path> Generate environment from JSON selections (- for stdin)"
            echo ""
            echo "Configuration: project.env"
            echo "Mock services:  mocks/<name>/domains + mocks/<name>/mappings/*.json"
            echo ""
            ;;
        *)
            log_err "Unknown command: ${command}"
            log "Run './devstack.sh help' for usage."
            exit 1
            ;;
    esac
}

main "$@"
