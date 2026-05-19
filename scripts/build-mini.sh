#!/usr/bin/env bash
# build-mini.sh — build Envoy on dio@mini and publish a GitHub release.
#
# Usage:
#   ./scripts/build-mini.sh --sha <commit> [options]
#
# Options:
#   --repo   <owner/repo>     Source repo (default: envoyproxy/envoy)
#   --sha    <ref>            Commit SHA, branch, or tag (required)
#   --patch  <url>            Raw URL to a .patch file applied before build
#   --tag    <release-tag>    Override release tag (default: envoy-{sha8}-{date})
#   --no-release              Build only, skip release creation and upload
#   --out    <dir>            Local dir to save binaries (default: ./dist)
#   --mini   <host>           SSH host (default: dio@mini)
#   --jobs   <n>              Bazel --jobs (default: HOST_CPUS)
#
# Requires on local machine: gh (authenticated), ssh, scp, curl
# Bootstraps on mini:        bazelisk (via brew), build dependencies
#
# BuildBuddy remote cache:
#   Set BUILDBUDDY_API_KEY in your shell environment. The script forwards it
#   to mini over SSH so the binary never touches disk in plaintext beyond the
#   ssh session.

set -euo pipefail

# ── defaults ───────────────────────────────────────────────────────────────────
ENVOY_REPO="envoyproxy/envoy"
COMMIT_SHA=""
PATCH_URL=""
RELEASE_TAG=""
NO_RELEASE=false
OUT_DIR="./dist"
MINI_HOST="dio@mini"
BAZEL_JOBS="HOST_CPUS"
GH_REPO="dio/envoy-builder"
ARTIFACT_NAME="envoy-macos-arm64"

# ── colors ─────────────────────────────────────────────────────────────────────
BOLD=$'\e[1m'; DIM=$'\e[2m'; GREEN=$'\e[32m'; YELLOW=$'\e[33m'; RED=$'\e[31m'; CYAN=$'\e[36m'; RESET=$'\e[0m'

info()  { echo "${CYAN}▶${RESET} $*"; }
ok()    { echo "${GREEN}✓${RESET} $*"; }
warn()  { echo "${YELLOW}!${RESET} $*"; }
die()   { echo "${RED}✗${RESET} $*" >&2; exit 1; }
header(){ echo; echo "${BOLD}── $* ──${RESET}"; }

# ── arg parsing ────────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)        ENVOY_REPO="$2";  shift 2 ;;
    --sha)         COMMIT_SHA="$2";  shift 2 ;;
    --patch)       PATCH_URL="$2";   shift 2 ;;
    --tag)         RELEASE_TAG="$2"; shift 2 ;;
    --no-release)  NO_RELEASE=true;  shift   ;;
    --out)         OUT_DIR="$2";     shift 2 ;;
    --mini)        MINI_HOST="$2";   shift 2 ;;
    --jobs)        BAZEL_JOBS="$2";  shift 2 ;;
    -h|--help)
      sed -n '3,28p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) die "Unknown argument: $1 (try --help)" ;;
  esac
done

[[ -n "$COMMIT_SHA" ]] || die "--sha is required"

# ── derived values ─────────────────────────────────────────────────────────────
SHORT_SHA="${COMMIT_SHA:0:8}"
TODAY="$(date -u +%Y%m%d)"
[[ -n "$RELEASE_TAG" ]] || RELEASE_TAG="envoy-${SHORT_SHA}-${TODAY}"
WORK_DIR="\$HOME/envoy-builder/$(echo "$ENVOY_REPO" | tr '/' '_')"
mkdir -p "$OUT_DIR"
LOCAL_BINARY="${OUT_DIR}/${ARTIFACT_NAME}"

header "envoy-builder: mini build"
info "repo:     $ENVOY_REPO"
info "sha:      $COMMIT_SHA"
info "patch:    ${PATCH_URL:-—}"
info "tag:      $RELEASE_TAG"
info "host:     $MINI_HOST"
info "release:  $([[ $NO_RELEASE == true ]] && echo "disabled" || echo "$GH_REPO")"

# ── local prerequisites ────────────────────────────────────────────────────────
header "Local checks"
for cmd in gh ssh scp; do
  command -v "$cmd" &>/dev/null || die "$cmd not found in PATH"
