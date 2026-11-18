#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
root="$(pwd)"
engine="$root/.build/engine-$(uname -m)"
out="${1:-$root/.dist}"
app="$out/VeloDrop.app"
identity="${VELODROP_SIGN_IDENTITY:--}"
version="$(plutil -extract version raw -o - "$root/Extension/manifest.json")"
dmg="VeloDrop-$version-macos-$(uname -m).dmg"

"$root/Scripts/build-engine.sh"
swift build -c release
bin="$(swift build -c release --show-bin-path)"
assets="$root/.build/velodrop-assets"
swift Scripts/render-icon.swift "$assets"
iconutil -c icns "$assets/AppIcon.iconset" -o "$assets/AppIcon.icns"

mkdir -p "$out"
tmp="$(mktemp -d "$out/.velodrop.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
volume="$tmp/volume"
mkdir -p "$volume"
staged="$volume/VeloDrop.app"
contents="$staged/Contents"
resources="$contents/Resources"
mkdir -p "$contents/MacOS" "$contents/Helpers" "$resources/EdgeExtension" "$resources/Notices"
cp "$bin/VeloDrop" "$contents/MacOS/"
cp "$bin/VeloBridge" "$engine/aria2c" "$contents/Helpers/"
cp "$assets/AppIcon.icns" "$resources/"
cp -R Resources/. "$resources/"
cp -R Extension/. "$resources/EdgeExtension/"
cp "$assets"/Icon*.png "$resources/EdgeExtension/"
cp "$engine/aria2-1.37.0/COPYING" "$resources/Notices/aria2-COPYING.txt"
cp "$engine/aria2-1.37.0/LICENSE.OpenSSL" "$resources/Notices/aria2-LICENSE.OpenSSL.txt"
cp Scripts/build-engine.sh Scripts/aria2-scoped-headers.patch "$resources/Notices/"
cp "$engine/aria2-1.37.0.tar.xz" "$resources/Notices/"
cat > "$contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>com.amayakite.velodrop</string>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleLocalizations</key><array><string>en</string><string>zh-Hans</string></array>
    <key>CFBundleName</key><string>VeloDrop</string>
    <key>CFBundleDisplayName</key><string>VeloDrop</string>
    <key>CFBundleExecutable</key><string>VeloDrop</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$version</string>
    <key>CFBundleVersion</key><string>5</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

flags=(--force --sign "$identity")
if [[ "$identity" != "-" ]]; then flags+=(--options runtime --timestamp); fi
codesign "${flags[@]}" "$contents/Helpers/aria2c"
codesign "${flags[@]}" "$contents/Helpers/VeloBridge"
codesign "${flags[@]}" "$staged"
codesign --verify --deep --strict "$staged"
ln -s /Applications "$volume/Applications"
hdiutil create -volname "VeloDrop $version" -fs HFS+ -format UDZO -srcfolder "$volume" "$tmp/$dmg"
hdiutil verify "$tmp/$dmg"
if [[ -e "$app" ]]; then rm -rf "$app"; fi
mv "$staged" "$app"
mv -f "$tmp/$dmg" "$out/$dmg"
printf '%s\n' "$out/$dmg"
