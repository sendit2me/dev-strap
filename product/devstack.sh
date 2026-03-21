#!/bin/bash
# =============================================================================
# DevStack CLI (Product Runtime)
# =============================================================================
# Manages the development stack for this project.
#
# Usage:
#   ./devstack.sh start              Start the stack
#   ./devstack.sh stop               Stop (preserve volumes)
#   ./devstack.sh stop --clean       Stop and remove everything
#   ./devstack.sh restart            Restart (preserve volumes)
#   ./devstack.sh restart --clean    Full teardown and rebuild
#   ./devstack.sh test [filter]      Run Playwright tests
#   ./devstack.sh shell [svc]        Shell into a container (default: app)
#   ./devstack.sh status             Show container status
#   ./devstack.sh logs [svc]         Tail logs (default: all)
#   ./devstack.sh mocks              List mock services
#   ./devstack.sh new-mock <n> <d>   Scaffold a new mock
#   ./devstack.sh reload-mocks       Hot-reload mock mappings
#   ./devstack.sh record <mock>      Record real API responses
#   ./devstack.sh apply-recording <m> Apply recorded mappings
#   ./devstack.sh verify-mocks       Verify mock DNS interception
#
# Prerequisites: Docker and Docker Compose v2
# =============================================================================

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

log()      { echo -e "${BLUE}[devstack]${NC} $*"; }
log_ok()   { echo -e "${GREEN}[devstack]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[devstack]${NC} $*"; }
log_err()  { echo -e "${RED}[devstack]${NC} $*"; }

check_docker() {
    if ! command -v docker &>/dev/null; then
        log_err "Docker is not installed. Install: https://docs.docker.com/get-docker/"
        exit 1
    fi
    if ! docker compose version &>/dev/null; then
        log_err "Docker Compose v2 is required. Install: https://docs.docker.com/compose/install/"
        exit 1
    fi
}

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

load_config() {
    if [ ! -f "${PROJECT_DIR}/project.env" ]; then
        log_err "project.env not found in ${PROJECT_DIR}"
        exit 1
    fi
    source "${PROJECT_DIR}/project.env"
}