done
ok "gh, ssh, scp present"

ssh -o BatchMode=yes -o ConnectTimeout=5 "$MINI_HOST" true 2>/dev/null \
  || die "Cannot SSH to $MINI_HOST (check key auth)"
ok "SSH to $MINI_HOST reachable"

# ── bootstrap mini ─────────────────────────────────────────────────────────────
header "Bootstrap mini"
ssh "$MINI_HOST" 'bash -s' << 'BOOTSTRAP'
set -euo pipefail
BREW=/opt/homebrew/bin/brew
PATH="/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:$PATH"
export PATH

echo "→ brew: $(${BREW} --version 2>&1 | head -1)"

# bazelisk
if ! command -v bazel &>/dev/null && ! command -v bazelisk &>/dev/null; then
  echo "→ installing bazelisk..."
  ${BREW} install bazelisk
fi
echo "→ bazel: $(bazel version 2>&1 | grep 'Bazelisk version' || bazel version 2>&1 | head -2)"

# build deps
for pkg in automake libtool cmake ninja; do
  command -v "$pkg" &>/dev/null || ${BREW} install "$pkg"
done
echo "→ build deps: ok"

# java (needed by Bazel's Starlark analysis)
if ! command -v java &>/dev/null; then
  echo "→ installing temurin jdk..."
  ${BREW} install --cask temurin
fi
echo "→ java: $(java -version 2>&1 | head -1)"
BOOTSTRAP

ok "Mini bootstrap complete"

# ── create draft release ───────────────────────────────────────────────────────
RELEASE_ID=""
if [[ $NO_RELEASE == false ]]; then
  header "Create draft release"
  RELEASE_BODY="## Envoy build

