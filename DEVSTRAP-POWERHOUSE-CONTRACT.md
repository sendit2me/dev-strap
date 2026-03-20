# dev-strap ↔ PowerHouse Interaction Contract

> **THIS DOCUMENT IS NOT OWNED BY THIS REPOSITORY.**
>
> This contract is shared between [dev-strap](https://github.com/sendit2me/dev-strap)
> and [PowerHouse](https://github.com/sendit2me/PowerHouse). An identical copy
> exists in both repositories. Neither team should edit this file unilaterally.
>
> Changes to this contract must be agreed upon with visibility into both systems
> and committed to both repositories simultaneously.
>
> **Contract version: 1**

---

## Purpose

This document defines the interface between PowerHouse (the orchestrator / AI
agent framework) and dev-strap (the containerized development environment
generator). It specifies exactly two operations — **discover** and
**bootstrap** — and the JSON payloads exchanged in each.

PowerHouse does not know how dev-strap builds environments.
dev-strap does not know how PowerHouse presents choices.
This contract is the only coupling between them.

---

## Principles

1. **dev-strap describes, PowerHouse presents.** dev-strap publishes what it
   can provide. PowerHouse decides how to show it to the user.
2. **No hardcoded knowledge.** PowerHouse never assumes specific categories,
   items, or keys exist. Everything is discovered at runtime.
3. **Flat and simple.** Configuration values are scalars. Overrides are shallow
   merges. No nesting in v1.
4. **Omission is meaningful.** In bootstrap payloads, only selected items
   appear. Absent = not selected.
5. **Fail loud.** dev-strap validates bootstrap input against its own manifest.
   Invalid input returns a structured error, never a partial build.
6. **No interactive prompts.** dev-strap never prompts for input during
   bootstrap. Everything it needs is in the bootstrap payload.

---

## Operation 1: DISCOVER

PowerHouse asks dev-strap what it can provide.

### Invocation

```bash
devstack.sh --options
```

### Response

Exit code `0`. JSON to stdout.

### Schema

```json
{
  "contract": "devstrap-options",
  "version": "1",
  "categories": {
    "<category-key>": {
      "label": "<string>",
      "description": "<string>",
      "selection": "single | multi",
      "required": "<boolean>",
      "items": {
        "<item-key>": {
          "label": "<string>",
          "description": "<string>",
          "defaults": { "<key>": "<scalar>", "..." : "..." },
          "requires": ["<category.item | category.*>"],
          "conflicts": ["<category.item>"]
        }
      }
    }
  }
}
```

### Field reference

| Field | Type | Required | Description |
|---|---|---|---|
| `contract` | string | yes | Always `"devstrap-options"`. PowerHouse uses this to validate it received the right payload. |
| `version` | string | yes | Contract major version. Currently `"1"`. PowerHouse must refuse payloads with an unrecognized version. |
| `categories` | object | yes | Keyed by category identifier. dev-strap defines these freely. |
| `category.label` | string | yes | Human-readable category name. |
| `category.description` | string | yes | One-line explanation of what this category represents. |
| `category.selection` | string | yes | `"single"` — user picks exactly one item. `"multi"` — user picks zero or more items. |
| `category.required` | boolean | yes | If `true`, the user must select at least one item from this category. |
| `items` | object | yes | Keyed by item identifier. dev-strap defines these freely. |
| `item.label` | string | yes | Human-readable item name. |
| `item.description` | string | yes | One-line explanation. Enough for a user to decide yes or no. |
| `item.defaults` | object | no | Flat key-value pairs. Values must be scalars (string, number, boolean). These serve two purposes: (1) display hints for PowerHouse (e.g. showing "port: 5432"), (2) configurable values the user may override during bootstrap. |
| `item.requires` | array | no | List of dependency references. Format: `"category.item"` for a specific item, `"category.*"` for any item in a category. If any dependency is unmet, dev-strap will reject the bootstrap. |
| `item.conflicts` | array | no | List of conflict references. Format: `"category.item"`. Selecting this item and a conflicting item together is invalid. |

### Key rules

- **Category keys** are lowercase, hyphen-separated identifiers (e.g.
  `app`, `database`, `services`, `tooling`).
- **Item keys** follow the same convention (e.g. `node-express`, `postgres`,
  `qa-dashboard`).
- **`defaults` values are always scalars.** No nested objects or arrays in v1.
- **`requires` with wildcard** (`"category.*"`) means "at least one item from
  that category must be selected."
- **PowerHouse must not assume any category or item exists.** It reads the
  manifest and builds its UI entirely from what it finds.

---

## Operation 2: BOOTSTRAP

PowerHouse tells dev-strap what the user selected. dev-strap generates the
environment.

### Invocation

```bash
devstack.sh --bootstrap --config <path-to-file.json>
```

Or via stdin:

```bash
devstack.sh --bootstrap --config -
```

### Input payload

```json
{
  "contract": "devstrap-bootstrap",
  "version": "1",
  "project": "<string>",
  "selections": {
    "<category-key>": {
      "<item-key>": {
        "overrides": { "<key>": "<scalar>" }
      }
    }
  }
}
```

### Field reference

| Field | Type | Required | Description |
|---|---|---|---|
| `contract` | string | yes | Always `"devstrap-bootstrap"`. |
| `version` | string | yes | Must match the version from the `devstrap-options` payload. |
| `project` | string | yes | Project name. Used as directory name and compose project name. Lowercase, hyphens allowed, no spaces. |
| `selections` | object | yes | Selected items, organized by category. |
| `selections.category.item` | object | yes | Presence of an item key means it is selected. |
| `item.overrides` | object | no | Flat key-value pairs that merge on top of the item's `defaults`. Keys must exist in the item's `defaults` from the manifest. Values must be scalars. |

### Key rules

- **Only selected items appear.** If `redis` is not selected, it is absent from
  the payload entirely. There is no `"enabled": false`.
- **`overrides` keys must exist in `defaults`.** PowerHouse cannot invent new
  configuration keys. It can only change values for keys that dev-strap
  declared in its manifest.
- **`project` must be a valid directory name.** Pattern: `[a-z][a-z0-9-]*`.
- **dev-strap validates the full payload** against its current manifest before
  generating anything. Validation includes: all referenced categories and items
  exist, `requires` dependencies are satisfied, `conflicts` are not violated,
  `single`-selection categories have at most one item, `required` categories
  have at least one item, `overrides` keys exist in `defaults`.

---

## Bootstrap response

### Success

Exit code `0`. JSON to stdout.

```json
{
  "contract": "devstrap-result",
  "version": "1",
  "status": "ok",
  "project_dir": "<relative-path>",
  "services": {
    "<item-key>": {
      "<key>": "<value>"
    }
  },
  "commands": {
    "<command-name>": "<string>"
  }
}
```

| Field | Type | Description |
|---|---|---|
| `project_dir` | string | Relative path to the generated project directory. |
| `services` | object | Resolved configuration for each selected item. Includes defaults merged with any overrides. PowerHouse uses this to know final ports, paths, etc. |
| `commands` | object | Shell commands PowerHouse can use to operate the stack. Common keys: `start`, `stop`, `test`, `logs`. dev-strap defines these freely. |

### Failure

Exit code non-zero. JSON to stdout.

```json
{
  "contract": "devstrap-result",
  "version": "1",
  "status": "error",
  "errors": [
    {
      "code": "<ERROR_CODE>",
      "message": "<human-readable explanation>"
    }
  ]
}
```

### Standard error codes

| Code | Meaning |
|---|---|
| `UNKNOWN_CATEGORY` | A category key in selections doesn't exist in the manifest. |
| `UNKNOWN_ITEM` | An item key in selections doesn't exist in the manifest. |
| `MISSING_REQUIRED` | A required category has no items selected. |
| `INVALID_SINGLE_SELECT` | A `single`-selection category has more than one item. |
| `MISSING_DEPENDENCY` | A `requires` dependency is not satisfied. |
| `CONFLICT` | Two conflicting items are both selected. |
| `INVALID_OVERRIDE` | An override key doesn't exist in the item's defaults. |
| `INVALID_PROJECT_NAME` | Project name doesn't match `[a-z][a-z0-9-]*`. |

---

## Complete example

### 1. PowerHouse discovers options

```bash
devstack.sh --options
```

```json
{
  "contract": "devstrap-options",
  "version": "1",
  "categories": {
    "app": {
      "label": "Application",
      "description": "Development application template",
      "selection": "multi",
      "required": true,
      "items": {
        "node-express": {
          "label": "Node.js (Express)",
          "description": "Express API with hot reload",
          "defaults": { "port": 3000 }
        },
        "rust": {
          "label": "Rust",
          "description": "Cargo workspace with watch",
          "defaults": { "port": 8080 }
        },
        "go": {
          "label": "Go",
          "description": "Go module with Air reload",
          "defaults": { "port": 3000 }
        }
      }
    },
    "database": {
      "label": "Database",
      "description": "Primary data store",
      "selection": "single",
      "required": false,
      "items": {
        "postgres": {
          "label": "PostgreSQL 16",
          "description": "Relational database",
          "defaults": { "port": 5432 }
        },
        "mariadb": {
          "label": "MariaDB 10.11",
          "description": "MySQL-compatible database",
          "defaults": { "port": 3306 }
        }
      }
    },
    "services": {
      "label": "Additional Services",
      "description": "Supporting infrastructure for development",
      "selection": "multi",
      "required": false,
      "items": {
        "redis": {
          "label": "Redis",
          "description": "Cache / queue / session store",
          "defaults": { "port": 6379 },
          "requires": ["app.*"]
        },
        "mailpit": {
          "label": "Mailpit",
          "description": "SMTP catcher with web UI",
          "defaults": { "smtp_port": 1025, "ui_port": 8025 }
        },
        "temporal": {
          "label": "Temporal",
          "description": "Workflow orchestration engine",
          "defaults": { "port": 7233, "ui_port": 8233 }
        }
      }
    },
    "tooling": {
      "label": "Development Tooling",
      "description": "Testing and development infrastructure",
      "selection": "multi",
      "required": false,
      "items": {
        "qa": {
          "label": "QA Container",
          "description": "Isolated test runner with Playwright, curl, jq — no source mounted"
        },
        "qa-dashboard": {
          "label": "QA Dashboard",
          "description": "Web UI for test results and reports",
          "defaults": { "port": 9000 },
          "requires": ["tooling.qa"]
        },
        "wiremock": {
          "label": "API Mocking",
          "description": "WireMock with hot-reload mock definitions",
          "defaults": { "port": 8443 }
        },
        "devcontainer": {
          "label": "VS Code Dev Container",
          "description": "Generates per-app devcontainer.json for VS Code Remote Containers"
        }
      }
    }
  }
}
```

### 2. PowerHouse sends selections

User chose: Node + Rust apps, PostgreSQL, Redis, Temporal, QA with dashboard,
API mocking. Rust port overridden to 8081.

```bash
devstack.sh --bootstrap --config selection.json
```

```json
{
  "contract": "devstrap-bootstrap",
  "version": "1",
  "project": "acme-platform",
  "selections": {
    "app": {
      "node-express": {},
      "rust": { "overrides": { "port": 8081 } }
    },
    "database": {
      "postgres": {}
    },
    "services": {
      "redis": {},
      "temporal": {}
    },
    "tooling": {
      "qa": {},
      "qa-dashboard": {},
      "wiremock": {}
    }
  }
}
```

### 3. dev-strap responds

```json
{
  "contract": "devstrap-result",
  "version": "1",
  "status": "ok",
  "project_dir": "./acme-platform",
  "services": {
    "node-express": { "port": 3000 },
    "rust": { "port": 8081 },
    "postgres": { "port": 5432 },
    "redis": { "port": 6379 },
    "temporal": { "port": 7233, "ui_port": 8233 },
    "qa": {},
    "qa-dashboard": { "port": 9000 },
    "wiremock": { "port": 8443 }
  },
  "commands": {
    "start": "./devstack.sh start",
    "stop": "./devstack.sh stop",
    "test": "./devstack.sh test",
    "logs": "./devstack.sh logs"
  }
}
```

---

## Sequence diagram

```
PowerHouse                                dev-strap
    │                                         │
    │──── devstack.sh --options ─────────────▶│
    │◀─── devstrap-options (JSON, exit 0) ───│
    │                                         │
    │  PowerHouse reads categories and items  │
    │  PowerHouse presents choices to user    │
    │  User makes selections                  │
    │  PowerHouse builds devstrap-bootstrap   │
    │                                         │
    │──── devstack.sh --bootstrap ───────────▶│
    │     --config selection.json             │
    │                                         │
    │     dev-strap validates selections      │
    │     dev-strap generates environment     │
    │                                         │
    │◀─── devstrap-result (JSON, exit 0) ────│
    │                                         │
    │  PowerHouse reads result                │
    │  PowerHouse knows ports and commands    │
    │  PowerHouse can start/stop/test stack   │
    │                                         │
```

---

## Versioning

- The `version` field is a single integer string: `"1"`, `"2"`, etc.
- A new version means a breaking change to the contract.
- PowerHouse must refuse to process a payload whose version it does not
  recognize.
- dev-strap must refuse a bootstrap payload whose version does not match its
  current contract version.
- Non-breaking additions (new categories, new items, new optional fields) do
  not require a version bump. This is by design — the contract is built to
  absorb additions without breaking either side.

---

## What is locked (do not change without a version bump)

- The three payload identifiers: `devstrap-options`, `devstrap-bootstrap`,
  `devstrap-result`
- The `contract` + `version` fields on every payload
- The structure of `categories` → `items` in the options payload
- The structure of `selections` → `category` → `item` in the bootstrap payload
- The `selection` types: `single`, `multi`
- The `requires` / `conflicts` reference syntax: `"category.item"`,
  `"category.*"`
- The `defaults` / `overrides` merge behavior (shallow, scalars only)
- The success/error structure in the result payload
- The standard error codes listed above

## What is flexible (no version bump needed)

- Categories — dev-strap adds or removes freely
- Items within categories — dev-strap adds or removes freely
- Keys within `defaults` — dev-strap defines whatever it needs
- `commands` keys in the result — dev-strap defines freely
- How dev-strap implements generation internally
- How PowerHouse presents choices to the user
- Additional informational fields on any payload (consumers must ignore
  unrecognized fields)
