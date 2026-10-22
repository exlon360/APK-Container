# Build, My Apps, Repositories, and Store

Preview 11 includes a native app library inspired by LiveContainer, a repository-backed Store, and a paired Mac build workflow. It preserves APK Container's existing Android engines, app-only session controls, display settings, JIT methods, and memory entitlements.

## Pair your Mac

The packaged Mac companion requires **Apple Silicon and macOS 13.5 or later**. Install Codex and sign in before pairing. The bridge uses the installed Codex app-server and account; there is no separate API key to enter.

1. Download `APKContainer-Bridge-preview10.zip` from the same release as the IPA. Extract **APK Container Bridge.app** into `~/Applications` or `/Applications`. The preview is ad-hoc signed, not notarized; macOS may require **Privacy & Security → Open Anyway** on first launch.
2. Open the companion. A configured bridge starts automatically; on first setup, click **Start Bridge**. Closing its window keeps it running. **Stop Bridge** or **Quit** stops it deliberately; saved projects remain on disk. While running, the companion prevents idle system sleep without changing the Mac’s sleep settings. Closing the laptop lid, logging out, or shutting down can still disconnect it.
3. Click **Generate agent.prf** and save the pairing file. Transfer it privately to your device, for example with AirDrop. In APK Container, open **Build → Import agent.prf**. The file contains a credential: keep it private and do not add it to a repository.
4. On the Mac, click **Pair Skill /apk**. This installs the bundled `/apk` skill and marks the bridge paired. Restart Codex if its skill list does not yet include a newly installed skill.
5. Keep the Mac and device on the same reachable network and allow local-network access on the device. **Build** shows **Mac connected** when the paired bridge is reachable. Describe your app and send it.

Preview 11 updates the iPhone/iPad client; it uses the same Preview 10 Mac companion (1.1.1/build 10) and preserves your existing pairing.

The connection is HTTPS with an exact certificate pin from `agent.prf`, plus a bearer credential stored in the device Keychain. The bridge rejects browser-origin requests and only exposes its project operations. It does not expose Codex's app-server directly. Fresh profiles prefer the Mac’s current numeric LAN address on port **48152** and include its `.local` hostname and other eligible LAN addresses as fallbacks. The device probes the saved addresses with the same certificate pin, validates the bridge identity, and uses a reachable one. The server accepts IPv4 and IPv6. A private VPN can work if the configured address is reachable; this release does not include a cloud relay.

The command-line entry point is bundled at `APK Container Bridge.app/Contents/Resources/bridge/bridge.mjs`; use its bundled `node/bin/node`. `init --url https://HOST:48152` selects a reachable hostname for a new configuration. An existing configuration is retained by `init`. Export a new profile whenever you deliberately change its address or credentials.

## Build and edit an app

**Build your app** starts a new conversation. The first request receives hidden Android 16 / LineageOS / APK Container compatibility instructions. Later requests in that conversation receive hidden edit/update instructions. The device conversation contains your own request, Codex's replies, and visible status or approval messages. Permission requests are not silently accepted.

Every app receives a separate project directory under `~/Documents/ChatGPT/apk files` and a separate persistent Codex conversation. **+** starts a new app; **My Apps → Open Chat** continues the same app. A verified checkpoint of the existing project and bridge record precedes every new build/edit request, under `~/.codex/backups/pre-prompt`. Checkpoints are retained and never automatically restored.

Codex is instructed to build a real debug-signed APK into `dist/`, preserve the app's identity and data across edits, and report **Features**, **Issues**, and **Ideas**. The bridge waits for turn completion, checks APK ZIP structure and its Android manifest, computes a SHA-256 digest, and saves an immutable download copy. A request-bound build report supplies the summary. A reply without a new APK does not get an app-created card. These checks establish artifact integrity, not compatibility with every Android API or successful execution on an iPhone/iPad.

The first successful build says **I've created your app**. Later builds say **I've edited your app** or **I've updated your app**, according to the request. Open **My Apps → Install APK** to download the latest build through the existing APK import chooser. Previously completed builds remain saved on the Mac if an edit fails. Imported apps appear in **Apps** and use the normal **Run** action.

Android SDK/JDK availability and account limits can affect builds. The build context directs Codex to keep new tool downloads inside the project and request necessary permissions. APK Container's translation layer supports a subset of Android; some generated apps may need the full Android compatibility runtime. Neither a successful compiler run nor a checksum proves translation-layer compatibility.

## The /apk skill and Codex sidebar

