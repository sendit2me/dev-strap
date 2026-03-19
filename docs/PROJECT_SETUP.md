# Setting Up Your Own Project

This guide walks through replacing the example app with your own project, from scratch.

## Step 1: Configure project.env

Edit `project.env` to match your project:

```env
# Your project name — used for container names, network, certs
PROJECT_NAME=my-saas-app

# App type — must match a directory in templates/apps/
# Options: node-express, php-laravel, go
APP_TYPE=node-express

# Path to your app source code, relative to devstack/
# This directory will be mounted into the app container
APP_SOURCE=./app

# Script to run inside the app container after it starts
# Use this for migrations, seeding, dependency installation, etc.
APP_INIT_SCRIPT=./app/init.sh

# Ports exposed on YOUR machine (localhost)
HTTP_PORT=8080          # http://localhost:8080 → your app
HTTPS_PORT=8443         # https://localhost:8443 → your app (with generated cert)
TEST_DASHBOARD_PORT=8082  # http://localhost:8082 → test reports

# Database — pick one or set to "none"
DB_TYPE=mariadb         # mariadb | postgres | none
DB_NAME=my_saas_app
DB_USER=app
DB_PASSWORD=secret
DB_ROOT_PASSWORD=root

# Extra services — comma-separated
EXTRAS=redis            # redis, mailpit, or leave empty
```

### Port allocation

Every port in `project.env` maps `localhost:<PORT>` on your machine to the correct container. No other ports are exposed. The internal Docker network handles everything else.

```
Your machine                    Docker network
─────────────                   ──────────────
localhost:8080  ──────────────▶ nginx:80     ──▶ app container
localhost:8443  ──────────────▶ nginx:443    ──▶ app container (or WireMock for mocked domains)
localhost:8082  ──────────────▶ test-dashboard:8080
```

If you're running multiple devstack projects simultaneously, change the ports so they don't collide:

```env
# Project A
HTTP_PORT=8080
HTTPS_PORT=8443

# Project B
HTTP_PORT=9080
HTTPS_PORT=9443
```

## Step 2: Set up your app source directory

### Option A: Start from the example

The included `app/` directory has a working Node.js app. Modify it:

```
app/
├── Dockerfile         # How to build your container
├── init.sh            # Runs inside container on first start
├── package.json       # Dependencies
└── src/
    └── index.js       # Your app code
```

### Option B: Start fresh

Delete the example and create your own:

```bash
rm -rf app/
mkdir -p app/src
```

Create `app/Dockerfile`. This is the only required file — it defines how to build your app container:

```dockerfile
# For Node.js
FROM node:22-alpine
WORKDIR /app
COPY package*.json ./
RUN npm install
COPY . .
EXPOSE 3000
CMD ["node", "--watch", "src/index.js"]
```

```dockerfile
# For Go
FROM golang:1.24-alpine
RUN go install github.com/air-verse/air@latest
WORKDIR /app
COPY go.* ./
RUN go mod download
COPY . .
EXPOSE 3000
CMD ["air", "-c", ".air.toml"]
```

```dockerfile
# For PHP/Laravel
FROM php:8.3-fpm
RUN apt-get update && apt-get install -y libpng-dev libonig-dev libxml2-dev \
    && docker-php-ext-install pdo_mysql mbstring gd
COPY --from=composer:latest /usr/bin/composer /usr/bin/composer
WORKDIR /var/www/html
COPY . .
RUN composer install
EXPOSE 9000
CMD ["php-fpm"]
```

### Option C: Point at existing source code

If your source code lives elsewhere, just change `APP_SOURCE`:

```env
APP_SOURCE=../my-existing-project
```

The path is relative to the `devstack/` directory. The entire directory gets volume-mounted into the container, so changes you make on your machine appear instantly in the container.

## Step 3: Environment variables for your app

Your app receives environment variables defined in its `service.yml` template. The defaults are in `templates/apps/<type>/service.yml`:

```yaml
environment:
  - NODE_ENV=development
  - PORT=3000
  - NODE_EXTRA_CA_CERTS=/certs/ca.crt    # Trusts the mock CA
  - DB_HOST=db                            # Container hostname
  - DB_PORT=3306
  - DB_NAME=${DB_NAME}                    # From project.env
  - DB_USER=${DB_USER}
  - DB_PASSWORD=${DB_PASSWORD}
```

### Adding custom environment variables

Edit the service.yml for your app type. For example, to add an API key:

```yaml
# templates/apps/node-express/service.yml
environment:
  - NODE_ENV=development
  - PORT=3000
  - NODE_EXTRA_CA_CERTS=/certs/ca.crt
  - DB_HOST=db
  - DB_PORT=3306
  - DB_NAME=${DB_NAME}
  - DB_USER=${DB_USER}
  - DB_PASSWORD=${DB_PASSWORD}
  - STRIPE_SECRET_KEY=sk_test_mock_key_12345    # Add your own
  - OPENAI_API_KEY=sk-mock-key                  # Fake keys are fine — it's mocked
  - APP_SECRET=any-dev-secret-here
```

These values are for development only. In production, you'd set real values via your deployment system.

### Using a .env file

If your app reads a `.env` file (like Laravel or dotenv), create it in your app source:

