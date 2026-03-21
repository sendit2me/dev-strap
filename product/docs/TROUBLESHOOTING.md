# Troubleshooting

## Container won't start

### Check status and logs

```bash
./devstack.sh status
./devstack.sh logs <service>
```

### "port is already allocated"

Another process is using the port.

```bash
# Find what's using the port
lsof -i :8080
# or
ss -tlnp | grep 8080
```

Fix: change the port in `project.env` and restart:

```env
HTTP_PORT=9080
```

```bash
./devstack.sh restart
```

### cert-gen container fails

```bash
./devstack.sh logs cert-gen
```

Common cause: a `mocks/*/domains` file contains invalid entries. Check that each line is a valid domain name with no special characters.

### "unable to prepare context: path not found"

The app source directory does not exist:

```bash
grep APP_SOURCE project.env
ls -la ./app
```

## Mock domain not resolving

1. Did you restart after adding the domain? New domains need new certificates and DNS aliases: `./devstack.sh restart`
2. Verify interception: `./devstack.sh verify-mocks`
3. Check Caddy logs: `./devstack.sh logs web`
4. Check the domain is listed in the mock's `domains` file: `cat mocks/<name>/domains`

## App gets TLS/SSL errors connecting to mocked API

The app container does not trust the DevStack CA certificate. Check:

```bash
./devstack.sh shell
ls -la /certs/ca.crt
```

The CA certificate must be mounted into the app container and the appropriate trust variable set:
- Go: `SSL_CERT_FILE=/certs/ca.crt`
- Node.js: `NODE_EXTRA_CA_CERTS=/certs/ca.crt`
- Python: `REQUESTS_CA_BUNDLE=/certs/ca.crt`

These are configured in `services/app.yml`.

## WireMock returns 404

The mapping does not match the request. Common causes:
- **URL mismatch**: `/v1/items` vs `/v1/items/` (trailing slash)
- **Method mismatch**: mapping is `GET` but request is `POST`
- **Body pattern not matching**: `bodyPatterns` conditions do not match the actual request body

Debug by checking what WireMock received:

```bash
./devstack.sh shell wiremock
wget -qO- http://localhost:8080/__admin/requests | head -200
wget -qO- http://localhost:8080/__admin/mappings | head -200
```

## WireMock returns HTML error page instead of JSON

A WireMock response template has a rendering error. Check logs:

```bash
./devstack.sh logs wiremock
```

Common cause: Handlebars template syntax errors, especially date format strings with single quotes in JSON.

## App can't connect to database

```bash
# Check database health
./devstack.sh status

# Check database logs
./devstack.sh logs db

# Verify env vars
grep DB_ project.env

# Verify database service is included
grep database docker-compose.yml
```

If the database shows "unhealthy", it may still be initializing. The start command waits for the health check, but if you're running init scripts independently, add a wait loop.

## Tests failing

```bash
# Check all services are healthy
./devstack.sh status

# Check mock responses are loaded
./devstack.sh mocks

# Run a specific test
./devstack.sh test "test name"

# Check test container logs
./devstack.sh logs tester
```

### "Executable doesn't exist" / browser version mismatch

The Playwright package version must exactly match the container image version. Check `tests/playwright/package.json` -- the version should be pinned (no `^` or `~`).

### Tests can't reach the app

The test container connects via the Docker network using hostname `web` (the Caddy container). Check:

```bash
grep baseURL tests/playwright/playwright.config.ts
# Should be: http://web or https://web:443
```

## Permission errors (root-owned files)

Containers run as root, so files they create (test results, recorded mappings, node_modules) are owned by root on the host.

The `stop --clean` command handles cleanup automatically. To clean manually:

```bash
docker run --rm -v $(pwd)/tests:/data alpine rm -rf /data/results/* /data/playwright/node_modules
docker run --rm -v $(pwd)/mocks/stripe:/data alpine rm -rf /data/recordings
```

## Port conflicts between projects

Two DevStack projects using the same Docker network subnet:

```
Pool overlaps with other one on this address space
```

Fix: change `NETWORK_SUBNET` in `project.env` for one project:

```env
# Project A
NETWORK_SUBNET=172.28.0.0/24

# Project B
NETWORK_SUBNET=172.29.0.0/24
```

## stop vs stop --clean

| Command | Database data | Caches (Redis, etc.) | Test results | Recordings |
|---------|:---:|:---:|:---:|:---:|
| `./devstack.sh stop` | Kept | Kept | Kept | Kept |
| `./devstack.sh stop --clean` | Deleted | Deleted | Deleted | Deleted |

Use `stop` for fast restarts during development. Use `stop --clean` for a fresh start when something is in a bad state.

## 502 Bad Gateway

Caddy can reach the network but the app is not responding on the expected port.

```bash
./devstack.sh shell app
# Check the app is listening:
# Node/Go/Python/Rust: curl http://localhost:3000/
# PHP-FPM: check php-fpm process is running
```

Make sure your app listens on port 3000 (or 9000 for PHP-FPM).

## "No space left on device"

Docker ran out of disk space:

```bash
# Remove stopped containers, unused networks, dangling images
docker system prune

# More aggressive: remove all unused images
docker system prune -a

# Check disk usage
docker system df
```

## Stack takes too long to start

First start pulls container images (the Playwright image alone is ~2GB). Subsequent starts use cached images and are much faster.

If builds are slow, check your `app/Dockerfile` uses layer caching properly (copy dependency files before source code).

## "network not found" after unexpected shutdown

If Docker crashed or the machine rebooted during a run:

```bash
./devstack.sh stop --clean
./devstack.sh start
```