| Field  | Value |
|--------|-------|
| Source | \`${ENVOY_REPO}\` |
| Commit | \`${COMMIT_SHA}\` |
| Target | macos-arm64 (mini) |
| Patch  | ${PATCH_URL:-—} |
| Built  | $(date -u +%Y-%m-%dT%H:%M:%SZ) |"

  RELEASE_ID=$(gh api \
    --method POST \
    -H "Accept: application/vnd.github+json" \
    "/repos/${GH_REPO}/releases" \
    -f tag_name="$RELEASE_TAG" \
    -f name="$RELEASE_TAG" \
    -f body="$RELEASE_BODY" \
    -F draft=true \
    --jq '.id')
  ok "Draft release created: $RELEASE_TAG (id=$RELEASE_ID)"
fi

# ── remote build ───────────────────────────────────────────────────────────────
header "Remote build on $MINI_HOST"
info "Streaming build log..."

# We pass secrets as env vars over the SSH command line -- they're in the
# process environment, not written to disk or shell history on mini.
REMOTE_ENV="ENVOY_REPO=${ENVOY_REPO} COMMIT_SHA=${COMMIT_SHA} PATCH_URL=${PATCH_URL:-} WORK_DIR=${WORK_DIR} BAZEL_JOBS=${BAZEL_JOBS}"
if [[ -n "${BUILDBUDDY_API_KEY:-}" ]]; then
  REMOTE_ENV="${REMOTE_ENV} BUILDBUDDY_API_KEY=${BUILDBUDDY_API_KEY}"
fi

REMOTE_BINARY_PATH=""
REMOTE_BINARY_PATH=$(ssh "$MINI_HOST" "env ${REMOTE_ENV} bash -s" << 'REMOTE'
set -euo pipefail
PATH="/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:$PATH"
export PATH

echo "→ host: $(hostname), $(uname -m), macOS $(sw_vers -productVersion)"
echo "→ bazel: $(bazel version 2>&1 | grep 'Bazelisk version\|Build label' | head -1)"

# ── workspace ──────────────────────────────────────────────────────────────────
mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

CLONE_URL="https://github.com/${ENVOY_REPO}.git"

if [[ -d src/.git ]]; then
  echo "→ updating existing clone..."
  cd src
  git remote set-url origin "$CLONE_URL"
  git fetch --depth=1 origin "${COMMIT_SHA}" 2>&1 | tail -3
  git checkout FETCH_HEAD
  git clean -fdx --exclude=.cache 2>/dev/null || true
else
  echo "→ cloning ${ENVOY_REPO} at ${COMMIT_SHA}..."
  git clone --depth=1 --no-checkout "$CLONE_URL" src
  cd src
  git fetch --depth=1 origin "${COMMIT_SHA}" 2>&1 | tail -3
  git checkout FETCH_HEAD
fi

echo "→ at $(git rev-parse HEAD)"

# ── patch ─────────────────────────────────────────────────────────────────────
if [[ -n "$PATCH_URL" ]]; then
  echo "→ fetching patch: $PATCH_URL"
  curl -fsSL "$PATCH_URL" -o /tmp/incoming.patch
  echo "  $(wc -l < /tmp/incoming.patch) lines"
  git apply --stat /tmp/incoming.patch
  git apply /tmp/incoming.patch
  echo "→ patch applied"
fi

# ── BuildBuddy (cache only on macOS) ──────────────────────────────────────────
rm -f .bazelrc.cache
if [[ -n "${BUILDBUDDY_API_KEY:-}" ]]; then
  cat >> .bazelrc.cache << EOF
build --remote_cache=grpcs://remote.buildbuddy.io
build --remote_header=x-buildbuddy-api-key=${BUILDBUDDY_API_KEY}
build --remote_upload_local_results
build --remote_timeout=3600
EOF
  echo "try-import %workspace%/.bazelrc.cache" >> .bazelrc
  echo "→ BuildBuddy remote cache enabled"
else
  echo "→ no BUILDBUDDY_API_KEY, using local cache only"
fi

# ── build ──────────────────────────────────────────────────────────────────────
echo "→ bazel build starting (--jobs=${BAZEL_JOBS})..."
bazel build \
  --config=release \
  --//:contrib_enabled=false \
  --jobs="${BAZEL_JOBS}" \
  --show_progress_rate_limit=15 \
  //source/exe:envoy

# ── locate binary ─────────────────────────────────────────────────────────────
BINARY=$(bazel cquery --config=release --output=files //source/exe:envoy 2>/dev/null | head -1)
if [[ -z "$BINARY" ]]; then
  BINARY=$(find bazel-bin/source/exe/ -maxdepth 1 -type f -executable 2>/dev/null | head -1)
fi
[[ -f "$BINARY" ]] || { echo "ERROR: could not find built binary"; exit 1; }

echo "→ binary: $BINARY ($(du -sh "$BINARY" | cut -f1))"
echo "BINARY_PATH:${WORK_DIR}/src/${BINARY}"
REMOTE
)

# Extract the binary path marker from the remote output
REMOTE_BIN=$(echo "$REMOTE_BINARY_PATH" | grep '^BINARY_PATH:' | cut -d: -f2-)
[[ -n "$REMOTE_BIN" ]] || die "Build failed or binary path not found in output"
ok "Build succeeded: $REMOTE_BIN"

# ── scp binary ────────────────────────────────────────────────────────────────
header "Fetch binary"
info "scp ${MINI_HOST}:${REMOTE_BIN} -> ${LOCAL_BINARY}"
scp "${MINI_HOST}:${REMOTE_BIN}" "${LOCAL_BINARY}"
ok "Binary saved: ${LOCAL_BINARY} ($(du -sh "$LOCAL_BINARY" | cut -f1))"

# ── upload and publish ────────────────────────────────────────────────────────
if [[ $NO_RELEASE == false && -n "$RELEASE_ID" ]]; then
  header "Publish release"
  info "Uploading $ARTIFACT_NAME to release $RELEASE_ID..."
  gh api \
    --method POST \
    -H "Accept: application/vnd.github+json" \
    -H "Content-Type: application/octet-stream" \
    "https://uploads.github.com/repos/${GH_REPO}/releases/${RELEASE_ID}/assets?name=${ARTIFACT_NAME}" \
    --input "$LOCAL_BINARY"
  ok "Asset uploaded"

  gh api \
    --method PATCH \
    -H "Accept: application/vnd.github+json" \
    "/repos/${GH_REPO}/releases/${RELEASE_ID}" \
    -F draft=false > /dev/null
  ok "Release published: https://github.com/${GH_REPO}/releases/tag/${RELEASE_TAG}"
fi

header "Done"
ok "${LOCAL_BINARY}"
[[ $NO_RELEASE == false ]] && ok "https://github.com/${GH_REPO}/releases/tag/${RELEASE_TAG}"
