# Troubleshooting

## Container won't start

### "port is already allocated"

Something else is using that port on your machine.

```bash
# Find what's using port 8080
lsof -i :8080
# or
ss -tlnp | grep 8080
```

Fix: either stop the conflicting process, or change the port in `project.env`:

```env
HTTP_PORT=9080
```

### "unable to prepare context: path not found"

The app source directory doesn't exist.

```bash
# Check what APP_SOURCE is set to
grep APP_SOURCE project.env

# Make sure that directory exists
ls -la ./app  # or whatever APP_SOURCE points to
```

### cert-gen container fails

```bash
docker logs myproject-cert-gen
```

Usually means the `core/certs/generate.sh` script has an error, or the domains.txt file is malformed. Check that your `mocks/*/domains` files contain valid domain names (one per line, no special characters).

## Mock not being intercepted

### App gets "connection refused" or "ECONNREFUSED"

The DNS alias isn't resolving to the nginx container. Check:

1. Is the domain listed in the correct `mocks/<name>/domains` file?
2. Did you restart after adding the mock? (`./devstack.sh stop && ./devstack.sh start`)
3. Is the domain in the generated compose file's network aliases?

```bash
grep "your-domain.com" .generated/docker-compose.yml
```

### App gets SSL/TLS errors

The app container doesn't trust the DevStack CA certificate. Check:

```bash
# Shell into app and test directly
./devstack.sh shell
curl -v https://api.your-mock.com/test

# If you see "certificate verify failed", the CA isn't trusted
# Check the cert is mounted
ls -la /certs/ca.crt

# Check the env var is set (for Node.js)
echo $NODE_EXTRA_CA_CERTS
```

Fix depends on language — see [CREATING_TEMPLATES.md](CREATING_TEMPLATES.md) section on trusting the CA.

### WireMock returns 404

The mapping doesn't match the request. Debug:

```bash
# Check what WireMock received
./devstack.sh shell wiremock
wget -qO- http://localhost:8080/__admin/requests | head -100

# Check what mappings are loaded
wget -qO- http://localhost:8080/__admin/mappings | head -100
```

Common causes:
- **URL mismatch**: Your mapping has `/v1/items` but the request hits `/v1/items/` (trailing slash)
- **Method mismatch**: Mapping is `GET` but request is `POST`
- **bodyPatterns not matching**: For conditional mocks, the JSON path or regex doesn't match the actual request body

Fix: adjust your mapping's `url`, `urlPattern`, `method`, or `bodyPatterns`.

### WireMock returns wrong response

If you have multiple mappings that could match, check priorities:

```json
// Lower number = matched first
{ "priority": 1, ... }   // <-- this wins
{ "priority": 5, ... }   // <-- fallback
```

Without explicit priorities, WireMock matches the most specific mapping first.

### WireMock returns HTML error page instead of JSON

A WireMock response template has a rendering error. Your app receives an HTML error page which the JSON parser can't handle.

Common cause: Handlebars template syntax errors in your mapping, especially date format strings with single quotes:

```json
// BROKEN — nested single quotes in JSON
"body": "{{now format='yyyy-MM-dd'T'HH:mm:ss'Z''}}"

// WORKS — use simple format or escape carefully
"body": "{{now}}"
"body": "{{now format='yyyy-MM-dd'}}"
```

To debug, check WireMock logs:

```bash
./devstack.sh logs wiremock
```

### Two mocked APIs have the same endpoint path

If `mocks/stripe/` and `mocks/openai/` both define `POST /v1/tokens`, WireMock can't distinguish them by default because all mocked domains share one WireMock instance.

Fix: add `X-Original-Host` header matching to the conflicting mappings:

```json
{
    "request": {
        "method": "POST",
        "url": "/v1/tokens",
        "headers": {
            "X-Original-Host": { "equalTo": "api.stripe.com" }
        }
    },
    "response": { ... }
}
```

Nginx automatically adds this header when proxying to WireMock.

## Test failures

### "Executable doesn't exist" / browser version mismatch

The Playwright test library version doesn't match the container image version.

Check both versions match:

```bash
# Container image version (in core/compose/generate.sh)
grep playwright core/compose/generate.sh
# Output: mcr.microsoft.com/playwright:v1.52.0-noble

# Package version
cat tests/playwright/package.json
# Should show: "@playwright/test": "1.52.0"
```

Fix: make both versions identical. Pin the package.json version (no `^` or `~`).

### Tests can't reach the app

```bash
# Check the app is running
./devstack.sh status

# Check the base URL in playwright config
grep baseURL tests/playwright/playwright.config.ts
# Should be: http://web or https://web:443
```

The test container connects to the app via the Docker network using hostname `web` (the nginx container).

### "Cannot find module" errors in tests

