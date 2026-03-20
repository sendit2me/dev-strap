# Testing

Tests run inside a Playwright container. You never install Playwright, Node, or browsers on your machine.

## Running tests

```bash
# Run all tests
./devstack.sh test

# Run tests matching a pattern
./devstack.sh test "checkout"
./devstack.sh test "health"
```

Output:

```
[devstack] Running tests (run: 20260319-153329)...

Running 6 tests using 1 worker

  6 passed (1.5s)

[devstack] All tests passed.
[devstack] Report:    http://localhost:8082/20260319-153329/report/index.html
[devstack] Artifacts: http://localhost:8082/20260319-153329/artifacts/
[devstack] JSON:      http://localhost:8082/20260319-153329/results.json
```

## Viewing test results

Every test run produces:

| Artifact | URL | What |
|----------|-----|------|
| HTML report | `http://localhost:8082/{run-id}/report/` | Interactive, browsable report with pass/fail per test |
| Screenshots | `http://localhost:8082/{run-id}/artifacts/` | Screenshot of every test step |
| JSON results | `http://localhost:8082/{run-id}/results.json` | Machine-parseable results for CI or AI agents |
| Traces | `http://localhost:8082/{run-id}/artifacts/` | Playwright trace files (network, DOM, console) |

The test dashboard at `http://localhost:8082` lists all run directories.

### Why screenshots matter

Screenshots are proof of execution. When someone says "it works", you open the test report and see exactly what the browser rendered. This is especially valuable for:

- Verifying visual regressions
- Confirming mock data appears correctly in the UI
- Debugging failures without reproducing them
- Reviewing AI-generated changes (the AI ran tests — did the UI actually look right?)

## Writing tests

Tests live in `tests/playwright/` and use the Playwright test framework.

### Test file naming

Name files with numeric prefixes if execution order matters:

```
tests/playwright/
├── 01-health.spec.ts         # Basic health checks (run first)
├── 02-login.spec.ts          # Authentication
├── 03-dashboard.spec.ts      # Authenticated features
├── 04-api-integration.spec.ts  # API mock verification
```

Playwright runs files in alphabetical order (with `workers: 1`).

### API-only test (no browser)

For testing API endpoints and mock interception:

```typescript
import { test, expect } from '@playwright/test';

test.describe('Stripe Mock', () => {

    test('creates a charge', async ({ request }) => {
        const response = await request.post('/api/charge', {
            data: { amount: 2500, currency: 'usd' }
        });
        expect(response.ok()).toBeTruthy();

        const body = await response.json();
        expect(body.status).toBe('succeeded');
        expect(body.amount).toBe(2500);
    });

    test('rejects negative amount', async ({ request }) => {
        const response = await request.post('/api/charge', {
            data: { amount: -100 }
        });
        expect(response.status()).toBe(400);
    });

});
```

### Browser test (with screenshots)

For testing the actual UI:

```typescript
import { test, expect } from '@playwright/test';

test.describe('Dashboard', () => {

    test('shows welcome message', async ({ page }) => {
        await page.goto('/dashboard');
        await expect(page.locator('h1')).toContainText('Welcome');

        // Screenshot is auto-captured (configured in playwright.config.ts)
        // You can also take manual screenshots:
        await page.screenshot({ path: '/results/screenshots/dashboard.png' });
    });

    test('displays items from mocked API', async ({ page }) => {
        await page.goto('/items');

        // Wait for data to load (it comes from WireMock mock)
        await expect(page.locator('.item-list')).toBeVisible();

        // Verify mock data appears in the UI
        await expect(page.locator('.item')).toHaveCount(3);
        await expect(page.locator('.item').first()).toContainText('Widget A');
    });

});
```

### Testing the stateful mock flow

```typescript
import { test, expect } from '@playwright/test';

test('checkout flow progresses through states', async ({ request }) => {
    // Step 1: Create checkout
    const create = await request.post('/api/checkout');
    expect(create.status()).toBe(201);
    expect((await create.json()).status).toBe('pending');

    // Step 2: Poll — should be "processing" (WireMock state changed)
    const poll1 = await request.get('/api/checkout/status');
    expect((await poll1.json()).status).toBe('processing');

    // Step 3: Poll again — should be "complete" (WireMock state changed again)
    const poll2 = await request.get('/api/checkout/status');
    expect((await poll2.json()).status).toBe('complete');
});
```