validate_config() {
    local errors=()

    [ -z "${PROJECT_NAME:-}" ] && errors+=("PROJECT_NAME is required")
    [ -z "${APP_TYPE:-}" ] && errors+=("APP_TYPE is required")

    if [ -n "${PROJECT_NAME:-}" ]; then
        if ! echo "${PROJECT_NAME}" | grep -qE '^[a-z][a-z0-9-]*$'; then
            errors+=("PROJECT_NAME '${PROJECT_NAME}' invalid (must match [a-z][a-z0-9-]*)")
        fi
    fi

    local port_vars=(HTTP_PORT HTTPS_PORT)
    for var in "${port_vars[@]}"; do
        local val="${!var:-}"
        if [ -n "${val}" ] && ! echo "${val}" | grep -qE '^[0-9]+$'; then
            errors+=("${var} '${val}' must be a number")
        fi
    done

    if [ ${#errors[@]} -gt 0 ]; then
        log_err "project.env validation failed:"
        for err in "${errors[@]}"; do
            log_err "  - ${err}"
        done
        exit 1
    fi
}

# ---------------------------------------------------------------------------
# Domain collection + Caddyfile generation
# ---------------------------------------------------------------------------

collect_domains() {
    local domains_file="${PROJECT_DIR}/domains.txt"
    : > "${domains_file}"

    if [ -d "${PROJECT_DIR}/mocks" ]; then
        for mock_dir in "${PROJECT_DIR}"/mocks/*/; do
            [ -d "${mock_dir}" ] || continue
            [ -f "${mock_dir}domains" ] || continue
            while IFS= read -r domain || [ -n "${domain}" ]; do
                domain=$(echo "${domain}" | tr -d '[:space:]')
                [ -z "${domain}" ] && continue
                [[ "${domain}" == \#* ]] && continue
                echo "${domain}" >> "${domains_file}"
            done < "${mock_dir}domains"
        done
    fi
}

generate_caddyfile() {
    local caddyfile="${PROJECT_DIR}/caddy/Caddyfile"
    mkdir -p "${PROJECT_DIR}/caddy"

    local mock_domains=()
    if [ -f "${PROJECT_DIR}/domains.txt" ]; then
        while IFS= read -r domain || [ -n "${domain}" ]; do
            domain=$(echo "${domain}" | tr -d '[:space:]')
            [ -z "${domain}" ] && continue
            mock_domains+=("${domain}")
        done < "${PROJECT_DIR}/domains.txt"
    fi

    log "Generating Caddyfile (${#mock_domains[@]} mocked domains)..."

    # Global options
    cat > "${caddyfile}" <<'EOF'
{
    auto_https off
}

EOF

    # App server block
    if [ "${APP_TYPE}" = "php-laravel" ]; then
        cat >> "${caddyfile}" <<CADDY
localhost:80, localhost:443, ${PROJECT_NAME}.local:80, ${PROJECT_NAME}.local:443 {
    tls /certs/server.crt /certs/server.key
    root * /var/www/html/public
    php_fastcgi app:9000
    file_server
    handle_path /test-results/* {
        root * /srv/test-results
        file_server browse
    }
}

CADDY
    elif [ -n "${FRONTEND_TYPE:-}" ] && [ "${FRONTEND_TYPE}" != "none" ]; then
        cat >> "${caddyfile}" <<CADDY
localhost:80, localhost:443, ${PROJECT_NAME}.local:80, ${PROJECT_NAME}.local:443 {
    tls /certs/server.crt /certs/server.key
    handle ${FRONTEND_API_PREFIX:-/api}/* {
        reverse_proxy app:3000
    }
    handle_path /test-results/* {
        root * /srv/test-results
        file_server browse
    }
    handle {
        reverse_proxy frontend:${FRONTEND_PORT:-5173}
    }
}

CADDY
    else
        cat >> "${caddyfile}" <<CADDY
localhost:80, localhost:443, ${PROJECT_NAME}.local:80, ${PROJECT_NAME}.local:443 {
    tls /certs/server.crt /certs/server.key
    reverse_proxy app:3000
    handle_path /test-results/* {
        root * /srv/test-results
        file_server browse
    }
}

CADDY
    fi

    # Mock domain site block
    if [ ${#mock_domains[@]} -gt 0 ]; then
        local domain_list=""
        for domain in "${mock_domains[@]}"; do
            [ -n "${domain_list}" ] && domain_list="${domain_list}, "
            domain_list="${domain_list}${domain}:443"
        done
        cat >> "${caddyfile}" <<CADDY
${domain_list} {
    tls /certs/server.crt /certs/server.key
    reverse_proxy wiremock:8080 {
        header_up X-Original-Host {http.request.host}
        header_up X-Real-IP {remote_host}
        header_up X-Forwarded-Proto {scheme}
    }
}
CADDY
    fi
}

# ---------------------------------------------------------------------------
# Dynamic service generation
# ---------------------------------------------------------------------------

generate_caddy_service() {
    local service_file="${PROJECT_DIR}/services/caddy.yml"
    mkdir -p "${PROJECT_DIR}/services"

    log "Generating caddy service definition..."

    # Collect mock domain aliases from domains.txt
    local aliases=""
    if [ -f "${PROJECT_DIR}/domains.txt" ]; then
        while IFS= read -r domain || [ -n "${domain}" ]; do
            domain=$(echo "${domain}" | tr -d '[:space:]')
            [ -z "${domain}" ] && continue
            aliases="${aliases}
          - ${domain}"
        done < "${PROJECT_DIR}/domains.txt"
    fi

    # Determine conditional volumes and depends_on
    local extra_volumes=""
    local extra_depends=""

    if [ "${APP_TYPE}" = "php-laravel" ]; then
        extra_volumes="
      - \${APP_SOURCE:-./app}:/var/www/html:cached"
    fi

    if [ -f "${PROJECT_DIR}/services/frontend.yml" ]; then
        extra_depends="
      frontend:
        condition: service_started"
    fi

    cat > "${service_file}" <<CADDY_SVC
services:
  web:
    image: caddy:2-alpine
    container_name: \${PROJECT_NAME}-web
    ports:
      - "\${HTTP_PORT}:80"
      - "\${HTTPS_PORT}:443"
    volumes:
      - ./caddy/Caddyfile:/etc/caddy/Caddyfile:ro
      - devstack-certs:/certs:ro
      - ./tests/results:/srv/test-results:ro${extra_volumes}
    depends_on:
      cert-gen:
        condition: service_completed_successfully
      app:
        condition: service_started${extra_depends}
    networks:
      devstack-internal:
        aliases:
          - \${PROJECT_NAME}.local${aliases}
    healthcheck:
      test: ["CMD", "wget", "--spider", "-q", "http://127.0.0.1:80/"]
      interval: 5s
      timeout: 3s
      retries: 20
CADDY_SVC
}

generate_wiremock_service() {
    local service_file="${PROJECT_DIR}/services/wiremock.yml"
    mkdir -p "${PROJECT_DIR}/services"

    # Only generate if mocks directory has content
    if [ ! -d "${PROJECT_DIR}/mocks" ]; then
        return 0
    fi

    local has_mocks=0
    for mock_dir in "${PROJECT_DIR}"/mocks/*/; do
        [ -d "${mock_dir}" ] || continue
        has_mocks=1
        break
    done

    if [ "${has_mocks}" = "0" ]; then
        return 0
    fi

    log "Generating wiremock service definition..."

    # Build volume mounts from mocks/*/mappings
    local mock_volumes=""
    for mock_dir in "${PROJECT_DIR}"/mocks/*/; do
        [ -d "${mock_dir}" ] || continue
        local name
        name=$(basename "${mock_dir}")
        mock_volumes="${mock_volumes}
      - ./mocks/${name}/mappings:/home/wiremock/mappings/${name}:ro"
    done

    cat > "${service_file}" <<WIREMOCK_SVC
services:
  wiremock:
    image: wiremock/wiremock:latest
    container_name: \${PROJECT_NAME}-wiremock
    command: --port 8080 --verbose --global-response-templating
    volumes:${mock_volumes}
      - devstack-certs:/home/wiremock/certs:ro
    depends_on:
      cert-gen:
        condition: service_completed_successfully
    networks:
      - devstack-internal
    healthcheck:
      test: ["CMD", "wget", "-qO", "/dev/null", "http://localhost:8080/__admin/"]
      interval: 5s
      timeout: 3s
      retries: 10
WIREMOCK_SVC
}

# ---------------------------------------------------------------------------
# Cleanup helpers
# ---------------------------------------------------------------------------

_clean_test_artifacts() {
    if [ -d "${PROJECT_DIR}/tests/results" ] || \
       [ -d "${PROJECT_DIR}/tests/playwright/node_modules" ]; then
        docker run --rm \
            -v "${PROJECT_DIR}/tests:/data" \
            alpine sh -c "rm -rf /data/results/* /data/playwright/node_modules \
                /data/playwright/package-lock.json" 2>/dev/null || true
    fi
}

_clean_recordings() {
    local has_recordings=0
    for rec_dir in "${PROJECT_DIR}"/mocks/*/recordings; do
        [ -d "${rec_dir}" ] || continue
        has_recordings=1
        docker run --rm \
            -v "${rec_dir}:/data" \
            alpine rm -rf /data/mappings /data/__files 2>/dev/null || true
        rmdir "${rec_dir}" 2>/dev/null || true
    done
    if [ "${has_recordings}" = "1" ]; then
        log "Cleaned up recording directories"
    fi
}

# ---------------------------------------------------------------------------
# Start
# ---------------------------------------------------------------------------
cmd_start() {
    validate_config

    log "Starting DevStack for ${PROJECT_NAME}..."

    mkdir -p "${PROJECT_DIR}/tests/results"

    # Collect mock domains and generate Caddyfile + dynamic services
    collect_domains
    generate_caddyfile
    generate_caddy_service
    generate_wiremock_service

    # Build and start
    log "Building and starting services..."
    docker compose -p "${PROJECT_NAME}" up --build -d

    # Wait for cert-gen to complete
    log "Waiting for certificate generation..."
    docker compose -p "${PROJECT_NAME}" wait cert-gen 2>/dev/null || true

    # Wait for database health (if db service exists)
    if docker compose -p "${PROJECT_NAME}" ps --format json 2>/dev/null \
        | grep -q '"Service":"db"'; then
        log "Waiting for database..."
        local retries=0
        local max_retries=30
        while [ $retries -lt $max_retries ]; do
            local health
            health=$(docker inspect --format='{{.State.Health.Status}}' \
                "${PROJECT_NAME}-db" 2>/dev/null || echo "unknown")
            if [ "${health}" = "healthy" ]; then
                break
            fi
            retries=$((retries + 1))
            sleep 2
        done
        if [ $retries -ge $max_retries ]; then
            log_warn "Database health check timed out — continuing anyway"
        fi
    fi

    # Run init script if configured
    if [ -n "${APP_INIT_SCRIPT:-}" ] && [ -f "${PROJECT_DIR}/${APP_INIT_SCRIPT}" ]; then
        log "Running app init script..."
        docker compose -p "${PROJECT_NAME}" \
            exec -T app sh < "${PROJECT_DIR}/${APP_INIT_SCRIPT}" || \
            log_warn "Init script failed — check './devstack.sh logs app'"
    fi

    # Summary
    echo ""
    log_ok "============================================="
    log_ok " DevStack is running: ${PROJECT_NAME}"
    log_ok "============================================="
    echo ""
    log "Application:     http://localhost:${HTTP_PORT}"
    log "Application SSL: https://localhost:${HTTPS_PORT}"

    if [ -n "${TEST_DASHBOARD_PORT:-}" ]; then
        log "Test Dashboard:  http://localhost:${TEST_DASHBOARD_PORT}"
    fi

    # List mocked services
    local mock_count=0
    if [ -d "${PROJECT_DIR}/mocks" ]; then
        for mock_dir in "${PROJECT_DIR}"/mocks/*/; do
            [ -d "${mock_dir}" ] || continue
            [ -f "${mock_dir}domains" ] || continue
            mock_count=$((mock_count + 1))
        done
    fi
    if [ $mock_count -gt 0 ]; then
        echo ""
        log "Mocked services (${mock_count}):"
        for mock_dir in "${PROJECT_DIR}"/mocks/*/; do
            [ -d "${mock_dir}" ] || continue
            [ -f "${mock_dir}domains" ] || continue
            local name=$(basename "${mock_dir}")
            local domains=$(cat "${mock_dir}domains" | tr '\n' ', ' | sed 's/,$//')
            log "  ${CYAN}${name}${NC} -> ${domains}"
        done
    fi

    if [ -n "${DB_TYPE:-}" ] && [ "${DB_TYPE}" != "none" ]; then
        echo ""
        log "Database (${DB_TYPE}): ${DB_NAME:-$PROJECT_NAME} (user: ${DB_USER:-$PROJECT_NAME})"
    fi

    echo ""
    log "Commands:"
    log "  ./devstack.sh test           Run tests"
    log "  ./devstack.sh shell          Shell into app container"
    log "  ./devstack.sh logs           Tail all logs"
    log "  ./devstack.sh stop           Stop (volumes preserved)"
    log "  ./devstack.sh stop --clean   Stop and remove everything"
    echo ""
}

# ---------------------------------------------------------------------------
# Stop
# ---------------------------------------------------------------------------
cmd_stop() {
    local clean=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --clean) clean=1; shift ;;
            *) log_err "Unknown flag: $1"; exit 1 ;;
        esac
    done

    log "Stopping DevStack..."

    if [ "${clean}" = "1" ]; then
        docker compose -p "${PROJECT_NAME}" down -v --remove-orphans 2>/dev/null || true
        _clean_test_artifacts
        _clean_recordings
        log_ok "DevStack stopped. All containers, volumes, and artifacts removed."
    else
        docker compose -p "${PROJECT_NAME}" down --remove-orphans 2>/dev/null || true
        log_ok "DevStack stopped. Volumes preserved."
        log "Run './devstack.sh stop --clean' to also remove database and cache volumes."
    fi
}

