# Research 11: devstack.sh Modular Split Design

> **Status**: Research complete (2026-03-20)
> **Drives**: Task D3 from `docs/REVIEW-FINDINGS-TASKS.md`
> **Scope**: Split `devstack.sh` (1,688 lines) into sourced modules without changing user-facing behavior

---

## 1. Complete Function Inventory

### 1.1 Function Table

| # | Function | Lines | Line Range | Purpose |
|---|----------|-------|------------|---------|
| 1 | `log` | 1 | 36 | Blue-prefixed info message |
| 2 | `log_ok` | 1 | 37 | Green-prefixed success message |
| 3 | `log_warn` | 1 | 38 | Yellow-prefixed warning message |
| 4 | `log_err` | 1 | 39 | Red-prefixed error message |
| 5 | `check_docker` | 9 | 41-50 | Verify docker + compose v2 installed |
| 6 | `load_config` | 8 | 52-59 | Source project.env into shell |
| 7 | `cmd_generate` | 17 | 64-81 | Run Caddyfile + compose generators |
| 8 | `cmd_start` | 113 | 86-199 | Full startup: generate, build, run, wait, summarize |
| 9 | `cmd_stop` | 25 | 204-228 | Tear down containers, clean generated files and test artifacts |
| 10 | `cmd_test` | 47 | 233-279 | Run Playwright tests inside tester container |
| 11 | `cmd_shell` | 18 | 284-301 | Interactive shell into a service container |
| 12 | `cmd_status` | 10 | 306-315 | Show `docker compose ps` formatted output |
| 13 | `cmd_logs` | 18 | 320-337 | Tail logs for a service or all services |
| 14 | `cmd_mocks` | 65 | 342-406 | List all configured mock services and their domains/mappings |
| 15 | `cmd_restart` | 4 | 411-414 | Convenience: `cmd_stop` then `cmd_start` |
| 16 | `cmd_reload_mocks` | 31 | 419-449 | Hot-reload WireMock mappings via admin API |
| 17 | `cmd_new_mock` | 60 | 454-513 | Scaffold a new mock directory with example mapping |
| 18 | `cmd_record` | 104 | 518-621 | Proxy to real API via temporary WireMock recorder container |
| 19 | `cmd_apply_recording` | 79 | 626-713 | Copy recorded mappings into active mock, fix paths |
| 20 | `cmd_verify_mocks` | 57 | 718-774 | Test each mocked domain is reachable from app container |
| 21 | `cmd_init` | 100 | 779-918 | Interactive project scaffolding |
| 22 | `require_jq` | 8 | 925-932 | Check jq is installed, emit contract error if not |
| 23 | `cmd_contract_options` | 15 | 935-949 | Output manifest.json as JSON to stdout |
| 24 | `cmd_contract_bootstrap` | 90 | 952-1041 | Parse --bootstrap args, validate payload, generate, respond |
| 25 | `validate_bootstrap_payload` | 143 | 1045-1191 | 11-check validation of bootstrap JSON against manifest |
| 26 | `resolve_wiring` | 99 | 1197-1296 | Resolve wiring template rules from manifest |
| 27 | `generate_from_bootstrap` | 252 | 1300-1551 | Generate project.env, scaffold dirs, run generators |
| 28 | `build_bootstrap_response` | 47 | 1554-1599 | Build JSON success response with resolved services |
| 29 | `main` | 85 | 1604-1688 | Entry point: contract flags, load config, route commands |

**Total**: 29 functions, 1,688 lines

### 1.2 Line Count by Functional Area

| Area | Functions | Lines | % of Total |
|------|-----------|-------|------------|
| Logging/helpers | `log`, `log_ok`, `log_warn`, `log_err`, `check_docker`, `load_config` | ~20 | 1.2% |
| Config generation | `cmd_generate` | ~17 | 1.0% |
| Lifecycle | `cmd_start`, `cmd_stop`, `cmd_restart` | ~142 | 8.4% |
| Observability | `cmd_status`, `cmd_logs`, `cmd_shell` | ~46 | 2.7% |
| Testing | `cmd_test` | ~47 | 2.8% |
| Mocks | `cmd_mocks`, `cmd_new_mock`, `cmd_reload_mocks`, `cmd_record`, `cmd_apply_recording`, `cmd_verify_mocks` | ~396 | 23.5% |
| Init/scaffolding | `cmd_init` | ~100 | 5.9% |
| Contract (PowerHouse) | `require_jq`, `cmd_contract_options`, `cmd_contract_bootstrap`, `validate_bootstrap_payload`, `resolve_wiring`, `generate_from_bootstrap`, `build_bootstrap_response` | ~654 | 38.7% |
| Entry point + help | `main` (includes help text) | ~85 | 5.0% |
| Non-function code | Color constants, shebang, header, `set -euo pipefail`, `DEVSTACK_DIR`/`GENERATED_DIR` init | ~25 | 1.5% |

### 1.3 Globals Read/Written per Function

