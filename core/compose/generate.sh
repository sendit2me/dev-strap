#!/bin/bash
# =============================================================================
# Docker Compose Generator
# =============================================================================
# Assembles a complete docker-compose.yml from:
#   - project.env (core settings)
#   - templates/apps/{APP_TYPE}/  (app service definition)
#   - templates/databases/{DB_TYPE}/ (database service)
#   - templates/extras/{name}/ (extra services)
#   - mocks/*/domains (network aliases for DNS interception)
#
# Output: .generated/docker-compose.yml
# =============================================================================

set -euo pipefail

DEVSTACK_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
OUTPUT_DIR="${DEVSTACK_DIR}/.generated"
OUTPUT_FILE="${OUTPUT_DIR}/docker-compose.yml"

source "${DEVSTACK_DIR}/project.env"

mkdir -p "${OUTPUT_DIR}"

# ---------------------------------------------------------------------------
# Collect all mocked domains for DNS aliases on the web container
# ---------------------------------------------------------------------------
ALL_MOCK_DOMAINS=()
WIREMOCK_MAPPING_VOLUMES=""
WIREMOCK_FILES_VOLUMES=""
if [ -d "${DEVSTACK_DIR}/mocks" ]; then
    for mock_dir in "${DEVSTACK_DIR}"/mocks/*/; do
        [ -d "${mock_dir}" ] || continue
        mock_name=$(basename "${mock_dir}")
        domains_file="${mock_dir}domains"
        mappings_dir="${mock_dir}mappings"
        files_dir="${mock_dir}__files"

        if [ -f "${domains_file}" ]; then
            while IFS= read -r domain || [ -n "${domain}" ]; do
                domain=$(echo "${domain}" | tr -d '[:space:]')
                [ -z "${domain}" ] && continue
                [[ "${domain}" == \#* ]] && continue
                ALL_MOCK_DOMAINS+=("${domain}")
            done < "${domains_file}"
        fi

        if [ -d "${mappings_dir}" ]; then
            WIREMOCK_MAPPING_VOLUMES="${WIREMOCK_MAPPING_VOLUMES}      - ${mappings_dir}:/home/wiremock/mappings/${mock_name}:ro
"
        fi

        if [ -d "${files_dir}" ]; then
            WIREMOCK_FILES_VOLUMES="${WIREMOCK_FILES_VOLUMES}      - ${files_dir}:/home/wiremock/__files/${mock_name}:ro
"
        fi
    done
fi

# ---------------------------------------------------------------------------
# Collect domains.txt for cert-gen container
# ---------------------------------------------------------------------------
DOMAINS_TXT="${OUTPUT_DIR}/domains.txt"
> "${DOMAINS_TXT}"
for domain in "${ALL_MOCK_DOMAINS[@]}"; do
    echo "${domain}" >> "${DOMAINS_TXT}"
done

# ---------------------------------------------------------------------------
# Build network aliases YAML for the web container
# ---------------------------------------------------------------------------
WEB_ALIASES=""
if [ ${#ALL_MOCK_DOMAINS[@]} -gt 0 ]; then
    for domain in "${ALL_MOCK_DOMAINS[@]}"; do
        WEB_ALIASES="${WEB_ALIASES}          - ${domain}
"
    done
fi

# ---------------------------------------------------------------------------
# Build extras services
# ---------------------------------------------------------------------------
EXTRAS_SERVICES=""
EXTRAS_DEPENDS=""
IFS=',' read -ra EXTRA_LIST <<< "${EXTRAS:-}"
for extra in "${EXTRA_LIST[@]}"; do
    extra=$(echo "${extra}" | tr -d '[:space:]')
    [ -z "${extra}" ] && continue
    extra_file="${DEVSTACK_DIR}/templates/extras/${extra}/service.yml"
    if [ -f "${extra_file}" ]; then
        EXTRAS_SERVICES="${EXTRAS_SERVICES}
$(cat "${extra_file}" | \
            sed "s|\${PROJECT_NAME}|${PROJECT_NAME}|g" | \
            sed "s|\${DB_NAME}|${DB_NAME}|g" | \
            sed "s|\${DB_USER}|${DB_USER}|g" | \
            sed "s|\${DB_PASSWORD}|${DB_PASSWORD}|g" | \
            sed "s|\${MAILPIT_PORT}|${MAILPIT_PORT:-8025}|g")"
        EXTRAS_DEPENDS="${EXTRAS_DEPENDS}
      ${extra}:
        condition: service_healthy"
    else
        echo "[compose-gen] WARNING: No template found for extra '${extra}'"
    fi
done

# ---------------------------------------------------------------------------
# Build database service
# ---------------------------------------------------------------------------
DB_SERVICE=""
DB_DEPENDS=""
DB_VOLUMES=""
if [ "${DB_TYPE}" != "none" ]; then
    db_template="${DEVSTACK_DIR}/templates/databases/${DB_TYPE}/service.yml"
    if [ -f "${db_template}" ]; then
        DB_SERVICE=$(cat "${db_template}" | \
            sed "s|\${PROJECT_NAME}|${PROJECT_NAME}|g" | \
            sed "s|\${DB_NAME}|${DB_NAME}|g" | \
            sed "s|\${DB_USER}|${DB_USER}|g" | \
            sed "s|\${DB_PASSWORD}|${DB_PASSWORD}|g" | \
            sed "s|\${DB_ROOT_PASSWORD}|${DB_ROOT_PASSWORD}|g")
        DB_DEPENDS="
      db:
        condition: service_healthy"
        DB_VOLUMES="
  ${PROJECT_NAME}-db-data:"
    else
        echo "[compose-gen] WARNING: No template found for database '${DB_TYPE}'"
    fi
fi

# ---------------------------------------------------------------------------
# Derive DB_PORT from DB_TYPE
# ---------------------------------------------------------------------------
case "${DB_TYPE}" in
    postgres) DB_PORT=5432 ;;
    mariadb)  DB_PORT=3306 ;;
    *)        DB_PORT=3306 ;;
esac

# ---------------------------------------------------------------------------
# App-type-specific volumes
# ---------------------------------------------------------------------------
APP_VOLUMES=""
if [ "${APP_TYPE}" = "go" ]; then
    APP_VOLUMES="
  ${PROJECT_NAME}-go-modules:"
fi

# ---------------------------------------------------------------------------
# Build app service from template
# ---------------------------------------------------------------------------
APP_SERVICE=""
# Resolve APP_SOURCE to absolute path (relative to DEVSTACK_DIR)
APP_SOURCE_ABS="${DEVSTACK_DIR}/${APP_SOURCE#./}"
app_template="${DEVSTACK_DIR}/templates/apps/${APP_TYPE}/service.yml"
if [ -f "${app_template}" ]; then
    APP_SERVICE=$(cat "${app_template}" | \
        sed "s|\${PROJECT_NAME}|${PROJECT_NAME}|g" | \
        sed "s|\${APP_SOURCE}|${APP_SOURCE_ABS}|g" | \
        sed "s|\${DB_TYPE}|${DB_TYPE}|g" | \
        sed "s|\${DB_PORT}|${DB_PORT}|g" | \
        sed "s|\${DB_NAME}|${DB_NAME}|g" | \
        sed "s|\${DB_USER}|${DB_USER}|g" | \
        sed "s|\${DB_PASSWORD}|${DB_PASSWORD}|g" | \
        sed "s|\${DB_ROOT_PASSWORD}|${DB_ROOT_PASSWORD}|g")
else
    echo "[compose-gen] ERROR: No app template found at ${app_template}"
    exit 1
fi

# ---------------------------------------------------------------------------
# Assemble docker-compose.yml
# ---------------------------------------------------------------------------
cat > "${OUTPUT_FILE}" <<COMPOSE_HEAD
# =============================================================================
# AUTO-GENERATED by devstack — do not edit manually
# Regenerated on every \`devstack.sh start\`
# =============================================================================

services:

  # ---------------------------------------------------------------------------
  # Certificate Generator — runs once, creates certs volume
  # ---------------------------------------------------------------------------
  cert-gen:
    image: eclipse-temurin:17-alpine
    container_name: ${PROJECT_NAME}-cert-gen
    volumes:
      - ${PROJECT_NAME}-certs:/certs
      - ${DEVSTACK_DIR}/core/certs/generate.sh:/scripts/generate.sh:ro
      - ${OUTPUT_DIR}/domains.txt:/config/domains.txt:ro
    environment:
      - PROJECT_NAME=${PROJECT_NAME}
    entrypoint: ["sh", "/scripts/generate.sh"]
    networks:
      - ${PROJECT_NAME}-internal

  # ---------------------------------------------------------------------------
  # Application
  # ---------------------------------------------------------------------------
${APP_SERVICE}

  # ---------------------------------------------------------------------------
  # Web Server (Nginx) — reverse proxy + mock API interceptor
  # ---------------------------------------------------------------------------
  web:
    image: nginx:alpine
    container_name: ${PROJECT_NAME}-web
    ports:
      - "${HTTP_PORT}:80"
      - "${HTTPS_PORT}:443"
    volumes:
      - ${OUTPUT_DIR}/nginx.conf:/etc/nginx/nginx.conf:ro
      - ${PROJECT_NAME}-certs:/etc/nginx/certs:ro
      - ${DEVSTACK_DIR}/tests/results:/var/www/html/public/test-results:ro
COMPOSE_HEAD

# Add app source volume mount for web if PHP (serves static files)
if [ "${APP_TYPE}" = "php-laravel" ]; then
    cat >> "${OUTPUT_FILE}" <<COMPOSE_WEB_PHP
      - ${APP_SOURCE_ABS}:/var/www/html:ro
COMPOSE_WEB_PHP
fi

cat >> "${OUTPUT_FILE}" <<COMPOSE_WEB_NET
    depends_on:
      cert-gen:
        condition: service_completed_successfully
      app:
        condition: service_started${DB_DEPENDS}
    networks:
      ${PROJECT_NAME}-internal:
        aliases:
          - ${PROJECT_NAME}.local
${WEB_ALIASES}
    healthcheck:
      test: ["CMD", "wget", "--spider", "-q", "http://127.0.0.1/"]
      interval: 5s
      timeout: 3s
      retries: 20

COMPOSE_WEB_NET

# ---------------------------------------------------------------------------
# WireMock — mock API responses
# ---------------------------------------------------------------------------
if [ ${#ALL_MOCK_DOMAINS[@]} -gt 0 ]; then
    cat >> "${OUTPUT_FILE}" <<COMPOSE_WIREMOCK
  # ---------------------------------------------------------------------------
  # WireMock — serves mock API responses
  # ---------------------------------------------------------------------------
  wiremock:
    image: wiremock/wiremock:latest
    container_name: ${PROJECT_NAME}-wiremock
    command: >
      --port 8080
      --verbose
      --global-response-templating
    volumes:
${WIREMOCK_MAPPING_VOLUMES}${WIREMOCK_FILES_VOLUMES}      - ${PROJECT_NAME}-certs:/home/wiremock/certs:ro
    depends_on:
      cert-gen:
        condition: service_completed_successfully
    networks:
      - ${PROJECT_NAME}-internal
    healthcheck:
      test: ["CMD", "wget", "-qO", "/dev/null", "http://localhost:8080/__admin/"]
      interval: 5s
      timeout: 3s
      retries: 10

COMPOSE_WIREMOCK
fi

# ---------------------------------------------------------------------------
# Database
# ---------------------------------------------------------------------------
if [ -n "${DB_SERVICE}" ]; then
    cat >> "${OUTPUT_FILE}" <<COMPOSE_DB
  # ---------------------------------------------------------------------------
  # Database
  # ---------------------------------------------------------------------------
${DB_SERVICE}

COMPOSE_DB
fi

# ---------------------------------------------------------------------------
# Extras (redis, mailpit, etc.)
# ---------------------------------------------------------------------------
if [ -n "${EXTRAS_SERVICES}" ]; then
    cat >> "${OUTPUT_FILE}" <<COMPOSE_EXTRAS
  # ---------------------------------------------------------------------------
  # Extra Services
  # ---------------------------------------------------------------------------
${EXTRAS_SERVICES}

COMPOSE_EXTRAS
fi

# ---------------------------------------------------------------------------
# Test Runner (Playwright)
# ---------------------------------------------------------------------------
cat >> "${OUTPUT_FILE}" <<COMPOSE_TESTER
  # ---------------------------------------------------------------------------
  # Test Runner — Playwright in container
  # ---------------------------------------------------------------------------
  tester:
    image: mcr.microsoft.com/playwright:v1.52.0-noble
    container_name: ${PROJECT_NAME}-tester
    working_dir: /tests
    volumes:
      - ${DEVSTACK_DIR}/tests/playwright:/tests
      - ${DEVSTACK_DIR}/tests/results:/results
      - ${PROJECT_NAME}-certs:/certs:ro
    environment:
      - BASE_URL=https://web:443
      - NODE_EXTRA_CA_CERTS=/certs/ca.crt
      - PLAYWRIGHT_HTML_REPORT=/results/report
    depends_on:
      web:
        condition: service_healthy
    entrypoint: ["tail", "-f", "/dev/null"]
    networks:
      - ${PROJECT_NAME}-internal

  # ---------------------------------------------------------------------------
  # Test Dashboard — view reports in browser
  # ---------------------------------------------------------------------------
  test-dashboard:
    image: busybox:latest
    container_name: ${PROJECT_NAME}-test-dashboard
    ports:
      - "${TEST_DASHBOARD_PORT}:8080"
    volumes:
      - ${DEVSTACK_DIR}/tests/results:/results:ro
    working_dir: /results
    command: httpd -f -p 8080 -h /results
    networks:
      - ${PROJECT_NAME}-internal

COMPOSE_TESTER

# ---------------------------------------------------------------------------
# Networks and Volumes
# ---------------------------------------------------------------------------
cat >> "${OUTPUT_FILE}" <<COMPOSE_FOOTER
# =============================================================================
# Networks
# =============================================================================
networks:
  ${PROJECT_NAME}-internal:
    driver: bridge
    ipam:
      config:
        - subnet: ${NETWORK_SUBNET}

# =============================================================================
# Volumes
# =============================================================================
volumes:
  ${PROJECT_NAME}-certs:${DB_VOLUMES}${APP_VOLUMES}
COMPOSE_FOOTER

echo "[compose-gen] Generated ${OUTPUT_FILE}"
echo "[compose-gen] Services: cert-gen, app, web, wiremock, tester, test-dashboard"
[ -n "${DB_SERVICE}" ] && echo "[compose-gen] Database: ${DB_TYPE}"
[ -n "${EXTRAS_SERVICES}" ] && echo "[compose-gen] Extras: ${EXTRAS}"
