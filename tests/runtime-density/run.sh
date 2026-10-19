#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
test_output=$(mktemp -d "${TMPDIR:-/tmp}/apk-container-density-test.XXXXXX")
trap 'rm -rf "$test_output"' EXIT HUP INT TERM
xcrun swiftc -module-cache-path "$test_output/module-cache" \
    "$root/src/app/Husk/RuntimeDisplayDensity.swift" \
    "$root/tests/runtime-density/RuntimeDisplayDensityTests.swift" \
    -o "$test_output/runtime-density-tests"
"$test_output/runtime-density-tests"
