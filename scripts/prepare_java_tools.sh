#!/bin/bash
# Local, pinned Java build tools. Never modifies the system Java installation.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TOOLS="$ROOT/build/tools"
mkdir -p "$TOOLS"
fetch() {
    local url="$1" output="$2" expected="$3"
    if [ ! -f "$output" ]; then
        curl -fL --retry 2 "$url" -o "$output.part"
        mv "$output.part" "$output"
    fi
    local actual
    actual="$(shasum -a 256 "$output" | cut -d ' ' -f 1)"
    [ "$actual" = "$expected" ] || { echo "Checksum mismatch: $output" >&2; exit 1; }
}
if [ -z "${HUSK_JDK:-}" ]; then
    [ "$(uname -m)" = arm64 ] || { echo "Set HUSK_JDK to a JDK 21 installation on this host." >&2; exit 1; }
    fetch 'https://github.com/adoptium/temurin21-binaries/releases/download/jdk-21.0.12.1%2B1/OpenJDK21U-jdk_aarch64_mac_hotspot_21.0.12.1_1.tar.gz' \
        "$TOOLS/jdk.tar.gz" 3623232f33a9c3baadf304480b2535f9a3cba8a58d42ecbb438ba267315d9998
    if [ ! -d "$TOOLS/jdk-21.0.12.1+1" ]; then
        tar -xzf "$TOOLS/jdk.tar.gz" -C "$TOOLS"
    fi
fi
if [ -z "${HUSK_D8:-}" ]; then
    fetch https://dl.google.com/dl/android/maven2/com/android/tools/r8/9.5.26/r8-9.5.26.jar \
        "$TOOLS/r8.jar" 3502f087388ce95bbf5254555927f09385dc2636873964d0bd53f3eaf4fb49ad
fi
