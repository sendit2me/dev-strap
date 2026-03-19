# DevStack Quickstart

## Prerequisites

- Docker (with Compose v2)
- That's it. No language runtimes, no package managers, no tools on your machine.

## Try the included example (2 minutes)

The devstack ships with a working Node.js example app that calls two mocked external APIs.

```bash
cd devstack/
./devstack.sh start
```

Once running:

| URL | What |
|-----|------|
| http://localhost:8080 | Example app with links to try each mock pattern |
| https://localhost:8443 | Same app over HTTPS |
| http://localhost:8082 | Test results dashboard |

Run the tests:

```bash
./devstack.sh test
```

All 6 tests should pass. View the HTML report at `http://localhost:8082`.

Tear it all down:

```bash
./devstack.sh stop
```

Everything is removed — containers, volumes, generated config, test results. Next `start` is a clean slate.

## Set up your own project

See [PROJECT_SETUP.md](PROJECT_SETUP.md) for the full walkthrough.

## CLI Reference

```bash
./devstack.sh start          # Generate config, build, start all containers
./devstack.sh stop           # Tear down everything (clean slate)
./devstack.sh test           # Run all Playwright tests in container
./devstack.sh test "login"   # Run tests matching a grep filter
./devstack.sh shell          # Shell into the app container
./devstack.sh shell db       # Shell into any container by service name
./devstack.sh status         # Show all containers and their health
./devstack.sh logs           # Tail all container logs
./devstack.sh logs app       # Tail a single service's logs
./devstack.sh mocks          # List all configured mock services and their mappings
./devstack.sh generate       # Regenerate config files without starting (for inspection)
./devstack.sh help           # Show help
```

## Where to go next

| I want to... | Read |
|---------------|------|
| Set up my own project from scratch | [PROJECT_SETUP.md](PROJECT_SETUP.md) |
| Mock an external API | [ADDING_MOCKS.md](ADDING_MOCKS.md) |
| Add a custom service (Redis, Mailpit, etc.) | [ADDING_SERVICES.md](ADDING_SERVICES.md) |
| Write and run tests | [TESTING.md](TESTING.md) |
| Set up VS Code dev containers | [DEVELOPMENT.md](DEVELOPMENT.md) |
| Create a new app template (Rust, Python, etc.) | [CREATING_TEMPLATES.md](CREATING_TEMPLATES.md) |
| Understand how it all works | [ARCHITECTURE.md](ARCHITECTURE.md) |
| Debug something that isn't working | [TROUBLESHOOTING.md](TROUBLESHOOTING.md) |