# ---------------------------------------------------------------------------
# Restart
# ---------------------------------------------------------------------------
cmd_restart() {
    cmd_stop "$@"
    cmd_start
}

# ---------------------------------------------------------------------------
# Test
# ---------------------------------------------------------------------------
cmd_test() {
    local filter="${1:-}"
    local run_id
    run_id="$(date +%Y%m%d-%H%M%S)"

    local results_dir="${PROJECT_DIR}/tests/results/${run_id}"
    mkdir -p "${results_dir}"

    log "Running tests (run: ${run_id})..."

    local pw_cmd="cd /tests && npm install --silent 2>/dev/null && npx playwright test"
    if [ -n "${filter}" ]; then
        pw_cmd="${pw_cmd} --grep '${filter}'"
        log "Filter: ${filter}"
    fi
    pw_cmd="${pw_cmd} --reporter=html,json"
    pw_cmd="${pw_cmd} --output=/results/${run_id}/artifacts"

    local exit_code=0
    docker compose -p "${PROJECT_NAME}" \
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

    if [ -n "${TEST_DASHBOARD_PORT:-}" ]; then
        log "Report:    http://localhost:${TEST_DASHBOARD_PORT}/${run_id}/report/index.html"
        log "Artifacts: http://localhost:${TEST_DASHBOARD_PORT}/${run_id}/artifacts/"
        log "JSON:      http://localhost:${TEST_DASHBOARD_PORT}/${run_id}/results.json"
    fi

    return $exit_code
}

