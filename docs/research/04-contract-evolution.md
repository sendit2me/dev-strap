# Research: Contract Evolution

> **Date**: 2026-03-20
> **Scope**: Port collision detection, preset bundles, contract versioning, auto-wiring, category restructuring, contract documentation updates
> **Input files**: `DEVSTRAP-POWERHOUSE-CONTRACT.md`, `contract/manifest.json`, `devstack.sh` (contract functions), `tests/contract/test-contract.sh`, `docs/dev-strap-catalog-proposals.md`

---

## 1. Port Collision Detection

### Problem

The current `validate_bootstrap_payload()` runs 10 checks but never examines whether two selected items bind to the same host port. Today the manifest already contains collisions waiting to happen:

- `node-express` defaults to port 3000; `go` defaults to port 3000
- `php-laravel` defaults to port 9000; the proposed `minio` defaults api_port 9000
- Proposed `qa-dashboard` port 8082 sits close to `wiremock` port 8443 (no collision, but ranges are tightening)

When PowerHouse sends a bootstrap with two items on the same port, dev-strap generates a docker-compose.yml that fails at `docker compose up` with a cryptic bind error. The user sees no actionable message.

### Design: Validation Check 11

**Goal**: After all 10 existing checks pass (or accumulate errors), walk every selected item's resolved ports (defaults merged with overrides) and detect duplicates. Report all collisions, not just the first.

**Port extraction logic**:

Items declare ports under different key names. There is no single `port` key convention. The manifest uses:
- `port` (single-port items: node-express, go, postgres, redis, etc.)
- `smtp_port` + `ui_port` (mailpit)
- `client_port` + `monitor_port` (proposed NATS)
- `api_port` + `console_port` (proposed MinIO)

All keys whose name ends in `_port` or equals `port` are port declarations. This is a naming convention we should enforce in the manifest — any default key that represents a host port binding must be named `port` or `*_port`.

**Should overrides be checked?** Yes. A user might override `node-express.port` to 5432, colliding with postgres. The collision check must run on _resolved_ values (defaults merged with overrides), not on raw defaults alone.

**Error code**: `PORT_CONFLICT`

**Error message format**:
```
Port 3000 is used by both "app.node-express" (port) and "app.go" (port)
```
For multi-port items:
```
Port 9000 is used by both "app.php-laravel" (port) and "services.minio" (api_port)
```

### Draft Implementation

This is validation check 11, appended after check 10 (override key validation) inside the jq expression in `validate_bootstrap_payload()`:

```bash
# 11. port collision detection
# Build a list of {port, owner, key_name} for every selected item,
# then group by port and flag groups with >1 entry.

# Collect all port bindings: resolved defaults + overrides
([
    ($p.selections // {}) | to_entries[] |
    .key as $cat |
    (.value // {}) | to_entries[] |
    .key as $item |
    .value as $sel |
    (($manifest.categories[$cat].items[$item].defaults // {}) * ($sel.overrides // {})) |
    to_entries[] |
    select(.key == "port" or (.key | endswith("_port"))) |
    {port: (.value | tostring), owner: "\($cat).\($item)", key_name: .key}
] | group_by(.port) | map(select(length > 1))) as $collisions |

reduce ($collisions[]) as $group (.;
    ($group | map(.owner + " (" + .key_name + ")") | join(" and ")) as $owners |
    . + [{
        code: "PORT_CONFLICT",
        message: "Port \($group[0].port) is used by both \($owners)"
    }]
)
```

**Placement**: Append directly after the closing `)` of check 10, before the final single-quote that ends the jq program.

**Key details**:
- `(.value | tostring)` normalizes numbers and strings for comparison (the manifest uses numeric 3000, but an override could arrive as `"3000"`)
- `group_by(.port) | map(select(length > 1))` finds all groups with 2+ items on the same port
- When a group has 3+ items on the same port, they all appear in a single error message. This is better than N(N-1)/2 pairwise errors.
- Overrides are merged before extraction (`defaults * overrides`), so user overrides that create collisions are caught.

### Draft Test Cases

**Fixture: `port-collision-defaults.json`** — Node.js + Go (both default to 3000):
```json
{
  "contract": "devstrap-bootstrap",
  "version": "1",
  "project": "collision-test",
  "selections": {
    "app": {
      "node-express": {},
      "go": {}
    }
  }
}
```
Expected: `PORT_CONFLICT` error mentioning port 3000, `app.node-express`, and `app.go`.

