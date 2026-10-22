# Hosted startup and JIT

APK Container's native Apps, Build, My Apps, Repositories and Store screens do not require executable memory. LiveContainer can mark its process as debugged without an APK Container JIT script servicing traps. Calling the native JIT allocator from the first `onAppear` could therefore stop the whole process before the first frame. Moving that call to a worker queue cannot protect the UI: a debugger stop affects every thread.

Preview 13 gates foreground JIT preparation when either `LC_HOME_PATH` or `LP_HOME_PATH` is present. An ordinary hosted opening or return from the background does not call `ready`, enable a debugger or prewarm. Displayed JIT status uses `available`, which observes flags and cached results without probing executable memory. Standalone early preparation is retained.

Explicit Android launch/import requests, runtime download actions and manual JIT actions retain preparation. A manual JIT request is held in memory across the StikDebug foreground handoff and consumed before preparation; it is not persisted into another cold launch. Returning without JIT cancels an external request, while an asynchronous helper that is still busy retains it. Attachment failures clear the request. An already-debugged manual Enable action still notifies the preparation path. Opting into automatic Android start remains supported when the existing installed-at-launch and onboarding conditions are met. Its recovery marker is checked before a JIT probe and a previous failed automatic start stays suppressed for the process.

This change prevents a specific unsafe passive-startup operation. It does not prove the cause of a particular device's black screen, verify LiveContainer's loader, or make an unresponsive debugger serve an explicit Android launch. No guest data, pairing credentials, memory entitlements, VPN settings or native runtime assets are reset by this change.

## Validation

Run `tests/jit-startup/run.sh` for hosted policy and JIT handoff regression coverage. Build the iPhoneOS Release and run the package verifier before publishing. Physical-device launch and StikDebug behavior must be reported separately from desktop tests.

## Evidence when the guest cannot open

LiveContainer may hide Open Data Folder for shared or active containers. Do not toggle Shared App, delete the container or reset its data merely to retrieve logs. For a private container, Files → Browse → On My iPad → LiveContainer → Data → Application → the container folder → Documents can expose `husk.log` and `husk-native.log`. The folder name appears in LiveContainer's app settings under Containers. Shared App Group data is not exposed by ordinary Files access.

If the folder is inaccessible, iPad Settings → Privacy & Security → Analytics & Improvements → Analytics Data may contain an incident at the failure time named Husk, LiveContainer, LiveProcess or JetsamEvent. A debugger stop can leave no crash report. Existing launch logs ending at the JIT allocation request, without an allocator result, would support the trap-stall hypothesis. No launch log would instead require checking the host's loader or signing path.

References: [LiveContainer container controls](https://github.com/LiveContainer/LiveContainer/blob/9108ae624ea001f7d7696d48407f890b48fa2653/LiveContainerSwiftUI/Views/AppList/AppSettings/LCContainerView.swift), [LiveContainer data paths](https://github.com/LiveContainer/LiveContainer/blob/9108ae624ea001f7d7696d48407f890b48fa2653/LiveContainerSwiftUI/Utilities/Shared.swift), [Apple diagnostic reports](https://developer.apple.com/documentation/xcode/acquiring-crash-reports-and-diagnostic-logs).
