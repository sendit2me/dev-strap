# Phase 5a: Caddy Swap — Implementation Specification

> **Status**: FIRM — ready to execute
> **Prerequisite**: Phases 1-4 complete (commits `4643faa`, `9ea545a`)
> **Research**: `08-caddy-deep-dive.md`, `09-caddy-generator-design.md`

---

## Scope

Replace nginx with Caddy v2 as the reverse proxy. Four files created, four files modified, one file deleted. Zero template changes.

---

## Task 1: Create Caddyfile Generator

**File**: `core/caddy/generate-caddyfile.sh` (NEW)

Create the directory `core/caddy/` and the generator script. The script reads `project.env` and `mocks/*/domains` (same inputs as the nginx generator) and outputs `.generated/Caddyfile`.

The generator has three code paths for the app block:
1. `APP_TYPE == php-laravel` → `php_fastcgi app:9000` + `root` + `file_server`
2. `FRONTEND_TYPE` is set (non-empty, not "none") → path-based routing: `/api/*` → backend, `/*` → frontend
3. Default → `reverse_proxy app:3000`

All three include the test-results `handle_path` block and TLS config.

The mock interception block is shared across all code paths: comma-separated domain list with `:443` suffix, `tls` with our certs, `reverse_proxy wiremock:8080` with `header_up X-Original-Host {http.request.host}`.

Global options block: `{ auto_https off }` — prevents ACME attempts in Docker.

**Exact content**: Use the draft from `docs/research/09-caddy-generator-design.md` Section 6 (lines 610-792). This is the final version — it handles all three app routing modes, mock interception, and test-results serving.

**Post-create**: `chmod +x core/caddy/generate-caddyfile.sh`

**Verification**:
```bash
bash core/caddy/generate-caddyfile.sh
cat .generated/Caddyfile  # should be ~25 lines for a standard project
```

---

## Task 2: Update Compose Generator

**File**: `core/compose/generate.sh` (MODIFY)

### 2a: cert-gen image (line 218)

Change:
```
    image: eclipse-temurin:17-alpine
```
To:
```
    image: alpine:3
```

### 2b: cert-gen entrypoint (line 226)

Change:
```
    entrypoint: ["sh", "/scripts/generate.sh"]
```
To:
```
    entrypoint: ["sh", "-c", "apk add --no-cache openssl >/dev/null 2>&1 && sh /scripts/generate.sh"]
```

### 2c: Web service comment (line 236)

Change:
```
  # Web Server (Nginx) — reverse proxy + mock API interceptor
```
To:
```
  # Web Server (Caddy) — reverse proxy + mock API interceptor
```

### 2d: Web service image (line 239)

Change:
```
    image: nginx:alpine
```
To:
```
    image: caddy:2-alpine
```

### 2e: Web service config volume (line 245)

Change:
```
      - ${OUTPUT_DIR}/nginx.conf:/etc/nginx/nginx.conf:ro
```
To:
```
      - ${OUTPUT_DIR}/Caddyfile:/etc/caddy/Caddyfile:ro
```

### 2f: Web service cert volume (line 246)

Change:
```
      - ${PROJECT_NAME}-certs:/etc/nginx/certs:ro
```
To:
```
      - ${PROJECT_NAME}-certs:/certs:ro
```

### 2g: Web service test-results volume (line 247)

Change:
```
      - ${DEVSTACK_DIR}/tests/results:/var/www/html/public/test-results:ro
```
To:
```
      - ${DEVSTACK_DIR}/tests/results:/srv/test-results:ro
```

### 2h: Summary output (line ~370-372)

Change:
```
echo "[compose-gen] Services: cert-gen, app, web, wiremock, tester, test-dashboard"
```
To:
```
echo "[compose-gen] Services: cert-gen, app, web (caddy), wiremock, tester, test-dashboard"
```

**Verification**: `bash -n core/compose/generate.sh`

---

## Task 3: Update cert-gen Script

**File**: `core/certs/generate.sh` (MODIFY)

