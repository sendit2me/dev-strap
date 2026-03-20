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
# Resolve APP_SOURCE to absolute path (needed by both app and extras templates)
# ---------------------------------------------------------------------------
APP_SOURCE_ABS="${DEVSTACK_DIR}/${APP_SOURCE#./}"

FRONTEND_SOURCE_ABS=""
if [ -n "${FRONTEND_TYPE:-}" ] && [ "${FRONTEND_TYPE}" != "none" ]; then
    FRONTEND_SOURCE_ABS="${DEVSTACK_DIR}/${FRONTEND_SOURCE#./}"
fi

# ---------------------------------------------------------------------------
# Build extras services
# ---------------------------------------------------------------------------
EXTRAS_SERVICES=""
EXTRAS_DEPENDS=""
EXTRAS_VOLUMES=""
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
            sed "s|\${MAILPIT_PORT}|${MAILPIT_PORT:-8025}|g" | \
            sed "s|\${DEVSTACK_DIR}|${DEVSTACK_DIR}|g" | \
            sed "s|\${PROMETHEUS_PORT}|${PROMETHEUS_PORT:-9090}|g" | \
            sed "s|\${GRAFANA_PORT}|${GRAFANA_PORT:-3001}|g" | \
            sed "s|\${DOZZLE_PORT}|${DOZZLE_PORT:-9999}|g" | \
            sed "s|\${NATS_PORT}|${NATS_PORT:-4222}|g" | \
            sed "s|\${NATS_MONITOR_PORT}|${NATS_MONITOR_PORT:-8222}|g" | \
            sed "s|\${MINIO_PORT}|${MINIO_PORT:-9000}|g" | \
            sed "s|\${MINIO_CONSOLE_PORT}|${MINIO_CONSOLE_PORT:-9001}|g" | \
            sed "s|\${ADMINER_PORT}|${ADMINER_PORT:-8083}|g" | \
            sed "s|\${SWAGGER_PORT}|${SWAGGER_PORT:-8084}|g" | \
            sed "s|\${FRONTEND_PORT}|${FRONTEND_PORT:-5173}|g" | \
            sed "s|\${APP_SOURCE}|${APP_SOURCE_ABS}|g")"
        EXTRAS_DEPENDS="${EXTRAS_DEPENDS}
      ${extra}:
        condition: service_healthy"
        extra_volumes_file="${DEVSTACK_DIR}/templates/extras/${extra}/volumes.yml"
        if [ -f "${extra_volumes_file}" ]; then
            EXTRAS_VOLUMES="${EXTRAS_VOLUMES}
$(cat "${extra_volumes_file}" | sed "s|\${PROJECT_NAME}|${PROJECT_NAME}|g")"
        fi
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
case "${APP_TYPE}" in
    go)
        APP_VOLUMES="
  ${PROJECT_NAME}-go-modules:"
        ;;
    python-fastapi)
        APP_VOLUMES="
  ${PROJECT_NAME}-python-cache:"
        ;;
    rust)
        APP_VOLUMES="
  ${PROJECT_NAME}-cargo-registry:
  ${PROJECT_NAME}-cargo-target:"
        ;;
esac

# ---------------------------------------------------------------------------
# Build app service from template
# ---------------------------------------------------------------------------
APP_SERVICE=""
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
# Build frontend service from template (if configured)
# ---------------------------------------------------------------------------
FRONTEND_SERVICE=""
if [ -n "${FRONTEND_TYPE:-}" ] && [ "${FRONTEND_TYPE}" != "none" ]; then
    frontend_template="${DEVSTACK_DIR}/templates/frontends/${FRONTEND_TYPE}/service.yml"
    if [ -f "${frontend_template}" ]; then
        FRONTEND_SERVICE=$(cat "${frontend_template}" | \
            sed "s|\${PROJECT_NAME}|${PROJECT_NAME}|g" | \
            sed "s|\${FRONTEND_SOURCE}|${FRONTEND_SOURCE_ABS}|g" | \
            sed "s|\${FRONTEND_API_PREFIX}|${FRONTEND_API_PREFIX:-/api}|g" | \
            sed "s|\${HTTPS_PORT}|${HTTPS_PORT}|g")
    else
        echo "[compose-gen] WARNING: No frontend template found at ${frontend_template}"
    fi
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
    image: alpine:3
    container_name: ${PROJECT_NAME}-cert-gen
    volumes:
      - ${PROJECT_NAME}-certs:/certs
      - ${DEVSTACK_DIR}/core/certs/generate.sh:/scripts/generate.sh:ro
      - ${OUTPUT_DIR}/domains.txt:/config/domains.txt:ro
    environment:
      - PROJECT_NAME=${PROJECT_NAME}
    entrypoint: ["sh", "-c", "apk add --no-cache openssl >/dev/null 2>&1 && sh /scripts/generate.sh"]
    networks:
      - ${PROJECT_NAME}-internal

  # ---------------------------------------------------------------------------
  # Application
  # ---------------------------------------------------------------------------
${APP_SERVICE}

  # ---------------------------------------------------------------------------
  # Web Server (Caddy) — reverse proxy + mock API interceptor
  # ---------------------------------------------------------------------------
  web:
    image: caddy:2-alpine
    container_name: ${PROJECT_NAME}-web
    ports:
      - "${HTTP_PORT}:80"
      - "${HTTPS_PORT}:443"
    volumes:
      - ${OUTPUT_DIR}/Caddyfile:/etc/caddy/Caddyfile:ro
      - ${PROJECT_NAME}-certs:/certs:ro
      - ${DEVSTACK_DIR}/tests/results:/srv/test-results:ro
COMPOSE_HEAD

# Frontend service (if configured)
if [ -n "${FRONTEND_SERVICE}" ]; then
    cat >> "${OUTPUT_FILE}" <<COMPOSE_FRONTEND

  # ---------------------------------------------------------------------------
  # Frontend Dev Server
  # ---------------------------------------------------------------------------
${FRONTEND_SERVICE}

COMPOSE_FRONTEND
fi

# Add app source volume mount for web if PHP (serves static files)
if [ "${APP_TYPE}" = "php-laravel" ]; then
    cat >> "${OUTPUT_FILE}" <<COMPOSE_WEB_PHP
      - ${APP_SOURCE_ABS}:/var/www/html:ro
COMPOSE_WEB_PHP
fi

FRONTEND_DEPENDS=""
if [ -n "${FRONTEND_SERVICE}" ]; then
    FRONTEND_DEPENDS="
      frontend:
        condition: service_started"
fi

cat >> "${OUTPUT_FILE}" <<COMPOSE_WEB_NET
    depends_on:
      cert-gen:
        condition: service_completed_successfully
      app:
        condition: service_started${DB_DEPENDS}${FRONTEND_DEPENDS}
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
  ${PROJECT_NAME}-certs:${DB_VOLUMES}${APP_VOLUMES}${EXTRAS_VOLUMES}
COMPOSE_FOOTER

echo "[compose-gen] Generated ${OUTPUT_FILE}"
echo "[compose-gen] Services: cert-gen, app, web (caddy), wiremock, tester, test-dashboard"
[ -n "${DB_SERVICE}" ] && echo "[compose-gen] Database: ${DB_TYPE}"
[ -n "${FRONTEND_SERVICE}" ] && echo "[compose-gen] Frontend: ${FRONTEND_TYPE}"
[ -n "${EXTRAS_SERVICES}" ] && echo "[compose-gen] Extras: ${EXTRAS}"
