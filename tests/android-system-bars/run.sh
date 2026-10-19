#!/bin/sh
set -eu
project_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
test_output=$(mktemp -d "${TMPDIR:-/tmp}/apk-container-system-bars.XXXXXX")
trap 'rm -rf "$test_output"' EXIT HUP INT TERM
xcrun swiftc -module-cache-path "$test_output/module-cache" \
    "$project_root/src/app/Husk/RuntimeDisplayConfiguration.swift" \
    "$project_root/src/app/Husk/AndroidSystemBars.swift" \
    "$project_root/tests/android-system-bars/AndroidSystemBarsTests.swift" \
    -o "$test_output/android-system-bars-tests"
"$test_output/android-system-bars-tests"
xcrun swiftc -module-cache-path "$test_output/module-cache" \
    "$project_root/src/app/Husk/RuntimeDisplayConfiguration.swift" \
    "$project_root/tests/android-system-bars/MetalCropTests.swift" \
    -o "$test_output/metal-crop-tests"
"$test_output/metal-crop-tests" "$project_root"
xcrun swiftc -module-cache-path "$test_output/module-cache" \
    "$project_root/src/app/Husk/RuntimePresentationSurface.swift" \
    "$project_root/tests/android-system-bars/PresentationSurfaceTests.swift" \
    -o "$test_output/presentation-surface-tests"
"$test_output/presentation-surface-tests"