### 3a: Remove JKS generation (lines 122-140)

Delete the entire section from `# 3. JKS Keystore for WireMock` through the `keytool` command (lines 122-140). This removes the Java/keytool dependency, which is why we can use `alpine:3` instead of `eclipse-temurin:17-alpine`.

### 3b: Update summary output (line 147)

Change:
```
ls -la "${CERT_DIR}"/*.crt "${CERT_DIR}"/*.key "${CERT_DIR}"/*.jks 2>/dev/null
```
To:
```
ls -la "${CERT_DIR}"/*.crt "${CERT_DIR}"/*.key 2>/dev/null
```

### 3c: Update script header comment (line 8)

Change:
```
#   3. JKS keystore for WireMock
```
To:
```
#   (JKS removed — WireMock runs HTTP-only behind the proxy)
```

**Verification**: The script must run with only `openssl` available (no `keytool`). Test:
```bash
docker run --rm -v $(pwd)/core/certs/generate.sh:/scripts/generate.sh:ro alpine:3 sh -c "apk add --no-cache openssl && sh /scripts/generate.sh"
```

---

## Task 4: Update devstack.sh

**File**: `devstack.sh` (MODIFY)

Four exact changes. Use `grep -n` to find exact line numbers:

### 4a: Generator path (line 71)

Change:
```
    bash "${DEVSTACK_DIR}/core/nginx/generate-conf.sh"
```
To:
```
    bash "${DEVSTACK_DIR}/core/caddy/generate-caddyfile.sh"
```

### 4b: Generator log — generating (line 70)

Change:
```
    log "Generating nginx.conf..."
```
To:
```
    log "Generating Caddyfile..."
```

### 4c: Generator log — summary (line 78)

Change:
```
    log "  - nginx.conf"
```
To:
```
    log "  - Caddyfile"
```

### 4d: Verify-mocks log (line 770)

Change:
```
        log "Check: ./devstack.sh logs web (nginx routing)"
```
To:
```
        log "Check: ./devstack.sh logs web (proxy routing)"
```

**Verification**: `bash -n devstack.sh`

---

## Task 5: Delete nginx Generator

**File**: `core/nginx/generate-conf.sh` (DELETE)
**Directory**: `core/nginx/` (DELETE)

Remove after all tests pass. This is the last step.

---

## Task 6: Update docs/AI_BOOTSTRAP.md

**File**: `docs/AI_BOOTSTRAP.md` (MODIFY)

Update these references:
- Source-of-truth table: `core/nginx/generate-conf.sh` → `core/caddy/generate-caddyfile.sh`
- Generated files table: `.generated/nginx.conf` → `.generated/Caddyfile`
- Architecture diagram: "nginx" → "Caddy"
- File reading order item 4: `core/nginx/generate-conf.sh` → `core/caddy/generate-caddyfile.sh`
- `./devstack.sh logs web` description: remove "(nginx)" if present

---

## Task 7: Tests

### 7a: Run existing contract tests
```bash
bash tests/contract/test-contract.sh
```
All 176 must pass. The contract tests don't reference nginx directly — they test bootstrap/options/validation.

### 7b: Run bootstrap + generation for every app type
```bash
for app in node-express go php-laravel python-fastapi rust; do
    echo "Testing ${app}..."
    echo "{\"contract\":\"devstrap-bootstrap\",\"version\":\"1\",\"project\":\"test-${app}\",\"selections\":{\"app\":{\"${app}\":{}},\"database\":{\"postgres\":{}}}}" | ./devstack.sh --bootstrap --config - 2>/dev/null | jq -r '.status'
    # Check Caddyfile exists and is non-empty
    [ -s .generated/Caddyfile ] && echo "  Caddyfile: OK" || echo "  Caddyfile: MISSING"
    # Verify PHP gets php_fastcgi, others get reverse_proxy
    if [ "${app}" = "php-laravel" ]; then
        grep -q "php_fastcgi" .generated/Caddyfile && echo "  php_fastcgi: OK" || echo "  php_fastcgi: MISSING"
    else
        grep -q "reverse_proxy app:3000" .generated/Caddyfile && echo "  reverse_proxy: OK" || echo "  reverse_proxy: MISSING"
    fi
done
```

