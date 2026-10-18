#!/bin/bash
# Stage Android resources built from source, or a verified upstream release runtime.
set -euo pipefail
RUNTIME="${APK_CONTAINER_RUNTIME_ASSETS:-}"
if [ -n "$RUNTIME" ]; then
    DEST="$BUILT_PRODUCTS_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH"
    mkdir -p "$DEST"
    for item in vmlinuz-virt initramfs-virt edk2-aarch64-code.fd lineage-efi-vars-seed.fd lineage-vdb-seed.qcow2 pc-bios android-system java-runtime; do
        [ -e "$RUNTIME/$item" ] || { echo "error: missing runtime asset $RUNTIME/$item" >&2; exit 1; }
        ditto "$RUNTIME/$item" "$DEST/$item"
    done
    FRAMEWORK="$SRCROOT/../../build/husk-framework.dex"
    [ -f "$FRAMEWORK" ] || { echo "error: build the current Java framework with src/java-framework/build.sh" >&2; exit 1; }
    cp "$FRAMEWORK" "$DEST/java-runtime/husk-framework.dex"
    if [ "${APK_CONTAINER_PREBUILT_SHADERS:-NO}" = YES ]; then
        [ -f "$RUNTIME/default.metallib" ] || { echo "error: missing prebuilt shaders" >&2; exit 1; }
        cp "$RUNTIME/default.metallib" "$DEST/default.metallib"
    fi
    exit 0
fi

set -e
GUEST="$SRCROOT/../../guests/phase0"
if [ ! -f "$GUEST/vmlinuz-virt" ]; then
  echo "error: guest missing. Run ./scripts/fetch_phase0_guest.sh" >&2
  exit 1
fi
mkdir -p "$BUILT_PRODUCTS_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH"
cp "$GUEST/vmlinuz-virt" "$GUEST/initramfs-virt" \
   "$BUILT_PRODUCTS_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/"

# QEMU loads option ROMs by name from its data directory (-L). The full
# pc-bios tree is 24 MB and almost entirely firmware for architectures
# we will never boot (sparc64, riscv, loongarch, x86, ppc), so ship only
# the network boot ROMs -- 1.6 MB, and the only ones -M virt asks for.
BIOS="$SRCROOT/../../third_party/build/qemu-10.0.12-utm/pc-bios"
DEST="$BUILT_PRODUCTS_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/pc-bios"
mkdir -p "$DEST"
cp "$BIOS"/efi-*.rom "$BIOS"/pxe-*.rom "$DEST/" 2>/dev/null || true

# UEFI firmware for the Phase 1 guest: Debian's cloud image boots through
# GRUB under UEFI, so this is required. It is 64 MiB but almost all zeros,
# so the IPA's own zip squeezes it to about a megabyte -- cheaper than
# carrying a decompressor to unpack it at runtime.
FW="$BUILT_PRODUCTS_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/edk2-aarch64-code.fd"
if [ ! -f "$FW" ]; then
  bunzip2 -c "$BIOS/edk2-aarch64-code.fd.bz2" > "$FW"
fi

# These two qcow2 files are tiny sparse seeds (64 MiB and 16 GiB
# virtual). The app copies them into Documents on first launch; the
# pre-booted snapshot later replaces the userdata seed in place.
QEMU_IMG="$(command -v qemu-img || true)"
if [ -z "$QEMU_IMG" ]; then
  echo "error: qemu-img is required to generate the firmware and userdata seeds" >&2
  exit 1
fi
VARS_SEED="$BUILT_PRODUCTS_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/lineage-efi-vars-seed.fd"
VDB_SEED="$BUILT_PRODUCTS_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/lineage-vdb-seed.qcow2"
rm -f "$VARS_SEED" "$VDB_SEED"
"$QEMU_IMG" create -f qcow2 "$VARS_SEED" 64M
"$QEMU_IMG" create -f qcow2 "$VDB_SEED" 16G

# The parts of Android's /system that apps on the translation layer read directly: CA certificates and the system
# fonts (scripts/build_android_system.sh makes them from the Lineage image). Flutter apps need both.
SYS="$SRCROOT/../../build/android-system"
if [ -d "$SYS/fonts" ]; then
  rsync -a --delete "$SYS/" "$BUILT_PRODUCTS_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/android-system/"
else
  echo "warning: build/android-system missing (scripts/build_android_system.sh): Flutter apps will have no system fonts" >&2
fi

# Husk's Dalvik runtime for Java apps (libGDX games and the like): libcore, ICU and Husk's Java framework
# (scripts/build_java_runtime.sh). ELF libraries and jars, so resources, not code the app links.
JRT="$SRCROOT/../../build/java-runtime"
if [ -f "$JRT/husk-framework.dex" ]; then
  rsync -a --delete "$JRT/" "$BUILT_PRODUCTS_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/java-runtime/"
else
  echo "warning: build/java-runtime missing (scripts/build_java_runtime.sh): Java apps will not start" >&2
fi
