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

    # 1. Generate nginx.conf
    log "Generating nginx.conf..."
    bash "${DEVSTACK_DIR}/core/nginx/generate-conf.sh"

    # 2. Generate docker-compose.yml
    log "Generating docker-compose.yml..."
    bash "${DEVSTACK_DIR}/core/compose/generate.sh"

    log_ok "Configuration generated in ${GENERATED_DIR}/"
    log "  - nginx.conf"
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
        log "Check: ./devstack.sh logs web (nginx routing)"
        log "Check: ./devstack.sh status (container health)"
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Init — scaffold a new project interactively
# ---------------------------------------------------------------------------
cmd_init() {
    echo ""
    log "DevStack Project Setup"
    echo ""

    # Check if already configured
    if [ -d "${DEVSTACK_DIR}/mocks" ] && [ "$(ls -A "${DEVSTACK_DIR}/mocks" 2>/dev/null)" ]; then
        log_warn "This directory already has mocks configured."
        log "Run './devstack.sh start' to use the existing config."
        log "Or delete mocks/ and app/ to start fresh."
        exit 1
    fi

    # Interactive prompts (with defaults)
    echo -n "  Project name [myproject]: "
    read -r input_name
    local proj_name="${input_name:-myproject}"

    echo -n "  App type (node-express, php-laravel, go) [node-express]: "
    read -r input_type
    local app_type="${input_type:-node-express}"

    # Validate app type
    if [ ! -d "${DEVSTACK_DIR}/templates/apps/${app_type}" ]; then
        log_err "Unknown app type '${app_type}'. Available:"
        ls -1 "${DEVSTACK_DIR}/templates/apps/"
        exit 1
    fi

    echo -n "  Database (mariadb, postgres, none) [mariadb]: "
    read -r input_db
    local db_type="${input_db:-mariadb}"

    echo -n "  Extra services (comma-separated: redis, mailpit) [redis]: "
    read -r input_extras
    local extras="${input_extras:-redis}"

    echo -n "  HTTP port [8080]: "
    read -r input_port
    local http_port="${input_port:-8080}"

    # Write project.env
    cat > "${DEVSTACK_DIR}/project.env" <<INIT_ENV
# =============================================================================
# DevStack Project Configuration
# Generated by: ./devstack.sh init
# =============================================================================

PROJECT_NAME=${proj_name}
NETWORK_SUBNET=172.28.0.0/24

APP_TYPE=${app_type}
APP_SOURCE=./app
APP_INIT_SCRIPT=./app/init.sh

HTTP_PORT=${http_port}
HTTPS_PORT=$((http_port + 363))
TEST_DASHBOARD_PORT=$((http_port + 2))
MAILPIT_PORT=8025

DB_TYPE=${db_type}
DB_NAME=${proj_name}
DB_USER=${proj_name}
DB_PASSWORD=secret
DB_ROOT_PASSWORD=root

EXTRAS=${extras}
INIT_ENV

    # Create app directory with template Dockerfile
    mkdir -p "${DEVSTACK_DIR}/app"
    if [ ! -f "${DEVSTACK_DIR}/app/Dockerfile" ]; then
        cp "${DEVSTACK_DIR}/templates/apps/${app_type}/Dockerfile" "${DEVSTACK_DIR}/app/Dockerfile"
    fi

    # Create init.sh
    if [ ! -f "${DEVSTACK_DIR}/app/init.sh" ]; then
        cat > "${DEVSTACK_DIR}/app/init.sh" <<'INIT_SH'
#!/bin/sh
echo "[init] App initialization starting..."
# Add your setup steps here (install deps, run migrations, seed data)
echo "[init] Done."
INIT_SH
        chmod +x "${DEVSTACK_DIR}/app/init.sh"
    fi

    # Create mocks directory
    mkdir -p "${DEVSTACK_DIR}/mocks"

    # Create tests directory
    mkdir -p "${DEVSTACK_DIR}/tests/playwright"
    if [ ! -f "${DEVSTACK_DIR}/tests/playwright/playwright.config.ts" ]; then
        cat > "${DEVSTACK_DIR}/tests/playwright/package.json" <<'TEST_PKG'
{
  "name": "devstack-tests",
  "version": "1.0.0",
  "devDependencies": {
    "@playwright/test": "1.52.0"
  }
}
TEST_PKG
        cat > "${DEVSTACK_DIR}/tests/playwright/playwright.config.ts" <<'TEST_CFG'
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
    fi

    echo ""
    log_ok "Project initialized: ${proj_name}"
    echo ""
    log "Created:"
    log "  project.env        — project configuration"
    log "  app/Dockerfile     — container build (from ${app_type} template)"
    log "  app/init.sh        — startup script (edit to add migrations, etc.)"
    log "  tests/playwright/  — test config"
    echo ""
    log "Next steps:"
    log "  1. Add your app code to app/"
    log "  2. Add mocked services: ./devstack.sh new-mock stripe api.stripe.com"
    log "  3. Start: ./devstack.sh start"
    echo ""
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
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
        init)              cmd_init "$@" ;;
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
            echo "  init                        Interactive project setup (scaffolds project.env, app/, etc.)"
            echo "  generate                    Regenerate config files without starting"
            echo "  help                        Show this help"
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
