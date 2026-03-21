# dev-strap Review Prompt

> **For**: An AI agent or reviewer evaluating the complete system.
> **Method**: Multi-pass, do-and-review. Each pass DOES something, then evaluates the result.
> **Attitude**: Don't be nice. Find real problems.

You are reviewing dev-strap -- a meta-tool (factory) that generates self-contained Docker development environments (products). You have no prior knowledge of what changed recently. Evaluate what exists.

Run every pass in order. Each pass builds on context from the previous. Produce a named report section at the end of each pass.

---

## Pass 1: First Contact

**Goal**: Can someone with zero context use this thing?

Read `README.md` only. Do not read AI docs, architecture docs, or source code yet. You are a developer who just found this repo.

### Do

```bash
# 1. Read the README
cat README.md

# 2. Try the help command
./devstack.sh help

# 3. Try to create a project (use a preset if the README mentions one)
./devstack.sh init --preset api-only
# If that fails, try:
./devstack.sh init

# 4. cd into the generated project
cd <project-name>/

# 5. Try the product CLI
./devstack.sh help
./devstack.sh start
./devstack.sh status
./devstack.sh test
./devstack.sh mocks
```

If Docker is unavailable, note it and do static analysis instead: verify the generated files look correct, check that docker-compose.yml parses, check that service files exist.

### Review

For each step above, answer:

- Did it work? If not, what was the error?
- Was the output clear? Did it tell you what to do next?
- Did the README accurately describe what happened?
- Were any commands missing from help that should be there, or listed in help but broken?

If anything confused you, that IS a finding. Document what confused you and why.

**Write as: "First Contact Report"**

---

## Pass 2: Day-2 Operations

**Goal**: Can someone extend and operate a running project?

Using the project from Pass 1 (or bootstrap a fresh one if Pass 1 failed).

### Do

```bash
# Mock management
# 1. Add a new mock (pick any API -- GitHub, Twilio, httpbin, whatever)
./devstack.sh new-mock github api.github.com

# 2. Add a mapping file for the mock
# Create mocks/github/mappings/repos.json with a stub response

# 3. Reload mocks without restarting
./devstack.sh reload-mocks

# 4. Verify mock interception
./devstack.sh verify-mocks

# Service management
# 5. Try stop (should preserve data)
./devstack.sh stop

# 6. Try start again (should be faster, data preserved)
./devstack.sh start

# 7. Try stop --clean (should remove everything)
./devstack.sh stop --clean

# Recording flow
# 8. Try recording from a real API
./devstack.sh record <mock-name>

# 9. Apply the recording
./devstack.sh apply-recording <mock-name>

# Manual service addition
# 10. Try adding a service manually:
#     - Drop a yml file in services/
#     - Add an include line to docker-compose.yml
#     - Restart
```

Read the product documentation:
- `docs/SERVICES.md` -- does it explain how services work?
- `docs/MOCKS.md` -- does it explain how mocks work?
- `docs/TROUBLESHOOTING.md` -- does it cover common problems you hit?

### Review

- Did mock creation, reload, and verification work?
- Did the recording flow work end-to-end?
- Did stop preserve data and stop --clean remove everything?
- Could you add a service manually? Was it obvious how?
- Were the product docs accurate? Did they match what actually happened?
- What was undocumented that should be documented?

**Write as: "Day-2 Report"**

---

## Pass 3: Architecture Deep Dive

**Goal**: Is this thing well-built?

Now read the factory code. You are no longer a user -- you are a code reviewer.

### Do

Read these files in this order. For each, note issues as you go.

**Factory CLI** -- `devstack.sh` (root):
- `cmd_init()` -- Does it read available types from the filesystem or hardcode them?
- `cmd_contract_options()` -- Does it serialize manifest.json correctly?
- `cmd_contract_bootstrap()` -- Does it call validate then generate?
- `validate_bootstrap_payload()` -- Are all validation checks sound? Are edge cases covered?
- `resolve_wiring()` -- Does it produce correct output for all 6 wiring rules?
- `generate_from_bootstrap()` -- Does it produce a self-contained product directory?
- `build_bootstrap_response()` -- Does the response include everything the caller needs?

**Product CLI** -- `product/devstack.sh`:
- Is it truly self-contained? Search for any references back to the factory (core/, templates/, contract/).
- Does `cmd_start()` generate only the dynamic files? (caddy.yml, wiremock.yml, Caddyfile, domains.txt)
- Does `cmd_stop()` preserve volumes by default?
- Does `cmd_stop --clean` actually clean everything?
- Are mock management commands complete and correct?

