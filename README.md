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