### 7c: Verify mock interception in Caddyfile
```bash
# Bootstrap with wiremock
echo '{"contract":"devstrap-bootstrap","version":"1","project":"test-mocks","selections":{"app":{"go":{}},"tooling":{"wiremock":{}}}}' | ./devstack.sh --bootstrap --config - 2>/dev/null
grep -q "X-Original-Host" .generated/Caddyfile && echo "Mock header: OK" || echo "Mock header: MISSING"
grep -q "wiremock:8080" .generated/Caddyfile && echo "WireMock proxy: OK" || echo "WireMock proxy: MISSING"
```

### 7d: Verify cert-gen without JKS
```bash
grep -q "keytool" core/certs/generate.sh && echo "FAIL: keytool still present" || echo "JKS removed: OK"
grep -q "\.jks" core/certs/generate.sh && echo "FAIL: .jks still referenced" || echo "JKS refs removed: OK"
```

### 7e: Verify compose uses Caddy
```bash
echo '{"contract":"devstrap-bootstrap","version":"1","project":"test-caddy","selections":{"app":{"node-express":{}}}}' | ./devstack.sh --bootstrap --config - 2>/dev/null
grep -q "caddy:2-alpine" .generated/docker-compose.yml && echo "Caddy image: OK" || echo "Caddy image: MISSING"
grep -q "Caddyfile:/etc/caddy/Caddyfile" .generated/docker-compose.yml && echo "Caddyfile mount: OK" || echo "Caddyfile mount: MISSING"
grep -q "/certs:ro" .generated/docker-compose.yml && echo "Cert mount: OK" || echo "Cert mount: MISSING"
grep -q "alpine:3" .generated/docker-compose.yml && echo "Cert-gen slim: OK" || echo "Cert-gen slim: MISSING"
```

---

## Files Summary

| File | Action | Lines changed |
|------|--------|---------------|
| `core/caddy/generate-caddyfile.sh` | CREATE | ~140 lines |
| `core/compose/generate.sh` | MODIFY | ~8 lines changed |
| `core/certs/generate.sh` | MODIFY | ~20 lines removed |
| `devstack.sh` | MODIFY | 4 lines changed |
| `docs/AI_BOOTSTRAP.md` | MODIFY | ~5 references updated |
| `core/nginx/generate-conf.sh` | DELETE | -207 lines |
| `core/nginx/` | DELETE | directory |

**Net change**: ~140 new (Caddy generator) - 207 deleted (nginx generator) = **-67 lines** for equivalent functionality plus frontend routing support.

---

## Parallelization

Tasks 1-4 touch different files and can be done by separate agents:
- **Agent A**: Task 1 (Caddyfile generator) — creates `core/caddy/generate-caddyfile.sh`
- **Agent B**: Tasks 2+3 (compose generator + cert-gen) — modifies `core/compose/generate.sh` + `core/certs/generate.sh`
- **Agent C**: Tasks 4+5+6 (devstack.sh + nginx deletion + docs) — modifies `devstack.sh`, deletes `core/nginx/`, updates `docs/AI_BOOTSTRAP.md`

Task 7 (tests) runs after all agents complete.

---

## Operational Notes

- **Caddy refuses to start if cert files are missing**. The existing `depends_on: cert-gen: condition: service_completed_successfully` handles this. Do not change the dependency chain.
- **New mock domains require restart** (`./devstack.sh restart`). Certs need regeneration for new SANs. Caddy is stateless — restart is clean, lost packets are acceptable for a dev tool.
- **Caddy admin API** runs on port 2019 internally. Not exposed to host. Available for future `reload-proxy` command if needed.
- **`auto_https off`** in global block prevents ACME attempts. Without this, Caddy would try to reach Let's Encrypt on every start and fail with timeouts in Docker.
