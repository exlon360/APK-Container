#!/bin/sh
set -eu
project_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
test_output=$(mktemp -d "${TMPDIR:-/tmp}/apk-repositories.XXXXXX")
trap 'rm -rf "$test_output"' EXIT HUP INT TERM
xcrun swiftc -module-cache-path "$test_output/module-cache" \
  "$project_root/src/app/Husk/RepositoryCatalog.swift" \
  "$project_root/src/app/Husk/RepositoryArtifact.swift" \
  "$project_root/src/app/Husk/RepositoryTransfer.swift" \
  "$project_root/src/app/Husk/AppSource.swift" \
  "$project_root/tests/repositories/RepositoryTestStubs.swift" \
  "$project_root/tests/repositories/RepositoryTests.swift" \
  -o "$test_output/repository-tests"
"$test_output/repository-tests" "$project_root" "$@"
