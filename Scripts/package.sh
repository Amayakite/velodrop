#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
root="$(pwd)"
engine="$root/.build/engine-$(uname -m)"
out="${1:-$root/.dist}"
app="$out/VeloDrop.app"
identity="${VELODROP_SIGN_IDENTITY:--}"
version="$(plutil -extract version raw -o - "$root/Extension/manifest.json")"
build_number="${VELODROP_BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
dmg="VeloDrop-$version-macos-$(uname -m).dmg"

"$root/Scripts/build-engine.sh"
swift build -c release --disable-sandbox
bin="$(swift build -c release --disable-sandbox --show-bin-path)"
assets="$root/.build/velodrop-assets"
swift Scripts/render-icon.swift "$assets"
iconutil -c icns "$assets/AppIcon.iconset" -o "$assets/AppIcon.icns"

mkdir -p "$out"
tmp="$(mktemp -d "$out/.velodrop.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
volume="$tmp/volume"
mkdir -p "$volume"
# Stage the app outside the disk image. Only the installer is published in
# the volume, so there is no drag target that can hit the in-use error.
staged="$tmp/VeloDrop.app"
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
    <key>CFBundleVersion</key><string>$build_number</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><false/>
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

# The disk image opens with a tiny installer instead of a drag target. It can
# quit a running copy, replace the app bundle, and relaunch in one step, which
# avoids Finder's "VeloDrop is in use" failure during upgrades.
installer="$volume/Install VeloDrop.app"
icontents="$installer/Contents"
iresources="$icontents/Resources"
mkdir -p "$icontents/MacOS" "$iresources/Payload"
cp "$bin/VeloDropInstaller" "$icontents/MacOS/"
cp "$assets/AppIcon.icns" "$iresources/"
cp -R "$staged" "$iresources/Payload/VeloDrop.app"
cat > "$icontents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>com.amayakite.velodrop.installer</string>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleLocalizations</key><array><string>en</string><string>zh-Hans</string></array>
    <key>CFBundleName</key><string>Install VeloDrop</string>
    <key>CFBundleDisplayName</key><string>Install VeloDrop</string>
    <key>CFBundleExecutable</key><string>VeloDropInstaller</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$version</string>
    <key>CFBundleVersion</key><string>$build_number</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
if [[ "$identity" == "-" ]]; then
    codesign --force --deep --sign - "$installer"
else
    codesign --force --deep --options runtime --timestamp --sign "$identity" "$installer"
fi
codesign --verify --deep --strict "$installer"

hdiutil create -volname "Install VeloDrop $version" -fs HFS+ -format UDZO -srcfolder "$volume" "$tmp/$dmg"
hdiutil verify "$tmp/$dmg"
if [[ -e "$app" ]]; then rm -rf "$app"; fi
if [[ -e "$out/Install VeloDrop.app" ]]; then rm -rf "$out/Install VeloDrop.app"; fi
mv "$staged" "$app"
cp -R "$installer" "$out/Install VeloDrop.app"
mv -f "$tmp/$dmg" "$out/$dmg"
printf '%s\n' "$out/$dmg"