| Function | Reads | Sets |
|----------|-------|------|
| `log`, `log_ok`, `log_warn`, `log_err` | Color constants (`BLUE`, `GREEN`, `YELLOW`, `RED`, `NC`) | -- |
| `check_docker` | -- | -- |
| `load_config` | `DEVSTACK_DIR` | Sources `project.env` into current shell (all project vars) |
| `cmd_generate` | `DEVSTACK_DIR`, `GENERATED_DIR` | -- (but child scripts read project vars) |
| `cmd_start` | `DEVSTACK_DIR`, `GENERATED_DIR`, `PROJECT_NAME`, `APP_SOURCE`, `DB_TYPE`, `APP_INIT_SCRIPT`, `HTTP_PORT`, `HTTPS_PORT`, `TEST_DASHBOARD_PORT`, `DB_NAME`, `DB_USER`, `CYAN`, `NC` | -- |
| `cmd_stop` | `DEVSTACK_DIR`, `GENERATED_DIR`, `PROJECT_NAME` | -- |
| `cmd_test` | `DEVSTACK_DIR`, `GENERATED_DIR`, `PROJECT_NAME`, `TEST_DASHBOARD_PORT` | -- |
| `cmd_shell` | `GENERATED_DIR`, `PROJECT_NAME` | -- |
| `cmd_status` | `GENERATED_DIR`, `PROJECT_NAME` | -- |
| `cmd_logs` | `GENERATED_DIR`, `PROJECT_NAME` | -- |
| `cmd_mocks` | `DEVSTACK_DIR`, `CYAN`, `YELLOW`, `NC` | -- |
| `cmd_restart` | (transitive via `cmd_stop` + `cmd_start`) | -- |
| `cmd_reload_mocks` | `GENERATED_DIR`, `PROJECT_NAME` | -- |
| `cmd_new_mock` | `DEVSTACK_DIR` | -- |
| `cmd_record` | `DEVSTACK_DIR`, `GENERATED_DIR`, `PROJECT_NAME` | -- |
| `cmd_apply_recording` | `DEVSTACK_DIR`, `GENERATED_DIR` | -- |
| `cmd_verify_mocks` | `DEVSTACK_DIR`, `GENERATED_DIR`, `PROJECT_NAME`, `GREEN`, `RED`, `NC` | -- |
| `cmd_init` | `DEVSTACK_DIR` | Writes `project.env` file (not shell vars) |
| `require_jq` | -- | -- |
| `cmd_contract_options` | `DEVSTACK_DIR` | -- |
| `cmd_contract_bootstrap` | `DEVSTACK_DIR` | -- |
| `validate_bootstrap_payload` | -- (pure: args only) | -- |
| `resolve_wiring` | -- (pure: args only) | -- |
| `generate_from_bootstrap` | `DEVSTACK_DIR` | Writes `project.env`, creates dirs/files |
| `build_bootstrap_response` | -- (pure: args only) | -- |
| `main` | `DEVSTACK_DIR` | -- |

### 1.4 External Commands per Function

| Function | External Commands |
|----------|------------------|
| `check_docker` | `docker`, `docker compose` |
| `load_config` | `source` (bash builtin) |
| `cmd_generate` | `mkdir`, `bash` (child scripts) |
| `cmd_start` | `mkdir`, `docker compose` (build, up, wait, exec), `docker inspect`, `sleep`, `cat`, `tr`, `sed`, `basename` |
| `cmd_stop` | `docker compose` (down), `rm`, `docker run` (alpine cleanup) |
| `cmd_test` | `date`, `mkdir`, `docker compose` (exec) |
| `cmd_shell` | `docker compose` (exec) |
| `cmd_status` | `docker compose` (ps) |
| `cmd_logs` | `docker compose` (logs) |
| `cmd_mocks` | `basename`, `cat`, `tr`, `sed`, `find`, `grep` |
| `cmd_reload_mocks` | `docker compose` (exec wiremock wget) |
| `cmd_new_mock` | `mkdir`, `cat` (heredoc) |
| `cmd_record` | `head`, `tr`, `docker compose`, `docker run` (wiremock recorder, alpine count) |
| `cmd_apply_recording` | `docker run` (alpine copy/fix), `mkdir`, `rmdir`, `basename` |
| `cmd_verify_mocks` | `docker compose` (exec app wget), `basename`, `cat`, `tr`, `grep` |
| `cmd_init` | `ls`, `read` (bash builtin), `mkdir`, `cp`, `cat`, `chmod` |
| `require_jq` | `jq` |
| `cmd_contract_options` | `jq` |
| `cmd_contract_bootstrap` | `jq`, `printf` |
| `validate_bootstrap_payload` | `jq` (single invocation, all logic in jq filter) |
| `resolve_wiring` | `jq` (single invocation) |
| `generate_from_bootstrap` | `printf`, `jq`, `mkdir`, `cp`, `cat`, `chmod` |
| `build_bootstrap_response` | `jq` |

---

## 2. Dependency Graph

### 2.1 Call Graph

