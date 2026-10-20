#!/usr/bin/env bash
# Create a reviewable draft; publication is a separate action.
set -euo pipefail
if [[ $# != 2 ]]; then
  echo 'Usage: scripts/release-owned.sh dist/<release-tag> release-notes.md' >&2
  exit 2
fi
prefix=$1
notes=$2
tag=$(basename "$prefix")
[[ "$tag" == envoy-* ]] || { echo 'Expected an owned Envoy tag' >&2; exit 1; }
[[ -f "$notes" ]] || { echo 'Release notes are required' >&2; exit 1; }
for suffix in tar.gz sha256 provenance.json; do
  [[ -f "$prefix.$suffix" ]] || { echo "Missing $prefix.$suffix" >&2; exit 1; }
done
(cd "$(dirname "$prefix")" && shasum -a 256 -c "$tag.sha256")
# gh release create refuses an existing release; never upload with --clobber.
gh release create "$tag" --repo dio/envoy-builder --draft \
  --title "$tag" --notes-file "$notes" \
  "$prefix.tar.gz" "$prefix.sha256" "$prefix.provenance.json"
