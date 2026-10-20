# envoy-builder

Nightly Envoy builds for macOS arm64, Linux arm64, and Linux amd64.

Builds run on a Mac mini via [envoy-mini-builder](https://github.com/dio/envoy-mini-builder).
The GitHub Actions workflow SSHes to the mini over Tailscale, runs the Bazel build there,
and publishes the binary as a release asset.

## Releases

Binaries are published to the [releases page](https://github.com/dio/envoy-builder/releases).

Asset naming:

| Platform | Asset |
|----------|-------|
| macOS arm64 | `envoy-darwin-arm64` |
| Linux arm64 | `envoy-linux-arm64` |
| Linux amd64 | `envoy-linux-amd64` |


## macOS deployment-target variants

The Darwin workflow accepts `macos_minimum_os` (for example `15.0`) with a
required separate `release_tag`. It passes explicit Bazel target/host minimum
versions and compiler/linker deployment flags through envoy-mini-builder v0.7.5.
Use the same full source SHA with a tag such as `envoy-<sha8>-macos15`; do not
replace artifacts already pinned by consumers. Check the resulting Mach-O
minimum version and run the binary on the target OS before adopting its hashes.

## Dataplane-owned Envoy

Dataplane owns the upstream revision, ordered patch stack, and build profile in
`externals/envoy`. This repository hosts the resulting binaries. This follows
[the RTDS example](https://github.com/dio/envoy-rtds-runtime-poc): consumers pin a
release archive checksum and use the matching Envoy SDK and ABI.

Dataplane-owned Darwin builds explicitly target macOS 13.0. Packaging compares
the receipt minimum OS against the arm64 Mach-O load command. This checks the
build target; running on a newer Mac does not establish macOS 13 runtime qualification.

Build and qualify the binary in Dataplane first. Then package its build receipt:

```bash
uv run --no-project python scripts/package-owned.py \
  --binary ../dataplane/out/envoy/envoy \
  --receipt ../dataplane/out/envoy/provenance.json \
  --license ../dataplane/.cache/envoy/LICENSE \
  --notice ../dataplane/.cache/envoy/NOTICE \
  --platform darwin-arm64
```

Use the actual Dataplane checkout path. The command prints an immutable release
tag containing the source revision, binary hash, and platform. `dist/` contains
an archive (`envoy`, `provenance.json`, `LICENSE`, and `NOTICE`), its SHA-256 checksum, and the standalone
provenance. No patch source or local checkout is included. Packaging checks the
receipt against the binary; it does not establish runtime qualification.

Release notes must state the host OS baseline and tests actually passed. Publish
only tested platforms; a macOS build does not qualify Linux. Create a new release
for any changed binary, including build flags or patches. Never overwrite assets
that consumers have pinned. The existing nightly workflows remain independent;
their source-only tags do not identify Dataplane's owned patch stack.

Run packaging checks with:

```bash
uv run --no-project python -m unittest discover -s scripts -p 'test_*.py'
```

After writing the qualification notes, create a reviewable draft with
`scripts/release-owned.sh dist/<printed-tag> release-notes.md`. It rechecks the
archive checksum and uploads the three assets without replacing an existing
release. Publishing the draft is a separate action.

## macOS Dataplane proxy test package

For the unsigned development release, use the checksum-verifying standalone
installer. It installs only the binary pair and a launcher under `~/.local`,
without sudo, a compiler, or changes to system Gatekeeper settings:

```sh
curl -fL https://raw.githubusercontent.com/dio/envoy-builder/main/install.sh -o install.sh
# Inspect install.sh before executing it.
bash install.sh
~/.local/bin/dataplane-envoy --version
```

Use `--prefix /absolute/path` to choose another location. The launcher sets
`ENVOY_DYNAMIC_MODULES_SEARCH_PATH` to the matching bundle automatically. Supply
a Dataplane-generated Envoy configuration; the runtime/management launcher and
`dp` CLI are not included. Installation does not start a service.

The `dio/tap/dataplane-proxy` cask also downloads the binary pair, but Homebrew
adds quarantine and macOS blocks these unsigned development artifacts. The
cask is not the recommended path until Developer ID signing/notarization exists.

After running `make qualify-proxy` from a clean, committed Dataplane checkout:

```sh
uv run --no-project python scripts/package-proxy.py \
  --dataplane /path/to/dataplane \
  --qualification /path/to/dataplane/out/qualification/proxy/run-XXXX/result.json \
  --revision <full-tested-commit>
```

The packager checks both binary hashes, the clean source revision, macOS deployment
targets, and successful native serving, REST, and feature-toggle qualification.
Upload its immutable archive, checksum and provenance as a new prerelease, then
update `Casks/dataplane-proxy.rb` in `dio/homebrew-tap`. Never replace an old asset.
Only Apple Silicon macOS is packaged; macOS 13 is the build target, not a claim
that qualification ran on macOS 13. Record the actual test OS in release notes.
