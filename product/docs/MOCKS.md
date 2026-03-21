# Mock API Management

## How Mocking Works

Your app makes HTTPS requests to external APIs (e.g., `api.stripe.com`) exactly as it would in production. The stack intercepts these transparently:

1. **Docker DNS** resolves the mocked domain to Caddy (via network aliases on the `web` container)
2. **Caddy** terminates TLS using auto-generated certificates, adds an `X-Original-Host` header, and forwards the request to WireMock
3. **WireMock** matches the request against stub mappings in `mocks/*/mappings/*.json` and returns the configured response

Your app code needs no `isDev` flags, no mock SDKs, no environment conditionals. The same code runs against real APIs in production and mocked APIs in development.

## Your Mocks

```bash
ls mocks/
# stripe/  sendgrid/
```

Each mock directory contains:

```
mocks/stripe/
├── domains              Domains to intercept (one per line)
└── mappings/            WireMock JSON stub definitions
    ├── create-charge.json
    └── list-customers.json
```

The `domains` file drives three things:
- DNS aliases on the Caddy container (Docker resolves them to Caddy)
- SANs on the auto-generated TLS certificate
- Site blocks in the Caddyfile (proxied to WireMock)

## Adding a Mock

```bash
./devstack.sh new-mock stripe api.stripe.com
```

This creates:
- `mocks/stripe/domains` containing `api.stripe.com`
- `mocks/stripe/mappings/example.json` with a sample stub

Then restart to pick up the new domain (new domains need new certs and DNS aliases):

```bash
./devstack.sh restart
```

To intercept multiple domains for the same mock, add them to the `domains` file (one per line):

```
api.stripe.com
hooks.stripe.com
```

## Editing Mock Responses

Edit or add JSON files in `mocks/<name>/mappings/`. Then hot-reload without restarting:

```bash
./devstack.sh reload-mocks
```

This calls WireMock's admin API to re-read all mapping files from disk. Changes take effect immediately.

## Mock Mapping Format

Each JSON file in `mappings/` defines one request-response pair.

### Simple GET

```json
{
    "name": "stripe -- list customers",
    "request": {
        "method": "GET",
        "url": "/v1/customers"
    },
    "response": {
        "status": 200,
        "headers": { "Content-Type": "application/json" },
        "jsonBody": {
            "data": [{ "id": "cus_123", "name": "Test User" }],
            "has_more": false
        }
    }
}
```

### URL Pattern Matching

```json
{
    "request": {
        "method": "GET",
        "urlPattern": "/v1/customers/[a-zA-Z0-9_]+"
    },
    "response": {
        "status": 200,
        "jsonBody": { "id": "cus_matched", "name": "Any Customer" }
    }
}
```

### POST with Body Matching

Use `bodyPatterns` to return different responses based on request content. Lower `priority` number is matched first.

```json
{
    "priority": 1,
    "request": {
        "method": "POST",
        "url": "/v1/charges",
        "bodyPatterns": [
            { "matchesJsonPath": "$.currency", "equalTo": "eur" }
        ]
    },
    "response": {
        "status": 200,
        "jsonBody": { "id": "ch_eur", "currency": "eur" }
    }
}
```

```json
{
    "priority": 5,
    "request": {
        "method": "POST",
        "url": "/v1/charges"
    },
    "response": {
        "status": 200,
        "jsonBody": { "id": "ch_default", "currency": "usd" }
    }
}
```

### Stateful Mocks (Scenarios)

WireMock scenarios let an endpoint return different responses on successive calls. Each state is a separate mapping file.

**`01-create.json`** -- first call creates the resource:

```json
{
    "scenarioName": "job-flow",
    "requiredScenarioState": "Started",
    "newScenarioState": "Created",
    "request": { "method": "POST", "url": "/v1/jobs" },
    "response": {
        "status": 201,
        "jsonBody": { "id": "job_1", "status": "queued" }
    }
}
```

