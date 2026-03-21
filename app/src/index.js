const express = require('express');
const https = require('https');
const http = require('http');

const app = express();
const PORT = process.env.PORT || 3000;

app.use(express.json());

// ---------------------------------------------------------------------------
// Helper: make an HTTPS request to a (mocked) external API
// ---------------------------------------------------------------------------
function fetchFromProvider(hostname, path, options = {}) {
    return new Promise((resolve, reject) => {
        const reqOptions = {
            hostname,
            port: 443,
            path,
            method: options.method || 'GET',
            headers: {
                'Content-Type': 'application/json',
                ...options.headers,
            },
        };

        const req = https.request(reqOptions, (res) => {
            let data = '';
            res.on('data', (chunk) => { data += chunk; });
            res.on('end', () => {
                try {
                    resolve({ status: res.statusCode, data: JSON.parse(data) });
                } catch {
                    resolve({ status: res.statusCode, data });
                }
            });
        });

        req.on('error', reject);

        if (options.body) {
            req.write(JSON.stringify(options.body));
        }
        req.end();
    });
}

// ---------------------------------------------------------------------------
// Routes
// ---------------------------------------------------------------------------

// Home page
app.get('/', (req, res) => {
    res.send(`
        <!DOCTYPE html>
        <html>
        <head>
            <title>DevStack Example App</title>
            <style>
                body { font-family: system-ui, sans-serif; max-width: 800px; margin: 40px auto; padding: 0 20px; background: #1a1a2e; color: #e0e0e0; }
                h1 { color: #00d4aa; }
                h2 { color: #7c83ff; margin-top: 2em; }
                a { color: #00d4aa; }
                pre { background: #16213e; padding: 16px; border-radius: 8px; overflow-x: auto; border: 1px solid #333; }
                code { color: #f0f0f0; }
                .endpoint { background: #0f3460; padding: 12px 16px; border-radius: 6px; margin: 8px 0; border-left: 4px solid #00d4aa; }
                .method { font-weight: bold; color: #00d4aa; }
                .mock-badge { display: inline-block; background: #e94560; color: white; font-size: 11px; padding: 2px 8px; border-radius: 12px; margin-left: 8px; }
            </style>
        </head>
        <body>
            <h1>DevStack Example App</h1>
            <p>This app demonstrates transparent mock interception. The code makes real HTTPS
               requests to external APIs — but DNS + Caddy + WireMock intercept them and return
               mock responses. <strong>No isDev flags, no code changes.</strong></p>

            <h2>API Endpoints</h2>

            <div class="endpoint">
                <span class="method">GET</span> <a href="/api/items">/api/items</a>
                <span class="mock-badge">mocked: api.example-provider.com</span>
                <br><small>Fetches items from the "external" provider API (simple mock)</small>
            </div>

            <div class="endpoint">
                <span class="method">POST</span> /api/checkout
                <span class="mock-badge">mocked: api.payment-provider.com</span>
                <br><small>Creates a checkout session (stateful mock — progresses through states)</small>
            </div>

            <div class="endpoint">
                <span class="method">GET</span> <a href="/api/checkout/status">/api/checkout/status</a>
                <span class="mock-badge">mocked: api.payment-provider.com</span>
                <br><small>Polls checkout status (call multiple times to see state transitions)</small>
            </div>

            <div class="endpoint">
                <span class="method">POST</span> /api/charge
                <span class="mock-badge">mocked: api.payment-provider.com</span>
                <br><small>Charges a payment (conditional mock — amount >= 10000 triggers review)</small>
            </div>

            <h2>Try It</h2>
            <pre><code># Simple GET (mocked external API)
curl http://localhost:${PORT}/api/items

# Stateful flow — create checkout, then poll status twice
curl -X POST http://localhost:${PORT}/api/checkout
curl http://localhost:${PORT}/api/checkout/status
curl http://localhost:${PORT}/api/checkout/status

# Conditional — normal charge
curl -X POST http://localhost:${PORT}/api/charge -H 'Content-Type: application/json' -d '{"amount": 2500}'

# Conditional — high value triggers review
curl -X POST http://localhost:${PORT}/api/charge -H 'Content-Type: application/json' -d '{"amount": 15000}'</code></pre>

            <h2>Test Results</h2>
            <p><a href="/test-results/">View Playwright test reports</a></p>
        </body>
        </html>
    `);
});

// Simple mock: fetch items from "external" API
app.get('/api/items', async (req, res) => {
    try {
        const result = await fetchFromProvider('api.example-provider.com', '/v1/items');
        res.json({
            source: 'api.example-provider.com',
            intercepted: true,
            ...result.data
        });
    } catch (err) {
        res.status(502).json({ error: 'Failed to reach provider', detail: err.message });
    }
});

// Stateful mock: create checkout session
app.post('/api/checkout', async (req, res) => {
    try {
        const result = await fetchFromProvider('api.payment-provider.com', '/v1/checkout/sessions', {
            method: 'POST',
            body: { amount: 4999, currency: 'usd' }
        });
        res.status(result.status).json({
            source: 'api.payment-provider.com',
            intercepted: true,
            ...result.data
        });
    } catch (err) {
        res.status(502).json({ error: 'Failed to reach payment provider', detail: err.message });
    }
});

// Stateful mock: poll checkout status (call multiple times to see state transitions)
app.get('/api/checkout/status', async (req, res) => {
    try {
        const result = await fetchFromProvider('api.payment-provider.com', '/v1/checkout/sessions/cs_mock_12345');
        res.json({
            source: 'api.payment-provider.com',
            intercepted: true,
            ...result.data
        });
    } catch (err) {
        res.status(502).json({ error: 'Failed to reach payment provider', detail: err.message });
    }
});

// Conditional mock: charge — different response based on amount
app.post('/api/charge', async (req, res) => {
    const amount = req.body.amount || 1000;
    try {
        const result = await fetchFromProvider('api.payment-provider.com', '/v1/charges', {
            method: 'POST',
            body: { amount, currency: 'usd' }
        });
        res.json({
            source: 'api.payment-provider.com',
            intercepted: true,
            requested_amount: amount,
            ...result.data
        });
    } catch (err) {
        res.status(502).json({ error: 'Failed to reach payment provider', detail: err.message });
    }
});

// Health check
app.get('/health', (req, res) => {
    res.json({ status: 'ok', timestamp: new Date().toISOString() });
});

// ---------------------------------------------------------------------------
// Start
// ---------------------------------------------------------------------------
app.listen(PORT, '0.0.0.0', () => {
    console.log(`[app] DevStack Example App running on port ${PORT}`);
    console.log(`[app] Mock providers: api.example-provider.com, api.payment-provider.com`);
});
