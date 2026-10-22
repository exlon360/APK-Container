#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
out=$(mktemp -d "${TMPDIR:-/tmp}/apk-jit-startup.XXXXXX")
trap 'rm -rf "$out"' EXIT HUP INT TERM
# Compile a snapshot: production files can be inspected while a release builds.
# Only platform access and fixture isolation are adapted; coordinator logic is unchanged.
python3 - "$root" "$out" <<'PY'
import pathlib, sys
root, out = map(pathlib.Path, sys.argv[1:])
source = (root / 'src/app/Husk/JITSetup.swift').read_text()
replacements = {
    'import UIKit\n': '',
    'UserDefaults.standard': 'Fixture.defaults',
    'FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]': 'Fixture.directory',
    '    private init() {': '    init() {',
}
for old, new in replacements.items():
    assert old in source, 'JITSetup fixture seam changed: ' + old
    source = source.replace(old, new)
assert 'UserDefaults.standard' not in source
assert 'for: .documentDirectory' not in source
(out / 'JITSetup.swift').write_text(source)
(out / 'JITStartupPolicy.swift').write_bytes((root / 'src/app/Husk/JITStartupPolicy.swift').read_bytes())
bootstrap = (root / 'src/app/Husk/JITBootstrap.swift').read_text()
for old, new in {
    'import UIKit\n': '',
    'UserDefaults.standard': 'BootstrapFixture.defaults',
    '@_silgen_name("csops")': '@_silgen_name("fixture_csops")',
}.items():
    assert old in bootstrap, 'JITBootstrap fixture seam changed: ' + old
    bootstrap = bootstrap.replace(old, new)
(out / 'JITBootstrap.swift').write_text(bootstrap)
content = (root / 'src/app/Husk/ContentView.swift').read_text()
recovery = content[content.index('enum AutoStart {'):]
for old, new in {
    'FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]': 'RecoveryFixture.directory',
    'DispatchQueue.main.asyncAfter': 'RecoveryFixture.enqueue',
}.items():
    assert old in recovery, 'AutoStart fixture seam changed: ' + old
    recovery = recovery.replace(old, new)
assert 'for: .documentDirectory' not in recovery
(out / 'AutoStart.swift').write_text('import Foundation\n' + recovery)
PY
xcrun swiftc -module-cache-path "$out/cache" "$out/JITStartupPolicy.swift" "$out/JITSetup.swift" \
    "$root/tests/jit-startup/Fixture.swift" "$root/tests/jit-startup/StartupTests.swift" -o "$out/tests"
"$out/tests" "$out/data"
xcrun swiftc -module-cache-path "$out/cache" "$out/JITStartupPolicy.swift" "$out/JITBootstrap.swift" \
    "$root/tests/jit-startup/BootstrapTests.swift" -o "$out/bootstrap-tests"
"$out/bootstrap-tests"
xcrun swiftc -module-cache-path "$out/cache" "$out/AutoStart.swift" \
    "$root/tests/jit-startup/AutoStartTests.swift" -o "$out/recovery-tests"
"$out/recovery-tests" "$out/recovery"
