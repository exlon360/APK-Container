# Building APK Container

The practical build route compiles this checkout's app, native Android translation layer, Java framework, and Rust pairing library. It reuses selected runtime binaries and assets from the official Husk **3.0** release. A completed build writes a local, ad-hoc-signed IPA for a sideloader to sign at installation; it does not install anything on an iPhone or iPad.

## Prerequisites

- macOS with Xcode and its iPhoneOS SDK; the project targets arm64 devices with an iOS 15.5 deployment target.
- `xcodegen`, Python 3, and a Rust stable toolchain with the `aarch64-apple-ios` target installed.
- Network access for the pinned upstream release, Java tools, and Cargo dependencies, plus space for the extracted runtime and Xcode build products.

`scripts/prepare_java_tools.sh` downloads a pinned Temurin JDK 21 and R8 into the ignored `build/tools/` directory and verifies their SHA-256 hashes. It does not change the system Java installation. Automatic JDK download currently targets Apple Silicon Macs. To use existing tools, supply `HUSK_JDK` as the JDK home directory and `HUSK_D8` as the R8 JAR path; caller-supplied tools are not checksum-verified by the script.

## Release-assisted build

From the repository root:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
    ./scripts/build_apk_container.sh
```

Or choose an output filename:

```sh
./scripts/build_apk_container.sh "$PWD/build/APKContainer-local.ipa"
```

The default output is **`build/APKContainer.ipa`**. Xcode products and the build log are under `build/DerivedData/`; the log is `build/DerivedData/build.log`. The project retains the internal `Husk` target and executable names, while the installed app is named **APK Container**, its bundle identifier is `com.apkcontainer.app`, and its URL scheme is `apkcontainer://`.

The build script:

1. Downloads [Husk 3.0's official IPA](https://github.com/Leviidev/Husk/releases/tag/3.0) into `build/upstream-release/` and verifies SHA-256 `112a1ddbb3143ae25e80c18c5b195b6dfa5067d66cbf99d2188fc03f4ab0f61d` before extraction.
2. Stages its QEMU, ANGLE, and MoltenVK binaries, Android system and Java dependencies, firmware, disk seeds, and compiled Metal shader library. The precompiled shader supports Xcode installations without the optional Metal compiler.
3. Builds the current Rust pairing crate with its lockfile, prepares local Java tools, and compiles the current Java framework into `build/husk-framework.dex`.
4. Regenerates the Xcode project with `xcodegen`, compiles the app and native translation sources, stages resources, and validates the bundle before packaging it. The rebuilt Java framework replaces the release's framework DEX.

This route uses prebuilt third-party runtime components. A change to QEMU, ANGLE, MoltenVK, or the Metal shader itself needs that component rebuilt from source and staged appropriately. `APK_CONTAINER_RUST_TOOLCHAIN` selects a different installed Rust toolchain; it defaults to `stable`.

## Install and test on a device

After the build succeeds, import the local `.ipa` into a sideloader such as SideStore, AltStore, or Sideloadly and follow its signing flow. A compatible TrollStore installation can use the supported packaging path. Signing may change the bundle's entitlement availability; configure JIT through **Settings → JIT & Sideloading** on the device.

The default bundle identifier provides a separate container from Husk. Keep saves backed up before replacing an existing APK Container installation. This project does not automatically migrate Husk's saves.

Verify on an actual iPhone/iPad:

- Installation and launch, JIT activation, and available memory behavior.
- APK import and launch, portrait/landscape layouts, native resolution, lower presets, and custom limits.
- Touch and keyboard alignment, window resizing, and returning to fullscreen.
- Runtime setup, app launch/exit, and the foreground guard's transition back to the native library. Polling can briefly expose the Android launcher after an app exits.

No device performance improvement or universal APK compatibility is established by the build alone.

GPU RAM snapshots are disabled because their compositor shutdown caused a device-observed Android display-service crash after APK installation. GPU boots use current disk contents. Existing local and shipped snapshots are left intact but rejected by the new versioned hardware identity; incompatible shipped snapshots are no longer downloaded. The first cold boot can take several minutes. Software snapshot support remains; snapshot restore can rewind app data to its saved point.

## Local checks

These regression checks run without a connected device:

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
sh tests/display-resolution/run.sh
sh tests/android-presentation/run.sh
sh tests/runtime-snapshot/run.sh
git diff --check
```

They cover phone and iPad sizes, rotation, legacy presets, custom limits, pixel-density consistency, direct app entry resolution without a HOME app, service restart recovery, cancellation, and runtime snapshot compatibility. Android command responses are mocked; these checks do not exercise UIKit or Android engines. The upstream translation-layer harness remains under `tools/regress/` and requires its own APK fixtures and reference images.

## Building the runtime from source

`scripts/ci_build.sh` remains the broader source-build entry point. It fetches and builds QEMU, graphics dependencies, guest boot assets, and pairing support, then packages the app. It additionally needs the upstream tools such as Meson, Ninja, pkg-config, and `qemu-img`.

That route is not yet self-contained for Android system and Java assets. `scripts/build_android_system.sh` needs an external Lineage disk image and `debugfs`; `scripts/build_java_runtime.sh` needs an extracted Android APEX tree, platform resources, and an HTTP legacy JAR. Its upstream defaults contain developer-specific paths, which must be replaced with real inputs using the script arguments and `HTTP_LEGACY`, `FRAMEWORK_RES`, `HUSK_JDK`, and `HUSK_D8`. Missing assets can leave Flutter without fonts or Java apps unable to start even when native compilation succeeds.

Preserve the upstream attribution, [license](../LICENSE), and third-party notices when distributing builds. Preview IPAs are published in [APK Container releases](https://github.com/exlon360/APK-Container/releases). No automatic sideloading update feed is configured.
