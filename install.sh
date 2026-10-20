#!/bin/bash
# Install the pinned, unsigned Dataplane development binary pair for macOS arm64.
set -euo pipefail
release=dataplane-proxy-4df1998da2ae-dcdbfe165202-darwin-arm64
archive_sha=396108784686534fff99089c89b88267023e2457bc364db9bea65c62dbddfa40
envoy_sha=afa15906f5fe6c71ac917b4564fca56b8839a93b9b75fdadee473accccd2c96e
bundle_sha=0b63d0e621b7530547b384b8a99f212f95d9b318cd14e019d6670a2a2f3734a3
prefix=${DATAPLANE_INSTALL_PREFIX:-"$HOME/.local"}
case ${1:-} in
  --prefix) [[ $# == 2 ]] || { echo 'Usage: install.sh [--prefix DIRECTORY]' >&2; exit 2; }; prefix=$2 ;;
  --help|-h) echo 'Usage: install.sh [--prefix DIRECTORY] (default: ~/.local)'; exit 0 ;;
  '') ;;
  *) echo 'Usage: install.sh [--prefix DIRECTORY]' >&2; exit 2 ;;
esac
[[ $(uname -s) == Darwin && $(uname -m) == arm64 ]] || { echo 'Only macOS arm64 is supported' >&2; exit 1; }
[[ $(sw_vers -productVersion | cut -d. -f1) -ge 13 ]] || { echo 'macOS 13 or newer required' >&2; exit 1; }
[[ "$prefix" == /* && "$prefix" != / ]] || { echo 'Use an absolute installation prefix other than /' >&2; exit 1; }
if [[ -e "$prefix/bin/dataplane-envoy" || -L "$prefix/bin/dataplane-envoy" ]]; then
  grep -q '^# Dataplane managed launcher$' "$prefix/bin/dataplane-envoy" || { echo 'Refusing to replace an unrelated dataplane-envoy' >&2; exit 1; }
fi
work=$(mktemp -d "${TMPDIR:-/tmp}/dataplane-install.XXXXXXXX")
trap 'rm -rf "$work"' EXIT
curl --fail --location --proto '=https' --tlsv1.2 --retry 3 \
  "https://github.com/dio/envoy-builder/releases/download/$release/$release.tar.gz" -o "$work/archive.tar.gz"
verify() { [[ $(shasum -a 256 "$1" | awk '{print $1}') == "$2" ]] || { echo "Checksum mismatch: $1" >&2; exit 1; }; }
verify "$work/archive.tar.gz" "$archive_sha"
mkdir "$work/pair"
tar -xzf "$work/archive.tar.gz" -C "$work/pair"
verify "$work/pair/envoy" "$envoy_sha"
verify "$work/pair/libproxy_bundle.so" "$bundle_sha"
base="$prefix/lib/dataplane-proxy"
mkdir -p "$base/releases" "$prefix/bin"
target="$base/releases/$release"
if [[ -e "$target" ]]; then
  verify "$target/envoy" "$envoy_sha"
  verify "$target/libproxy_bundle.so" "$bundle_sha"
else
  mv "$work/pair" "$target"
fi
[[ ! -e "$base/current" || -L "$base/current" ]] || { echo 'Refusing to replace a non-symlink current path' >&2; exit 1; }
ln -sfn "$target" "$base/current"
cat > "$work/launcher" <<'WRAPPER'
#!/bin/bash
# Dataplane managed launcher
set -euo pipefail
prefix=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
export ENVOY_DYNAMIC_MODULES_SEARCH_PATH="${ENVOY_DYNAMIC_MODULES_SEARCH_PATH:-$prefix/lib/dataplane-proxy/current}"
exec "$prefix/lib/dataplane-proxy/current/envoy" "$@"
WRAPPER
chmod 755 "$work/launcher"
mv "$work/launcher" "$prefix/bin/dataplane-envoy"
printf 'Installed %s\nEnvoy: %s/bin/dataplane-envoy\nBundle: %s/current/libproxy_bundle.so\n' "$release" "$prefix" "$base"
echo 'Unsigned development binaries; no system Gatekeeper settings were changed.'
echo 'Supply a Dataplane-generated Envoy configuration. The dp CLI is not included.'
"$prefix/bin/dataplane-envoy" --version
