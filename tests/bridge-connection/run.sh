#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
out=$(mktemp -d "${TMPDIR:-/tmp}/apk-bridge-connection.XXXXXX")
fixture_pid=''
cleanup() {
    if [ -n "$fixture_pid" ]; then kill "$fixture_pid" 2>/dev/null || true; wait "$fixture_pid" 2>/dev/null || true; fi
    rm -rf "$out"
}
trap cleanup EXIT HUP INT TERM
node "$root/tests/bridge-connection/fixture.mjs" "$out" > "$out/fixture.log" 2>&1 &
fixture_pid=$!
xcrun swiftc -module-cache-path "$out/cache" "$root/src/app/Husk/BuildBridgeModels.swift" \
    "$root/src/app/Husk/BuildBridgeConnection.swift" "$root/tests/bridge-connection/ConnectionTests.swift" -o "$out/tests"
tries=0
while [ ! -f "$out/fixture.json" ]; do
    tries=$((tries + 1))
    if [ "$tries" -gt 50 ] || ! kill -0 "$fixture_pid" 2>/dev/null; then cat "$out/fixture.log"; exit 1; fi
    sleep 0.1
done
"$out/tests" "$out/fixture.json"
