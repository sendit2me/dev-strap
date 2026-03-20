# Adding Mock Services

## Quick Reference

```bash
mkdir -p mocks/<service-name>/mappings
echo "api.domain.com" > mocks/<service-name>/domains
# Add JSON mapping files to mocks/<service-name>/mappings/
./devstack.sh stop && ./devstack.sh start
```

## Directory Structure

Each mock service is a directory under `mocks/` with:

```
mocks/
└── my-service/
    ├── domains              # One domain per line (required)
    └── mappings/            # WireMock JSON stubs (required)
        ├── endpoint-a.json
        └── endpoint-b.json
```

### `domains` file

Plain text, one domain per line. Lines starting with `#` are comments.

```
api.stripe.com
# This domain is also intercepted
hooks.stripe.com
```

These domains become:
- DNS aliases on the Caddy container (Docker resolves them to Caddy)
- SANs on the auto-generated SSL certificate
- Site address entries in the Caddyfile (proxied to WireMock)

### `mappings/` directory

WireMock JSON mapping files. Each file defines one request-response pair.

## Mapping Examples

### Simple GET

```json
{
    "request": {
        "method": "GET",
        "url": "/v1/users/123"
    },
    "response": {
        "status": 200,
        "headers": { "Content-Type": "application/json" },
        "jsonBody": {
            "id": "123",
            "name": "Test User"
        }
    }
}
```

### URL Pattern Matching

```json
{
    "request": {
        "method": "GET",
        "urlPattern": "/v1/users/[a-zA-Z0-9]+"
    },
    "response": {
        "status": 200,
        "jsonBody": { "id": "matched", "name": "Any User" }
    }
}
```

### Stateful Scenario

WireMock scenarios let a single endpoint return different responses on successive calls.

Each state is a separate JSON file in the same `mappings/` directory:

**File: `01-create.json`** — first call creates the resource

```json
{
    "scenarioName": "my-flow",
    "requiredScenarioState": "Started",
    "newScenarioState": "Created",
    "request": { "method": "POST", "url": "/v1/jobs" },
    "response": {
        "status": 201,
        "jsonBody": { "id": "job_1", "status": "queued" }
    }
}
```

**File: `02-poll.json`** — second call shows processing

```json
{
    "scenarioName": "my-flow",
    "requiredScenarioState": "Created",
    "newScenarioState": "Done",
    "request": { "method": "GET", "url": "/v1/jobs/job_1" },
    "response": {
        "status": 200,
        "jsonBody": { "id": "job_1", "status": "processing" }
    }
}
```

**File: `03-complete.json`** — third call shows done (resets to `Started` for next cycle)

```json
{
    "scenarioName": "my-flow",
    "requiredScenarioState": "Done",
    "newScenarioState": "Started",
    "request": { "method": "GET", "url": "/v1/jobs/job_1" },
    "response": {
        "status": 200,
        "jsonBody": { "id": "job_1", "status": "complete", "result": "success" }
    }
}
```

### Conditional Branching

Use `bodyPatterns` to match against request body content. Lower `priority` number = matched first.

**File: `premium.json`** — high priority, matches when body contains `"type": "premium"`

```json
{
    "priority": 1,
    "request": {
        "method": "POST",
        "url": "/v1/subscriptions",
        "bodyPatterns": [
            { "matchesJsonPath": "$.type", "equalTo": "premium" }
        ]
    },
    "response": {
        "status": 200,
        "jsonBody": { "plan": "premium", "price": 99.99 }
    }
}
```

**File: `fallback.json`** — lower priority, matches any POST to `/v1/subscriptions`

```json
{
    "priority": 5,
    "request": {
        "method": "POST",
        "url": "/v1/subscriptions"
    },
    "response": {
        "status": 200,
        "jsonBody": { "plan": "free", "price": 0 }
    }
}
```

### Response Templating

WireMock can inject dynamic values. Enable with `--global-response-templating` (already configured in DevStack).

```json
{
    "request": {
        "method": "POST",
        "url": "/v1/tokens"
    },
    "response": {
        "status": 200,
        "jsonBody": {
            "token": "tok_{{randomValue type='UUID'}}",
            "created_at": "{{now format='yyyy-MM-dd'}}",
            "request_id": "{{request.headers.X-Request-Id}}"
        },
        "transformers": ["response-template"]
    }
}
```

### Streaming (Server-Sent Events)

```json
{
    "request": {
        "method": "POST",
        "url": "/v1/chat/completions",
        "bodyPatterns": [
            { "contains": "\"stream\": true" }
        ]
    },
    "response": {
        "status": 200,
        "headers": {
            "Content-Type": "text/event-stream",
            "Cache-Control": "no-cache"
        },
        "body": "data: {\"choices\":[{\"delta\":{\"content\":\"Hello\"}}]}\n\ndata: {\"choices\":[{\"delta\":{\"content\":\" World\"}}]}\n\ndata: [DONE]\n\n"
    },
    "priority": 1
}
```