**Contract manifest** -- `contract/manifest.json`:
- Are all categories, items, defaults, requires, and conflicts internally consistent?
- Do preset selections reference valid items?
- Do presets satisfy their own dependency constraints?
- Are wiring rules well-formed? Do templates reference valid fields?
- Is port allocation collision-free in default configuration?

**Templates** -- `templates/`:
- Does every `service.yml` have a `services:` top-level key?
- Do all templates use literal volume/network names (not `${PROJECT_NAME}-certs`)?
- Do services declaring named volumes include a `volumes:` section?
- Do all app templates have healthchecks?
- Are Dockerfiles well-structured? (layer caching, minimal images, correct base images)
- Are CA certificate handling patterns correct per language?

**Caddyfile generator** -- `core/caddy/generate-caddyfile.sh`:
- Does it handle all routing modes? (PHP FastCGI, frontend+backend, plain reverse proxy)
- Is mock interception correct? (DNS alias, TLS termination, X-Original-Host, WireMock)
- Does it use `handle` (not `handle_path`) for backend routes to preserve API prefixes?
- Is `auto_https off` set globally?

**Trace a full bootstrap end-to-end**:
1. Start with a JSON payload (or `init` selections)
2. Follow it through validation
3. Through wiring resolution
4. Through file generation
5. Into the product directory
6. Verify the product can start from what was generated

### Review

- Architecture quality: Is the factory/product separation clean?
- Code quality: Consistent patterns? Error handling? Edge cases?
- What's fragile? What would break if someone added a 6th backend?
- What's dead code? What's unreachable?
- Show exact file paths and line numbers for every finding.

**Write as: "Architecture Report"**

---

## Pass 4: Contract Validation

**Goal**: Does the PowerHouse contract interface work correctly?

Read `DEVSTRAP-POWERHOUSE-CONTRACT.md` first, then test the interface.

### Do

```bash
# 1. Get options -- validate output structure
./devstack.sh --options

# 2. Valid bootstrap -- minimal
echo '{"contract":"devstrap-bootstrap","version":"1","project":"test-min","selections":{"app":{"go":{}}}}' | ./devstack.sh --bootstrap --config -

# 3. Valid bootstrap -- full stack
echo '{"contract":"devstrap-bootstrap","version":"1","project":"test-full","selections":{"app":{"node-express":{}},"frontend":{"vite":{}},"database":{"postgres":{}},"services":{"redis":{},"nats":{}},"tooling":{"qa","wiremock":{}},"observability":{"prometheus":{},"grafana":{}}}}' | ./devstack.sh --bootstrap --config -

# 4. Preset bootstrap
echo '{"contract":"devstrap-bootstrap","version":"1","project":"test-preset","preset":"api-only","selections":{"app":{"go":{}}}}' | ./devstack.sh --bootstrap --config -

# 5. Invalid: empty project name
echo '{"contract":"devstrap-bootstrap","version":"1","project":"","selections":{"app":{"go":{}}}}' | ./devstack.sh --bootstrap --config -

# 6. Invalid: no app selected
echo '{"contract":"devstrap-bootstrap","version":"1","project":"test-noapp","selections":{"database":{"postgres":{}}}}' | ./devstack.sh --bootstrap --config -

# 7. Invalid: unknown item
echo '{"contract":"devstrap-bootstrap","version":"1","project":"test-bad","selections":{"app":{"django":{}}}}' | ./devstack.sh --bootstrap --config -

# 8. Invalid: conflicting items (two databases)
echo '{"contract":"devstrap-bootstrap","version":"1","project":"test-conflict","selections":{"app":{"go":{}},"database":{"postgres":{},"mariadb":{}}}}' | ./devstack.sh --bootstrap --config -

# 9. Invalid: missing dependency (grafana without prometheus)
echo '{"contract":"devstrap-bootstrap","version":"1","project":"test-dep","selections":{"app":{"go":{}},"observability":{"grafana":{}}}}' | ./devstack.sh --bootstrap --config -

# 10. Port override
echo '{"contract":"devstrap-bootstrap","version":"1","project":"test-ports","selections":{"app":{"go":{"port":4000}},"database":{"postgres":{"port":5433}}}}' | ./devstack.sh --bootstrap --config -
```

For each valid bootstrap, examine the generated directory:
- Does `docker-compose.yml` use `include:` correctly?
- Does `ls services/` match the selections?
- Does `project.env` have correct values?
- Do wiring rules resolve correctly in the response?

### Review

