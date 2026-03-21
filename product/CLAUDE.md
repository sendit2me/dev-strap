Read `docs/AI_BOOTSTRAP.md` before doing any work on this project.

This is a Docker-based development environment, not a library or application framework. The infrastructure is defined by files in `services/` and mock definitions in `mocks/`.

Key rules:
- `services/caddy.yml` and `services/wiremock.yml` are regenerated on every start -- do not edit manually
- All other files in `services/` are source-of-truth -- edit freely
- Mock mapping changes hot-reload via `./devstack.sh reload-mocks`
- New mock domains require `./devstack.sh restart`
- `project.env` is the central configuration -- `${VAR}` in service files resolve from it at Docker Compose runtime
- `domains.txt`, `caddy/Caddyfile`, and `certs/*` are generated -- do not edit manually
