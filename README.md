# envoy-builder

On-demand Envoy binary builds via GitHub Actions.

Paste a commit SHA, pick your platforms, get release assets.

## Inputs

| Input | Required | Default | Notes |
|---|---|---|---|
| `envoy_repo` | no | `envoyproxy/envoy` | `owner/repo`, forks work |
| `commit_sha` | **yes** | — | full or short SHA, branch, tag |
| `patch_url` | no | — | raw URL to a `.patch` file applied before build |
| `release_tag` | no | `envoy-{sha8}-{date}` | overrides auto tag |
| `build_macos_arm64` | no | `true` | macOS M-series |
| `build_linux_amd64` | no | `true` | static, `ubuntu-24.04` |
| `build_linux_arm64` | no | `false` | static, `ubuntu-24.04-arm` |

## Usage

### Web UI

Open `web/index.html` -- paste SHA, toggle targets, click **Open in GitHub Actions**.
The page builds the `workflow_dispatch` URL and opens it. No backend.

You can host it on GitHub Pages (repo Settings → Pages → `web/` branch or folder).

### gh CLI

```sh
gh workflow run build-envoy.yml \
  --repo dio/envoy-builder \
  -f commit_sha=a1b2c3d4 \
  -f envoy_repo=envoyproxy/envoy \
  -f build_macos_arm64=true \
  -f build_linux_amd64=true \
  -f build_linux_arm64=false
```

### Remote execution + cache (BuildBuddy)

Envoy's Bazel build is 2-4h cold. BuildBuddy cuts that significantly.

| Platform | Mode | Effect |
|---|---|---|
| Linux (amd64 / arm64) | RBE — actions run on BuildBuddy executors | `--jobs=100` parallel actions; GHA runner is just an orchestrator |
| macOS arm64 | Remote cache only | No macOS executors on BuildBuddy OSS; cache still eliminates redundant rebuilds |

Setup:
1. Sign up at https://app.buildbuddy.io (free OSS tier)
2. Get an **Executor** API key (Settings → API Keys)
3. Add it as a repo secret named `BUILDBUDDY_API_KEY`

The workflow detects the secret and injects `.bazelrc.cache` at build time.
Without it the build falls back to local cache only.

## Applying a patch

Format your patch with `git format-patch` or `git diff`, upload it somewhere
with a stable raw URL (GitHub Gist, pastebin, S3, etc.), then pass that URL
as `patch_url`.

```sh
git diff HEAD~1 > my-fix.patch
# upload to gist, get raw URL
gh workflow run build-envoy.yml \
  --repo dio/envoy-builder \
  -f commit_sha=a1b2c3d4 \
  -f patch_url="https://gist.githubusercontent.com/dio/…/my-fix.patch"
```

## Outputs

Each build target uploads its binary as a release asset:

| Asset name | Platform |
|---|---|
| `envoy-macos-arm64` | macOS arm64 (dynamic, requires local dylibs) |
| `envoy-linux-amd64` | Linux x86-64, statically linked |
| `envoy-linux-arm64` | Linux arm64, statically linked |

The release is created as a draft while builds run, then published on
success. On failure it's published as a prerelease tagged `[FAILED]`.

## Self-hosted Mac runner

For better throughput and zero macOS-runner cost, register a self-hosted
runner on your Apple Silicon Mac:

```sh
# In the repo: Settings → Actions → Runners → New self-hosted runner → macOS arm64
# Follow the download + configure steps, then:
./run.sh
```

Change the `build` job's `macos-15` to `self-hosted` for the mac target.