**`02-poll.json`** -- next call shows progress:

```json
{
    "scenarioName": "job-flow",
    "requiredScenarioState": "Created",
    "newScenarioState": "Done",
    "request": { "method": "GET", "url": "/v1/jobs/job_1" },
    "response": {
        "status": 200,
        "jsonBody": { "id": "job_1", "status": "complete" }
    }
}
```

Scenarios reset to `"Started"` when the stack restarts.

### Response Templating

WireMock supports dynamic values via Handlebars. Response templating is enabled globally.

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

### Disambiguating Shared Paths

All mocked domains share one WireMock instance. If two APIs use the same method and path (e.g., both Stripe and OpenAI have `POST /v1/tokens`), add `X-Original-Host` header matching:

```json
{
    "request": {
        "method": "POST",
        "url": "/v1/tokens",
        "headers": {
            "X-Original-Host": { "equalTo": "api.stripe.com" }
        }
    },
    "response": { "..." }
}
```

Caddy adds this header automatically when proxying to WireMock.

## Recording Real API Responses

Record from a real API to quickly create mock mappings:

```bash
# 1. Create the mock (if it doesn't exist)
./devstack.sh new-mock stripe api.stripe.com
./devstack.sh restart

# 2. Start recording (proxies to the real API)
./devstack.sh record stripe
# Make requests through your app in another terminal
# Press Ctrl+C when done

# 3. Review captured mappings (may contain API keys!)
ls mocks/stripe/recordings/mappings/

# 4. Apply recordings to the mock
./devstack.sh apply-recording stripe
```

What `apply-recording` does:
- Copies mapping files from `recordings/mappings/` to `mappings/`
- Copies response body files from `recordings/__files/` to `__files/`
- Rewrites `bodyFileName` paths to match WireMock's mount structure
- Cleans up the recordings directory
- Hot-reloads WireMock if the stack is running

**Important**: Review recordings before applying. They may contain API keys, tokens, or other credentials in headers or response bodies.

## When to Restart vs Hot-Reload

| Change | Action |
|--------|--------|
| Edited a mapping JSON file | `./devstack.sh reload-mocks` (instant) |
| Added a new mapping file to existing mock | `./devstack.sh reload-mocks` (instant) |
| Added a new mock (new domain) | `./devstack.sh restart` (needs new certs + DNS) |
| Added a domain to existing mock | `./devstack.sh restart` (needs new certs + DNS) |
| Removed a mock | `./devstack.sh restart` |

Rule of thumb: if you changed anything in a `domains` file, restart. If you only changed `mappings/*.json`, reload.

## Verifying Mocks

After starting the stack, verify that all mocked domains are being intercepted:

```bash
./devstack.sh verify-mocks
```

This shells into the app container and makes HTTPS requests to each mocked domain. A `PASS` result means the domain resolves to Caddy and reaches WireMock (even a 404 from WireMock is a PASS -- it means interception works, you just need a mapping for that path).

To inspect what WireMock received and what mappings are loaded:

```bash
./devstack.sh shell wiremock
wget -qO- http://localhost:8080/__admin/requests | head -200
wget -qO- http://localhost:8080/__admin/mappings | head -200
```

## Debugging Tips

- **404 from WireMock**: The mapping does not match the request. Check URL, method, and body patterns. Trailing slashes matter (`/v1/items` vs `/v1/items/`).
- **HTML error page instead of JSON**: A WireMock response template has a rendering error. Check `./devstack.sh logs wiremock` for details.
- **Wrong response returned**: Check `priority` values across mappings. Lower number is matched first.
- **Domain not resolving**: Did you restart after adding the domain? Check `./devstack.sh logs web` for Caddy errors.
- **TLS errors in app**: The app container must trust the DevStack CA. Check that `/certs/ca.crt` is mounted and the appropriate environment variable is set (`SSL_CERT_FILE`, `NODE_EXTRA_CA_CERTS`, etc.).
