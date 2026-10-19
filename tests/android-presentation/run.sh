#!/bin/sh
set -eu
project_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
test_output=$(mktemp -d "${TMPDIR:-/tmp}/apk-container-presentation-test.XXXXXX")
trap 'rm -rf "$test_output"' EXIT HUP INT TERM
xcrun swiftc -module-cache-path "$test_output/module-cache" \
    "$project_root/src/app/Husk/AndroidPolicyEpochGuard.swift" \
    "$project_root/src/app/Husk/AndroidAppPresentation.swift" \
    "$project_root/tests/android-presentation/AndroidAppPresentationTests.swift" \
    -o "$test_output/android-presentation-tests"
"$test_output/android-presentation-tests"