- `/apk pair` checks the companion and pairs its build workflow.
- `/apk status` reports connection setup without printing credentials.
- `/apk sync` uses Codex's app tools, when available, to organize the bridge's generated conversations under the **apk files** sidebar section. It only moves conversations identified by the bridge; it does not edit Codex's internal database.

The filesystem folder and the sidebar section are separate. App-server does not provide a supported sidebar placement API, so newly created build conversations may need `/apk sync` to appear in that section.

## Repositories and Store

**Repositories** includes ten real GitHub release feeds:

| App | GitHub repository |
| --- | --- |
| NewPipe | `TeamNewPipe/NewPipe` |
| Aegis | `beemdevelopment/Aegis` |
| Tasks.org | `tasks/tasks` |
| Markor | `gsantner/markor` |
| Material Files | `zhanghai/MaterialFiles` |
| LocalSend | `localsend/localsend` |
| AnkiDroid | `ankidroid/Anki-Android` |
| Fossify Gallery | `FossifyOrg/Gallery` |
| Fossify File Manager | `FossifyOrg/File-Manager` |
| Fossify Calendar | `FossifyOrg/Calendar` |

Enable or disable each feed, add another GitHub repository, or remove it. The **Store** lists APK assets from enabled repositories and lets you choose a download. Feeds are cached with ETags and a 15-minute refresh interval; manual refresh can encounter GitHub's unauthenticated rate limit. Downloads use HTTPS, bounded sizes, APK manifest checks, and GitHub's SHA-256 asset digest when provided. Only install APKs from sources you trust; appearing in Store is not a claim that an app works with the translation layer.

## Troubleshooting

- **Cannot reach Mac / request timed out:** click **Reconnect** to discard the old connection and start a new one. This works even if a background read is pending, while protecting in-flight build submissions. Keep any VPN required by StikDebug/JIT enabled. If it still fails, open **Connection Details** and copy the report; it contains attempted addresses, request stages, and error codes, without the pairing token or app prompts. Generate and import a fresh `agent.prf` if the Mac address has changed. Check that both devices are on the same reachable Wi-Fi; guest/client-isolated Wi-Fi and VPN routing can block device-to-Mac traffic. In iOS Settings, allow **Local Network** for APK Container—or for **LiveContainer** when it hosts APK Container. Use the address shown in the Mac companion if you add an address manually. No firewall or VPN settings are changed automatically.
- **Permission or pairing error:** follow the specific explanation in Build. HTTP/server errors no longer turn a healthy connection into a generic “Mac offline” message. Pairing keeps the same token and certificate unless you deliberately replace the bridge configuration.
- **Mac sleeps or window closes:** the updated bridge stays running when its window closes and holds an idle-sleep assertion while running. Explicit Stop/Quit and laptop-lid sleep still disconnect it. Open it from the Dock to show its window again.
- **Run /apk on your Mac:** click **Pair Skill /apk** in the companion.
- **Codex cannot start or authenticate:** open Codex on the Mac, sign in, and retry. Use the current desktop app with its bundled app-server.
- **An approval is waiting:** review and answer the visible request in Build. Unsupported interactions are declined and reported.
- **Bridge stopped during a build:** restarting marks unfinished requests interrupted. Send a follow-up to resume the saved project; no stale artifact is reported as newly created.
- **No new APK:** read Codex's reply. Source edits or explanations alone do not produce an install card.
- **Store refresh failed:** retain the cached entries, wait for rate-limit recovery, then refresh. A failed checksum or incomplete download is never imported.

## Build and test the companion

From the repository root, with a standalone arm64 Node.js 24 binary:

```sh
APK_CONTAINER_NODE=/absolute/path/to/node bridge/scripts/package-mac.sh
node --test tests/bridge/*.test.mjs
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer sh tests/build-bridge/run.sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer sh tests/build-bridge/store-run.sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer sh tests/bridge-connection/run.sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer bash tests/mac-bridge/run.sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer sh tests/repositories/run.sh
```

The companion bundles Node and its full version-specific license, bridge source, and `/apk` skill. It does not bundle Codex or an Android SDK. Packaging verifies the app signature and bundled executable resources. Connection regression tests exercise direct-IP fallback, pinned TLS, read-only reconnection, and IPv4/IPv6 listeners. Build POSTs are never blindly replayed after a network error. The backend suite uses controlled app-server fixtures; a separate installed app-server smoke test checks initialization and request-schema acceptance without running an inference. Real device pairing, a full generated-app build, sideloading, and Android execution still require device testing.
