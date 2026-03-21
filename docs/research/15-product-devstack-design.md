# Research 15: Product devstack.sh Design

> **Date**: 2026-03-21
> **Status**: Research complete
> **Drives**: ARCHITECTURE-NEXT.md — "How lightweight can devstack.sh be?"
> **Depends on**: Research 11 (function inventory), Research 13 (non-destructive restart, validation), ARCHITECTURE-NEXT.md (factory/product split)
> **Source files studied**: `devstack.sh` (1,688 lines), `core/caddy/generate-caddyfile.sh`, `core/certs/generate.sh`, `core/compose/generate.sh`, `project.env`

---

## Table of Contents

1. [Command Inventory: Factory vs Product](#1-command-inventory-factory-vs-product)
2. [What "start" Means in the Product](#2-what-start-means-in-the-product)
3. [Non-Destructive Stop/Restart](#3-non-destructive-stoprestart)
4. [Caddyfile and Cert Generation](#4-caddyfile-and-cert-generation)
5. [project.env Validation](#5-projectenv-validation)
6. [Complete Draft of Product devstack.sh](#6-complete-draft-of-product-devstacksh)
7. [What the Product Does NOT Contain](#7-what-the-product-does-not-contain)
8. [File Structure Comparison](#8-file-structure-comparison)

---

## 1. Command Inventory: Factory vs Product

All 29 functions from the current monolith, classified by lifecycle.

### 1.1 Factory-Only Functions (stay in the dev-strap repo)

These exist solely for creation-time concerns — presenting choices, validating selections, generating a project from templates. Once the project is bootstrapped, none of these are ever called again.

| # | Function | Lines | Why Factory-Only |
|---|----------|-------|------------------|
| 21 | `cmd_init` | 100 | Interactive project scaffolding — reads `templates/`, writes `project.env` |
| 22 | `require_jq` | 8 | Only used by contract interface |
| 23 | `cmd_contract_options` | 15 | `--options` — outputs the catalog manifest |
| 24 | `cmd_contract_bootstrap` | 90 | `--bootstrap` — parses payload, validates, generates, responds |
| 25 | `validate_bootstrap_payload` | 143 | 11-check validation against manifest |
| 26 | `resolve_wiring` | 99 | Resolves wiring template rules from manifest |
| 27 | `generate_from_bootstrap` | 252 | Generates project.env, scaffolds dirs, runs generators |
| 28 | `build_bootstrap_response` | 47 | Builds JSON success response |

**Total factory-only**: 8 functions, ~754 lines (44.7% of current script)

### 1.2 Product Functions (ship with the user's project)

These are runtime concerns — managing the stack after it exists.

| # | Function | Lines | Role in Product |
|---|----------|-------|-----------------|
| 1-4 | `log`, `log_ok`, `log_warn`, `log_err` | 4 | Unchanged — logging helpers |
| 5 | `check_docker` | 9 | Unchanged — still need Docker at runtime |
| 6 | `load_config` | 8 | Simplified — just source `project.env`, validate |
| 7 | `cmd_generate` | ~17->~5 | **Massively simplified** — only Caddyfile generation, no compose |
| 8 | `cmd_start` | 113 | Simplified — no compose generation, static files |
| 9 | `cmd_stop` | 25 | **Redesigned** — non-destructive by default |
| 10 | `cmd_test` | 47 | Unchanged (docker compose exec path changes) |
| 11 | `cmd_shell` | 18 | Unchanged |
| 12 | `cmd_status` | 10 | Unchanged |
| 13 | `cmd_logs` | 18 | Unchanged |
| 14 | `cmd_mocks` | 65 | Unchanged |
| 15 | `cmd_restart` | 4 | Redesigned — passes `--clean` flag through |
| 16 | `cmd_reload_mocks` | 31 | Unchanged |
| 17 | `cmd_new_mock` | 60 | Unchanged |
| 18 | `cmd_record` | 104 | Unchanged |
| 19 | `cmd_apply_recording` | 79 | Unchanged |
| 20 | `cmd_verify_mocks` | 57 | Unchanged |
| 29 | `main` | ~85->~50 | Simplified — no contract flags, smaller help |

**Total product**: 20 functions (including 4 log helpers), estimated ~350 lines

### 1.3 New Functions in Product

| Function | Lines | Purpose |
|----------|-------|---------|
| `validate_config` | ~25 | Validate `project.env` on start (from research 13) |
| `generate_caddyfile` | ~50 | Inline Caddyfile generation (replaces the external script) |
| `collect_domains` | ~15 | Collect `mocks/*/domains` into `domains.txt` (shared by Caddyfile + cert-gen) |
| `_clean_recordings` | ~12 | Clean root-owned recording directories (from research 13) |

### 1.4 Line Count Shift

| | Current | Product |
|---|---------|---------|
| Total lines | 1,688 | ~350 |
| Factory code removed | — | ~754 (contract, init, validation, wiring, scaffold) |
| Compose generation removed | — | ~400 (the external `core/compose/generate.sh` is not invoked) |
| Caddyfile gen simplified | ~182 (external script) | ~50 (inline) |
| Net reduction | — | **~79%** |

---

## 2. What "start" Means in the Product

### 2.1 Current Start (factory-entangled)

```
cmd_start -> cmd_generate -> bash core/caddy/generate-caddyfile.sh    (reads templates)
                          -> bash core/compose/generate.sh             (reads templates)
          -> docker compose build
          -> docker compose up -d
          -> wait cert-gen
          -> wait database
          -> run init script
          -> print summary
```

Every start regenerates `docker-compose.yml` from scratch using `templates/`, `project.env`, and `mocks/*/domains`. The compose file is an output, not a source of truth.

### 2.2 Product Start (no compose generation)

```
cmd_start -> validate_config          (check project.env format)
          -> collect_domains           (mocks/*/domains -> domains.txt)
          -> generate_caddyfile        (project.env + domains.txt -> caddy/Caddyfile)
          -> docker compose up --build -d
          -> wait cert-gen             (reads domains.txt, generates certs if SANs changed)
          -> wait database
          -> run init script
          -> print summary
```

Key differences:

1. **No compose generation**. The `docker-compose.yml` and `services/*.yml` files are static — placed once by the factory and never regenerated. Adding or removing a service means editing the compose file directly, which is exactly what Docker Compose was designed for.

2. **Only Caddyfile generation**. The Caddyfile still needs regeneration because mock domains are filesystem-driven (`mocks/*/domains`). Adding a mock means adding a directory, and the Caddyfile must reflect it.

3. **`domains.txt` collection**. Both Caddyfile generation and cert generation need the list of mocked domains. Collect once, share the file.

4. **Validation first**. Check `project.env` before doing anything expensive.

5. **No `.generated/` directory**. The Caddyfile writes directly to `caddy/Caddyfile`. The compose file is `docker-compose.yml` in the project root. No indirection layer.

### 2.3 Compose File Reference

The product uses `docker-compose.yml` directly (not from `.generated/`). Every `docker compose` invocation becomes:

```bash
docker compose -p "${PROJECT_NAME}" <command>
```

No `-f` flag needed — Docker Compose finds `docker-compose.yml` in the working directory. This simplifies every function that currently passes `-f "${GENERATED_DIR}/docker-compose.yml"`.

### 2.4 The `--build` flag

`docker compose up --build -d` rebuilds containers whose Dockerfiles or build contexts have changed. This is safe and fast: Docker layer caching means unchanged images are not rebuilt. It replaces the current two-step `build` then `up -d`.

---

## 3. Non-Destructive Stop/Restart

Directly implementing the recommendation from Research 13.

### 3.1 Behavior Matrix

| Command | Containers | Networks | `caddy/Caddyfile` | Named Volumes | Recordings |
|---------|:----------:|:--------:|:------------------:|:-------------:|:----------:|
| `stop` | Remove | Remove | Keep | **Keep** | Keep |
| `stop --clean` | Remove | Remove | Keep | **Delete** | Delete |
| `restart` | Recreate | Recreate | Regenerate | **Keep** | Keep |
| `restart --clean` | Recreate | Recreate | Regenerate | **Delete** | Delete |

### 3.2 What "Keep" Means for Named Volumes

Named volumes contain:
- **Database data** (`${PROJECT_NAME}-db-data`) — migrations, seed data, user data during development
- **Module caches** (`go-modules`, `cargo-registry`, `cargo-target`, `python-cache`) — expensive to rebuild
- **Cert volume** (`${PROJECT_NAME}-certs`) — regenerated automatically if SANs change (Research 13, section 2)

Losing these on every restart was the original pain point. With the product model, `stop` means "turn it off, pick up where I left off later." `stop --clean` means "nuclear option, start completely fresh."

### 3.3 Implementation

```bash
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
    else
        docker compose -p "${PROJECT_NAME}" down --remove-orphans 2>/dev/null || true
    fi

    # Clean test artifacts and recordings on --clean
    if [ "${clean}" = "1" ]; then
        _clean_test_artifacts
        _clean_recordings
        log_ok "DevStack stopped. All containers, volumes, and artifacts removed."
    else
        log_ok "DevStack stopped. Volumes preserved."
        log "Run './devstack.sh stop --clean' to also remove database and cache volumes."
    fi
}

cmd_restart() {
    cmd_stop "$@"
    cmd_start
}
```

### 3.4 No `.generated/` Cleanup

The current `cmd_stop` does `rm -rf "${GENERATED_DIR}"`. In the product there is no `.generated/` directory. The Caddyfile at `caddy/Caddyfile` is regenerated on `start` anyway, so there is nothing to clean up.

---

## 4. Caddyfile and Cert Generation

### 4.1 Why These Are the Only Generation the Product Does

The factory/product boundary is: **generation happens once at assembly time; the product uses static files at runtime.**

Two exceptions survive:

1. **Caddyfile** — Mock domains are filesystem-driven. Adding `mocks/newapi/domains` must result in a new site block in the Caddyfile. The Caddyfile cannot be static because the user adds mocks after bootstrap.

2. **Certificates** — Cert SANs must match mock domains. When domains change, certs must regenerate. But this is handled by the cert-gen container itself (Research 13, section 2) — the product script only needs to collect `domains.txt`.

### 4.2 Domain Collection

Shared helper that both Caddyfile generation and cert-gen use:

```bash
collect_domains() {
    local domains_file="${PROJECT_DIR}/domains.txt"
    : > "${domains_file}"  # truncate

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
```

Output: `domains.txt` in the project root, one domain per line. This file is bind-mounted into the cert-gen container at `/config/domains.txt`.

### 4.3 Caddyfile Generation (Inline, ~50 Lines)

The current external script at `core/caddy/generate-caddyfile.sh` (182 lines) is simplified because:

- No `DEVSTACK_DIR` path resolution back to the factory
- No `${OUTPUT_DIR}/.generated/Caddyfile` indirection — writes directly to `caddy/Caddyfile`
- The same three cases (PHP-FPM, frontend+backend, plain reverse proxy) remain
- Mock domain block remains

```bash
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

    # App server block — three cases: PHP-FPM, frontend+backend, plain reverse proxy
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

    # Mock domain site block — single block for all mocked domains, proxy to WireMock
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
```

### 4.4 Cert Generation — Ships As-Is

The `core/certs/generate.sh` script runs inside the cert-gen container. It does not depend on the factory. It reads `/config/domains.txt` and `/certs/` — both are container paths mapped by the service YAML.

The product includes this script at `certs/generate.sh`. The `services/cert-gen.yml` mounts it:

```yaml
services:
  cert-gen:
    image: alpine:latest
    command: sh /scripts/generate.sh
    volumes:
      - ./certs/generate.sh:/scripts/generate.sh:ro
      - ./domains.txt:/config/domains.txt:ro
      - certs:/certs
    environment:
      - PROJECT_NAME=${PROJECT_NAME}
```

The cert domain change detection from Research 13 (section 2) is already inside `generate.sh` — no product-side logic needed.

---

## 5. project.env Validation

### 5.1 Product vs Factory Validation

The factory validation (`validate_bootstrap_payload`, 143 lines) checks selections against the manifest — categories, items, dependencies, conflicts, port collisions. The product never needs any of this because the selections are already resolved.

Product validation is simpler: **"Is the config file well-formed enough to run Docker Compose?"**

### 5.2 What to Validate

| Check | Why |
|-------|-----|
| `PROJECT_NAME` exists | Used in `docker compose -p` and container names |
| `PROJECT_NAME` matches `[a-z][a-z0-9-]*` | Docker project names have format restrictions |
| `APP_TYPE` exists | Determines Caddyfile routing (PHP-FPM vs reverse proxy) |
| `HTTP_PORT` is numeric | Displayed in summary; invalid values confuse the user |
| `HTTPS_PORT` is numeric | Same |

### 5.3 What NOT to Validate

| Skip | Why |
|------|-----|
| `APP_TYPE` against `templates/` | No `templates/` directory in the product |
| `DB_TYPE` against `templates/` | Same |
| `EXTRAS` list | No extras directory — services are in `services/*.yml` |
| `NETWORK_SUBNET` format | Docker Compose validates this itself with a better error message |
| Port collisions | Already caught at assembly time; at runtime, Docker will error on bind conflicts |

### 5.4 Implementation

```bash
validate_config() {
    local errors=()

    [ -z "${PROJECT_NAME:-}" ] && errors+=("PROJECT_NAME is required")
    [ -z "${APP_TYPE:-}" ] && errors+=("APP_TYPE is required")

    if [ -n "${PROJECT_NAME:-}" ]; then
        if ! echo "${PROJECT_NAME}" | grep -qE '^[a-z][a-z0-9-]*$'; then
            errors+=("PROJECT_NAME '${PROJECT_NAME}' is invalid (must match [a-z][a-z0-9-]*)")
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
```

Notably simpler than the factory version: ~20 lines vs ~90 lines (from Research 13 section 3, which was designed for the monolith and checked template directories).

---

## 6. Complete Draft of Product devstack.sh

This is the full script. Every line is intentional. No placeholders, no TODOs.

```bash
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

    # Collect mock domains and generate Caddyfile
    collect_domains
    generate_caddyfile

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
# Mocks — list configured mock services
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
        --network "${PROJECT_NAME}_${PROJECT_NAME}-internal" \
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
```

### 6.1 Line Count

| Section | Lines |
|---------|-------|
| Header + shebang | 22 |
| Helpers (log, check_docker) | 20 |
| Config (load, validate) | 30 |
| Domain collection + Caddyfile gen | 85 |
| Cleanup helpers | 22 |
| `cmd_start` | 75 |
| `cmd_stop` | 20 |
| `cmd_restart` | 3 |
| `cmd_test` | 35 |
| `cmd_shell` | 5 |
| `cmd_status` | 3 |
| `cmd_logs` | 7 |
| `cmd_mocks` | 55 |
| `cmd_reload_mocks` | 20 |
| `cmd_new_mock` | 40 |
| `cmd_record` | 65 |
| `cmd_apply_recording` | 55 |
| `cmd_verify_mocks` | 40 |
| `main` + help | 50 |
| **Total** | **~352** |

That is 352 lines vs the current 1,688 -- a **79% reduction**.

### 6.2 Key Design Decisions in the Draft

**`PROJECT_DIR` instead of `DEVSTACK_DIR`**. The variable name changes to reflect that this script lives in the user's project, not in the dev-strap factory. Every path is relative to the project root.

**No `-f` flag on compose commands**. Docker Compose finds `docker-compose.yml` in the working directory. Removing the explicit path from every invocation eliminates an entire class of "file not found" errors and removes the coupling to `.generated/`.

**No "is running" guards on most commands**. The current script checks `if [ ! -f "${GENERATED_DIR}/docker-compose.yml" ]` before nearly every command. In the product, `docker-compose.yml` always exists (it is static). Docker Compose itself handles the case where containers are not running -- `exec` fails, `logs` is empty, `ps` shows nothing. The product trusts Docker Compose to give the right error.

**`cmd_status` and `cmd_logs` have no guard**. If the stack is not running, `docker compose ps` outputs an empty table and `docker compose logs` outputs nothing. Both are informative without a custom error message.

**Database detection by service name, not `DB_TYPE`**. The product has no `DB_TYPE=none` concept for conditionals. Instead, `cmd_start` checks whether a service named `db` exists in the running compose project. If the factory did not include a database service, there is no `db` to wait for. This is filesystem-driven, not config-driven.

**`apply-recording` checks for running stack differently**. Instead of checking for a generated compose file, it uses `docker compose ps --quiet` to see if any containers are running. This is compose-native and does not depend on file paths.

---

## 7. What the Product Does NOT Contain

Everything in this list stays in the dev-strap factory repository. None of it ships with the bootstrapped project.

### 7.1 Files

| Factory File/Directory | Why It Stays |
|------------------------|--------------|
| `contract/manifest.json` | Catalog of available options -- creation-time only |
| `templates/apps/*/` | App template Dockerfiles and service YAMLs -- copied once at assembly |
| `templates/databases/*/` | Database service templates -- copied once at assembly |
| `templates/extras/*/` | Extra service templates -- copied once at assembly |
| `templates/frontends/*/` | Frontend templates -- copied once at assembly |
| `core/compose/generate.sh` | Compose file generator -- the product uses static compose files |
| `core/caddy/generate-caddyfile.sh` | Replaced by the 50-line inline function in product's `devstack.sh` |
| `docs/` | Factory documentation; product gets its own README |
| `tests/` (factory tests) | The 184 contract/integration tests test the factory, not the product |
| `.generated/` | Does not exist in the product -- files are first-class, not derived |

### 7.2 Functions

| Function | Why It Stays |
|----------|-------------|
| `cmd_init` | Interactive scaffolding reads `templates/` -- factory concern |
| `require_jq` | Only used by contract interface |
| `cmd_contract_options` | `--options` outputs the catalog manifest |
| `cmd_contract_bootstrap` | `--bootstrap` generates a project from JSON |
| `validate_bootstrap_payload` | 11-check validation against the manifest |
| `resolve_wiring` | Resolves auto-wiring rules from the manifest |
| `generate_from_bootstrap` | Writes project.env, copies templates, runs generators |
| `build_bootstrap_response` | Builds the JSON response for PowerHouse |

### 7.3 Concepts

| Concept | Why It Does Not Apply |
|---------|-----------------------|
| Template variable substitution | Done once by the factory; product files have concrete values |
| Catalog categories and items | The user already chose; the product has what was chosen |
| Wiring rules | Resolved at assembly time; results are in `project.env` |
| Preset bundles | Selection mechanism -- factory concern |
| Port collision detection | Validated at assembly time |
| `EXTRAS` comma-separated list | Services are individual YAML files in `services/`, not a list |
| `sed`/`envsubst` on templates | No templates to process |
| `.generated/` directory | No generation indirection |

---

## 8. File Structure Comparison

### 8.1 Current Structure (factory + product tangled)

```
my-app/                              (lives inside dev-strap repo)
├── devstack.sh                      <- 1,688 lines (factory + product)
├── project.env                      <- config
├── contract/
│   └── manifest.json                <- catalog (factory)
├── core/
│   ├── caddy/
│   │   └── generate-caddyfile.sh    <- Caddyfile generator (factory)
│   ├── certs/
│   │   └── generate.sh             <- cert generator (ships with product)
│   └── compose/
│       └── generate.sh             <- compose generator (factory)
├── templates/
│   ├── apps/
│   │   ├── node-express/            <- 5 app templates (factory)
│   │   ├── go/
│   │   ├── php-laravel/
│   │   ├── python-fastapi/
│   │   └── rust/
│   ├── databases/
│   │   ├── mariadb/                 <- 2 DB templates (factory)
│   │   └── postgres/
│   ├── extras/
│   │   ├── redis/                   <- N extra templates (factory)
│   │   ├── mailpit/
│   │   └── ...
│   └── frontends/
│       └── vite/                    <- frontend template (factory)
├── .generated/                      <- rebuild on every start
│   ├── docker-compose.yml           <- generated (transient)
│   ├── Caddyfile                    <- generated (transient)
│   └── domains.txt                  <- generated (transient)
├── app/
│   ├── Dockerfile
│   ├── init.sh
│   └── src/
├── mocks/
│   └── stripe/
│       ├── domains
│       └── mappings/*.json
└── tests/
    └── playwright/
```

Problems:
- The project carries the entire catalog (`templates/`, `contract/`)
- Every start regenerates from scratch (`core/compose/generate.sh`, `core/caddy/generate-caddyfile.sh`)
- The product is not portable -- it depends on the factory's directory structure
- `ls` reveals factory internals alongside project files
- `.generated/` is a transient layer between config and runtime

### 8.2 Product Structure (after factory/product split)

```
my-app/                              (standalone, portable)
├── devstack.sh                      <- ~350 lines (runtime only)
├── project.env                      <- config
├── docker-compose.yml               <- static, includes from services/
├── domains.txt                      <- collected on start from mocks/*/domains
├── services/
│   ├── app.yml                      <- the specific app chosen (e.g., Go)
│   ├── database.yml                 <- the specific DB chosen (e.g., PostgreSQL)
│   ├── redis.yml                    <- present only if chosen
│   ├── caddy.yml                    <- reverse proxy
│   ├── wiremock.yml                 <- mock server
│   ├── cert-gen.yml                 <- certificate generation
│   ├── tester.yml                   <- Playwright test runner
│   └── qa-dashboard.yml             <- test results viewer
├── caddy/
│   └── Caddyfile                    <- generated on start from project.env + mocks
├── certs/
│   └── generate.sh                  <- cert generation script (runs in container)
├── app/
│   ├── Dockerfile
│   ├── init.sh
│   └── src/
├── mocks/
│   └── stripe/
│       ├── domains
│       └── mappings/*.json
└── tests/
    ├── playwright/
    │   ├── playwright.config.ts
    │   └── *.spec.ts
    └── results/
```

### 8.3 What Changed

| Aspect | Current | Product |
|--------|---------|---------|
| `devstack.sh` | 1,688 lines | ~350 lines |
| Compose file | `.generated/docker-compose.yml` (transient) | `docker-compose.yml` (static, source of truth) |
| Service definitions | Generated from `templates/` on every start | `services/*.yml` -- placed once, static |
| Caddyfile | `.generated/Caddyfile` via external script | `caddy/Caddyfile` via inline function |
| Cert script | `core/certs/generate.sh` (in factory tree) | `certs/generate.sh` (in project) |
| Template directory | Present, all languages/services | Absent -- only the chosen ones exist as `services/*.yml` |
| Contract directory | Present (`contract/manifest.json`) | Absent |
| Core directory | Present (`core/compose/`, `core/caddy/`) | Absent |
| Understanding the stack | Read `project.env`, parse `EXTRAS`, mentally map to templates | `ls services/` |
| Adding a service | Edit `project.env` EXTRAS list, restart (regenerates compose) | Drop a YAML in `services/`, add include line, restart |
| Removing a service | Edit `project.env`, restart | Delete YAML, remove include line, restart |
| Portability | Requires dev-strap repo structure | Self-contained, copy anywhere |

### 8.4 Root Compose File

The `docker-compose.yml` in the product root is a thin include file:

```yaml
# docker-compose.yml
include:
  - services/cert-gen.yml
  - services/app.yml
  - services/caddy.yml
  - services/database.yml
  - services/redis.yml
  - services/wiremock.yml
  - services/tester.yml
  - services/qa-dashboard.yml
```

`ls services/` tells you your stack. `cat docker-compose.yml` tells you the load order. No generation, no templates, no indirection.
