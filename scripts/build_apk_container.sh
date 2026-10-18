#!/bin/bash
# Build the fork using pinned, unmodified Android runtime binaries from Husk 3.0.
# The app, Android native translation layer and pairing library are built from this checkout.
# For an entirely source-built runtime, see ci_build.sh and docs/BUILD-APK-CONTAINER.md.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
ARCHIVE="$ROOT/build/upstream-release/Husk-3.0.ipa"
EXPECTED=112a1ddbb3143ae25e80c18c5b195b6dfa5067d66cbf99d2188fc03f4ab0f61d
mkdir -p "$(dirname "$ARCHIVE")" build/ios-arm64/lib build/ios-arm64/sysroot/lib
if [ ! -f "$ARCHIVE" ]; then
    curl -fL --retry 2 https://github.com/Leviidev/Husk/releases/download/3.0/Husk.ipa -o "$ARCHIVE.part"
    mv "$ARCHIVE.part" "$ARCHIVE"
fi
ACTUAL="$(shasum -a 256 "$ARCHIVE" | cut -d ' ' -f 1)"
[ "$ACTUAL" = "$EXPECTED" ] || { echo "Runtime archive checksum mismatch" >&2; exit 1; }
EXTRACT="$ROOT/build/upstream-release/extracted"
if [ ! -d "$EXTRACT" ]; then
    mkdir -p "$EXTRACT"
    unzip -q "$ARCHIVE" -d "$EXTRACT"
fi
RUNTIME="$EXTRACT/Payload/Husk.app"
cp "$RUNTIME/Frameworks/libqemu-aarch64-softmmu.dylib" build/ios-arm64/lib/
cp "$RUNTIME/Frameworks/libANGLE-shared.dylib" build/ios-arm64/sysroot/lib/
if [ ! -d build/ios-arm64/lib/MoltenVK.xcframework ]; then
    xcodebuild -create-xcframework -framework "$RUNTIME/Frameworks/MoltenVK.framework" \
        -output "$ROOT/build/ios-arm64/lib/MoltenVK.xcframework"
fi
# Keep Cargo downloads in this checkout's ignored build folder.
export CARGO_HOME="${CARGO_HOME:-$ROOT/build/cargo-home}"
export IPHONEOS_DEPLOYMENT_TARGET=15.5
rustup run "${APK_CONTAINER_RUST_TOOLCHAIN:-stable}" cargo build \
    --manifest-path src/rppairing-ios/Cargo.toml --release --locked --target aarch64-apple-ios
cp src/rppairing-ios/target/aarch64-apple-ios/release/libhusk_rppairing.a build/ios-arm64/lib/
"$ROOT/scripts/prepare_java_tools.sh"
export HUSK_JDK="${HUSK_JDK:-$ROOT/build/tools/jdk-21.0.12.1+1/Contents/Home}"
export HUSK_D8="${HUSK_D8:-$ROOT/build/tools/r8.jar}"
./src/java-framework/build.sh "$ROOT/build/husk-framework.dex"
export APK_CONTAINER_RUNTIME_ASSETS="$RUNTIME"
# The source shader is unchanged from 3.0; this build uses its compiled metallib.
# This also supports Xcode installations without the optional Metal compiler.
export APK_CONTAINER_PREBUILT_SHADERS=YES
./scripts/package_ipa.sh "${1:-$ROOT/build/APKContainer.ipa}"
