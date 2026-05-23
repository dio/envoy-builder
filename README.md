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

## Trigger a build manually

Go to Actions → Build Envoy → Run workflow.

Inputs:

| Input | Default | Description |
|-------|---------|-------------|
| `sha` | `main` | Commit SHA, branch, or tag |
| `repo` | `envoyproxy/envoy` | Source repo (forks work) |
| `patch_url` | | Raw URL to a `.patch` file applied before build |
| `platforms` | `all` | `all`, `darwin-arm64`, `linux-arm64`, `linux-amd64` |