Dependencies aren't installed. The test command runs `npm install` automatically, but if it fails:

```bash
# Shell into the tester and install manually
./devstack.sh shell tester
cd /tests && npm install
```

### Permission denied on test results

Test results are written by the container (as root). The `./devstack.sh stop` command handles cleanup using a Docker container. If you need to manually clean:

```bash
docker run --rm -v $(pwd)/tests:/data alpine rm -rf /data/results/* /data/playwright/node_modules
```

## Database issues

### "Connection refused" to database

The database might not be ready yet. Check:

```bash
./devstack.sh status
# Look for "healthy" status on the db container
```

If the db shows "unhealthy", check its logs:

```bash
./devstack.sh logs db
```

Common cause: the init script runs before the database is ready. The `devstack.sh start` command waits for the database health check, but if your init script is running a second time (inside the app), it might hit a timing issue.

Fix: add a wait loop to your init.sh:

```bash
# Wait for database
until mariadb -h db -u root -proot -e "SELECT 1" 2>/dev/null; do
    echo "[init] Waiting for database..."
    sleep 2
done
```

### Migrations fail

```bash
# Shell into the app and run manually
./devstack.sh shell
php artisan migrate --force  # Laravel
npx prisma migrate deploy    # Prisma
```

Check the error output. Common causes:
- Database doesn't exist yet (check `DB_NAME` matches what's in the MariaDB/Postgres env)
- Previous migration left a partial state (since we clean-slate on restart, this shouldn't happen)

## nginx issues

### 502 Bad Gateway

Nginx can reach the network but the app container isn't responding on the expected port.

```bash
# Check app is listening
./devstack.sh shell app
# For Node: curl http://localhost:3000/
# For PHP: check php-fpm is running

# Check nginx config
cat .generated/nginx.conf | grep proxy_pass
```

Fix: make sure your app listens on port 3000 (or 9000 for PHP-FPM), matching what's in the generated nginx config.

### 403 Forbidden

Nginx is trying to serve a directory listing (no index file). Usually means the `root` directive points to a directory without an index file.

For non-PHP apps, this shouldn't happen (nginx proxies everything to the app). For PHP apps, check that `public/index.php` exists in your app source.

## General

### "No space left on device"

Docker is running out of disk space. Clean up:

```bash
# Remove stopped containers, unused networks, dangling images
docker system prune

# More aggressive: remove all unused images
docker system prune -a

# Check disk usage
docker system df
```

### Stack takes too long to start

First start pulls container images (Playwright alone is ~2GB). Subsequent starts are faster because images are cached.

If builds are slow, check your Dockerfile uses layer caching properly (copy dependency files before source code).

### "network not found" after unexpected shutdown

If Docker crashed or the machine rebooted during a run:

```bash
# Force cleanup
docker compose -p myproject down -v --remove-orphans
rm -rf .generated
./devstack.sh start
```

### Root-owned files (permission denied)

Containers run as root by default, so files written by containers (test results, recorded mappings, node_modules) are owned by root on the host. DevStack handles this automatically on `stop`, but if you need to manually clean:

```bash
# Use a Docker container to remove root-owned files
docker run --rm -v $(pwd)/tests:/data alpine rm -rf /data/results/* /data/playwright/node_modules
docker run --rm -v $(pwd)/mocks/stripe:/data alpine rm -rf /data/recordings
```

### Recording doesn't capture anything

The recorder container listens on its own hostname (`${PROJECT_NAME}-recorder:8080`), not on the mocked domain. You need to make requests directly to the recorder, not through nginx.

From another terminal while recording:

```bash
./devstack.sh shell app
wget -qO- http://myproject-recorder:8080/v1/charges
```

Or use `curl` with your actual app by temporarily changing the API base URL to `http://myproject-recorder:8080`.

### Recorded mapping bodyFileName not found

After applying recordings, WireMock can't find response body files. This happens when `bodyFileName` paths don't match the mount structure.

`apply-recording` automatically rewrites paths (e.g., `"bodyFileName": "body-get-abc.json"` becomes `"bodyFileName": "stripe/body-get-abc.json"` to match the mount at `/home/wiremock/__files/stripe/`).

If you copied files manually instead of using `apply-recording`, you need to either:
1. Prefix `bodyFileName` values with the mock name: `"stripe/body-get-abc.json"`
2. Or place body files directly in `mocks/<name>/__files/` and use `apply-recording` next time

### Subnet conflict running multiple projects

If you get a Docker network error like "Pool overlaps with other one on this address space", two DevStack projects are using the same subnet.

Fix: change `NETWORK_SUBNET` in `project.env` for one of the projects:

```env
# Project A
NETWORK_SUBNET=172.28.0.0/24

# Project B
NETWORK_SUBNET=172.29.0.0/24
```