**Fixture: `port-collision-override.json`** — user overrides node-express to 5432, colliding with postgres:
```json
{
  "contract": "devstrap-bootstrap",
  "version": "1",
  "project": "collision-override",
  "selections": {
    "app": {
      "node-express": { "overrides": { "port": 5432 } }
    },
    "database": {
      "postgres": {}
    }
  }
}
```
Expected: `PORT_CONFLICT` error mentioning port 5432.

**Fixture: `port-collision-multi-port.json`** — after NATS/MinIO are added, test multi-port items sharing a port:
```json
{
  "contract": "devstrap-bootstrap",
  "version": "1",
  "project": "multi-port-collision",
  "selections": {
    "app": {
      "node-express": {}
    },
    "services": {
      "minio": {}
    },
    "observability": {
      "prometheus": {}
    }
  }
}
```
Expected: `PORT_CONFLICT` error for port 9000 between `services.minio` (api_port) and `observability.prometheus` (port) -- note: only if MinIO keeps api_port 9000 and prometheus keeps 9090. Adjust once final port assignments are made. The real collision today would be `php-laravel` (9000) vs `minio` (api_port 9000).

**Fixture: `no-port-collision.json`** — valid payload with no collisions:
```json
{
  "contract": "devstrap-bootstrap",
  "version": "1",
  "project": "no-collision",
  "selections": {
    "app": {
      "node-express": {}
    },
    "database": {
      "postgres": {}
    },
    "services": {
      "redis": {}
    }
  }
}
```
Expected: No `PORT_CONFLICT` errors. All ports are distinct (3000, 5432, 6379).

**Fixture: `port-collision-resolved-by-override.json`** — defaults collide but user overrides one:
```json
{
  "contract": "devstrap-bootstrap",
  "version": "1",
  "project": "resolved-collision",
  "selections": {
    "app": {
      "node-express": {},
      "go": { "overrides": { "port": 3001 } }
    }
  }
}
```
Expected: No `PORT_CONFLICT`. The override resolves the default collision.

**Test assertions in `test-contract.sh`**:
```bash
# PORT_CONFLICT: defaults collide
result=$(run_bootstrap "${FIXTURES}/port-collision-defaults.json")
assert_json "PORT_CONFLICT (defaults)" "${result}" '.errors[] | select(.code == "PORT_CONFLICT")'

# PORT_CONFLICT: override creates collision
result=$(run_bootstrap "${FIXTURES}/port-collision-override.json")
assert_json "PORT_CONFLICT (override)" "${result}" '.errors[] | select(.code == "PORT_CONFLICT")'

# No collision when ports are distinct
result=$(run_bootstrap "${FIXTURES}/no-port-collision.json")
assert_json "no PORT_CONFLICT" "${result}" \
    '(.errors // [] | map(select(.code == "PORT_CONFLICT")) | length) == 0'

# Override resolves default collision
result=$(run_bootstrap "${FIXTURES}/port-collision-resolved-by-override.json")
assert_json "override resolves collision" "${result}" \
    '(.errors // [] | map(select(.code == "PORT_CONFLICT")) | length) == 0'
```

### Port Naming Convention (enforce going forward)

Add to the contract documentation: "Any default key that represents a host port binding MUST be named `port` or end with `_port`. This convention enables automated port collision detection. Keys that do not follow this pattern will not be checked for collisions."

### Recommendation

