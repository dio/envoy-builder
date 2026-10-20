# Envoy builder

This repository hosts build automation and binary releases. Dataplane owns its
Envoy revision, patches, and selected extensions under `externals/envoy`.

- Keep pinned releases immutable; changed binaries require a new release tag.
- Package owned builds with `scripts/package-owned.py` and verify their receipts.
- Record platform, minimum OS/libc, and actual qualification tests in release notes.
- Do not infer Linux qualification from a macOS build or from cross-compilation.
- Keep private source, credentials, and local paths out of public release assets.
- Use `uv run --no-project python` for Python scripts and tests.
- Before publishing, run packaging tests and inspect the archive and provenance.
