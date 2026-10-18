#!/usr/bin/env python3
"""Verify the installable fork's identity, Android assets, JIT and memory signature."""
import hashlib
import plistlib
import subprocess
import sys
import tempfile
import zipfile
from pathlib import Path

package = Path(sys.argv[1]).resolve()
with zipfile.ZipFile(package) as archive:
    names = archive.namelist()
    app_plists = [n for n in names if n.startswith("Payload/") and n.count("/") == 2 and n.endswith(".app/Info.plist")]
    assert len(app_plists) == 1, "Expected exactly one app"
    prefix = app_plists[0].removesuffix("Info.plist")
    info = plistlib.loads(archive.read(app_plists[0]))
    assert info["CFBundleDisplayName"] == "APK Container"
    assert info["CFBundleIdentifier"] == "com.apkcontainer.app"
    assert info["UIDeviceFamily"] == [1, 2], "Must support iPhone and iPad"
    assert info["CFBundleURLTypes"][0]["CFBundleURLSchemes"] == ["apkcontainer"]
    assert not any("ps4" in n.lower() for n in names), "PS4 payload remains"
    assert all(d["CFBundleTypeName"] != "PS4 Package" for d in info.get("CFBundleDocumentTypes", []))
    required = ["Frameworks/libqemu-aarch64-softmmu.dylib", "Frameworks/libANGLE-shared.dylib",
                "Frameworks/MoltenVK.framework/MoltenVK", "Frameworks/StikJIT.framework/StikJIT",
                "Frameworks/libFilePickerFix.dylib", "PlugIns/HuskJITHelper.appex/HuskJITHelper",
                "husk-jit.js", "java-runtime/husk-framework.dex", "default.metallib"]
    for item in required:
        assert prefix + item in names, f"Missing {item}"
    helper = plistlib.loads(archive.read(prefix + "PlugIns/HuskJITHelper.appex/Info.plist"))
    assert helper["CFBundleIdentifier"] == info["CFBundleIdentifier"] + ".JITHelper"
    expected_dex = Path(__file__).resolve().parents[1] / "build/husk-framework.dex"
    if expected_dex.exists():
        assert archive.read(prefix + "java-runtime/husk-framework.dex") == expected_dex.read_bytes(), "Java framework is stale"
    with tempfile.TemporaryDirectory(prefix="apk-container-signature-") as temp:
        executable = Path(temp) / info["CFBundleExecutable"]
        executable.write_bytes(archive.read(prefix + info["CFBundleExecutable"]))
        result = subprocess.run(["codesign", "-d", "--entitlements", "-", "--xml", str(executable)], capture_output=True, check=True)
        entitlements = plistlib.loads(result.stdout)
        keys = ["get-task-allow", "com.apple.developer.kernel.increased-memory-limit",
                "com.apple.developer.kernel.extended-virtual-addressing"]
        if package.suffix != ".tipa" and "--trollstore" not in sys.argv[2:]:
            keys.append("dynamic-codesigning")
        for key in keys:
            assert entitlements.get(key) is True, f"Missing entitlement: {key}"

print("Package verified: APK Container, iPhone+iPad, Android runtimes, current Java framework, JIT and extended memory; no PS4.")
print("SHA-256:", hashlib.sha256(package.read_bytes()).hexdigest())
