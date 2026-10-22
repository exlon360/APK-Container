#!/bin/sh
set -eu
apk_bridge_app="${APK_CONTAINER_BRIDGE_APP:-$HOME/Applications/APK Container Bridge.app}"
if [ ! -d "$apk_bridge_app" ] && [ -d "/Applications/APK Container Bridge.app" ]; then
  apk_bridge_app="/Applications/APK Container Bridge.app"
fi
apk_bridge_resources="$apk_bridge_app/Contents/Resources"
if [ ! -x "$apk_bridge_resources/node/bin/node" ] || [ ! -f "$apk_bridge_resources/bridge/bridge.mjs" ]; then
  echo 'APK Container Bridge is not installed. Install and open the Mac companion first.' >&2
  exit 1
fi
exec "$apk_bridge_resources/node/bin/node" "$apk_bridge_resources/bridge/bridge.mjs" "$@"