# ---------------------------------------------------------------------------
# Shell
# ---------------------------------------------------------------------------
cmd_shell() {
    local service="${1:-app}"
    log "Opening shell in '${service}' container..."
    docker compose -p "${PROJECT_NAME}" exec "${service}" bash 2>/dev/null || \
    docker compose -p "${PROJECT_NAME}" exec "${service}" sh
}

# ---------------------------------------------------------------------------
# Status
# ---------------------------------------------------------------------------
cmd_status() {
    docker compose -p "${PROJECT_NAME}" \
        ps --format "table {{.Name}}\t{{.Status}}\t{{.Ports}}"
}

# ---------------------------------------------------------------------------
# Logs
# ---------------------------------------------------------------------------
cmd_logs() {
    local service="${1:-}"
    if [ -n "${service}" ]; then
        docker compose -p "${PROJECT_NAME}" logs -f "${service}"
    else
        docker compose -p "${PROJECT_NAME}" logs -f
    fi
}

# ---------------------------------------------------------------------------
# Mocks -- list configured mock services
# ---------------------------------------------------------------------------
cmd_mocks() {
    echo ""
    log "Configured mock services:"
    echo ""

    if [ ! -d "${PROJECT_DIR}/mocks" ]; then
        log_warn "No mocks directory found."
        return 0
    fi

    local count=0
    for mock_dir in "${PROJECT_DIR}"/mocks/*/; do
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
            for mapping in "${mappings_dir}"/*.json; do
                [ -f "${mapping}" ] || continue
                local mapping_name
                mapping_name=$(grep -o '"name"[[:space:]]*:[[:space:]]*"[^"]*"' "${mapping}" 2>/dev/null \
                    | head -1 | sed 's/"name"[[:space:]]*:[[:space:]]*"//;s/"$//')
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
        log "Create one: ./devstack.sh new-mock stripe api.stripe.com"
    fi

    log "To add a mock:"
    log "  1. ./devstack.sh new-mock <name> <domain>"
    log "  2. Add WireMock JSON mappings to mocks/<name>/mappings/"
    log "  3. Run './devstack.sh restart'"
}

# ---------------------------------------------------------------------------
# Reload Mocks
# ---------------------------------------------------------------------------
cmd_reload_mocks() {
    log "Reloading mock mappings..."

    local response
    response=$(docker compose -p "${PROJECT_NAME}" \
        exec -T wiremock wget -qO- --post-data='' \
        "http://localhost:8080/__admin/mappings/reset" 2>&1) || {
        log_err "Failed to reload mocks. Is WireMock running?"
        log "Try: ./devstack.sh status"
        return 1
    }

    local mappings_response count
    mappings_response=$(docker compose -p "${PROJECT_NAME}" \
        exec -T wiremock wget -qO- \
        "http://localhost:8080/__admin/mappings" 2>/dev/null) || true
    count=$(echo "${mappings_response}" | grep -o '"total" *: *[0-9]*' | grep -o '[0-9]*' | head -1)
    count="${count:-0}"

    log_ok "Mock mappings reloaded (${count} mappings loaded)."
    log "Note: New domains require a restart (./devstack.sh restart)"
}

# ---------------------------------------------------------------------------
# New Mock
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

    local mock_dir="${PROJECT_DIR}/mocks/${name}"

    if [ -d "${mock_dir}" ]; then
        log_err "Mock '${name}' already exists at ${mock_dir}"
        exit 1
    fi

    mkdir -p "${mock_dir}/mappings"
    echo "${domain}" > "${mock_dir}/domains"

    cat > "${mock_dir}/mappings/example.json" <<MOCK_EOF
{
    "name": "${name} -- example endpoint",
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
    log "  1. Edit mocks/${name}/mappings/example.json (or add more)"
    log "  2. Run './devstack.sh restart' to pick up the new domain"
    log "  After first restart, use './devstack.sh reload-mocks' for mapping changes"
}

# ---------------------------------------------------------------------------
# Record
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
        log "  # Make requests -- real responses are captured"
        log "  # Press Ctrl+C to stop recording"
        log "  # Review, then: ./devstack.sh apply-recording stripe"
        exit 1
    fi

    local mock_dir="${PROJECT_DIR}/mocks/${name}"
    if [ ! -d "${mock_dir}" ]; then
        log_err "Mock '${name}' not found. Create it first:"
        log "  ./devstack.sh new-mock ${name} api.${name}.com"
        exit 1
    fi

    local domains_file="${mock_dir}/domains"
    if [ ! -f "${domains_file}" ]; then
        log_err "No domains file in mocks/${name}/."
        exit 1
    fi

    local target_domain
    target_domain=$(head -1 "${domains_file}" | tr -d '[:space:]')
    if [ -z "${target_domain}" ]; then
        log_err "domains file is empty in mocks/${name}/"
        exit 1
    fi

    local record_dir="${mock_dir}/recordings"

    if [ -d "${record_dir}" ]; then
        docker run --rm -v "${record_dir}:/data" \
            alpine rm -rf /data/mappings /data/__files 2>/dev/null || true
    fi
    mkdir -p "${record_dir}/mappings" "${record_dir}/__files"

    log "Starting recording for '${name}' (proxying to https://${target_domain})..."
    log ""
    log "How it works:"
    log "  1. Temporary WireMock recorder proxies to the REAL ${target_domain}"
    log "  2. Make requests through your app as normal"
    log "  3. Press Ctrl+C when done"
    log ""
    log_warn "This calls the REAL API. Valid credentials required; may incur costs."
    echo ""

    docker run --rm -it \
        --name "${PROJECT_NAME}-recorder" \
        --network "${PROJECT_NAME}_devstack-internal" \
        -v "${record_dir}/mappings:/home/wiremock/mappings" \
        -v "${record_dir}/__files:/home/wiremock/__files" \
        wiremock/wiremock:latest \
        --port 8080 \
        --proxy-all "https://${target_domain}" \
        --record-mappings \
        --verbose || true

    local captured
    captured=$(docker run --rm -v "${record_dir}:/data" alpine sh -c \
        'find /data/mappings -name "*.json" 2>/dev/null | wc -l' 2>/dev/null)
    captured=$(echo "${captured}" | tr -d '[:space:]')

    if [ "${captured}" -gt 0 ]; then
        echo ""
        log_ok "Recorded ${captured} mapping(s)."
        echo ""
        docker run --rm -v "${record_dir}:/data" alpine sh -c \
            'for f in /data/mappings/*.json; do echo "  - $(basename "$f")"; done' 2>/dev/null
        echo ""
        log "Next steps:"
        log "  1. Review:  ls mocks/${name}/recordings/mappings/"
        log "  2. Apply:   ./devstack.sh apply-recording ${name}"
        log "  3. Reload:  ./devstack.sh reload-mocks"
        log ""
        log_warn "Review recordings before applying -- they may contain API keys."
    else
        echo ""
        log_warn "No mappings captured. Did you make requests while recording?"
    fi
}

# ---------------------------------------------------------------------------
# Apply Recording
# ---------------------------------------------------------------------------
cmd_apply_recording() {
    local name="${1:-}"

    if [ -z "${name}" ]; then
        log_err "Usage: ./devstack.sh apply-recording <mock-name>"
        exit 1
    fi

    local mock_dir="${PROJECT_DIR}/mocks/${name}"
    local record_dir="${mock_dir}/recordings"

    if [ ! -d "${record_dir}/mappings" ]; then
        log_err "No recordings found for '${name}'."
        log "Run './devstack.sh record ${name}' first."
        exit 1
    fi

    local count
    count=$(docker run --rm -v "${record_dir}:/data" alpine sh -c \
        'find /data/mappings -name "*.json" 2>/dev/null | wc -l' 2>/dev/null)
    count=$(echo "${count}" | tr -d '[:space:]')

    if [ "${count}" -eq 0 ]; then
        log_warn "No recorded mappings to apply."
        exit 0
    fi

    log "Applying ${count} recording(s) to mocks/${name}/..."

    mkdir -p "${mock_dir}/mappings" "${mock_dir}/__files"

    docker run --rm \
        -v "${record_dir}:/src:ro" \
        -v "${mock_dir}:/dst" \
        -e "MOCK_NAME=${name}" \
        alpine sh -c '
            for f in /src/mappings/*.json; do
                [ -f "$f" ] || continue
                fname=$(basename "$f")
                if grep -q "bodyFileName" "$f"; then
                    sed "s|\"bodyFileName\" *: *\"|\"bodyFileName\" : \"${MOCK_NAME}/|" "$f" \
                        > "/dst/mappings/${fname}"
                else
                    cp "$f" "/dst/mappings/${fname}"
                fi
            done
            for f in /src/__files/*; do
                [ -f "$f" ] || continue
                cp "$f" "/dst/__files/$(basename "$f")"
            done
            chown -R '"$(id -u):$(id -g)"' /dst/mappings/ /dst/__files/ 2>/dev/null || true
        '

    log_ok "Applied ${count} recording(s):"
    for f in "${mock_dir}/mappings"/mapping-*.json; do
        [ -f "${f}" ] || continue
        log "  - $(basename "${f}")"
    done
    echo ""

    docker run --rm -v "${record_dir}:/data" \
        alpine rm -rf /data/mappings /data/__files 2>/dev/null || true
    rmdir "${record_dir}" 2>/dev/null || true

    log_ok "Recordings applied and cleaned up."

    # Reload if stack is running
    if docker compose -p "${PROJECT_NAME}" ps --quiet 2>/dev/null | grep -q .; then
        log "Reloading mock mappings..."
        cmd_reload_mocks
    else
        log "Run './devstack.sh restart' to activate the new mappings."
    fi
}

# ---------------------------------------------------------------------------
# Verify Mocks
# ---------------------------------------------------------------------------
cmd_verify_mocks() {
    log "Verifying mock interception..."
    echo ""

    local pass=0
    local fail=0

    for mock_dir in "${PROJECT_DIR}"/mocks/*/; do
        [ -d "${mock_dir}" ] || continue
        local domains_file="${mock_dir}domains"
        [ -f "${domains_file}" ] || continue
        local name=$(basename "${mock_dir}")

        while IFS= read -r domain || [ -n "${domain}" ]; do
            domain=$(echo "${domain}" | tr -d '[:space:]')
            [ -z "${domain}" ] && continue
            [[ "${domain}" == \#* ]] && continue

            local http_code
            http_code=$(docker compose -p "${PROJECT_NAME}" \
                exec -T app sh -c \
                "wget --no-check-certificate -qS --timeout=5 -O /dev/null https://${domain}/ 2>&1 \
                 | grep -o 'HTTP/[0-9.]* [0-9]*' | tail -1" 2>/dev/null) || true

            if echo "${http_code}" | grep -qE "HTTP.*[0-9]"; then
                local status_num
                status_num=$(echo "${http_code}" | grep -o '[0-9]*$')
                if [ "${status_num}" = "404" ]; then
                    echo -e "  ${GREEN}PASS${NC}  ${domain} (${name}) -- routed to WireMock (404: no mapping for /)"
                else
                    echo -e "  ${GREEN}PASS${NC}  ${domain} (${name}) -- HTTP ${status_num}"
                fi
                pass=$((pass + 1))
            else
                echo -e "  ${RED}FAIL${NC}  ${domain} (${name}) -- not reachable"
                fail=$((fail + 1))
            fi
        done < "${domains_file}"
    done

    echo ""
    if [ $fail -eq 0 ]; then
        log_ok "All ${pass} mocked domain(s) verified."
    else
        log_err "${fail} domain(s) failed. ${pass} passed."
        log "Check: ./devstack.sh logs caddy"
        log "Check: ./devstack.sh status"
        return 1
    fi
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
        start)            cmd_start "$@" ;;
        stop)             cmd_stop "$@" ;;
        restart)          cmd_restart "$@" ;;
        test)             cmd_test "$@" ;;
        shell)            cmd_shell "$@" ;;
        status)           cmd_status "$@" ;;
        logs)             cmd_logs "$@" ;;
        mocks)            cmd_mocks "$@" ;;
        reload-mocks)     cmd_reload_mocks "$@" ;;
        new-mock)         cmd_new_mock "$@" ;;
        record)           cmd_record "$@" ;;
        apply-recording)  cmd_apply_recording "$@" ;;
        verify-mocks)     cmd_verify_mocks "$@" ;;
        help|--help|-h)
            echo ""
            echo "DevStack -- Container-first development with transparent mock interception"
            echo ""
            echo "Usage: ./devstack.sh <command> [options]"
            echo ""
            echo "Stack:"
            echo "  start                       Build and start the stack"
            echo "  stop                        Stop (volumes preserved)"
            echo "  stop --clean                Stop and remove everything"
            echo "  restart                     Restart (volumes preserved)"
            echo "  restart --clean             Full teardown and rebuild"
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
            echo "  apply-recording <mock-name> Apply recorded mappings into mock"
            echo "  verify-mocks                Check all mocked domains are reachable"
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