```
main()
  |
  +-- [contract path, no load_config]
  |     +-- require_jq()
  |     +-- cmd_contract_options()
  |     +-- cmd_contract_bootstrap()
  |           +-- validate_bootstrap_payload()  [pure jq]
  |           +-- check_docker()
  |           +-- generate_from_bootstrap()
  |           |     +-- cmd_generate()
  |           +-- build_bootstrap_response()
  |                 +-- resolve_wiring()  [pure jq]
  |
  +-- [standard path, requires load_config]
        +-- check_docker()
        +-- load_config()
        +-- cmd_start()
        |     +-- cmd_generate()
        +-- cmd_stop()
        +-- cmd_restart()
        |     +-- cmd_stop()
        |     +-- cmd_start()
        |           +-- cmd_generate()
        +-- cmd_test()
        +-- cmd_shell()
        +-- cmd_status()
        +-- cmd_logs()
        +-- cmd_generate()
        +-- cmd_mocks()
        +-- cmd_reload_mocks()
        +-- cmd_new_mock()
        +-- cmd_record()
        +-- cmd_apply_recording()
        |     +-- cmd_reload_mocks()
        +-- cmd_verify_mocks()
        +-- cmd_init()
```

### 2.2 Cross-Function Dependencies

Direct internal calls (function A calls function B):

| Caller | Calls |
|--------|-------|
| `cmd_start` | `cmd_generate` |
| `cmd_restart` | `cmd_stop`, `cmd_start` |
| `cmd_apply_recording` | `cmd_reload_mocks` |
| `cmd_contract_bootstrap` | `validate_bootstrap_payload`, `check_docker`, `generate_from_bootstrap`, `build_bootstrap_response` |
| `generate_from_bootstrap` | `cmd_generate`, `resolve_wiring` |
| `build_bootstrap_response` | `resolve_wiring` |
| `main` | `require_jq`, `check_docker`, `load_config`, all `cmd_*` functions |

### 2.3 Coupling Clusters

**Cluster 1: Logging** (leaf, no dependencies)
- `log`, `log_ok`, `log_warn`, `log_err`
- Required by every other cluster

**Cluster 2: Config** (leaf, depends on logging)
- `check_docker`, `load_config`
- Required by lifecycle and contract clusters

**Cluster 3: Generation** (depends on config, logging)
- `cmd_generate`
- Called by lifecycle cluster and contract cluster

**Cluster 4: Lifecycle** (depends on config, generation, logging)
- `cmd_start`, `cmd_stop`, `cmd_restart`
- `cmd_start` calls `cmd_generate`
- `cmd_restart` calls both `cmd_stop` and `cmd_start`

**Cluster 5: Observability** (depends on config, logging; independent leaf)
- `cmd_status`, `cmd_logs`, `cmd_shell`

**Cluster 6: Testing** (depends on config, logging; independent leaf)
- `cmd_test`

**Cluster 7: Mocks** (depends on config, logging; `cmd_apply_recording` depends on `cmd_reload_mocks`)
- `cmd_mocks`, `cmd_new_mock`, `cmd_reload_mocks`, `cmd_record`, `cmd_apply_recording`, `cmd_verify_mocks`

**Cluster 8: Init** (depends on logging; independent leaf)
- `cmd_init`

**Cluster 9: Contract** (depends on config, generation, logging)
- `require_jq`, `cmd_contract_options`, `cmd_contract_bootstrap`, `validate_bootstrap_payload`, `resolve_wiring`, `generate_from_bootstrap`, `build_bootstrap_response`
- `generate_from_bootstrap` calls `cmd_generate` (cross-cluster dependency on generation)
- `cmd_contract_bootstrap` calls `check_docker` (cross-cluster dependency on config)

### 2.4 Shared State Dependencies (Visual)

```
DEVSTACK_DIR ─────── set once at top ────── read by 21 of 29 functions
GENERATED_DIR ────── set once at top ────── read by 14 of 29 functions
PROJECT_NAME ─────── set by load_config ─── read by lifecycle, observability, mocks, testing
APP_SOURCE ───────── set by load_config ─── read by cmd_start only
DB_TYPE ──────────── set by load_config ─── read by cmd_start only
APP_INIT_SCRIPT ──── set by load_config ─── read by cmd_start only
HTTP_PORT ────────── set by load_config ─── read by cmd_start only
HTTPS_PORT ───────── set by load_config ─── read by cmd_start only
TEST_DASHBOARD_PORT ─ set by load_config ── read by cmd_start, cmd_test
DB_NAME, DB_USER ─── set by load_config ─── read by cmd_start only
Color constants ──── set once at top ────── read by all logging + a few display functions
```

---

## 3. Module Design

### 3.1 Proposed File Structure

```
devstack.sh                     -- Entry point (source + route)
core/lib/logging.sh             -- Colors, log functions
core/lib/config.sh              -- check_docker, load_config
core/lib/lifecycle.sh           -- cmd_start, cmd_stop, cmd_restart, cmd_generate
core/lib/mocks.sh               -- cmd_mocks, cmd_new_mock, cmd_reload_mocks,
                                   cmd_record, cmd_apply_recording, cmd_verify_mocks
core/lib/testing.sh             -- cmd_test
core/lib/observability.sh       -- cmd_status, cmd_logs, cmd_shell
core/lib/init.sh                -- cmd_init
core/contract/options.sh        -- require_jq, cmd_contract_options
core/contract/bootstrap.sh      -- cmd_contract_bootstrap, validate_bootstrap_payload,
                                   resolve_wiring, generate_from_bootstrap,
                                   build_bootstrap_response
```