```bash
# app/.env
APP_NAME=My SaaS App
APP_ENV=local
APP_DEBUG=true
DB_CONNECTION=mysql
DB_HOST=db
DB_PORT=3306
DB_DATABASE=my_saas_app
DB_USERNAME=app
DB_PASSWORD=secret
```

This file lives in your `APP_SOURCE` directory and is mounted into the container. The app reads it normally.

## Step 4: The init script

`init.sh` runs inside the app container after the stack starts. Use it for anything your app needs before it's ready:

```bash
#!/bin/sh

# Install dependencies
cd /app && npm install

# Run database migrations
npx prisma migrate deploy

# Seed test data
npx prisma db seed

echo "[init] Ready."
```

For Laravel:

```bash
#!/bin/sh

cd /var/www/html

# Install PHP deps
composer install --no-interaction

# Generate app key if missing
php artisan key:generate --no-interaction

# Run migrations
php artisan migrate --force

# Seed data
php artisan db:seed --force

# Clear caches
php artisan optimize:clear

echo "[init] Ready."
```

For Go:

```bash
#!/bin/sh

cd /app

# Download dependencies
go mod download

# Run migrations (example with golang-migrate)
migrate -path ./migrations -database "mysql://${DB_USER}:${DB_PASSWORD}@tcp(db:3306)/${DB_NAME}" up

echo "[init] Ready."
```

Make it executable:

```bash
chmod +x app/init.sh
```

## Step 5: Set up your mock services

Decide which external APIs your app calls and create a mock for each. See [ADDING_MOCKS.md](ADDING_MOCKS.md) for the full guide.

### Option A: Write mappings by hand

```bash
# Scaffold the mock
./devstack.sh new-mock stripe api.stripe.com
```

This creates `mocks/stripe/` with a `domains` file and an example mapping. Edit or replace the mappings:

```json
{
    "request": {
        "method": "POST",
        "url": "/v1/charges"
    },
    "response": {
        "status": 200,
        "headers": { "Content-Type": "application/json" },
        "jsonBody": {
            "id": "ch_mock_123",
            "status": "succeeded",
            "amount": 2500,
            "currency": "usd"
        }
    }
}
```

### Option B: Record from the real API

If you don't know the exact response format, record it:

```bash
./devstack.sh new-mock stripe api.stripe.com
./devstack.sh restart                            # pick up the new domain
./devstack.sh record stripe                      # proxies to real Stripe API
# Make requests through your app — responses are captured
# Press Ctrl+C when done
./devstack.sh apply-recording stripe             # copies recordings into the mock
```

This captures real request/response pairs and converts them into WireMock mappings. Review them before committing — they may contain API keys in headers.

After either option, your app code calls `https://api.stripe.com/v1/charges` with real HTTPS — DevStack intercepts it transparently.

### Iterating on mocks

Once the domain is set up, you don't need a full restart to change mappings:

```bash
# Edit a mapping file
vim mocks/stripe/mappings/create-charge.json

# Hot-reload (no restart)
./devstack.sh reload-mocks
```

A full restart (`./devstack.sh restart`) is only needed when adding a new domain.

## Step 6: Write tests

See [TESTING.md](TESTING.md) for the full guide.

Quick start — create a test in `tests/playwright/`:

```typescript
// tests/playwright/01-my-app.spec.ts
import { test, expect } from '@playwright/test';

test('home page loads', async ({ page }) => {
    await page.goto('/');
    await expect(page).toHaveTitle(/My SaaS App/);
});

test('API returns data from mocked provider', async ({ request }) => {
    const response = await request.post('/api/charge', {
        data: { amount: 2500 }
    });
    expect(response.ok()).toBeTruthy();
    const body = await response.json();
    expect(body.status).toBe('succeeded');
});
```

## Step 7: Start and verify

```bash
./devstack.sh start
```

Check everything:

```bash
# Is it running?
./devstack.sh status

# Can I reach it?
curl http://localhost:8080/

# Are mocks working?
./devstack.sh shell app
curl -k https://api.stripe.com/v1/charges -X POST

# Run tests
./devstack.sh test

# View test report
open http://localhost:8082
```

## Full example: project.env for a Laravel + Stripe + OpenAI app

```env
PROJECT_NAME=my-ai-saas
APP_TYPE=php-laravel
APP_SOURCE=../my-laravel-app
APP_INIT_SCRIPT=../my-laravel-app/devstack-init.sh
HTTP_PORT=8080
HTTPS_PORT=8443
TEST_DASHBOARD_PORT=8082
DB_TYPE=mariadb
DB_NAME=ai_saas
DB_USER=ai_saas
DB_PASSWORD=secret
DB_ROOT_PASSWORD=root
EXTRAS=redis,mailpit
```

With mocks:

```
mocks/
├── stripe/
│   ├── domains           → "api.stripe.com"
│   └── mappings/
│       ├── create-charge.json
│       └── create-checkout.json
├── openai/
│   ├── domains           → "api.openai.com"
│   └── mappings/
│       ├── chat-completion.json
│       └── chat-stream.json
└── sendgrid/
    ├── domains           → "api.sendgrid.com"
    └── mappings/
        └── send-email.json
```

Ports available:
- http://localhost:8080 — your Laravel app
- http://localhost:8025 — Mailpit inbox (catches all outgoing emails)
- http://localhost:8082 — test results dashboard
