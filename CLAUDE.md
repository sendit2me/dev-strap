Read `docs/AI_BOOTSTRAP.md` before doing any work on this codebase.

This is a meta-tool (infrastructure generator), not an application.
Key distinction: templates in `templates/` are inputs, product files in `product/` ship to users.

The system has two parts:
- Factory (this repo): presents catalog, assembles projects
- Product (what users get): self-contained Docker environment

Do NOT edit product files to test factory changes -- bootstrap a test project instead.