### 3.2 Module Details

#### `core/lib/logging.sh` (~15 lines)

**Functions**:
- `log`, `log_ok`, `log_warn`, `log_err`

**Variables defined**:
- `RED`, `GREEN`, `YELLOW`, `BLUE`, `CYAN`, `NC`

**Sources**: nothing

**Sourced by**: every other module (transitively, via entry point)

**Exports**: All 4 log functions + 6 color constants

**Notes**: This is the absolute leaf dependency. No function in this file calls any other function outside of itself. All it does is define ANSI color codes and 4 one-liner echo wrappers.

---

#### `core/lib/config.sh` (~20 lines)

**Functions**:
- `check_docker`
- `load_config`

**Variables read**: `DEVSTACK_DIR`

**Sources**: `core/lib/logging.sh` (needs `log_err`)

**Exports**: `check_docker`, `load_config`

**Notes**: `load_config` sources `project.env` into the current shell, making all project variables available to subsequently-called functions. This is why modules cannot be sourced lazily after load_config -- they need to run in the same shell context.

---

#### `core/lib/lifecycle.sh` (~160 lines)

**Functions**:
- `cmd_generate` (17 lines)
- `cmd_start` (113 lines)
- `cmd_stop` (25 lines)
- `cmd_restart` (4 lines)

**Variables read**: `DEVSTACK_DIR`, `GENERATED_DIR`, `PROJECT_NAME`, `APP_SOURCE`, `DB_TYPE`, `APP_INIT_SCRIPT`, `HTTP_PORT`, `HTTPS_PORT`, `TEST_DASHBOARD_PORT`, `DB_NAME`, `DB_USER`, `CYAN`, `NC`

**Sources**: `core/lib/logging.sh`, `core/lib/config.sh`

**Internal calls**: `cmd_start` calls `cmd_generate`; `cmd_restart` calls `cmd_stop` + `cmd_start`

**Exports**: `cmd_generate`, `cmd_start`, `cmd_stop`, `cmd_restart`

**Notes**: `cmd_generate` is also called by `generate_from_bootstrap` in the contract module. This is the key cross-cluster dependency. Since all modules are sourced at startup, this works naturally -- `generate_from_bootstrap` can call `cmd_generate` because it's already defined in the shell.

---

#### `core/lib/mocks.sh` (~400 lines)

**Functions**:
- `cmd_mocks` (65 lines)
- `cmd_new_mock` (60 lines)
- `cmd_reload_mocks` (31 lines)
- `cmd_record` (104 lines)
- `cmd_apply_recording` (79 lines)
- `cmd_verify_mocks` (57 lines)

**Variables read**: `DEVSTACK_DIR`, `GENERATED_DIR`, `PROJECT_NAME`, `CYAN`, `YELLOW`, `GREEN`, `RED`, `NC`

**Sources**: `core/lib/logging.sh`

**Internal calls**: `cmd_apply_recording` calls `cmd_reload_mocks`

**Exports**: All 6 mock functions

**Notes**: This is the largest coherent module. All functions operate on the `mocks/` directory structure and/or communicate with WireMock via its admin API. The only internal dependency is `cmd_apply_recording -> cmd_reload_mocks`, both within the same module.

---

#### `core/lib/testing.sh` (~50 lines)

**Functions**:
- `cmd_test`

**Variables read**: `DEVSTACK_DIR`, `GENERATED_DIR`, `PROJECT_NAME`, `TEST_DASHBOARD_PORT`

**Sources**: `core/lib/logging.sh`

**Exports**: `cmd_test`

**Notes**: Completely independent leaf module. No internal function calls.

---

#### `core/lib/observability.sh` (~50 lines)

**Functions**:
- `cmd_status` (10 lines)
- `cmd_logs` (18 lines)
- `cmd_shell` (18 lines)

**Variables read**: `GENERATED_DIR`, `PROJECT_NAME`

**Sources**: `core/lib/logging.sh`

**Exports**: `cmd_status`, `cmd_logs`, `cmd_shell`

**Notes**: All three are simple `docker compose` wrappers. Independent leaf module.

---

#### `core/lib/init.sh` (~105 lines)

**Functions**:
- `cmd_init`

**Variables read**: `DEVSTACK_DIR`

**Sources**: `core/lib/logging.sh`

**Exports**: `cmd_init`

