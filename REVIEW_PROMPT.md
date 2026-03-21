# DevStrap Review Prompts

Two review prompts for testing the system. Run them in separate sessions to compare how an AI agent performs with and without the bootstrap document.

---

## Review A: Cold Start (no bootstrap)

Copy everything below this section header into a new session. The agent gets no head start — it must figure out the project from scratch.

---

### Instructions

Clone the repository and work from there:

```bash
git clone https://github.com/sendit2me/dev-strap.git
cd dev-strap
```

**IMPORTANT: Do NOT read `CLAUDE.md` or `docs/AI_BOOTSTRAP.md`. Ignore them completely. Pretend they don't exist. Figure out the project by reading the actual code and human-facing docs.**

### Your task

You are reviewing a development environment bootstrapping tool. I need you to:

#### 1. Understand it (by reading code, not docs about code)

Start with `devstack.sh` and explore from there. Read the generator scripts, templates, contract manifest, product runtime, mock mapping files, and example app. Figure out:

- What does this system actually do?
- How does the HTTPS mock interception work end-to-end?
- What's source-of-truth vs derived? What generates what?
- What's the relationship between the repo and a bootstrapped project?
- What's the developer workflow?

Don't read all the docs/ files first — read code, form your own understanding, then check docs to see if they match.

#### 2. Run it

Try the two main workflows:

**Workflow A: Bootstrap a new project**
```bash
./devstack.sh init
# Follow the prompts, then cd into the created project
cd <your-project>/
./devstack.sh start
```

**Workflow B: Use the example project in the repo**
```bash
./devstack.sh start
```

For whichever you get running:
- Hit every endpoint the example app exposes
- Run the tests: `./devstack.sh test`
- Try every CLI command: `status`, `mocks`, `shell`, `logs`, `help`
- Add a new mock from scratch (pick any API — Twilio, GitHub, whatever)
- Add an endpoint to the example app that calls your new mock
- Write a Playwright test for it
- Run tests again — all should pass

#### 3. Try to break it

- What happens if you add a mock with an empty domains file?
- What happens if two mocks define the same URL path?
- What happens if you run `docker compose stop` instead of `./devstack.sh stop`?
- What happens if port 8080 is already in use?
- Try the `record` command — does the full record → apply-recording → playback flow work?
- Try `init` with `--preset` — does it scaffold a working project?
- Try `init` without preset — does it list all available app types?
- Try `verify-mocks` — is the output useful?
- Try `stop` vs `stop --clean` — is the difference clear?
- Bootstrap a project with frontend (`vite`) — does it produce a working compose file?
- Bootstrap a project with multiple services — does `ls services/` match what you selected?

#### 4. Report

Write a structured report:

- **Understanding summary**: Prove you understand the architecture (3 paragraphs max)
- **What worked**: List what you tested and the results (pass/fail with details)
- **What broke**: Every bug, failure, or confusing behavior (numbered, with severity)
- **Documentation accuracy**: Where do the docs say one thing but the system does another? What's missing? What's misleading?
- **Architecture critique**: What's fragile? What doesn't scale? What's a design mistake?
- **Recommendations**: Ordered by priority — what to fix first, what to fix eventually, what's fine as-is

#### Rules

- Don't be nice. I want real problems found.
- Don't suggest features — find bugs.
- Don't rewrite anything. Report only.
- Show exact commands and output for everything you test.
- If something confuses you, that IS a finding — document what confused you and why.

---
---

## Review B: Bootstrapped (with AI_BOOTSTRAP.md)

Copy everything below this section header into a new session. The agent starts by reading the bootstrap document designed for AI agents.

---

### Instructions

Clone the repository and work from there:

```bash
git clone https://github.com/sendit2me/dev-strap.git
cd dev-strap
```

**Start by reading `docs/AI_BOOTSTRAP.md` in full. Follow its file reading order. This document was written specifically for AI agents working on this codebase.**

Then read `CLAUDE.md` at the project root.

### Your task

You are reviewing a development environment bootstrapping tool. The AI_BOOTSTRAP.md gave you the architecture and pitfalls. Now validate whether that document is accurate, complete, and actually helpful.

#### 1. Validate the bootstrap document's claims

For each section of AI_BOOTSTRAP.md, verify it against the actual code:

- **Source-of-truth vs generated table** — Is every file listed correctly? Are any missing? Does the table reflect the actual project structure?
- **File reading order** — Did reading files in that order give you a complete picture? What was missing?
- **How changes flow** — Test each path. Edit a mapping and reload. Edit app code and verify live reload. Are the documented commands correct?
- **Architecture in 30 seconds** — Is this accurate? Trace a real request through the system to verify.
- **Variable substitution table** — Check every variable against the actual code. Are any variables missing from the table?
- **Pitfalls** — For each pitfall: can you reproduce the problem it warns about? Is the warning accurate? Are there pitfalls it missed?

#### 2. Run the full validation suite

```bash
# Bootstrap a project
./devstack.sh init
cd <your-project>/
./devstack.sh start
./devstack.sh test
./devstack.sh verify-mocks
./devstack.sh mocks
./devstack.sh reload-mocks
```

Then:

- Use `new-mock` to scaffold a mock
- Use `record` to capture from a real API (use httpbin.org — free, no auth)
- Use `apply-recording` to promote the recordings
- Restart and verify playback works
- Write a test for the new mock
- Run all tests

#### 3. Evaluate the bootstrap document's effectiveness

Answer these questions honestly:

1. **Did AI_BOOTSTRAP.md save you time?** Estimate how many tool calls / file reads you avoided because the bootstrap told you where to look.
2. **Was anything in the bootstrap wrong?** Claims that don't match the code.
3. **Was anything missing?** Things you had to discover by reading code that should have been in the bootstrap.
4. **Were the pitfalls useful?** Did any of them save you from a mistake you would have made?
5. **Would you trust this document in a future session?** Or would you re-read the code anyway?

#### 4. Report

Write a structured report with two parts:

**Part 1: System Review** (same as Review A)
- Understanding summary
- What worked / what broke (numbered, with severity)
- Architecture critique
- Recommendations

**Part 2: Bootstrap Document Review**
- Accuracy score (what % of claims are correct?)
- Completeness score (what % of important information is covered?)
- Time saved estimate
- Specific inaccuracies found (with line references)
- Specific gaps found
- Suggested additions or corrections
- Overall verdict: is this document worth maintaining, or is it overhead?

#### Rules

- Don't be nice. I want real problems found — in both the system AND the bootstrap doc.
- Don't fix anything. Report only.
- Show exact commands and output.
- If the bootstrap doc sent you in the wrong direction, that's a critical finding.
- Compare your experience to what a cold-start agent would face — would the bootstrap doc have helped or hurt?
