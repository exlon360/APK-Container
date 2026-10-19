# APK Container

APK Container is an Android-app-focused fork of [Husk by Leviidev and contributors](https://github.com/Leviidev/Husk) for iPhone and iPad. It replaces the console-style home with a native **Apps** library and grouped **Settings**, with a layout inspired by LiveContainer.

## What changes

- Import APKs and supported split bundles, open apps from the library, and manage their individual settings.
- Native iPhone/iPad resolution is the default for the translation layer. Choose performance presets or a custom 320–4096 pixel longest-edge limit; the other edge follows the display's proportions.
- Apps can open fullscreen or in a movable window. Fixed-size rendering surfaces keep their aspect ratio when resized.
- PS4 library, launch screens, native host code, and build steps are removed.
- Husk's Android translation engines, ANGLE/MoltenVK rendering, JIT methods, increased-memory-limit entitlement, and extended virtual addressing support are retained.

Supported apps use the native Android translation layer. Apps that need the full Android environment can use the QEMU compatibility runtime, configured under **Settings → Compatibility Runtime**. Its low-resolution display remains the default; device-shaped resolution presets are available separately.

APK Container starts each APK’s own entry activity directly; no Android home launcher or launcher icon cache is required. It checks the foreground app before showing the runtime surface, and waits for Android services to recover if they restart. The compatibility image still contains its original home app, but desktop navigation is removed. The foreground check polls Android, so a brief desktop frame after an app exits remains possible.

GPU runtime snapshots are disabled. Device logs showed the previous post-install snapshot stopping SurfaceFlinger and crashing Android’s display service, which then prevented APK launches. GPU mode now cold-boots the current Android disk; installed APKs and app data remain there. Older local and downloaded RAM snapshots are retained on disk but not restored, and incompatible pre-booted snapshots are no longer downloaded. Software snapshots use a versioned identity captured from the running hardware, so changing resolution settings cannot mislabel an existing session. The first cold boot can take several minutes.

## Using the app

1. Download the IPA from [Releases](https://github.com/exlon360/APK-Container/releases), or build it using the [build guide](docs/BUILD-APK-CONTAINER.md), then import it into your sideloader. When updating in LiveContainer, keep the existing app data container.
2. Open **Settings → JIT & Sideloading** to configure an available JIT method.
3. Add an APK from **Apps**. For the compatibility runtime, download its Android image through **Runtime Setup** when needed.
4. Use **Settings → Display & Resolution** for the default rendering quality, or an app's settings for its orientation and resolution override.

The app's identity is `com.apkcontainer.app`, with the `apkcontainer://` URL scheme. It uses a separate app container from upstream Husk under the default identifiers. Existing Husk saves are not automatically migrated. There is no automatic sideloading update feed configured; install an IPA from this fork’s releases or a local build.

## Current limits

Compatibility varies by APK, engine, ABI, device, and iOS version. The translation layer requires compatible 64-bit native libraries where the APK uses native code. A loaded native engine generally occupies the process until APK Container closes, so switching apps can require a restart. JIT and additional memory availability depend on the installation method and OS.

Lower render resolutions reduce pixel workload; this fork does not yet have measured device performance results. Passing source checks or producing an IPA does not establish successful device installation, app compatibility, or sustained performance.

## Development and attribution

See [BUILD-APK-CONTAINER.md](docs/BUILD-APK-CONTAINER.md) for the release-assisted build, source-build limitations, output paths, and checks. Upstream architecture and JIT documentation remain under [docs](docs), and may describe Husk's older interface.

APK Container retains Husk's **GPL-2.0-or-later** source license and attribution. See [LICENSE](LICENSE), upstream [licensing notes](docs/01-licensing.md), and the bundled third-party notices. Existing copyright headers and component licenses remain in place.
