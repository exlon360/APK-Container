# Android app target

Build a normal installable Android APK for Android 16 (API 36) / LineageOS. APK Container has two execution routes: a native translation layer with partial Android APIs, and a full Android compatibility runtime. They are not interchangeable, and arbitrary APKs are not automatically compatible with the translation layer.

Use the user's requested features, then choose the smallest dependency set that supports them. Standard Java Android activities and classic views are a useful starting point; inspect the current fork's Java/framework/native translation implementations before relying on a particular API. Avoid making Google Play Services, Play licensing, privileged system permissions, or an Android HOME launcher mandatory. Include an enabled explicit MAIN/LAUNCHER app entry. Preserve the package ID and signing key on updates. Do not force the user onto an Android home screen.

For native libraries, the translation layer targets arm64. Verify ABI, native loading and rendering support against the fork before claiming support. APKs should adapt to phone/tablet sizes and portrait/landscape changes; preserve user state through recreation. Keep file access inside app-owned storage or normal Android document pickers.

Inspect local SDK/JDK/build tools before building. If a dependency is missing, install only within the authorized project/tool scope or explain the required setup. Do not silently enable unrestricted host access to work around a failed build.

Project: https://github.com/exlon360/APK-Container
The bridge's hidden prompt includes the specific output directory and requestID. Put real output APKs in `dist/` and the turn's structured report at `dist/build-report.json`. Report what was compiled, what was tested, and any untested device behavior separately.