- Does `--options` output match what the contract spec says?
- Do valid payloads produce correct products?
- Do invalid payloads return correct, specific error messages?
- Are edge cases handled? (empty selections, port collisions, circular deps)
- Does the response JSON match the contract spec exactly?
- Is the contract version stable?

**Write as: "Contract Report"**

---

## Pass 5: Documentation Accuracy

**Goal**: Do the docs match the code?

For every documentation file, verify its claims against the actual code. Do not skim -- check each claim.

### Do

**Factory docs** (in `docs/`):
| File | Check against |
|------|--------------|
| `README.md` | Does the catalog listing match `manifest.json`? Do examples work? |
| `docs/AI_BOOTSTRAP.md` | Does the file reading order work? Are pitfalls accurate? Is the source-of-truth table correct? |
| `docs/ARCHITECTURE.md` | Does it describe the current system accurately? |
| `docs/QUICKSTART.md` | Can you follow it start to finish and get a working project? |
| `docs/CREATING_TEMPLATES.md` | Could someone follow it to add a new backend? |
| `docs/ADDING_SERVICES.md` | Could someone follow it to add a new service? |
| `docs/DEVELOPMENT.md` | Are the developer workflows correct? |
| `docs/TESTING.md` | Does it describe the test suite accurately? |
| `DEVSTRAP-POWERHOUSE-CONTRACT.md` | Does the spec match the actual `--options`/`--bootstrap` behavior? |

**Product docs** (in `product/docs/`):
| File | Check against |
|------|--------------|
| `product/docs/AI_BOOTSTRAP.md` | Does it describe the product accurately? |
| `product/docs/SERVICES.md` | Does it match how services actually work? |
| `product/docs/MOCKS.md` | Does it match how mocks actually work? |
| `product/docs/TROUBLESHOOTING.md` | Does it cover real problems? Are solutions correct? |

For each file, produce:
- **Accurate**: claims that match the code
- **Inaccurate**: claims that contradict the code (with file:line references)
- **Missing**: things the doc should cover but does not
- **Stale**: references to things that no longer exist (old names, removed features, wrong paths)

### Review

Score each doc on a 1-10 scale:
- **Accuracy** (do claims match code?)
- **Completeness** (does it cover what it needs to?)
- **Usefulness** (would it actually help someone?)

**Write as: "Documentation Report"**

---

## Pass 6: Final Assessment

**Goal**: Synthesize everything into an actionable summary.

Do not repeat findings from previous passes. Reference them by pass number and finding number.

### Produce

**1. Critical bugs** (must fix -- things that are broken)
List each with: description, location (file:line), how to reproduce, impact.

**2. Important issues** (should fix -- things that are wrong but not broken)
List each with: description, location, impact.

**3. Minor issues** (nice to fix -- quality improvements)
List each with: description, location.

**4. Scores**

| Dimension | Score (1-10) | Justification |
|-----------|-------------|---------------|
| Architecture | | Is the factory/product separation clean? Are concerns properly divided? |
| Code quality | | Consistent patterns? Error handling? Maintainability? |
| Documentation | | Can someone understand and extend the system from docs alone? |
| Test coverage | | Are critical paths tested? What's missing? |
| Contract stability | | Is the PowerHouse interface reliable and well-specified? |
| Developer experience | | Can someone go from clone to working project smoothly? |

**5. Risk assessment**
What could break? What needs attention before this is production-ready?

**6. Recommendation**
What should be done next? Ordered by priority. Be specific -- name files, functions, line numbers.

**Write as: "Final Assessment"**

---

## Rules

These apply to ALL passes:

1. **Show your work.** Every finding must include the exact command you ran, the file path, or the line number. "The docs are wrong" is not a finding. "docs/QUICKSTART.md line 42 says to run `./devstack.sh generate` but that command does not exist in the product CLI" is a finding.

2. **Don't be nice.** If something is bad, say it's bad. If something is confusing, say it's confusing. Sugar-coating wastes everyone's time.

3. **Don't suggest features.** Find bugs, inconsistencies, and documentation gaps. Do not propose new capabilities.

4. **Don't fix anything.** Report only. Do not edit files, create patches, or rewrite code.

5. **Confusion is a finding.** If you had to re-read something three times to understand it, or if you made a wrong assumption because the docs were misleading, document that.

6. **Static analysis is acceptable.** If Docker is unavailable, note it explicitly and do code-level analysis. But always prefer actually running things when possible.

7. **Each pass produces a report.** Name it exactly as specified. The final deliverable is all six reports in order.
