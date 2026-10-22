---
name: apk
description: Pair APK Container with its Mac bridge, build or update Android apps for APK Container, and organize its app chats. Use for /apk, $apk, APK Container Build pairing, or a request to continue one of its generated apps.
---

# APK Container

Connect APK Container's Build screen to Codex on this Mac. Keep the user's app request authoritative. Build for Android 16 / LineageOS and exlon360's APK Container fork; target the translation layer only where its supported APIs permit it.

## Pair the device

For `/apk pair`, or `/apk` without an app request:

1. Run `scripts/apk.sh status` relative to this skill. If the Mac companion is missing, explain that APK Container Bridge must be installed first; do not invent a connected session.
2. Run `scripts/apk.sh pair`. This enables the local bridge's authenticated device requests; it does not send an inference request or change Codex account credentials.
3. Tell the user to keep the Mac bridge running (its window may be closed), generate `agent.prf` there, and import that file in APK Container → Build. Do not print, publish, or send the token, private key, or profile contents. The file is a credential.
4. If Codex sidebar tools are available, find or create the `apk files` section, inspect `scripts/apk.sh projects --json`, and move only those returned thread IDs into that section. Capture the previous section placement before changing it. Do not message or modify unrelated tasks. If these app tools are unavailable, leave sidebar organization alone; app workspaces still live under `~/Documents/ChatGPT/apk files`.

For `/apk sync`, refresh only the sidebar organization above. For `/apk status`, report the bridge status without dumping its private state directory.

## Build or change an app

Read [compatibility.md](references/compatibility.md) when writing app code. Each app has its own project directory and conversation. Preserve the current app's identity and data through updates; `+` in Build/My Apps starts a separate app. Every new request needs a fresh verified checkpoint of affected existing project files before editing; the bridge performs this for device requests. A manual Codex request must do the equivalent before changing files.

The bridge automatically supplies the creation context on the first prompt and the edit/update context on every later prompt. Keep those setup instructions out of the device-visible conversation; show the user's actual request and useful progress. Do not conceal errors, requested approvals, or missing build tools. Use the configured Codex model rather than choosing another model.

Produce a real APK under `dist/`, and validate its manifest/package, build result, and target before claiming completion. For bridge turns, write `dist/build-report.json` with the supplied requestID and `features`, `issues`, `ideas` arrays. A bridge completion card appears only after the completed turn produces a newly verified APK. Never substitute placeholder ZIPs or claim that compilation proves on-device compatibility.

Each response should explain **Features**, **Issues**, and **Ideas** concisely. Once the artifact is ready, use “I've created your app” for the first build, “I've updated your app” for added/improved features, or “I've edited your app” for a targeted edit, with the instruction to open My Apps on the device. Report an unsuccessful build plainly and keep the previous APK available.