### Sharing authentication state between tests

If test 01 logs in and test 03 needs to be authenticated:

```typescript
// 01-login.spec.ts
import { test, expect } from '@playwright/test';

test('login and save session', async ({ page }) => {
    await page.goto('/login');
    await page.fill('#email', 'admin@example.com');
    await page.fill('#password', 'password');
    await page.click('button[type="submit"]');
    await expect(page).toHaveURL('/dashboard');

    // Save authentication state
    await page.context().storageState({ path: '/tests/.auth/user.json' });
});
```

```typescript
// 03-dashboard.spec.ts
import { test, expect } from '@playwright/test';

// Reuse saved authentication state
test.use({ storageState: '/tests/.auth/user.json' });

test('dashboard shows user data', async ({ page }) => {
    await page.goto('/dashboard');
    // Already logged in — no login step needed
    await expect(page.locator('.username')).toContainText('admin');
});
```

Create the auth directory:

```bash
mkdir -p tests/playwright/.auth
echo '{}' > tests/playwright/.auth/.gitkeep
```

## Playwright configuration

The config is at `tests/playwright/playwright.config.ts`:

```typescript
import { defineConfig } from '@playwright/test';

export default defineConfig({
    testDir: '.',
    testMatch: '**/*.spec.ts',
    timeout: 30000,           // 30s per test
    retries: 0,               // No retries locally (set to 2 for CI)
    workers: 1,               // Sequential execution

    use: {
        baseURL: process.env.BASE_URL || 'http://web',
        ignoreHTTPSErrors: true,   // Our self-signed certs
        screenshot: 'on',          // Screenshot every test
        trace: 'on-first-retry',   // Trace on retry
        video: 'retain-on-failure', // Video only on failure
    },

    reporter: [
        ['html', { outputFolder: process.env.PLAYWRIGHT_HTML_REPORT || '/results/report', open: 'never' }],
        ['json', { outputFile: process.env.PLAYWRIGHT_JSON_OUTPUT_FILE || '/results/results.json' }],
        ['list'],  // Console output
    ],

    outputDir: '/results/artifacts',
});
```

### Key config options

| Setting | What it controls | Default |
|---------|-----------------|---------|
| `baseURL` | Where `page.goto('/')` points | `http://web` (the Caddy container) |
| `ignoreHTTPSErrors` | Accept self-signed certs | `true` |
| `screenshot` | When to capture screenshots | `on` (every test) |
| `workers` | Parallel test execution | `1` (sequential) |
| `timeout` | Max time per test | `30000` (30s) |

### Adding npm packages to tests

If your tests need additional packages (test helpers, fixtures, etc.):

1. Add them to `tests/playwright/package.json`
2. They get installed automatically on the next `./devstack.sh test` run

## Playwright version pinning

The Playwright test library version must match the container image version. Both are currently pinned to **1.52.0**:

- Container: `mcr.microsoft.com/playwright:v1.52.0-noble` (in compose generator)
- Package: `"@playwright/test": "1.52.0"` (in tests/playwright/package.json)

If you update one, update the other. Mismatched versions cause "Executable doesn't exist" errors.

## Test results are ephemeral

`./devstack.sh stop` deletes all test results. This is intentional:

- Tests are deterministic (same mocks → same results)
- If it was failing before stop, it'll fail again after start
- Results are a derivable artifact, not data

If you need to preserve a specific report, copy it out before stopping:

```bash
cp -r tests/results/20260319-153329 ~/saved-test-results/
```

## Using tests with AI agents

The test infrastructure is designed for AI-assisted development:

```bash
# AI agent workflow:
# 1. Agent makes code changes
# 2. Agent runs tests
./devstack.sh test

# 3. Agent checks exit code (0 = pass, 1 = fail)
# 4. On failure, agent reads JSON results:
cat tests/results/*/results.json

# 5. Agent can also read screenshots for visual verification
# 6. Agent fixes issues and re-runs
```

The JSON report contains structured failure information (test name, error message, stack trace) that an AI agent can parse programmatically.
