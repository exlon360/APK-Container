#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
out=$(mktemp -d "${TMPDIR:-/tmp}/apk-build-models.XXXXXX")
trap 'rm -rf "$out"' EXIT HUP INT TERM
xcrun swiftc -module-cache-path "$out/cache" "$root/src/app/Husk/BuildBridgeModels.swift" "$root/tests/build-bridge/BuildBridgeModelTests.swift" -o "$out/tests"
"$out/tests"