**Implement check 11 immediately.** It is a non-breaking addition to the validation logic. The `PORT_CONFLICT` error code is additive (new error codes do not require a version bump per the contract's "flexible" rules). PowerHouse already handles unknown error codes gracefully by displaying the `message` field.

---

## 2. Preset Bundles

### Design

Presets are a top-level key in the `devstrap-options` response. They are purely informational — PowerHouse uses them to pre-fill its UI, then the user customizes from there. The `--bootstrap` payload is always a full `selections` object; presets are never sent in bootstrap payloads.

This design means presets are **UI-only sugar in the options response**. dev-strap does not need to "expand" presets during validation — by the time `--bootstrap` arrives, PowerHouse has already expanded the preset into concrete selections.

### Schema

```json
{
  "contract": "devstrap-options",
  "version": "1",
  "presets": {
    "<preset-key>": {
      "label": "<string>",
      "description": "<string>",
      "selections": {
        "<category-key>": ["<item-key>", "..."]
      },
      "prompts": ["<category-key>"]
    }
  },
  "categories": { "..." : "..." }
}
```

**Field reference**:

| Field | Type | Required | Description |
|---|---|---|---|
| `presets` | object | no | Top-level key. Absent if no presets are defined. |
| `preset.label` | string | yes | Human-readable name for the preset. |
| `preset.description` | string | yes | One-line explanation of what this preset sets up. |
| `preset.selections` | object | yes | Pre-filled selections. Keys are category keys, values are arrays of item keys. |
| `preset.prompts` | array | no | Category keys where the user must still make a choice. PowerHouse walks these categories interactively even though the preset has filled in defaults. |

### How PowerHouse interprets presets

1. User picks a preset from the list (or skips presets and walks categories manually).
2. PowerHouse reads `preset.selections` and marks those items as selected in its UI.
3. PowerHouse reads `preset.prompts` and presents those categories for user input, even though some items may already be pre-selected.
4. User can add, remove, or override any selection.
5. PowerHouse builds the standard `devstrap-bootstrap` payload from the final state.

### What happens when a preset includes an item requiring user choice

Example: The `spa-api` preset pre-selects `vite` but says `prompts: ["app"]` because the user must pick a backend language. PowerHouse shows the `app` category with `vite` already checked, and the user picks `go` (or `node-express`, etc.) as the second app selection.

If a preset pre-selects an item from a `single`-selection category, PowerHouse should show that category as pre-filled but allow the user to change it. The preset's choice is a default, not a lock.

### Should presets be validated?

Yes, at manifest build time (a dev-strap internal concern, not a contract concern). Validation rules:

1. Every category key in `preset.selections` must exist in `categories`.
2. Every item key in `preset.selections[category]` must exist in that category's items.
3. Every category key in `preset.prompts` must exist in `categories`.
4. Dependencies must be satisfiable: if a preset selects `grafana`, it must also select `prometheus` (or list `observability` in `prompts` so the user adds it).
5. No conflicts within a preset's selections.

This validation runs when the manifest is loaded, not at bootstrap time. If a preset is invalid, `--options` should still succeed (presets are advisory), but a warning should be logged to stderr.

### Should --bootstrap handle presets?

No. The bootstrap payload has no `preset` field. Presets are entirely resolved by PowerHouse before the bootstrap call. This keeps the contract clean: presets are a UI convenience, not a bootstrap semantic.

If a future version wants server-side preset expansion (e.g., `"preset": "spa-api"` in the bootstrap payload), that would be a v2 feature.

### Draft manifest.json with presets

```json
{
  "contract": "devstrap-options",
  "version": "1",
  "presets": {
    "spa-api": {
      "label": "SPA + API",
      "description": "Frontend SPA with API backend, database, testing, and mocking",
      "selections": {
        "app": ["vite"],
        "database": ["postgres"],
        "tooling": ["qa", "wiremock"]
      },
      "prompts": ["app"]
    },
    "api-only": {
      "label": "API Service",
      "description": "Headless API with database, caching, testing, and API docs",
      "selections": {
        "database": ["postgres"],
        "services": ["redis"],
        "tooling": ["qa", "swagger-ui"]
      },
      "prompts": ["app"]
    },
    "full-stack": {
      "label": "Full Stack + Observability",
      "description": "Complete development environment with frontend, backend, database, caching, and monitoring",
      "selections": {
        "app": ["vite"],
        "database": ["postgres"],
        "services": ["redis"],
        "tooling": ["qa", "qa-dashboard", "wiremock"],
        "observability": ["prometheus", "grafana", "dozzle"]
      },
      "prompts": ["app"]
    },
    "data-pipeline": {
      "label": "Data Pipeline",
      "description": "ETL and event processing with messaging and object storage",
      "selections": {
        "app": ["python-fastapi"],
        "database": ["postgres"],
        "services": ["nats", "minio"]
      }
    }
  },
  "categories": {
    "...existing categories..."
  }
}
```

Note: `data-pipeline` has no `prompts` because `python-fastapi` is pre-selected and no further user choice is needed for app.

### Draft test cases

**In `test-contract.sh`, under the --options section**:

```bash
# Preset structure (once presets are added to manifest.json)
assert_json "has presets key"             "${options_output}" '.presets'
assert_json "has spa-api preset"          "${options_output}" '.presets["spa-api"]'
assert_json_eq "spa-api has label"        "${options_output}" '.presets["spa-api"].label' "SPA + API"
assert_json "spa-api has selections"      "${options_output}" '.presets["spa-api"].selections'
assert_json "spa-api selects vite"        "${options_output}" '.presets["spa-api"].selections.app | index("vite") != null'
assert_json "spa-api prompts for app"     "${options_output}" '.presets["spa-api"].prompts | index("app") != null'

# Preset validation: all referenced items exist in manifest
# (This tests the manifest's internal consistency)
preset_valid=$(printf '%s\n' "${options_output}" | jq '
    .categories as $cats |
    [.presets | to_entries[] |
     .value.selections | to_entries[] |
     .key as $cat | .value[] as $item |
     select(($cats[$cat].items // {} | has($item)) | not) |
     "\($cat).\($item)"] | length == 0')
assert_eq "all preset items exist in manifest" "true" "${preset_valid}"
```

### Recommendation

**Add presets as a top-level key in the options response.** This is a non-breaking addition (PowerHouse must ignore unrecognized top-level keys per contract rules). No version bump needed. PowerHouse can adopt preset support whenever ready, and older PowerHouse versions will simply ignore the key.

---

## 3. Contract Versioning Strategy

### What changes are backward-compatible (no version bump)

Per the contract document's "What is flexible" section:

- New categories (e.g., `frontend`)
- New items within existing categories
- New keys within `defaults`
- New `commands` keys in the result
- New top-level keys on any payload (e.g., `presets`) — consumers must ignore unrecognized fields
- New error codes (e.g., `PORT_CONFLICT`)
- New optional fields on items (e.g., `tags`, `icon`)

**All of the following planned changes are backward-compatible**:
- Adding `presets` top-level key to options response
- Adding `PORT_CONFLICT` error code
- Adding new items (vite, python-fastapi, rust, nats, minio, db-ui, swagger-ui)
- Adding new categories (if we create a `frontend` category)
- Adding informational fields to items (e.g., `port_keys` metadata)

### What changes break the contract (require version bump)

- Changing the structure of `categories` -> `items` (e.g., adding nesting levels)
- Changing `defaults` from scalars-only to allowing objects/arrays
- Adding new required fields to the bootstrap payload
- Changing the semantics of `requires`/`conflicts` syntax
- Changing the `selection` type behavior (e.g., making `multi` require min/max counts)
- Adding `$ref` syntax in `defaults` values (breaks "values must be scalars")
- Making `presets` a required field or changing how selections are structured

### Should we go to v2 now?

**No.** Here is the analysis:

Of all the planned features, only one fundamentally requires a structural change to the contract: **auto-wiring with `$ref` syntax** (which would put objects into `defaults` values, breaking the "flat scalar-only" constraint).

Everything else fits within v1:
- Port collision detection: new error code (additive)
- Preset bundles: new top-level key (additive, consumers ignore unknowns)
- New items and categories: explicitly flexible in v1
- Category restructuring: flexible in v1

**Going to v2 now would force a synchronized upgrade on the PowerHouse side for no immediate gain.** The cost of a version bump is coordination overhead: PowerHouse must update its version check, handle the new schema, and potentially maintain backward compatibility with v1 dev-strap instances.

### Recommendation: Stay v1, batch breaking changes for v2

1. **Now (v1)**: Ship port collision detection, preset bundles, new items, category changes. All are non-breaking.
2. **v2 planning**: Accumulate breaking changes that need to ship together:
   - `$ref` auto-wiring in defaults (if we choose that approach)
   - Any structural changes to `selections` (e.g., preset expansion in bootstrap)
   - Min/max selection counts on categories
   - Nested defaults (if needed)
3. **v2 trigger**: When the first breaking change is ready to ship, bundle all accumulated breaking changes into v2 and release them together. Do not do multiple version bumps for incremental breaking changes.

### How to communicate changes to the PowerHouse team

**For non-breaking changes (within v1)**:

1. Add a `changelog` section to `DEVSTRAP-POWERHOUSE-CONTRACT.md` (see Section 6).
2. Update the contract document in both repositories simultaneously.
3. Notify PowerHouse team of new capabilities they can adopt at their convenience.
4. New capabilities are opt-in: PowerHouse can ignore `presets`, new error codes, etc.

**For v2 migration**:

1. Publish a migration guide in the contract document (see Section 6).
2. dev-strap supports both v1 and v2 during a transition period.
3. PowerHouse implements v2 support and tests against dev-strap's v2 endpoint.
4. After PowerHouse ships v2 support, deprecate v1 (keep working for N releases, then remove).

### What does a v1 to v2 migration look like?

**dev-strap side**:
- `--options` output changes its `version` field to `"2"`.
- The manifest.json schema changes (e.g., `defaults` allows objects, `$ref` syntax).
- `validate_bootstrap_payload()` accepts `version: "2"` and validates the new schema.
- During transition: if `version: "1"` arrives, apply v1 validation. If `"2"`, apply v2.

**PowerHouse side**:
- On `--options`, check `version`. If `"2"`, use v2 parsing.
- Build UI from the new schema (e.g., resolve `$ref` in defaults, handle nested values).
- Send bootstrap payloads with `version: "2"`.
- During transition: check dev-strap's reported version and use the matching payload format.

**Dual-version support in dev-strap** (sketch):
```bash
validate_bootstrap_payload() {
    local payload="$1"
    local manifest_file="$2"
    local version
    version=$(printf '%s\n' "${payload}" | jq -r '.version // ""')

    case "${version}" in
        1) validate_bootstrap_v1 "${payload}" "${manifest_file}" ;;
        2) validate_bootstrap_v2 "${payload}" "${manifest_file}" ;;
        *) jq -n --arg v "${version}" \
               '[{code:"INVALID_VERSION",message:"Unsupported version \"\($v)\""}]' ;;
    esac
}
```

---

## 4. Auto-Wiring Syntax

### The problem

When items are co-selected, certain configuration values can be inferred:

| Co-selection | Inference |
|---|---|
| Vite + Go backend | Vite's `proxy_target` = `http://go:3000` |
| Swagger UI + Node.js | Swagger's `spec_url` = `http://node-express:3000/openapi.yaml` |
| Adminer + PostgreSQL | Adminer's `default_server` = `postgres` |
| Grafana + Prometheus | Grafana's datasource URL = `http://prometheus:9090` |

Today, these wiring values must be set manually after bootstrap or hardcoded in templates. The proposals document suggests a `$ref` syntax in defaults.

### Does $ref break "flat scalar-only"?

Yes. The `$ref` proposal from the catalog proposals document is:
```json
{
  "defaults": {
    "port": 5173,
    "proxy_target": { "$ref": "app.*.port", "template": "http://{key}:{value}" }
  }
}
```

This puts an object as a default value, violating the v1 contract's "values must be scalars" constraint. PowerHouse must be able to display defaults as simple key-value pairs. An object in a default value would break PowerHouse's UI rendering.

### Proposal A: $ref in defaults (requires v2)

**Syntax**:
```json
{
  "defaults": {
    "port": 5173,
    "proxy_target": ""
  },
  "wiring": {
    "proxy_target": {
      "from": "app.*.port",
      "template": "http://{item}:{value}",
      "condition": "any"
    }
  }
}
```

Keep `defaults` flat and scalar. Add a sibling `wiring` key at the item level that describes how default values should be resolved when co-selections are present.

**Field reference**:

| Field | Type | Description |
|---|---|---|
| `wiring.<key>` | string | The defaults key this wiring rule fills. Must exist in `defaults`. |
| `wiring.<key>.from` | string | Reference in `category.item.default_key` or `category.*.default_key` format. Wildcard means "any selected item in that category." |
| `wiring.<key>.template` | string | String template. `{item}` = the matched item's key, `{value}` = the referenced default's value. |
| `wiring.<key>.condition` | string | `"any"` = first match wins, `"all"` = error if multiple items match (ambiguous). |

**Resolution**:
1. dev-strap reads the bootstrap selections.
2. For each selected item with `wiring` rules, dev-strap resolves `from` against the other selected items.
3. The resolved value replaces the empty default.
4. If no match is found (e.g., no backend is selected), the default stays as-is (empty string).

**Advantages**: Defaults remain scalar. Wiring is explicit and declarative. PowerHouse can display wiring rules as hints ("this will auto-fill from your backend's port").

**Disadvantages**: New item-level key (`wiring`) — additive but PowerHouse needs to understand it for display. Somewhat complex for the manifest author.

**Contract impact**: Adding `wiring` as an optional item-level key is non-breaking in v1 (consumers ignore unrecognized fields). The resolution logic is internal to dev-strap. PowerHouse can choose to display wiring hints or ignore them.

### Proposal B: Post-generation wiring rules (separate mechanism)

Keep the manifest and contract unchanged. Implement wiring as a post-generation step inside `generate_from_bootstrap()`.

**Implementation**: After generating project.env and running `cmd_generate`, apply wiring rules based on what was selected:

```bash
# In generate_from_bootstrap(), after cmd_generate:
apply_wiring() {
    local payload="$1"

    # If vite + any backend app selected, set VITE_PROXY_TARGET
    if printf '%s\n' "${payload}" | jq -e '.selections.app.vite' &>/dev/null; then
        local backend_key backend_port
        backend_key=$(printf '%s\n' "${payload}" | jq -r '
            .selections.app | keys | map(select(. != "vite")) | .[0] // empty')
        if [ -n "${backend_key}" ]; then
            backend_port=$(printf '%s\n' "${payload}" | jq -r --arg k "${backend_key}" '
                .selections.app[$k].overrides.port //
                (input | .categories.app.items[$k].defaults.port) // 3000' \
                "${manifest_file}")
            # Patch project.env or generated config
            echo "VITE_PROXY_TARGET=http://${backend_key}:${backend_port}" >> "${DEVSTACK_DIR}/project.env"
        fi
    fi
}
```

**Advantages**: Zero contract changes. Zero manifest changes. Works entirely inside dev-strap's generation logic.

**Disadvantages**: Wiring rules are hardcoded in bash, not declarative. PowerHouse has no visibility into what will be auto-wired. Adding new wiring rules requires code changes, not manifest changes.

### Proposal C: Wiring rules as a separate manifest section (recommended)

Add a top-level `wiring` key to the manifest, separate from items:

```json
{
  "contract": "devstrap-options",
  "version": "1",
  "categories": { "..." : "..." },
  "wiring": [
    {
      "when": ["app.vite", "app.*"],
      "set": "app.vite.proxy_target",
      "template": "http://{app.*}:{app.*.port}"
    },
    {
      "when": ["tooling.swagger-ui", "app.*"],
      "set": "tooling.swagger-ui.spec_url",
      "template": "http://{app.*}:{app.*.port}/openapi.yaml"
    },
    {
      "when": ["tooling.db-ui", "database.*"],
      "set": "tooling.db-ui.default_server",
      "template": "{database.*}"
    },
    {
      "when": ["observability.grafana", "observability.prometheus"],
      "set": "observability.grafana.datasource_url",
      "template": "http://prometheus:{observability.prometheus.port}"
    }
  ]
}
```

**Field reference**:

| Field | Type | Description |
|---|---|---|
| `wiring` | array | List of wiring rules. |
| `wiring[].when` | array | Conditions. All must be satisfied (AND). Each is a `category.item` or `category.*` reference. |
| `wiring[].set` | string | Target default key in `category.item.default_key` format. |
| `wiring[].template` | string | Value template. `{category.*}` resolves to the matched item key. `{category.*.default_key}` resolves to that item's resolved default value. |

**Resolution order**:
1. Merge defaults with overrides for all selected items.
2. Apply wiring rules in order. Each rule checks `when` conditions against the current selections.
3. If a wiring rule's target key already has a non-empty value (from an override), skip the rule. User overrides take precedence.
4. Resolved wiring values appear in the bootstrap response's `services` object.

**Advantages**:
- Defaults stay flat and scalar (v1-compatible).
- Wiring rules are declarative and discoverable.
- PowerHouse can display wiring hints: "If you select Vite + a backend, proxy_target will auto-fill."
- Adding new wiring rules is a manifest change, not a code change.
- Top-level key is non-breaking (consumers ignore unrecognized fields).

**Disadvantages**:
- Template syntax needs careful specification.
- Ambiguity when `category.*` matches multiple items (e.g., two backend apps selected). Need a resolution strategy (first? error? skip?).

**Ambiguity resolution**: When `category.*` matches multiple selected items, use the first item alphabetically. The user can override if the wrong one was picked. This is a pragmatic choice — the common case is one backend, and the auto-wired value is a convenience default, not a hard constraint.

### Recommendation

**Implement Proposal C (top-level wiring section) within v1.** It is non-breaking because:
1. `wiring` is a new top-level key in the options response (consumers ignore unknowns).
2. `defaults` values remain scalar.
3. The resolution logic is internal to dev-strap's `generate_from_bootstrap()`.
4. PowerHouse can optionally display wiring hints but does not need to understand them to function.

If Proposal C proves insufficient (e.g., the template syntax is too limited), escalate to Proposal A (item-level wiring key) which is also non-breaking in v1.

Reserve `$ref`-in-defaults (the original catalog proposal syntax) for v2, if we ever conclude that the declarative alternatives are inadequate.

---

## 5. New Category Structure

### Current categories

| Key | Label | Selection | Items |
|---|---|---|---|
| `app` | Application | multi | node-express, php-laravel, go |
| `database` | Database | single | postgres, mariadb |
| `services` | Additional Services | multi | redis, mailpit |
| `tooling` | Development Tooling | multi | qa, qa-dashboard, wiremock, devcontainer |
| `observability` | Observability | multi | prometheus, grafana, dozzle |

### Question: Should `frontend` be its own category?

**Option 1: Frontend as its own category**

```json
{
  "frontend": {
    "label": "Frontend",
    "description": "Frontend development server",
    "selection": "single",
    "required": false,
    "items": {
      "vite": {
        "label": "Frontend Dev Server (Vite)",
        "description": "Vite dev server with HMR, configurable API proxy",
        "defaults": { "port": 5173, "proxy_target": "" }
      }
    }
  }
}
```

**Pros**: Clean separation. PowerHouse can present frontend choices independently. `required: false` makes it optional. Category semantics are clear.

**Cons**: Another top-level category for PowerHouse to render. Today there's only one frontend option (Vite), so the category feels sparse. If we add more (e.g., Webpack dev server, Storybook), it would justify itself.

**Option 2: Frontend items in `app` category**

Keep `app` as a multi-select category. Add `vite` alongside `node-express`, `go`, etc.

```json
{
  "app": {
    "items": {
      "vite": {
        "label": "Frontend Dev Server (Vite)",
        "description": "Vite dev server with HMR, configurable API proxy",
        "defaults": { "port": 5173, "proxy_target": "" }
      },
      "node-express": { "..." : "..." },
      "go": { "..." : "..." }
    }
  }
}
```

**Pros**: Simpler structure. `app` is already multi-select, so selecting Vite + Go is natural. Aligns with how the catalog proposals describe it.

**Cons**: Mixes frontend and backend items. The label "Application" is generic enough, but it makes the "pick a backend" prompt from presets less clear.

### Recommendation

**Keep frontend items in the `app` category.** Rationale:

1. `app` is already multi-select, so no structural change is needed.
2. The common workflow (Vite + one backend) is just selecting two items from `app`.
3. Presets can use `prompts: ["app"]` to guide users to pick a backend alongside Vite.
4. If we later have 3+ frontend items, we can split into a `frontend` category (non-breaking change in v1).
5. Category count affects PowerHouse UI complexity. Fewer categories = cleaner UX for now.

### Full proposed category structure after expansion

| Key | Label | Selection | Required | Items |
|---|---|---|---|---|
| `app` | Application | multi | yes | node-express, php-laravel, go, vite, python-fastapi, rust |
| `database` | Database | single | no | postgres, mariadb |
| `services` | Additional Services | multi | no | redis, mailpit, nats, minio |
| `tooling` | Development Tooling | multi | no | qa, qa-dashboard, wiremock, devcontainer, db-ui, swagger-ui |
| `observability` | Observability | multi | no | prometheus, grafana, dozzle |

### How category structure affects PowerHouse UI flow

PowerHouse walks categories in the order they appear in the `--options` response. The manifest's key ordering determines the UI flow:

1. **app** (required) — presented first, user must pick at least one
2. **database** — optional, single-select
3. **services** — optional, multi-select
4. **tooling** — optional, multi-select
5. **observability** — optional, multi-select

With presets, this flow changes: preset pre-fills selections, then PowerHouse only walks `prompts` categories.

Adding more categories would insert more steps in the non-preset flow. This is why keeping frontend in `app` is preferable for now — it avoids adding a step.

---

## 6. Contract Documentation

### What needs updating in DEVSTRAP-POWERHOUSE-CONTRACT.md

1. **Add `PORT_CONFLICT` to the standard error codes table.**
2. **Add `presets` schema to the options response section.**
3. **Add `wiring` schema to the options response section (when implemented).**
4. **Add a changelog section at the bottom.**
5. **Add a migration notes section (empty until v2).**
6. **Update the "Complete example" to include presets and the new items.**
7. **Add the port naming convention rule.**
8. **Add `PORT_CONFLICT` to "What is locked" list** (it becomes a standard error code).

### Draft changelog section

Add before the final "What is locked / What is flexible" sections:

```markdown
---

## Changelog

### v1.1 (non-breaking additions)

**New error code: `PORT_CONFLICT`**

Added validation check 11: port collision detection. When two or more selected
items resolve to the same host port (after merging defaults with overrides),
dev-strap returns a `PORT_CONFLICT` error listing the conflicting items and
port. PowerHouse does not need to handle this error specially — it follows the
standard error format.

**New top-level key in options response: `presets`**

Presets are pre-built selection bundles for common project patterns. PowerHouse
can use them to pre-fill its UI. See schema above. Presets are never sent in
bootstrap payloads — they are resolved to concrete selections by PowerHouse
before calling `--bootstrap`.

PowerHouse versions that do not recognize `presets` will ignore it per the
existing rule: "consumers must ignore unrecognized fields."

**New top-level key in options response: `wiring`**

Wiring rules describe how default values should be auto-filled when certain
items are co-selected. dev-strap resolves wiring rules during generation.
PowerHouse can optionally display wiring hints. See schema above.

**Port naming convention**

Default keys representing host port bindings must be named `port` or end with
`_port`. This enables automated port collision detection.

**New items added to existing categories**

- `app.vite` — Frontend Dev Server (Vite)
- `app.python-fastapi` — Python (FastAPI)
- `app.rust` — Rust
- `services.nats` — NATS messaging
- `services.minio` — MinIO S3-compatible storage
- `tooling.db-ui` — Database UI (Adminer)
- `tooling.swagger-ui` — API Documentation (Swagger UI)
```

### Draft migration notes

```markdown
---

## Migration notes

### For PowerHouse: adopting v1.1 features

These changes are backward-compatible. Adopt them at your own pace.

**PORT_CONFLICT errors**: No action required. Your existing error display logic
will show the error message. If you want to enhance the UX, you could detect
`PORT_CONFLICT` and offer to auto-adjust the conflicting port.

**Presets**: To support presets:
1. Read the `presets` key from the `--options` response.
2. If present, offer preset selection before (or alongside) category walkthrough.
3. When user picks a preset, pre-fill your selection state with `preset.selections`.
4. Walk categories listed in `preset.prompts` for additional user input.
5. Build the standard `devstrap-bootstrap` payload from the final state.

**Wiring rules**: To display wiring hints:
1. Read the `wiring` key from the `--options` response.
2. When the user's current selections satisfy a rule's `when` conditions, display
   a hint: "proxy_target will auto-fill to http://go:3000."
3. No action required in the bootstrap payload — dev-strap resolves wiring
   internally.

**New items and categories**: No action required. Your existing dynamic UI
rendering will pick them up automatically (per the contract principle: "PowerHouse
never assumes specific categories, items, or keys exist").
```

### Summary of contract document changes

| Section | Change | Breaking? |
|---|---|---|
| Standard error codes table | Add `PORT_CONFLICT` row | No |
| Options response schema | Add `presets` field description | No |
| Options response schema | Add `wiring` field description | No |
| Key rules | Add port naming convention | No |
| Complete example | Update to show presets, new items | No |
| New section: Changelog | Add at end | No |
| New section: Migration notes | Add at end | No |
| "What is locked" list | Add `PORT_CONFLICT` error code | No |

---

## Summary of Recommendations

| Area | Recommendation | Contract Impact | Priority |
|---|---|---|---|
| Port collision detection | Implement check 11 immediately | Additive (new error code) | High — prevents broken compose files |
| Preset bundles | Add `presets` top-level key to options response | Additive (new top-level key) | High — improves onboarding UX |
| Contract versioning | Stay v1; batch breaking changes for future v2 | None | N/A — strategic decision |
| Auto-wiring | Proposal C: top-level `wiring` section in manifest | Additive (new top-level key) | Medium — implement after presets |
| Category structure | Keep frontend in `app`; split later if needed | None (v1 flexible) | Low — just a manifest change |
| Contract docs | Add changelog + migration notes sections | None — documentation only | Ship alongside each feature |

**Sequencing**:
1. Port collision detection (immediate, unblocks catalog expansion safely)
2. New items added to manifest (after port collision detection is in place)
3. Preset bundles (after new items exist to reference)
4. Auto-wiring rules (after presets, since presets + wiring together deliver the "fast start" experience)
5. Contract documentation updates (ship with each feature above)
