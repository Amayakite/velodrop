#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
out="${1:-.dist}"
mkdir -p "$out"
out="$(cd "$out" && pwd)"

version="$(plutil -extract version raw -o - Extension/manifest.json)"
package="$out/VeloDrop-$version-Chromium.zip"
stage="$(mktemp -d "$out/.chromium.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
mkdir -p "$stage/extension"

git ls-files -z -- Extension | while IFS= read -r -d '' source; do
    target="$stage/extension/${source#Extension/}"
    mkdir -p "$(dirname "$target")"
    cp "$source" "$target"
done

# The storefront supplies the store key. Keep the development key in the
# unpacked build so existing locally loaded extensions retain their ID.
manifest="$stage/extension/manifest.json"
plutil -remove key "$manifest"
plutil -convert json "$manifest"
swift Scripts/render-icon.swift "$stage/assets"
cp "$stage/assets"/Icon*.png "$stage/extension/"

(cd "$stage/extension" && /usr/bin/zip -q -X -r "$stage/extension.zip" .)
mv "$stage/extension.zip" "$package"
printf '%s\n' "$package"
