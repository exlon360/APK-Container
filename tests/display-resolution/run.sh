#!/bin/sh
set -eu
project_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
test_output=$(mktemp -d "${TMPDIR:-/tmp}/apk-container-display-test.XXXXXX")
trap 'rm -rf "$test_output"' EXIT HUP INT TERM
xcrun swiftc -module-cache-path "$test_output/module-cache" \
    "$project_root/src/app/Husk/DisplayResolution.swift" \
    "$project_root/tests/display-resolution/DisplayResolutionTests.swift" \
    -o "$test_output/display-resolution-tests"
"$test_output/display-resolution-tests"
