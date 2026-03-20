# Research 12: Replacing sed Templating with envsubst

> **Status**: Research complete
> **Relates to**: REVIEW-FINDINGS-TASKS.md D4
> **Files analyzed**: `core/compose/generate.sh`, `core/caddy/generate-caddyfile.sh`, all 21 template files in `templates/`

---

## 1. Complete sed Chain Inventory

### 1.1 Substitution Site 1: Extras Templates (lines 103-120)

The extras sed chain is the largest -- 17 piped sed commands applied to every extra service template:

| # | sed target | Variable value source | Default |
|---|---|---|---|
| 1 | `${PROJECT_NAME}` | `project.env` | — |
| 2 | `${DB_NAME}` | `project.env` | — |
| 3 | `${DB_USER}` | `project.env` | — |
| 4 | `${DB_PASSWORD}` | `project.env` | — |
| 5 | `${MAILPIT_PORT}` | `project.env` | `8025` |
| 6 | `${DEVSTACK_DIR}` | derived (script's own dir) | — |
| 7 | `${PROMETHEUS_PORT}` | `project.env` | `9090` |
| 8 | `${GRAFANA_PORT}` | `project.env` | `3001` |
| 9 | `${DOZZLE_PORT}` | `project.env` | `9999` |
| 10 | `${NATS_PORT}` | `project.env` | `4222` |
| 11 | `${NATS_MONITOR_PORT}` | `project.env` | `8222` |
| 12 | `${MINIO_PORT}` | `project.env` | `9000` |
| 13 | `${MINIO_CONSOLE_PORT}` | `project.env` | `9001` |
| 14 | `${ADMINER_PORT}` | `project.env` | `8083` |
| 15 | `${SWAGGER_PORT}` | `project.env` | `8084` |
| 16 | `${FRONTEND_PORT}` | `project.env` | `5173` |
| 17 | `${APP_SOURCE}` | derived (resolved to abs path) | — |

A separate 1-command sed chain processes extras volumes files (line 127):

| # | sed target | Variable value source |
|---|---|---|
| 1 | `${PROJECT_NAME}` | `project.env` |

### 1.2 Substitution Site 2: Database Templates (lines 143-148)

5 piped sed commands:

| # | sed target | Variable value source |
|---|---|---|
| 1 | `${PROJECT_NAME}` | `project.env` |
| 2 | `${DB_NAME}` | `project.env` |
| 3 | `${DB_USER}` | `project.env` |
| 4 | `${DB_PASSWORD}` | `project.env` |
| 5 | `${DB_ROOT_PASSWORD}` | `project.env` |

### 1.3 Substitution Site 3: App Templates (lines 194-202)

8 piped sed commands:

| # | sed target | Variable value source |
|---|---|---|
| 1 | `${PROJECT_NAME}` | `project.env` |
| 2 | `${APP_SOURCE}` | derived (resolved to abs path) |
| 3 | `${DB_TYPE}` | `project.env` |
| 4 | `${DB_PORT}` | derived (case statement from DB_TYPE) |
| 5 | `${DB_NAME}` | `project.env` |
| 6 | `${DB_USER}` | `project.env` |
| 7 | `${DB_PASSWORD}` | `project.env` |
| 8 | `${DB_ROOT_PASSWORD}` | `project.env` |

### 1.4 Substitution Site 4: Frontend Templates (lines 215-219)

4 piped sed commands:

| # | sed target | Variable value source | Default |
|---|---|---|---|
| 1 | `${PROJECT_NAME}` | `project.env` | — |
| 2 | `${FRONTEND_SOURCE}` | derived (resolved to abs path) | — |
| 3 | `${FRONTEND_API_PREFIX}` | `project.env` | `/api` |
| 4 | `${HTTPS_PORT}` | `project.env` | — |

### 1.5 Total Count

- **35 individual sed commands** across 4 substitution sites (17 + 1 + 5 + 8 + 4)
- All sed commands are **simple global substitutions** (`s|pattern|replacement|g`)
- None use regex captures, conditional logic, multi-line operations, or address ranges
- The pipe delimiter `|` is used instead of `/` (good -- avoids conflicts with path values)

### 1.6 Caddyfile Generator: No sed Usage

`core/caddy/generate-caddyfile.sh` uses **zero sed commands**. All variable substitution is done through bash heredocs with native shell variable expansion (unquoted heredoc delimiters like `<<CADDY_APP` allow `${VAR}` to expand). This is already the pattern we want to move toward for the compose generator.

### 1.7 Compose Generator Heredocs: Already Use Native Expansion

The compose generator's heredoc sections (cert-gen, web, wiremock, tester, test-dashboard, networks/volumes) already use bash variable expansion -- they are NOT processed through sed. Only the four template-file-processing sections use sed.

---

## 2. envsubst Capabilities Analysis

### 2.1 How envsubst Works

`envsubst` reads stdin, replaces `$VAR` and `${VAR}` references with their values from environment variables, and writes to stdout.

```bash
export NAME="world"
echo 'Hello ${NAME}' | envsubst
# Output: Hello world
```

### 2.2 Key Capabilities

| Feature | Supported | Notes |
|---|---|---|
| `${VAR}` replacement | Yes | Primary use case |
| `$VAR` replacement | Yes | Also supported |
| Selective replacement | Yes | `envsubst '$VAR1 $VAR2'` replaces only listed vars |
| `${VAR:-default}` | **No** | envsubst does NOT process bash default syntax; it treats the entire `${VAR:-default}` as a variable name lookup, which fails and produces empty string |
| Undefined variables | Replaced with empty string | This is the default behavior -- can be dangerous |
| Multiple passes | Not needed | Single pass replaces all matching vars |

### 2.3 Availability

| Environment | Available | Package |
|---|---|---|
| Alpine Linux (alpine:3) | Yes | `gettext` package (`apk add gettext`) |
| Most Linux distros | Yes | Pre-installed or via `gettext` |
| macOS (Homebrew) | Yes | `brew install gettext` |
| caddy:2-alpine | Needs `apk add gettext` | But irrelevant -- Caddyfile generation runs on host, not in container |

Note: The generators run on the **host machine**, not inside containers. envsubst availability depends on the developer's OS, not the container images. On most Linux systems, envsubst is available via the `gettext` or `gettext-base` package, and is often pre-installed.

### 2.4 The Default Value Problem

Current sed commands handle defaults via bash parameter expansion in the generator script:

```bash
sed "s|\${MAILPIT_PORT}|${MAILPIT_PORT:-8025}|g"
```

Here, `${MAILPIT_PORT:-8025}` is evaluated by **bash** before sed sees it. The sed replacement string is already the resolved value.

With envsubst, the equivalent is:

```bash
export MAILPIT_PORT="${MAILPIT_PORT:-8025}"  # Resolve default BEFORE export
envsubst < template.yml
```

This works identically. Defaults must be resolved before the variables are exported to envsubst. The templates themselves never contain `${VAR:-default}` syntax -- only `${VAR}`.

---

## 3. Template Syntax Audit

### 3.1 Placeholder Format

Every template file uses exclusively the `${VARIABLE}` (braced) syntax. Zero instances of bare `$VARIABLE` were found across all 21 template files. This is the exact syntax envsubst expects.

### 3.2 Complete Variable Inventory Across All Templates

Unique variables found in template files (21 files scanned):

| Variable | Used in templates |
|---|---|
| `${PROJECT_NAME}` | All 21 templates |
| `${APP_SOURCE}` | All 5 app templates, swagger-ui |
| `${DB_PORT}` | All 5 app templates |
| `${DB_NAME}` | All 5 app templates, postgres, mariadb |
| `${DB_USER}` | All 5 app templates, postgres, mariadb |
| `${DB_PASSWORD}` | All 5 app templates, postgres, mariadb |
| `${DB_ROOT_PASSWORD}` | mariadb only |
| `${DB_TYPE}` | Not in templates (used in generator logic only) |
| `${DEVSTACK_DIR}` | prometheus, grafana |
| `${MAILPIT_PORT}` | mailpit |
| `${PROMETHEUS_PORT}` | prometheus |
| `${GRAFANA_PORT}` | grafana |
| `${DOZZLE_PORT}` | dozzle |
| `${NATS_PORT}` | nats |
| `${NATS_MONITOR_PORT}` | nats |
| `${MINIO_PORT}` | minio |
| `${MINIO_CONSOLE_PORT}` | minio |
| `${ADMINER_PORT}` | db-ui |
| `${SWAGGER_PORT}` | swagger-ui |
| `${FRONTEND_PORT}` | Not in templates directly (used in Caddy config) |
| `${FRONTEND_SOURCE}` | vite |
| `${FRONTEND_API_PREFIX}` | vite |
| `${HTTPS_PORT}` | vite |

### 3.3 Docker Compose `${VAR}` Collision: Non-Issue

Docker Compose uses `${VAR}` for runtime environment interpolation. dev-strap's templates also use `${VAR}`. This seems like a collision risk, but it is a **non-issue** because:

1. dev-strap's templates are never read directly by Docker Compose
2. The generator performs substitution and writes the result to `.generated/docker-compose.yml`
3. The generated file contains resolved values, not `${VAR}` placeholders
4. With envsubst, the same flow applies: templates are processed before Docker sees them

**Audit result**: Every `${VAR}` in every template file is intended for build-time substitution by the generator. Zero instances of pass-through variables that should survive to Docker Compose runtime.

### 3.4 Embedded Bash/Shell Syntax in Templates

Some templates contain shell-like strings that could theoretically conflict:

- `mariadb/service.yml` line 14: `"-p${DB_ROOT_PASSWORD}"` -- this IS a substitution target (the sed chain replaces it)
- `postgres/service.yml` line 13: `"pg_isready -U ${DB_USER} -d ${DB_NAME}"` -- these ARE substitution targets

No template contains bash scripts, shell expansions, or any `${VAR}` that should be preserved as literal text.

---

## 4. Recommended Design

### 4.1 Recommendation: Option C Hybrid with Helper Function

Use a helper function that exports all needed variables (with defaults resolved) and calls envsubst with a selective variable list. The approach:

- envsubst replaces template placeholders (replacing the sed chains)
- Heredoc sections in the generator remain unchanged (they already use bash expansion)
- Dynamic content construction (WireMock volumes, network aliases, depends_on blocks) remains in bash -- no template files involved

### 4.2 The Helper Function

```bash
# ---------------------------------------------------------------------------
# Template substitution — replaces sed chains
# ---------------------------------------------------------------------------
substitute_template() {
    local template_file="$1"

    # All variables that might appear in any template.
    # Defaults are resolved here, not in templates.
    export PROJECT_NAME
    export APP_SOURCE="${APP_SOURCE_ABS}"
    export DB_TYPE
    export DB_PORT
    export DB_NAME
    export DB_USER
    export DB_PASSWORD
    export DB_ROOT_PASSWORD
    export DEVSTACK_DIR
    export MAILPIT_PORT="${MAILPIT_PORT:-8025}"
    export PROMETHEUS_PORT="${PROMETHEUS_PORT:-9090}"
    export GRAFANA_PORT="${GRAFANA_PORT:-3001}"
    export DOZZLE_PORT="${DOZZLE_PORT:-9999}"
    export NATS_PORT="${NATS_PORT:-4222}"
    export NATS_MONITOR_PORT="${NATS_MONITOR_PORT:-8222}"
    export MINIO_PORT="${MINIO_PORT:-9000}"
    export MINIO_CONSOLE_PORT="${MINIO_CONSOLE_PORT:-9001}"
    export ADMINER_PORT="${ADMINER_PORT:-8083}"
    export SWAGGER_PORT="${SWAGGER_PORT:-8084}"
    export FRONTEND_PORT="${FRONTEND_PORT:-5173}"
    export FRONTEND_SOURCE="${FRONTEND_SOURCE_ABS}"
    export FRONTEND_API_PREFIX="${FRONTEND_API_PREFIX:-/api}"
    export HTTPS_PORT

    envsubst < "${template_file}"
}
```

### 4.3 Usage at Each Substitution Site

**App templates (currently 8 sed commands):**
```bash
# Before (8 piped sed commands):
APP_SERVICE=$(cat "${app_template}" | \
    sed "s|\${PROJECT_NAME}|${PROJECT_NAME}|g" | \
    sed "s|\${APP_SOURCE}|${APP_SOURCE_ABS}|g" | \
    sed "s|\${DB_TYPE}|${DB_TYPE}|g" | \
    sed "s|\${DB_PORT}|${DB_PORT}|g" | \
    sed "s|\${DB_NAME}|${DB_NAME}|g" | \
    sed "s|\${DB_USER}|${DB_USER}|g" | \
    sed "s|\${DB_PASSWORD}|${DB_PASSWORD}|g" | \
    sed "s|\${DB_ROOT_PASSWORD}|${DB_ROOT_PASSWORD}|g")

# After (1 line):
APP_SERVICE=$(substitute_template "${app_template}")
```

**Database templates (currently 5 sed commands):**
```bash
# Before:
DB_SERVICE=$(cat "${db_template}" | \
    sed "s|\${PROJECT_NAME}|${PROJECT_NAME}|g" | \
    sed "s|\${DB_NAME}|${DB_NAME}|g" | \
    sed "s|\${DB_USER}|${DB_USER}|g" | \
    sed "s|\${DB_PASSWORD}|${DB_PASSWORD}|g" | \
    sed "s|\${DB_ROOT_PASSWORD}|${DB_ROOT_PASSWORD}|g")

# After:
DB_SERVICE=$(substitute_template "${db_template}")
```

**Extras templates (currently 17 + 1 sed commands per extra):**
```bash
# Before (17 piped sed commands):
EXTRAS_SERVICES="${EXTRAS_SERVICES}
$(cat "${extra_file}" | \
    sed "s|\${PROJECT_NAME}|${PROJECT_NAME}|g" | \
    sed "s|\${DB_NAME}|${DB_NAME}|g" | \
    ... 15 more sed commands ...)"

# After:
EXTRAS_SERVICES="${EXTRAS_SERVICES}
$(substitute_template "${extra_file}")"
```

**Extras volumes (currently 1 sed command):**
```bash
# Before:
$(cat "${extra_volumes_file}" | sed "s|\${PROJECT_NAME}|${PROJECT_NAME}|g")

# After:
$(substitute_template "${extra_volumes_file}")
```

**Frontend templates (currently 4 sed commands):**
```bash
# Before:
FRONTEND_SERVICE=$(cat "${frontend_template}" | \
    sed "s|\${PROJECT_NAME}|${PROJECT_NAME}|g" | \
    sed "s|\${FRONTEND_SOURCE}|${FRONTEND_SOURCE_ABS}|g" | \
    sed "s|\${FRONTEND_API_PREFIX}|${FRONTEND_API_PREFIX:-/api}|g" | \
    sed "s|\${HTTPS_PORT}|${HTTPS_PORT}|g")

# After:
FRONTEND_SERVICE=$(substitute_template "${frontend_template}")
```

### 4.4 Why Not Selective envsubst?

`envsubst '$VAR1 $VAR2 $VAR3'` restricts replacement to listed variables only. This is safer but:

- Requires maintaining a parallel list of variables per substitution site
- Defeats the purpose of simplification -- we would be replicating the current per-site variable lists
- The full template audit (Section 3) shows there is zero risk of accidental substitution: every `${VAR}` in every template is a legitimate substitution target

The universal `substitute_template` function that exports everything and calls bare `envsubst` is simpler and equally safe.

### 4.5 Why Not Pure envsubst per Site (No Helper)?

Without a helper, each substitution site would need its own export block:

```bash
export PROJECT_NAME APP_SOURCE=...
APP_SERVICE=$(envsubst < "${app_template}")
```

This scatters exports throughout the script and introduces variable-scope concerns (exported variables persist). The helper function is cleaner because:
- Variables are exported in one place
- The function is reusable across all four sites
- Adding a new variable means editing one function, not four sites

---

## 5. Migration Plan

### 5.1 Step 1: Add the substitute_template Function

Add the function near the top of `core/compose/generate.sh`, after the variable derivation section (after line 88, after `FRONTEND_SOURCE_ABS` is computed, but before the extras loop).

Note: `DB_PORT` is derived later (line 162-166), so the function must either be placed after the DB_PORT derivation or the DB_PORT case block must be moved up. **Recommendation**: Move the DB_PORT case block up to immediately after `source "${DEVSTACK_DIR}/project.env"` (line 22). This is a safe reordering -- DB_PORT has no dependencies on anything computed later.

### 5.2 Step 2: Replace Each Substitution Site

Replace one site at a time, testing after each:

1. Extras service templates (lines 103-120) -- largest chain, highest value
2. Extras volumes templates (line 127) -- trivial
3. Database templates (lines 143-148) -- small chain
4. App templates (lines 194-202) -- critical path
5. Frontend templates (lines 215-219) -- only active when frontend configured

### 5.3 Step 3: Verify Output Equivalence

For each substitution site, before committing:

```bash
# Generate with current sed-based code, save output
./devstack.sh generate
cp .generated/docker-compose.yml /tmp/compose-sed.yml

# Apply envsubst changes, regenerate
./devstack.sh generate
cp .generated/docker-compose.yml /tmp/compose-envsubst.yml

# Diff must be empty
diff /tmp/compose-sed.yml /tmp/compose-envsubst.yml
```

### 5.4 Step 4: Run Full Test Suite

```bash
./devstack.sh stop && ./devstack.sh start
./devstack.sh test
# All 6 tests must pass
```

### 5.5 Step 5: Update AI_BOOTSTRAP.md

Change the "When adding a new template variable" section from:
> Add a `sed` substitution in `core/compose/generate.sh`

To:
> Add the variable to the `substitute_template()` function's export block in `core/compose/generate.sh`

### 5.6 Changes to Caddyfile Generator

None. `core/caddy/generate-caddyfile.sh` already uses bash heredocs with native variable expansion. No sed commands exist in that file.

### 5.7 Line Count Impact (Estimated)

| Section | Before (lines) | After (lines) | Delta |
|---|---|---|---|
| substitute_template function | 0 | ~28 | +28 |
| Extras sed chain (lines 103-120) | 18 | 1 | -17 |
| Extras volumes sed (line 127) | 1 | 1 | 0 |
| Database sed chain (lines 143-148) | 6 | 1 | -5 |
| App sed chain (lines 194-202) | 9 | 1 | -8 |
| Frontend sed chain (lines 215-219) | 5 | 1 | -4 |
| **Net change** | | | **-6** |

The line count is roughly neutral, but the complexity reduction is significant: 35 sed commands collapse into 1 function and 5 call sites.

---

## 6. Edge Case Analysis

### 6.1 Variables Containing Special Characters

**Paths with spaces**: `APP_SOURCE_ABS` or `DEVSTACK_DIR` could theoretically contain spaces. Current sed handles this fine because the `|` delimiter avoids conflicts. envsubst also handles this fine -- it does literal string replacement with no interpretation of the value.

**Passwords with special characters**: `DB_PASSWORD` or `DB_ROOT_PASSWORD` could contain `$`, `|`, `\`, or other shell-significant characters. This is where envsubst is **safer** than sed:
- sed interprets `&` and `\` in replacement strings, potentially corrupting passwords containing these characters
- envsubst performs literal replacement -- no interpretation of the value content

**Verdict**: envsubst is equal or better than sed for special characters.

### 6.2 Empty/Undefined Variables

| Scenario | sed behavior | envsubst behavior |
|---|---|---|
| Variable defined, empty value | Replaces with empty string | Replaces with empty string |
| Variable undefined, no default | Placeholder remains as literal `${VAR}` | Replaces with empty string |

The undefined-variable case differs. With sed, if a variable is not in the sed chain, the `${VAR}` placeholder survives into the output (which Docker Compose would then try to resolve). With envsubst, an undefined-but-exported variable becomes empty string.

**Mitigation**: The `substitute_template` function exports ALL known variables. Any `${VAR}` in a template that is not in the export list represents a bug -- the template references a variable the generator does not know about. With sed, this bug is silent (placeholder leaks to Docker). With envsubst, this bug is still silent but different (empty string). Neither approach catches the bug, but envsubst's failure mode (empty string causing a Docker error) is more likely to surface during testing than sed's (Docker trying to resolve the variable from the host environment, which might accidentally succeed).

### 6.3 Variables Used in Multiple Templates

Several variables appear in many templates (e.g., `${PROJECT_NAME}` in all 21). With the sed approach, each substitution site has its own sed chain, so the same variable is replaced identically everywhere.

With the `substitute_template` function, the variable is exported once and used by all call sites. This is actually **more consistent** -- there is zero risk of one substitution site using a different value than another.

### 6.4 Adding a New Variable

**Before (sed)**: Add a new sed command to every substitution site that uses the variable. If the extras chain needs it, add it to the 17-command pipe. If app templates need it, add it to the 8-command pipe. Easy to forget a site.

**After (envsubst)**: Add one `export` line to `substitute_template()`. All templates automatically have access. If a template uses `${NEW_VAR}` but the function does not export it, envsubst produces empty string -- which will likely cause a visible error during testing.

### 6.5 APP_SOURCE Variable Name Collision

There is a subtle issue: in the current code, the sed chain replaces `${APP_SOURCE}` with `${APP_SOURCE_ABS}` (the resolved absolute path). But the shell variable `APP_SOURCE` is set from `project.env` to a relative path like `./app`.

In the `substitute_template` function, we handle this by exporting `APP_SOURCE="${APP_SOURCE_ABS}"`. This shadows the original `APP_SOURCE` value. Since `APP_SOURCE` is not used after the substitution phase, this is safe. But it should be documented in the function.

The same pattern applies to `FRONTEND_SOURCE` which is overridden with `FRONTEND_SOURCE_ABS`.

### 6.6 envsubst Availability as a Dependency

Adding envsubst as a host dependency is a consideration. On most Linux distributions, `envsubst` is available via `gettext-base` (Debian/Ubuntu) or `gettext` (Alpine, Fedora, Arch). On macOS, it requires `brew install gettext`.

**Risk level**: Low. envsubst is part of GNU gettext, which is a ubiquitous POSIX utility. If a user's system lacks it, the error message (`envsubst: command not found`) is clear and the fix is a single package install.

**Mitigation option**: Add a check at the top of `generate.sh`:

```bash
if ! command -v envsubst &>/dev/null; then
    echo "[compose-gen] ERROR: envsubst not found. Install gettext:"
    echo "  Debian/Ubuntu: sudo apt install gettext-base"
    echo "  Alpine: apk add gettext"
    echo "  macOS: brew install gettext"
    exit 1
fi
```

### 6.7 The GRAFANA_PORT Default Discrepancy

The current sed chain for extras uses `${GRAFANA_PORT:-3001}` as the default, but `project.env` does not define `GRAFANA_PORT` and the typical Grafana port is 3000 (which would collide with the app's port 3000). The value `3001` is the correct host-side port to avoid collision. This default must be preserved in the `substitute_template` function's export block. All 12 port defaults currently in the sed chain must be carried over exactly.

---

## 7. Risks and Non-Risks Summary

| Concern | Risk level | Notes |
|---|---|---|
| Template syntax changes | None | Templates already use `${VAR}` -- no changes needed |
| Docker Compose `${VAR}` collision | None | All template vars are build-time, none pass through to Docker |
| Special chars in values | Improved | envsubst is safer than sed for `&`, `\` in passwords |
| Undefined variables | Low | Different failure mode (empty string vs literal placeholder), both are bugs |
| New dependency (envsubst) | Low | Ubiquitous POSIX utility, clear error if missing |
| Variable name shadowing | Low | `APP_SOURCE` and `FRONTEND_SOURCE` are shadowed; safe because original values are not needed after substitution |
| Caddyfile generator impact | None | Already uses bash heredocs, no sed, no changes needed |
| Default value handling | None | Defaults resolved via bash `${VAR:-default}` before export, same as current sed approach |