**Notes**: Independent leaf module. Does not call `load_config` (it writes `project.env`, it doesn't read it). Uses `read` builtin for interactive input.

---

#### `core/contract/options.sh` (~25 lines)

**Functions**:
- `require_jq`
- `cmd_contract_options`

**Variables read**: `DEVSTACK_DIR`

**Sources**: `core/lib/logging.sh` (transitively, though `require_jq` doesn't use logging -- it emits raw JSON)

**Exports**: `require_jq`, `cmd_contract_options`

**Notes**: `require_jq` is also needed by `cmd_contract_bootstrap`. Since all modules are sourced at entry, it's available. Alternatively, `require_jq` could live in `config.sh` but it's more semantically aligned with the contract interface.

---

#### `core/contract/bootstrap.sh` (~645 lines)

**Functions**:
- `cmd_contract_bootstrap` (90 lines)
- `validate_bootstrap_payload` (143 lines)
- `resolve_wiring` (99 lines)
- `generate_from_bootstrap` (252 lines)
- `build_bootstrap_response` (47 lines)

**Variables read**: `DEVSTACK_DIR`

**Sources**: `core/lib/logging.sh`, `core/contract/options.sh` (for `require_jq`)

**Cross-module calls**:
- `cmd_contract_bootstrap` calls `check_docker` (from `config.sh`)
- `generate_from_bootstrap` calls `cmd_generate` (from `lifecycle.sh`)

**Exports**: `cmd_contract_bootstrap`, `validate_bootstrap_payload`, `resolve_wiring`, `generate_from_bootstrap`, `build_bootstrap_response`

**Notes**: This is the largest single module at ~645 lines, dominated by the `jq` filter in `validate_bootstrap_payload` (143 lines of jq). The cross-module calls to `check_docker` and `cmd_generate` work because all modules are sourced before any function executes. `validate_bootstrap_payload`, `resolve_wiring`, and `build_bootstrap_response` are effectively pure functions (args in, stdout out) making them independently testable.

---

#### `devstack.sh` — Entry Point (~95 lines)

**Contents**:
- Shebang, `set -euo pipefail`
- `DEVSTACK_DIR` and `GENERATED_DIR` initialization
- Source all modules
- `main()` function: contract flag handling, `check_docker`, `load_config`, command routing, help text

**Estimated structure**:
```bash
#!/bin/bash
set -euo pipefail

DEVSTACK_DIR="$(cd "$(dirname "$0")" && pwd)"
GENERATED_DIR="${DEVSTACK_DIR}/.generated"

# Source modules
source "${DEVSTACK_DIR}/core/lib/logging.sh"
source "${DEVSTACK_DIR}/core/lib/config.sh"
source "${DEVSTACK_DIR}/core/lib/lifecycle.sh"
source "${DEVSTACK_DIR}/core/lib/observability.sh"
source "${DEVSTACK_DIR}/core/lib/testing.sh"
source "${DEVSTACK_DIR}/core/lib/mocks.sh"
source "${DEVSTACK_DIR}/core/lib/init.sh"
source "${DEVSTACK_DIR}/core/contract/options.sh"
source "${DEVSTACK_DIR}/core/contract/bootstrap.sh"

main() {
    # ... contract flags, check_docker, load_config, case statement, help ...
}

main "$@"
```

### 3.3 Line Count Summary

| Module | Est. Lines | % of Original |
|--------|-----------|---------------|
| `devstack.sh` (entry) | ~95 | 5.6% |
| `core/lib/logging.sh` | ~15 | 0.9% |
| `core/lib/config.sh` | ~20 | 1.2% |
| `core/lib/lifecycle.sh` | ~160 | 9.5% |
| `core/lib/mocks.sh` | ~400 | 23.7% |
| `core/lib/testing.sh` | ~50 | 3.0% |
| `core/lib/observability.sh` | ~50 | 3.0% |
| `core/lib/init.sh` | ~105 | 6.2% |
| `core/contract/options.sh` | ~25 | 1.5% |
| `core/contract/bootstrap.sh` | ~645 | 38.2% |
| **Total** | **~1,565** | **93%** |

The ~7% reduction comes from eliminating duplicated headers/comments that currently appear once at the top but won't need to be repeated in every module, plus the restructured entry point being slightly more compact than the current inline approach.

---

## 4. Shared State Design

### 4.1 Variable Categories

**Category A: Set at script start, never change**
```bash
DEVSTACK_DIR="$(cd "$(dirname "$0")" && pwd)"   # line 22
GENERATED_DIR="${DEVSTACK_DIR}/.generated"        # line 23
RED='\033[0;31m'                                  # lines 29-34
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'
```

These are constants. `DEVSTACK_DIR` and `GENERATED_DIR` must be set in the entry point before sourcing any module. Color constants are set in `logging.sh`.

**Category B: Set by `load_config` (sourcing project.env)**
```
PROJECT_NAME, NETWORK_SUBNET, APP_TYPE, APP_SOURCE, APP_INIT_SCRIPT,
HTTP_PORT, HTTPS_PORT, TEST_DASHBOARD_PORT, MAILPIT_PORT,
DB_TYPE, DB_NAME, DB_USER, DB_PASSWORD, DB_ROOT_PASSWORD,
EXTRAS, FRONTEND_TYPE, FRONTEND_SOURCE, FRONTEND_PORT, FRONTEND_API_PREFIX
PROMETHEUS_PORT, GRAFANA_PORT, DOZZLE_PORT, ADMINER_PORT, SWAGGER_PORT
```

These are set by `source "${DEVSTACK_DIR}/project.env"` inside `load_config()`. Once sourced, they're available to all functions in the same shell process. The contract path (`--options`, `--bootstrap`) intentionally skips `load_config` because it operates before `project.env` exists.

**Category C: Set by contract bootstrap (local to generate_from_bootstrap)**

Variables like `project_name`, `app_type`, `db_type`, `extras`, `frontend_type`, etc. inside `generate_from_bootstrap` are declared `local` and don't leak. They're used to write `project.env`, not read from it.

### 4.2 Initialization Order

```
1. devstack.sh sets DEVSTACK_DIR, GENERATED_DIR
2. source core/lib/logging.sh         -- sets color constants, defines log functions
3. source core/lib/config.sh          -- defines check_docker, load_config
4. source core/lib/lifecycle.sh       -- defines cmd_generate, cmd_start, cmd_stop, cmd_restart
5. source core/lib/observability.sh   -- defines cmd_status, cmd_logs, cmd_shell
6. source core/lib/testing.sh         -- defines cmd_test
7. source core/lib/mocks.sh           -- defines 6 mock functions
8. source core/lib/init.sh            -- defines cmd_init
9. source core/contract/options.sh    -- defines require_jq, cmd_contract_options
10. source core/contract/bootstrap.sh  -- defines 5 contract functions
11. main() is called
    11a. [contract path] require_jq, cmd_contract_options or cmd_contract_bootstrap
    11b. [standard path] check_docker, load_config (sets Category B vars), route to cmd_*
```

### 4.3 How `source` Works for Module Loading

When bash executes `source file.sh`, it reads and executes the file in the **current shell context**. This means:
- All functions defined in the sourced file are available to subsequent code
- All variables set in the sourced file are available (unless declared `local`)
- There is no namespace isolation -- name collisions will silently overwrite

**Performance**: `source` reads and parses the file once at startup. For 10 files totaling ~1,565 lines of bash, this adds <10ms to startup. Negligible compared to the `docker compose` calls that follow (100ms+). There is no runtime penalty after sourcing -- functions execute from memory.

**No lazy loading needed**: Every command invocation loads all modules. This is the standard pattern for bash CLI tools (e.g., git-sh-setup, nvm.sh). The total script is small enough that splitting and lazy-loading individual modules would add complexity with no measurable benefit.

### 4.4 Avoiding State Bugs

Rules for the split:
1. **`DEVSTACK_DIR` and `GENERATED_DIR` must be set in the entry point**, before any `source` statement. Modules reference them but must not redefine them.
2. **Modules must not call `load_config`**. Only `main()` calls it, and only on the standard (non-contract) path.
3. **Modules must not set global variables** except in their designated scope (colors in logging.sh, functions everywhere).
4. **Each module should have a header comment** declaring what variables it expects to be set when its functions are called.

---

## 5. Entry Point Design

### 5.1 Post-Split `devstack.sh`

```bash
#!/bin/bash
# =============================================================================
# DevStack CLI
# =============================================================================
# A container-first development environment with transparent mock interception.
# This is the entry point. All logic lives in core/lib/ and core/contract/.
# =============================================================================

set -euo pipefail

DEVSTACK_DIR="$(cd "$(dirname "$0")" && pwd)"
GENERATED_DIR="${DEVSTACK_DIR}/.generated"

# Load all modules
source "${DEVSTACK_DIR}/core/lib/logging.sh"
source "${DEVSTACK_DIR}/core/lib/config.sh"
source "${DEVSTACK_DIR}/core/lib/lifecycle.sh"
source "${DEVSTACK_DIR}/core/lib/observability.sh"
source "${DEVSTACK_DIR}/core/lib/testing.sh"
source "${DEVSTACK_DIR}/core/lib/mocks.sh"
source "${DEVSTACK_DIR}/core/lib/init.sh"
source "${DEVSTACK_DIR}/core/contract/options.sh"
source "${DEVSTACK_DIR}/core/contract/bootstrap.sh"

main() {
    # Contract flags: these do not require project.env
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
    esac

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
        generate)         cmd_generate "$@" ;;
        mocks)            cmd_mocks "$@" ;;
        reload-mocks)     cmd_reload_mocks "$@" ;;
        new-mock)         cmd_new_mock "$@" ;;
        record)           cmd_record "$@" ;;
        apply-recording)  cmd_apply_recording "$@" ;;
        verify-mocks)     cmd_verify_mocks "$@" ;;
        init)             cmd_init "$@" ;;
        help|--help|-h)
            echo ""
            echo "DevStack -- Container-first development with transparent mock interception"
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
```

This is ~95 lines. The help text accounts for ~30 of those and could be extracted to a function in a module, but there's no practical benefit -- it's a static string.

### 5.2 Testing Implications

The modular structure enables sourcing individual modules for unit testing:

```bash
# In a test file:
DEVSTACK_DIR="/path/to/dev-strap"
GENERATED_DIR="${DEVSTACK_DIR}/.generated"
source "${DEVSTACK_DIR}/core/lib/logging.sh"
source "${DEVSTACK_DIR}/core/lib/config.sh"

# Now test check_docker, load_config in isolation
```

For the contract module specifically:

```bash
# Source only what's needed for contract tests:
DEVSTACK_DIR="/path/to/dev-strap"
source "${DEVSTACK_DIR}/core/lib/logging.sh"
source "${DEVSTACK_DIR}/core/contract/options.sh"
source "${DEVSTACK_DIR}/core/contract/bootstrap.sh"
# lifecycle.sh needed because generate_from_bootstrap calls cmd_generate
source "${DEVSTACK_DIR}/core/lib/lifecycle.sh"

# Test validate_bootstrap_payload directly without docker
```

The existing test harness (`tests/contract/test-contract.sh`) calls `devstack.sh` as a subprocess, so it exercises the full source chain automatically. No changes needed to existing tests.

---

## 6. Backward Compatibility

### 6.1 User-Facing Behavior: No Change

The split is purely internal. All user commands (`./devstack.sh start`, `./devstack.sh --bootstrap`, etc.) work identically because:
- The entry point file is still `devstack.sh` at the project root
- All function names are preserved
- All argument handling is preserved
- All output (stdout/stderr) is identical

### 6.2 File Paths

New files created:
- `core/lib/logging.sh`
- `core/lib/config.sh`
- `core/lib/lifecycle.sh`
- `core/lib/observability.sh`
- `core/lib/testing.sh`
- `core/lib/mocks.sh`
- `core/lib/init.sh`
- `core/contract/options.sh`
- `core/contract/bootstrap.sh`

No existing files are renamed or moved. `devstack.sh` remains at the root.

**Documentation impact**: `docs/AI_BOOTSTRAP.md` lists `devstack.sh` as a file to read. After the split, the instruction should be updated to read the entry point plus the relevant module. However, since `devstack.sh` still sources everything, reading `devstack.sh` still gives the full picture of the CLI structure (commands, routing). The functions just live elsewhere.

### 6.3 Hooks and External Callers

The contract interface (`DEVSTRAP-POWERHOUSE-CONTRACT.md`) specifies that PowerHouse calls:
```bash
./devstack.sh --options
./devstack.sh --bootstrap --config <path>
```

These work identically after the split. The contract specifies command-line invocations, not internal function names.

The test harness (`tests/contract/test-contract.sh`) calls `./devstack.sh` as a subprocess. No changes needed.

### 6.4 `core/` Directory Conflict Check

The `core/` directory already exists with:
```
core/caddy/generate-caddyfile.sh
core/certs/generate.sh
core/compose/generate.sh
```

The new `core/lib/` and `core/contract/` subdirectories don't conflict with these existing paths. The `contract/` directory also already exists at the project root (contains `manifest.json`), but `core/contract/` is a separate path with no collision.

---

## 7. Migration Plan

### 7.1 Approach: Atomic (One Commit)

**Recommended**: Perform the split in a single commit. Rationale:
- The split is mechanical (move functions, add `source` lines)
- No logic changes are made
- An incremental approach would require temporary duplication or forwarding stubs
- The existing 113 contract test assertions + Playwright tests provide a safety net
- A single commit makes the refactoring reviewable as a coherent unit

### 7.2 Step-by-Step Procedure

1. **Create directory structure**
   ```
   mkdir -p core/lib core/contract
   ```

2. **Extract modules** (in dependency order, bottom-up):
   - Extract `core/lib/logging.sh` (colors + log functions)
   - Extract `core/lib/config.sh` (`check_docker`, `load_config`)
   - Extract `core/lib/lifecycle.sh` (`cmd_generate`, `cmd_start`, `cmd_stop`, `cmd_restart`)
   - Extract `core/lib/observability.sh` (`cmd_status`, `cmd_logs`, `cmd_shell`)
   - Extract `core/lib/testing.sh` (`cmd_test`)
   - Extract `core/lib/mocks.sh` (all 6 mock functions)
   - Extract `core/lib/init.sh` (`cmd_init`)
   - Extract `core/contract/options.sh` (`require_jq`, `cmd_contract_options`)
   - Extract `core/contract/bootstrap.sh` (5 contract functions)

3. **Rewrite entry point**: Replace function bodies in `devstack.sh` with `source` lines + slim `main()`

4. **Add module headers**: Each module gets a comment block declaring its purpose and expected globals

5. **Verify**: Run the full test suite

### 7.3 Test Strategy

**Phase 1: Existing tests must pass (no new tests)**

The contract test suite (`tests/contract/test-contract.sh`) has 113 assertions covering:
- `--options` output structure and content
- `--bootstrap` validation (all 11 checks)
- `--bootstrap` generation (project.env, scaffolded dirs, Dockerfile copy)
- `--bootstrap` response format (services, commands, wiring)
- Edge cases (stdin, missing config, invalid JSON)
- Port conflict detection
- Wiring resolution

Since these tests invoke `./devstack.sh` as a subprocess, they automatically exercise the new source chain. If any `source` path is wrong or a function is missing, these tests will fail immediately.

The Playwright tests (run via `./devstack.sh test`) exercise the full lifecycle (`start`, `stop`, container health) but require Docker, so they're integration tests.

**Phase 2: Add module-level tests (future)**

After the split, individual modules can be tested in isolation:
```bash
# Test that logging.sh defines expected functions
source core/lib/logging.sh
type log &>/dev/null && echo "PASS" || echo "FAIL"
```

This is optional and can be done as a separate task.

### 7.4 Rollback

If the split introduces issues, `git revert <commit>` restores the monolithic file. No data migration or state cleanup needed.

---

## 8. Robustness Item Mapping

Where the review findings from `docs/REVIEW-FINDINGS-TASKS.md` land in the new module structure:

| Finding | Description | Target Module | Notes |
|---------|-------------|---------------|-------|
| **D1** | Non-destructive restart (`--keep-volumes`) | `core/lib/lifecycle.sh` | Add flag to `cmd_restart`, modify `cmd_stop` to accept `-v` toggle |
| **D2** | Cert domain change detection | `core/lib/lifecycle.sh` | Add domain diff check before skipping cert-gen in `cmd_start` |
| **D5** | project.env validation | `core/lib/config.sh` | Add `validate_config()` called after `load_config` in `main()` |
| **D6** | Clean `mocks/*/recordings/` on stop | `core/lib/lifecycle.sh` | Add recording dir cleanup to `cmd_stop` |
| **B1** | App healthchecks | Templates (`templates/apps/*/service.yml`) | Not in devstack.sh -- these are template changes |
| **B2** | Init missing app types (only lists 3 of 5) | `core/lib/init.sh` | Replace hardcoded list with `ls templates/apps/` |
| **B3** | Port collision false positive (internal vs host) | `core/contract/bootstrap.sh` | Modify check 11 in `validate_bootstrap_payload` |
| **B5** | NATS/MinIO port overrides silently ignored | `core/contract/bootstrap.sh` | Add override handling in `generate_from_bootstrap` |
| **A2** | `--preset` documented but not implemented | `core/lib/init.sh` | Add `--preset` flag parsing to `cmd_init` |
| **B4** | Wiring creates keys not in item defaults | `core/contract/bootstrap.sh` | Modify check 10 in `validate_bootstrap_payload` to exempt wiring keys, or add keys to manifest defaults |

### 8.1 Implementation Order Recommendation

With the modular split in place, these fixes become scoped to a single file each:

1. **D5** in `config.sh` -- small, foundational, validates all subsequent operations
2. **B2** in `init.sh` -- small fix, isolated module
3. **D1** in `lifecycle.sh` -- moderate, changes `cmd_stop` and `cmd_restart` signatures
4. **D6** in `lifecycle.sh` -- small addition to `cmd_stop`
5. **D2** in `lifecycle.sh` -- moderate, needs cert SAN comparison logic
6. **B3** in `bootstrap.sh` -- requires design decision on manifest changes
7. **B5** in `bootstrap.sh` -- mechanical: add `NATS_PORT`, `MINIO_PORT`, etc.
8. **B4** in `bootstrap.sh` -- requires manifest schema change
9. **A2** in `init.sh` -- feature addition, needs manifest/preset integration

---

## 9. Open Questions

### Q1: Should `cmd_generate` live in `lifecycle.sh` or its own `generate.sh`?

**Answer: `lifecycle.sh`**. `cmd_generate` is 17 lines and is called only by `cmd_start` and `generate_from_bootstrap`. It's not large enough to warrant its own file. If it grows (e.g., adding validation, dry-run mode), it can be extracted later.

### Q2: Should `require_jq` live in `config.sh` or `contract/options.sh`?

**Answer: `contract/options.sh`**. It's only used by the contract path. Putting it in `config.sh` would mix contract concerns into general config. If a future non-contract feature needs jq, it can be moved then.

### Q3: Should the help text be in its own module?

**Answer: No**. The help text is ~30 lines and is tightly coupled to the command routing table. Extracting it would create a maintenance burden (updating two files when adding a command) with no readability benefit.

### Q4: Should modules guard against being sourced multiple times?

**Answer: No**. Bash sourcing is idempotent for function definitions. The overhead of include-guard patterns (`if [ -z "${_LOGGING_SH_LOADED:-}" ]`) adds complexity with no real benefit, since the entry point controls the source order and each file is sourced exactly once.

### Q5: What about shellcheck/linting on the split modules?

Each module should pass `shellcheck` independently. This means:
- Modules that reference `DEVSTACK_DIR` or `GENERATED_DIR` should include a shellcheck directive: `# shellcheck disable=SC2154` (variable referenced but not assigned in this file), OR
- Use `# shellcheck source=core/lib/logging.sh` directives to declare the source chain

The cleaner approach is a single `# Expects: DEVSTACK_DIR, GENERATED_DIR` comment at the top of each module, plus a `.shellcheckrc` with `external-sources=true`.
