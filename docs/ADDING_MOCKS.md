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
- DNS aliases on the nginx container (Docker resolves them to nginx)
- SANs on the auto-generated SSL certificate
- `server_name` entries in the nginx config (proxied to WireMock)

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

## Tips

- **Naming**: Prefix mapping files with numbers (`01-`, `02-`) for stateful scenarios to show order
- **Priority**: Use `priority` when multiple mappings could match the same request (1 = highest)
- **Multiple domains**: A single mock service can intercept multiple domains
- **`__files/` directory**: For large response bodies, put them in `mocks/<name>/__files/` and reference with `"bodyFileName": "response.json"` in the mapping
- **Reset state**: WireMock scenarios reset when the stack restarts (clean slate principle)
