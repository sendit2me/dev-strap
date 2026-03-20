# DBeaver / CloudBeaver Research: Docker-Compatible Database UI for dev-strap

> **Date**: 2026-03-20
> **Context**: Research into whether DBeaver has a Docker-compatible version suitable as a dev-strap service template, how it compares to Adminer, and whether one or both should be offered.
> **Pattern reference**: Existing extras in `templates/extras/{redis,mailpit,prometheus,grafana,dozzle}/service.yml`, Adminer research in `docs/research/01-new-services.md` (Section 3), and the compose generator at `core/compose/generate.sh`.

---

## Table of Contents

1. [CloudBeaver Community (Web-Based DBeaver)](#1-cloudbeaver-community-web-based-dbeaver)
2. [DBeaver Team Edition](#2-dbeaver-team-edition)
3. [Comparison: CloudBeaver vs Adminer](#3-comparison-cloudbeaver-vs-adminer)
4. [Integration with dev-strap](#4-integration-with-dev-strap)
5. [Alternative: DbGate](#5-alternative-dbgate)
6. [Recommendation](#6-recommendation)
7. [Sources](#7-sources)

---

## 1. CloudBeaver Community (Web-Based DBeaver)

### What It Is

CloudBeaver is the web-based, open-source edition of DBeaver. It is maintained by the DBeaver team under the Apache 2.0 license. The server is a Java application (runs on Jetty), and the frontend is TypeScript/React. It provides a browser-based database management experience with many features from the desktop DBeaver IDE: SQL editor with autocompletion, ER diagrams, data editor, metadata browser, and query history.

GitHub: [dbeaver/cloudbeaver](https://github.com/dbeaver/cloudbeaver)

### Docker Image

```
dbeaver/cloudbeaver:latest
```

- **Registry**: Docker Hub (`hub.docker.com/r/dbeaver/cloudbeaver`)
- **Image size**: ~480-500 MB compressed (Java runtime + drivers + frontend assets)
- **Base**: Debian-based (not Alpine -- Java application with many JDBC drivers bundled)
- **Versioning**: Tags track CloudBeaver releases (e.g., `24.3.0`, `25.0.0`). The `:latest` tag follows the latest Community release.

### Default Port

| Port | Protocol | Purpose | Expose to host? |
|------|----------|---------|-----------------|
| 8978 | HTTP | Web UI (Jetty server) | Yes, via `${CLOUDBEAVER_PORT}` |

Port 8978 is the only port. There is no separate API port or metrics port. This is CloudBeaver's canonical default and is unlikely to conflict with other dev-strap services (nothing else uses the 8900-8999 range).

### Volume Needs (Workspace Persistence)

```yaml
volumes:
  - ${PROJECT_NAME}-cloudbeaver-workspace:/opt/cloudbeaver/workspace
```

**Purpose**: The workspace directory stores:
- Server configuration (`.cloudbeaver.runtime.conf`)
- User accounts and sessions
- Saved database connections
- Query history
- Internal H2 database (CloudBeaver's own metadata store)

Without a volume, all configuration and saved connections are lost on container restart. This is different from Adminer, which is completely stateless.

**Disk usage**: The workspace grows slowly. For dev use, expect 10-50 MB over time (mostly query history and H2 database).

### Configuration for Auto-Connecting to PostgreSQL and MariaDB

CloudBeaver supports pre-configured database connections via two mechanisms:

#### Method 1: `initial-data-sources.conf` (Recommended for dev-strap)

Place a JSON configuration file at `/opt/cloudbeaver/conf/initial-data-sources.conf`. CloudBeaver reads this on first startup and creates the connections automatically.

**PostgreSQL example:**

```json
{
    "folders": {},
    "connections": {
        "dev-postgres": {
            "provider": "postgresql",
            "driver": "postgres-jdbc",
            "name": "Dev Database (PostgreSQL)",
            "save-password": true,
            "configuration": {
                "host": "db",
                "port": "5432",
                "database": "${DB_NAME}",
                "url": "jdbc:postgresql://db:5432/${DB_NAME}",
                "type": "dev",
                "auth-model": "native",
                "user": "${DB_USER}",
                "password": "${DB_PASSWORD}"
            }
        }
    }
}
```

**MariaDB example:**

```json
{
    "folders": {},
    "connections": {
        "dev-mariadb": {
            "provider": "mysql",
            "driver": "mariaDB",
            "name": "Dev Database (MariaDB)",
            "save-password": true,
            "configuration": {
                "host": "db",
                "port": "3306",
                "database": "${DB_NAME}",
                "url": "jdbc:mariadb://db:3306/${DB_NAME}",
                "type": "dev",
                "auth-model": "native",
                "user": "${DB_USER}",
                "password": "${DB_PASSWORD}"
            }
        }
    }
}
```

**Problem for dev-strap**: These config files use literal values, not environment variables. CloudBeaver does not perform `${VAR}` substitution on `initial-data-sources.conf`. The compose generator would need to produce a templated config file with the values from `project.env` already substituted, then mount it into the container. This adds complexity: either the generator writes a file to `.generated/cloudbeaver/initial-data-sources.conf`, or the service template includes an entrypoint wrapper that performs `envsubst`.

#### Method 2: First-Run Wizard (Manual)

On first launch, CloudBeaver presents a setup wizard at `http://localhost:8978`. The user sets an admin password and can then manually add database connections through the web UI. This is the default behavior and requires no pre-configuration, but it means connections are not automatic.

#### Method 3: Anonymous Access + Pre-configured Connections

For a zero-friction dev experience, CloudBeaver can be configured to:
1. Skip authentication (anonymous access)
2. Show pre-configured connections to all users

This requires settings in `cloudbeaver.conf` or via environment variables:

```json
{
    "app": {
        "anonymousAccessEnabled": true,
        "anonymousUserRole": "user"
    }
}
```

Or via the environment variable `CLOUDBEAVER_APP_ANONYMOUS_ACCESS_ENABLED=true`.

**Combined with Method 1**, this would give a near-zero-config experience: launch the container, open the browser, and the database connection is already visible. However, the first-run wizard still appears on the very first launch and must be completed once (setting an admin password). There is no clean way to fully skip the wizard via environment variables alone -- it requires writing an `initial-data.conf` file with admin credentials:

```json
{
    "adminName": "cbadmin",
    "adminPassword": "cbadmin"
}
```

This file goes at `{WORKSPACE}/conf/initial-data.conf` (i.e., `/opt/cloudbeaver/workspace/conf/initial-data.conf` inside the container).

### Health Check

```yaml
healthcheck:
  test: ["CMD-SHELL", "curl -sf http://localhost:8978/status > /dev/null"]
  interval: 15s
  timeout: 5s
  retries: 10
  start_period: 30s
```

**Endpoints available**:
- `/status` -- returns server status (commonly used in Docker health checks)
- `/health` -- alternative health endpoint

**Important**: CloudBeaver is Java-based and has a slow startup. The `start_period: 30s` is necessary to avoid false failures during JVM initialization. The image includes `curl` (Debian-based), so `curl -sf` is the correct tool (not `wget`).

**Contrast with Adminer**: Adminer starts in under 1 second. CloudBeaver takes 15-30 seconds on a typical dev machine (JVM startup + driver loading + H2 database initialization). On first launch it can take even longer due to workspace initialization.

### Resource Usage

| Resource | CloudBeaver | Adminer | Ratio |
|----------|-------------|---------|-------|
| Docker image size | ~500 MB compressed | ~90 MB compressed | 5.5x |
| RAM at idle | 300-500 MB (JVM heap) | ~10 MB (PHP process) | 30-50x |
| RAM under use | 500 MB - 1 GB | ~15 MB | 30-70x |
| Startup time | 15-30 seconds | < 1 second | 15-30x |
| Disk (workspace) | 10-50 MB growing | 0 (stateless) | N/A |
| CPU at idle | Low (JVM idle) | Negligible | -- |

The JVM heap can be constrained via `JAVA_OPTS="-Xmx512M"` to limit memory usage, but setting it below ~256 MB risks OutOfMemoryErrors with multiple open connections.

**Impact on dev-strap**: CloudBeaver is the heaviest optional service in the catalog. For comparison, Grafana uses ~50-100 MB RAM and Prometheus ~30-50 MB. CloudBeaver alone would use more RAM than all other extras combined. On machines with 8 GB RAM running a full dev-strap stack (app + db + nginx + wiremock + redis + mailpit + prometheus + grafana + dozzle), adding CloudBeaver could push total Docker memory to 2-3 GB.

### Supported Database Types

CloudBeaver Community includes JDBC drivers for:
- PostgreSQL (postgres-jdbc)
- MySQL / MariaDB (mariaDB driver)
- SQLite
- SQL Server
- Oracle
- ClickHouse
- Many others

Both PostgreSQL and MariaDB are fully supported out of the box with no additional driver installation. This matches dev-strap's supported database types.

### Features Beyond Adminer

| Feature | CloudBeaver | Adminer |
|---------|-------------|---------|
| SQL editor with autocompletion | Yes (full IDE-level) | Basic textarea |
| ER diagrams | Yes | No |
| Data editor (inline cell editing) | Yes | Yes (basic) |
| Query history | Yes (persistent) | No |
| Multiple simultaneous connections | Yes | One at a time |
| Export data (CSV, JSON, etc.) | Yes | Yes (basic) |
| Metadata browser (schemas, tables, views, indexes) | Yes (tree view) | Yes (list view) |
| User management / access control | Yes | No |
| Saved queries / scripts | Yes | No |
| Query execution plan / EXPLAIN | Yes | Manual |
| Dark theme | Yes | Via plugins |

---

## 2. DBeaver Team Edition

### Overview

DBeaver Team Edition is a collaborative, server-based version of DBeaver designed for team use. It adds role-based access control, shared connections, shared scripts, audit logging, and centralized credential management.

### Docker Image

```
dbeaver/cloudbeaver-te
```

Available on Docker Hub at `hub.docker.com/r/dbeaver/cloudbeaver-te`.

### Licensing

**Team Edition is NOT free.** Pricing:

| Plan | Cost | Notes |
|------|------|-------|
| Trial | Free for 14 days | 1 admin + 3 developers + 3 managers + 3 editors + 3 viewers |
| Subscription | Starting at ~$80/user/year | Annual subscription, scales by user count and role type |
| Full package | ~$1,600/year | Typical small-team pricing |

The license key is required to run the Docker image beyond the 14-day trial. Without a valid license, the container will not start (or will start in a limited/expired state).

### Verdict for dev-strap

**NOT suitable for dev-strap.** dev-strap is an open-source infrastructure generator. Including a paid, license-gated service as a template would be inappropriate:
- Users would hit a license wall after 14 days
- The template would silently break when the trial expires
- No way to automate license provisioning in a dev bootstrap tool

If users want Team Edition, they can add it manually. dev-strap should only template the Community edition (`dbeaver/cloudbeaver`).

---

## 3. Comparison: CloudBeaver vs Adminer

### For dev-strap's Use Case

dev-strap is a bootstrap tool for local development environments. The database UI is a convenience tool -- developers use it to inspect data, run ad-hoc queries, and debug schema issues. It is not a production tool.

| Criterion | Adminer | CloudBeaver | Winner for dev-strap |
|-----------|---------|-------------|---------------------|
| **Startup time** | < 1 second | 15-30 seconds | Adminer |
| **RAM usage** | ~10 MB | 300-500 MB | Adminer |
| **Image size** | ~90 MB | ~500 MB | Adminer |
| **Zero-config** | Yes (`ADMINER_DEFAULT_SERVER=db`) | No (first-run wizard, config files) | Adminer |
| **Stateless** | Yes (nothing to persist) | No (workspace volume needed) | Adminer |
| **PostgreSQL + MariaDB** | Both, auto-detected | Both, pre-configured | Tie |
| **SQL editing experience** | Basic textarea | Full IDE (autocomplete, syntax) | CloudBeaver |
| **ER diagrams** | No | Yes | CloudBeaver |
| **Query history** | No | Yes (persistent) | CloudBeaver |
| **Data export** | Basic | Rich (CSV, JSON, SQL) | CloudBeaver |
| **Learning curve** | None (login page, done) | Moderate (wizard, navigation) | Adminer |
| **Complexity added to stack** | Negligible | Significant (volume, config files, slow health check) | Adminer |
| **`depends_on` in compose** | Just `db` | Just `db` | Tie |
| **Health check reliability** | Immediate (PHP serves instantly) | Needs `start_period` (JVM startup) | Adminer |

### When CloudBeaver Makes Sense

- Teams doing heavy database work (complex queries, schema design)
- Projects where ER diagram visualization is valuable
- Developers who want a DBeaver-like experience without installing desktop DBeaver
- Long-lived dev environments where the one-time setup cost is amortized

### When Adminer Is Better

- Quick inspection of data during development
- Resource-constrained machines (laptops with limited RAM)
- Fast iteration cycles (start/stop dev-strap frequently)
- Projects where the database UI is a rarely-used convenience
- CI/CD environments where startup speed matters

---

## 4. Integration with dev-strap

### service.yml Draft (CloudBeaver)

```yaml
  cloudbeaver:
    image: dbeaver/cloudbeaver:latest
    container_name: ${PROJECT_NAME}-cloudbeaver
    ports:
      - "${CLOUDBEAVER_PORT}:8978"
    environment:
      CLOUDBEAVER_APP_ANONYMOUS_ACCESS_ENABLED: "true"
    volumes:
      - ${PROJECT_NAME}-cloudbeaver-workspace:/opt/cloudbeaver/workspace
    depends_on:
      db:
        condition: service_healthy
    networks:
      - ${PROJECT_NAME}-internal
    healthcheck:
      test: ["CMD-SHELL", "curl -sf http://localhost:8978/status > /dev/null"]
      interval: 15s
      timeout: 5s
      retries: 10
      start_period: 30s
```

### Auto-Connection Challenge

Unlike Adminer, which just needs `ADMINER_DEFAULT_SERVER=db` to pre-fill the server field, CloudBeaver requires a JSON configuration file with the full connection details (host, port, database, user, password, driver). This creates a multi-step integration:

1. The compose generator must produce a `initial-data-sources.conf` file in `.generated/cloudbeaver/` with values from `project.env` substituted in
2. The file must be mounted into the container at `/opt/cloudbeaver/conf/initial-data-sources.conf`
3. An `initial-data.conf` must also be generated to set admin credentials and skip the wizard
4. Anonymous access must be enabled so users do not need to log in

**Generator changes required:**

```bash
# In core/compose/generate.sh, before the extras loop:
if echo "${EXTRAS}" | tr ',' '\n' | grep -q '^cloudbeaver$'; then
    mkdir -p "${OUTPUT_DIR}/cloudbeaver"

    # Determine driver based on DB_TYPE
    case "${DB_TYPE}" in
        postgres)
            CB_PROVIDER="postgresql"
            CB_DRIVER="postgres-jdbc"
            CB_PORT="5432"
            CB_URL_PREFIX="jdbc:postgresql"
            ;;
        mariadb)
            CB_PROVIDER="mysql"
            CB_DRIVER="mariaDB"
            CB_PORT="3306"
            CB_URL_PREFIX="jdbc:mariadb"
            ;;
    esac

    # Generate initial-data-sources.conf
    cat > "${OUTPUT_DIR}/cloudbeaver/initial-data-sources.conf" <<CBEOF
{
    "folders": {},
    "connections": {
        "dev-db": {
            "provider": "${CB_PROVIDER}",
            "driver": "${CB_DRIVER}",
            "name": "Dev Database (${DB_TYPE})",
            "save-password": true,
            "configuration": {
                "host": "db",
                "port": "${CB_PORT}",
                "database": "${DB_NAME}",
                "url": "${CB_URL_PREFIX}://db:${CB_PORT}/${DB_NAME}",
                "type": "dev",
                "auth-model": "native",
                "user": "${DB_USER}",
                "password": "${DB_PASSWORD}"
            }
        }
    }
}
CBEOF

    # Generate initial-data.conf (auto-create admin, skip wizard)
    cat > "${OUTPUT_DIR}/cloudbeaver/initial-data.conf" <<CBEOF
{
    "adminName": "cbadmin",
    "adminPassword": "cbadmin"
}
CBEOF
fi
```

**Additional volume mounts in service.yml:**

```yaml
    volumes:
      - ${PROJECT_NAME}-cloudbeaver-workspace:/opt/cloudbeaver/workspace
      - ${DEVSTACK_DIR}/.generated/cloudbeaver/initial-data-sources.conf:/opt/cloudbeaver/conf/initial-data-sources.conf:ro
      - ${DEVSTACK_DIR}/.generated/cloudbeaver/initial-data.conf:/opt/cloudbeaver/workspace/conf/initial-data.conf:ro
```

**This is significantly more complex than Adminer's integration**, which requires zero generator changes beyond a single `sed` substitution for the port.

### manifest.json Entry Draft

```json
"cloudbeaver": {
  "label": "Database UI (CloudBeaver)",
  "description": "Full-featured web database IDE — SQL editor, ER diagrams, query history",
  "defaults": { "port": 8978 },
  "requires": ["database.*"]
}
```

**Category**: `tooling` (alongside adminer, swagger-ui, devcontainer).

### Compose Generator Changes

New `sed` substitution:

```bash
sed "s|\${CLOUDBEAVER_PORT}|${CLOUDBEAVER_PORT:-8978}|g"
```

Named volume `${PROJECT_NAME}-cloudbeaver-workspace` must be conditionally registered in the `EXTRAS_VOLUMES` accumulator (see `01-new-services.md` Section 7).

### project.env Variables

```env
CLOUDBEAVER_PORT=8978
```

### Requires and Conflicts

- **requires**: `["database.*"]` -- same as Adminer. CloudBeaver is useless without a database.
- **conflicts**: None. CloudBeaver and Adminer can coexist (different ports, different containers). However, offering both simultaneously is redundant for most users.

### Guard for Missing Database

Same pattern as Adminer:

```bash
if [ "${extra}" = "cloudbeaver" ] && [ "${DB_TYPE}" = "none" ]; then
    echo "[compose-gen] WARNING: Skipping 'cloudbeaver' — no database configured"
    continue
fi
```

---

## 5. Alternative: DbGate

During research, DbGate emerged as a notable middle-ground option worth mentioning.

### Overview

DbGate is an open-source (MIT license) cross-platform database manager with both desktop and web editions. The web edition runs in Docker and supports MySQL, PostgreSQL, SQL Server, MongoDB, Redis, and others.

### Docker Image

```
dbgate/dbgate:latest
```

- **Image size**: ~150 MB compressed (Node.js-based, much lighter than CloudBeaver)
- **RAM usage**: ~50-80 MB (comparable to Grafana, far less than CloudBeaver)
- **Startup time**: 3-5 seconds (Node.js, no JVM)
- **Port**: 3000 (configurable)

### Comparison

| Criterion | Adminer | DbGate | CloudBeaver |
|-----------|---------|--------|-------------|
| Image size | ~90 MB | ~150 MB | ~500 MB |
| RAM usage | ~10 MB | ~50-80 MB | 300-500 MB |
| Startup time | < 1s | 3-5s | 15-30s |
| SQL autocomplete | No | Yes | Yes |
| ER diagrams | No | Yes | Yes |
| Query history | No | Yes | Yes |
| Config complexity | Trivial | Low | High |
| License | Apache 2.0 | MIT | Apache 2.0 |

DbGate offers most of CloudBeaver's advanced features at a fraction of the resource cost. However, it is less well-known and has a smaller community than CloudBeaver/DBeaver. It is not part of the current dev-strap research scope but is worth noting for future consideration.

---

## 6. Recommendation

### Default Database UI: Adminer

Adminer should remain the default (and initially the only) database UI template in dev-strap. Reasons:

1. **Resource footprint**: ~10 MB RAM vs ~400 MB. In a dev stack that already runs 6-10 containers, adding 400 MB of overhead for a database browser is disproportionate.

2. **Zero configuration**: `ADMINER_DEFAULT_SERVER=db` and a single port mapping. No config files to generate, no workspace volumes to manage, no first-run wizard to bypass.

3. **Instant startup**: Adminer is ready in under 1 second. CloudBeaver takes 15-30 seconds and needs a `start_period` in the health check. This slows down `devstack.sh start` and makes health-check-dependent services wait longer.

4. **Stateless simplicity**: Adminer has no state to persist, corrupt, or clean up. CloudBeaver's workspace volume accumulates state that can become stale or cause issues after database type changes.

5. **Sufficient for dev use**: Most developers use a database UI to quickly inspect data, verify migrations, and run simple queries. Adminer handles all of these. Developers who need ER diagrams and advanced SQL editing likely already have desktop DBeaver or DataGrip installed.

### Should CloudBeaver Be Offered as an Option?

**Not in the initial implementation.** The integration complexity (generated config files, workspace volume, first-run wizard bypass, slow health checks) adds maintenance burden to the compose generator for a niche use case. The generator would need special-case logic for CloudBeaver that no other extra requires.

**Future consideration**: If there is user demand, CloudBeaver could be added as an alternative database UI under `templates/extras/cloudbeaver/`. The service.yml and generator changes documented in Section 4 provide the implementation blueprint. The key decision would be whether to:
- (a) Offer both Adminer and CloudBeaver as independent extras (users pick one), or
- (b) Add a `DB_UI_TYPE` variable in `project.env` (like `APP_TYPE` and `DB_TYPE`) that selects between them

Option (a) is simpler and consistent with how other extras work. Option (b) adds a new concept to the configuration model for marginal benefit.

### Implementation Priority

| Priority | Service | Rationale |
|----------|---------|-----------|
| **Do now** | Adminer | Trivial to implement, high value, already researched in `01-new-services.md` |
| **Defer** | CloudBeaver | Complex integration, high resource cost, niche demand |
| **Watch** | DbGate | Interesting middle ground, revisit when there is user feedback on database UI needs |

---

## 7. Sources

- [CloudBeaver Community Docker deployment wiki](https://github.com/dbeaver/cloudbeaver/wiki/CloudBeaver-Community-deployment-from-docker-image)
- [CloudBeaver Docker Hub page](https://hub.docker.com/r/dbeaver/cloudbeaver/)
- [CloudBeaver server configuration wiki](https://github.com/dbeaver/cloudbeaver/wiki/Server-configuration)
- [CloudBeaver pre-configured datasources wiki](https://github.com/dbeaver/cloudbeaver/wiki/Configuring-server-datasources)
- [CloudBeaver initial data configuration wiki](https://github.com/dbeaver/cloudbeaver/wiki/Initial-data-configuration)
- [CloudBeaver anonymous access configuration wiki](https://github.com/dbeaver/cloudbeaver/wiki/Anonymous-Access-Configuration)
- [CloudBeaver GitHub repository](https://github.com/dbeaver/cloudbeaver/)
- [DBeaver pricing and license types](https://dbeaver.com/edition/)
- [DBeaver Team Edition licenses](https://dbeaver.com/team-edition-licenses/)
- [CloudBeaver Team Edition Docker Hub](https://hub.docker.com/r/dbeaver/cloudbeaver-te)
- [CloudBeaver Kubernetes deployment with health checks](https://medium.com/totvsdevelopers/setting-up-databases-access-with-cloudbeaver-on-kubernetes-7a811c04f24c)
- [Adminer vs CloudBeaver comparison (SourceForge)](https://sourceforge.net/software/compare/Adminer-vs-CloudBeaver-Enterprise/)
- [Online database clients comparison (DbGate blog)](https://www.dbgate.io/news/2025-01-25-online-database-clients/)
- [CloudBeaver Hacker News discussion](https://news.ycombinator.com/item?id=26769549)
- [DbGate as CloudBeaver alternative](https://www.dbgate.io/alternatives/cloudbeaver/)
- [CloudBeaver Docker Compose examples (Awesome Docker Compose)](https://awesome-docker-compose.com/apps/database-management/cloudbeaver)
- [CloudBeaver command line parameters wiki](https://github.com/dbeaver/cloudbeaver/wiki/Command-line-parameters)
