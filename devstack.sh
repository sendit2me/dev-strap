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
    docker compose -f "${GENERATED_DIR}/docker-compose.yml" \
        -p "${PROJECT_NAME}" \
        build --quiet 2>/dev/null || true

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

    # Run init script if configured
    if [ -n "${APP_INIT_SCRIPT:-}" ] && [ -f "${DEVSTACK_DIR}/${APP_INIT_SCRIPT}" ]; then
        log "Running app init script..."
        docker compose -f "${GENERATED_DIR}/docker-compose.yml" \
            -p "${PROJECT_NAME}" \
            exec -T app sh -c "/app/init.sh" 2>/dev/null || \
        docker compose -f "${GENERATED_DIR}/docker-compose.yml" \
            -p "${PROJECT_NAME}" \
            exec -T app bash -c "$(cat "${DEVSTACK_DIR}/${APP_INIT_SCRIPT}")" 2>/dev/null || \
        log_warn "Init script failed or app container not ready yet"
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
    log "  4. Run './devstack.sh stop && ./devstack.sh start'"
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
        start)    cmd_start "$@" ;;
        stop)     cmd_stop "$@" ;;
        test)     cmd_test "$@" ;;
        shell)    cmd_shell "$@" ;;
        status)   cmd_status "$@" ;;
        logs)     cmd_logs "$@" ;;
        generate) cmd_generate "$@" ;;
        mocks)    cmd_mocks "$@" ;;
        help|--help|-h)
            echo ""
            echo "DevStack — Container-first development with transparent mock interception"
            echo ""
            echo "Usage: ./devstack.sh <command> [options]"
            echo ""
            echo "Commands:"
            echo "  start          Build and start the full stack"
            echo "  stop           Stop and remove everything (clean slate)"
            echo "  test [filter]  Run Playwright tests (optional grep filter)"
            echo "  shell [svc]    Shell into a container (default: app)"
            echo "  status         Show container status and health"
            echo "  logs [svc]     Tail logs (default: all services)"
            echo "  generate       Regenerate config files without starting"
            echo "  mocks          List configured mock services and domains"
            echo "  help           Show this help"
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
