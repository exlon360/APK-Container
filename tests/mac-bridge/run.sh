#!/bin/bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
node_binary="${APK_CONTAINER_NODE:-$HOME/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/bin/node}"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/apk-mac-lifecycle.XXXXXX")"
test_root="$(cd -P "$test_root" && pwd)"
test_passed=false
cleanup() {
  /usr/bin/pkill -f "bridge.mjs start --state-dir $test_root/state$" 2>/dev/null || true
  if [[ "$test_passed" == true ]]; then rm -rf "$test_root"; else printf 'Fixture retained: %s\n' "$test_root"; fi
}
trap cleanup EXIT
bundle="$test_root/APK Bridge Lifecycle Tests.app"
resources="$bundle/Contents/Resources"
mkdir -p "$bundle/Contents/MacOS" "$resources/node/bin" "$resources/skills" "$test_root/home"
cp -c "$node_binary" "$resources/node/bin/node"
ditto "$repo_root/bridge" "$resources/bridge"
ditto "$repo_root/skills/apk" "$resources/skills/apk"
python3 - "$repo_root" "$test_root" <<'PY'
from pathlib import Path
import sys, plistlib, uuid
root, target=map(Path,sys.argv[1:])
source=(root/'bridge/macos/APKContainerBridgeApp.swift').read_text()
a=source.index('@main\nstruct APKContainerBridgeApp')
b=source.index('\nfinal class BridgeAppDelegate',a)
source=source[:a]+source[b:]+'\n'+(root/'tests/mac-bridge/LifecycleTests.swift').read_text()
(target/'Fixture.swift').write_text(source)
p=target/'APK Bridge Lifecycle Tests.app/Contents/Info.plist'
p.write_bytes(plistlib.dumps({'CFBundleIdentifier':'com.apkcontainer.lifecycle.'+uuid.uuid4().hex,'CFBundleExecutable':'Fixture','CFBundleName':'APK Bridge Lifecycle Tests','CFBundlePackageType':'APPL','LSUIElement':True}))
PY
xcrun swiftc -parse-as-library -target arm64-apple-macos12.0 -module-cache-path "$test_root/module-cache" "$test_root/Fixture.swift" -o "$bundle/Contents/MacOS/Fixture"
port=$("$node_binary" --input-type=module - <<'JS'
import net from 'node:net';
const server=net.createServer();server.listen(0,'127.0.0.1',()=>{console.log(server.address().port);server.close()});
JS
)
HOME="$test_root/home" CODEX_HOME="$test_root/home/.codex" "$node_binary" "$repo_root/bridge/bridge.mjs" init \
  --state-dir "$test_root/state" --projects-dir "$test_root/projects" --backup-root "$test_root/checkpoints" \
  --url "https://127.0.0.1:$port" --codex /usr/bin/false >/dev/null
HOME="$test_root/home" CODEX_HOME="$test_root/home/.codex" APK_CONTAINER_BRIDGE_STATE_DIR="$test_root/state" \
 APK_TEST_PROFILE="$test_root/exported-agent.prf" "$bundle/Contents/MacOS/Fixture"

test_passed=true