## Verifying Mocks

After starting the stack:

```bash
# List all configured mocks
./devstack.sh mocks

# Check WireMock received requests (shell into wiremock container)
./devstack.sh shell wiremock
wget -qO- http://localhost:8080/__admin/requests | python3 -m json.tool

# Test a specific mock directly
./devstack.sh shell app
curl -k https://api.example-provider.com/v1/items
```

## Disambiguating Shared Paths (Multi-Domain Routing)

All mocked domains share a single WireMock instance. If two APIs use the same path (e.g., both Stripe and OpenAI have `POST /v1/tokens`), WireMock needs to distinguish them.

Caddy adds an `X-Original-Host` header with the original domain. Use `headerPatterns` in your mapping to match on it:

```json
{
    "name": "Stripe — create token (not OpenAI)",
    "request": {
        "method": "POST",
        "url": "/v1/tokens",
        "headers": {
            "X-Original-Host": {
                "equalTo": "api.stripe.com"
            }
        }
    },
    "response": {
        "status": 200,
        "jsonBody": { "id": "tok_stripe_123" }
    }
}
```

```json
{
    "name": "OpenAI — create token (not Stripe)",
    "request": {
        "method": "POST",
        "url": "/v1/tokens",
        "headers": {
            "X-Original-Host": {
                "equalTo": "api.openai.com"
            }
        }
    },
    "response": {
        "status": 200,
        "jsonBody": { "id": "tok_openai_456" }
    }
}
```

**When do you need this?** Only when two mocked services share the exact same HTTP method + URL path. Most real-world APIs have unique paths, so this is rare. If it does happen, add `X-Original-Host` matching to both conflicting mappings.

## Recording Real API Responses

To quickly create mock mappings from a real API:

```bash
# 1. Create the mock directory
./devstack.sh new-mock stripe api.stripe.com

# 2. Restart to register the new domain (certs, DNS, Caddy)
./devstack.sh restart

# 3. Start recording (proxies to the real API)
./devstack.sh record stripe
# Make requests through your app in another terminal — real responses are captured
# Press Ctrl+C when done

# 4. Review captured mappings (remove sensitive data!)
ls mocks/stripe/recordings/mappings/

# 5. Apply recordings — copies mappings + response bodies, fixes paths, reloads WireMock
./devstack.sh apply-recording stripe
```

**What `apply-recording` does:**
- Copies mapping files from `recordings/mappings/` to `mappings/`
- Copies response body files from `recordings/__files/` to `__files/`
- Rewrites `bodyFileName` paths to match WireMock's subdirectory mount structure
- Fixes file ownership (containers write as root, apply fixes to your user)
- Cleans up the `recordings/` directory
- Hot-reloads WireMock if the stack is running

The recorder runs a temporary WireMock in proxy mode that forwards to the real API and captures every request/response pair. Review the captured files before applying — they may contain API keys, tokens, or other sensitive data in headers.

## Hot-Reloading Mappings

After editing mapping files, you don't need a full restart:

```bash
# Change a mapping file
vim mocks/stripe/mappings/create-charge.json

# Reload without restart
./devstack.sh reload-mocks
```

This calls WireMock's `/__admin/mappings/reset` endpoint, which re-reads all mapping files from disk. Changes take effect immediately.

**When you DO need a full restart:** Adding a new domain (new `mocks/<name>/domains` file) requires regenerating the Caddyfile and certificates, which requires `./devstack.sh restart`.

## Debugging Mock Responses

```bash
# See what requests WireMock received
./devstack.sh shell wiremock
wget -qO- http://localhost:8080/__admin/requests | head -200

# See what mappings are loaded
wget -qO- http://localhost:8080/__admin/mappings | head -200

# Reset WireMock's request log (useful for clean test runs)
wget -qO- --post-data='' http://localhost:8080/__admin/requests/reset
```

Common issues:
- **404 from WireMock**: Mapping doesn't match. Check URL, method, and `bodyPatterns`.
- **HTML error page instead of JSON**: WireMock template rendering failed. Check your `{{...}}` expressions — especially date format strings with single quotes need careful escaping in JSON.
- **Wrong response returned**: Check `priority` values. Lower number = matched first.

## Tips

- **Naming**: Prefix mapping files with numbers (`01-`, `02-`) for stateful scenarios to show order
- **Priority**: Use `priority` when multiple mappings could match the same request (1 = highest)
- **Multiple domains**: A single mock service can intercept multiple domains
- **`__files/` directory**: For large response bodies, put them in `mocks/<name>/__files/` and reference with `"bodyFileName": "response.json"` in the mapping
- **Reset state**: WireMock scenarios reset when the stack restarts (clean slate principle)
- **Template escaping**: WireMock uses Handlebars. In JSON, `{{now format='yyyy-MM-dd'}}` works but complex format strings with single quotes need escaping — test with simple formats first
