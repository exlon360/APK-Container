#!/bin/sh
set -eu
project_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
test_output=$(mktemp -d "${TMPDIR:-/tmp}/apk-container-app-only-test.XXXXXX")
trap 'rm -rf "$test_output"' EXIT HUP INT TERM
xcrun swiftc -module-cache-path "$test_output/module-cache" \
    "$project_root/src/app/Husk/AndroidAppOnlyPolicy.swift" \
    "$project_root/src/app/Husk/AndroidPolicyRestoreJournal.swift" \
    "$project_root/tests/android-app-only/AndroidAppOnlyPolicyTests.swift" \
    -o "$test_output/android-app-only-tests"
"$test_output/android-app-only-tests"
