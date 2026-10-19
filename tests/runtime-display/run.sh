#!/bin/sh
set -eu
project_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
test_output=$(mktemp -d "${TMPDIR:-/tmp}/apk-container-runtime-display.XXXXXX")
trap 'rm -rf "$test_output"' EXIT HUP INT TERM
xcrun swiftc -module-cache-path "$test_output/module-cache" \
    "$project_root/src/app/Husk/RuntimeDisplayConfiguration.swift" \
    "$project_root/tests/runtime-display/RuntimeDisplayTests.swift" \
    -o "$test_output/runtime-display-tests"
"$test_output/runtime-display-tests"
