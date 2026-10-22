#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
node_binary="${APK_CONTAINER_NODE:-$HOME/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/bin/node}"
output_directory="${APK_CONTAINER_MAC_OUTPUT:-$repo_root/build}"
app_path="$output_directory/APK Container Bridge.app"
zip_path="$output_directory/APKContainer-Bridge-preview9.zip"

if [[ ! -x "$node_binary" ]]; then
    echo 'Set APK_CONTAINER_NODE to a standalone Apple Silicon Node.js 24 executable.' >&2
    exit 1
fi
if ! /usr/bin/file "$node_binary" | /usr/bin/grep -q 'arm64'; then
    echo 'The bundled Node.js must support Apple Silicon (arm64).' >&2
    exit 1
fi
# A portable app must not rely on Homebrew or developer-machine dylibs.
if /usr/bin/otool -L "$node_binary" | /usr/bin/tail -n +2 | /usr/bin/awk '{print $1}' | /usr/bin/grep -Ev '^(/usr/lib/|/System/Library/)' >/dev/null; then
    echo 'Node.js links to non-system libraries. Choose the standalone runtime.' >&2
    exit 1
fi
node_version="$("$node_binary" --version)"
if [[ ! "$node_version" =~ ^v24\.[0-9]+\.[0-9]+$ ]]; then
    echo 'This bridge package requires Node.js 24.' >&2
    exit 1
fi

stage="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/apk-container-mac.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
bundle="$stage/APK Container Bridge.app"
resources="$bundle/Contents/Resources"
mkdir -p "$bundle/Contents/MacOS" "$resources/node/bin" "$resources/bridge/scripts" "$resources/skills"
/usr/bin/xcrun swiftc -parse-as-library -target arm64-apple-macos12.0 \
    -module-cache-path "$stage/module-cache" -O \
    "$repo_root/bridge/macos/APKContainerBridgeApp.swift" \
    -o "$bundle/Contents/MacOS/APKContainerBridge"
/usr/bin/ditto "$node_binary" "$resources/node/bin/node"
/usr/bin/ditto "$repo_root/bridge/bridge.mjs" "$resources/bridge/bridge.mjs"
/usr/bin/ditto "$repo_root/bridge/lib" "$resources/bridge/lib"
/usr/bin/ditto "$repo_root/bridge/scripts/install-skill.mjs" "$resources/bridge/scripts/install-skill.mjs"
/usr/bin/ditto "$repo_root/skills/apk" "$resources/skills/apk"
/usr/bin/ditto "$repo_root/LICENSE" "$resources/LICENSE"

# Ship the complete license for the exact Node.js version, including its dependencies.
node_license="${APK_CONTAINER_NODE_LICENSE:-$(dirname "$node_binary")/../LICENSE}"
if [[ -f "$node_license" ]]; then
    /usr/bin/ditto "$node_license" "$resources/node/LICENSE"
else
    /usr/bin/curl --fail --silent --show-error --location --proto '=https' \
        "https://raw.githubusercontent.com/nodejs/node/$node_version/LICENSE" \
        --output "$resources/node/LICENSE"
fi
if [[ ! -s "$resources/node/LICENSE" ]]; then
    echo 'Node.js license is missing.' >&2
    exit 1
fi
cat > "$bundle/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleDisplayName</key><string>APK Container Bridge</string>
  <key>CFBundleExecutable</key><string>APKContainerBridge</string>
  <key>CFBundleIdentifier</key><string>com.apkcontainer.bridge</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>APK Container Bridge</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.1.0</string>
  <key>CFBundleVersion</key><string>9</string>
  <key>LSMinimumSystemVersion</key><string>13.5</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSLocalNetworkUsageDescription</key><string>Connect APK Container on your iPhone or iPad to this Mac to build and download your apps.</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
/usr/bin/plutil -lint "$bundle/Contents/Info.plist"
/usr/bin/codesign --force --sign - "$resources/node/bin/node"
/usr/bin/codesign --force --sign - "$bundle"
/usr/bin/codesign --verify --deep --strict "$bundle"
"$bundle/Contents/MacOS/APKContainerBridge" --smoke-test
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$bundle" "$stage/APKContainer-Bridge-preview9.zip"

# Every replacement has its own verified checkpoint, outside the repository.
"$node_binary" --input-type=module - "$repo_root" "$app_path" "$zip_path" <<'NODE'
import { pathToFileURL } from 'node:url';
import path from 'node:path';
const [root, app, archive] = process.argv.slice(2);
const { checkpointPaths } = await import(pathToFileURL(path.join(root, 'bridge/lib/backup.mjs')));
const checkpoint = checkpointPaths([app, archive], {
  label: 'apk-mac-package', summary: 'Package APK Container Bridge preview 9; preserve previous output artifacts'
});
console.log(`Verified package checkpoint: ${checkpoint}`);
NODE
mkdir -p "$output_directory"
rm -rf "$app_path"
rm -f "$zip_path"
/usr/bin/ditto "$bundle" "$app_path"
/usr/bin/ditto "$stage/APKContainer-Bridge-preview9.zip" "$zip_path"
# Document-provider folders can add Finder metadata after a copy. Clear only
# this newly created output, then validate the actual shipped archive outside
# the provider so that packaging does not depend on its metadata timing.
/usr/bin/xattr -cr "$app_path"
mkdir -p "$stage/archive-verification"
/usr/bin/ditto -x -k "$zip_path" "$stage/archive-verification"
/usr/bin/codesign --verify --deep --strict "$stage/archive-verification/APK Container Bridge.app"
"$stage/archive-verification/APK Container Bridge.app/Contents/MacOS/APKContainerBridge" --smoke-test
/usr/bin/shasum -a 256 "$zip_path"
printf 'App: %s\nArchive: %s\n' "$app_path" "$zip_path"
