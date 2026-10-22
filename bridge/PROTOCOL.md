# APK Container Bridge protocol v1

The Mac companion owns a Node process running `bridge.mjs start`. It serves a
small HTTPS API and runs the installed Codex CLI app-server over local stdio.
Codex credentials stay on the Mac. The bridge does not select a different model.
Both devices need a reachable local-network or VPN address, and the Mac bridge
must remain open. This is not a cloud relay.

## Command line

```text
node bridge.mjs init [--state-dir PATH] [--projects-dir PATH]
                    [--url https://Mac.local:48152] [--codex PATH]
                    [--backup-root PATH]
node bridge.mjs start [--state-dir PATH]
node bridge.mjs pair [--state-dir PATH]
node bridge.mjs profile --out PATH [--state-dir PATH]
node bridge.mjs status [--state-dir PATH]
node bridge.mjs projects --json [--state-dir PATH]
```

Defaults are `~/Library/Application Support/APK Container Bridge` for private
state and `~/Documents/ChatGPT/apk files` for app projects. `status` is read-only
and fails clearly if setup is absent. `init` is idempotent. `start` prints one
JSON line containing `event: "listening"`, `url`, `alternateURLs`, and `port`; SIGTERM or SIGINT
stops its own server and Codex child. No background login service is installed.

`init`, `status`, and `pair` return JSON with `bridgeID`, `name`, `url`, `alternateURLs`, `paired`,
`profilePath`, `stateDir`, `projectsDir`, and `version`. `profile` returns only
`profilePath`. `projects --json` returns `projects` with `id`, `name`, `threadID`,
`status`, `updatedAt`, and local `path`, for the `/apk` skill's sidebar setup.
Errors use nonzero exit status and an `error` JSON property. Tokens are never
printed by these commands.

## Pairing and HTTPS

`agent.prf` is private JSON, written with mode 0600:

```json
{
  "format": "apk-container-agent",
  "version": 1,
  "bridgeID": "UUID",
  "name": "APK Container Bridge",
  "url": "https://192.168.1.20:48152",
  "alternateURLs": ["https://Mac.local:48152"],
  "token": "64 lowercase hexadecimal characters",
  "certificateSHA256": "64 lowercase hexadecimal characters",
  "createdAt": "ISO8601 UTC timestamp"
}
```

The certificate pin is SHA-256 of the leaf certificate's DER bytes. Clients must
pin that exact certificate, send `Authorization: Bearer TOKEN`, and refuse
redirects. Profiles are bearer credentials and must be transferred privately.
The API rejects browser `Origin` headers. The bridge does not expose arbitrary
Codex methods, host filesystem browsing, or raw credentials.

`alternateURLs` is optional, preserving compatibility with existing version 1
profiles. The primary `url` and up to five alternatives are distinct HTTPS
origins for the same bridge identity, token, and certificate pin. Clients must
apply that pin to every origin and confirm `bridgeID` through `/v1/status`
before selecting a connection. Probing alternatives must not replay POSTs;
an interrupted write may already have reached the bridge.

For a configured `.local` hostname, newly generated profiles put the current
numeric Ethernet/Wi-Fi IPv4 address first and retain the hostname as an
alternative. This also helps older clients that only understand `url`. A
custom configured origin, including a VPN address, retains first priority.
Automatic alternatives come only from usable `en*` IPv4 interfaces, excluding
loopback and link-local addresses; VPN, AWDL, and virtual interfaces are not
automatically advertised. At most six origins are returned in total.

The stored configuration's `url` remains unchanged, as do the token,
certificate, and bridge identity. Read-only `status` computes current addresses
without rewriting `agent.prf`; explicit profile export refreshes its addresses
after checkpointing the existing profile. An address change may therefore
require exporting and importing a fresh profile if all saved choices stop
working. By default the server listens on both IPv6 and IPv4 through a
dual-stack socket, falling back to an IPv4 listener only when IPv6 is unavailable.

## HTTP

Every endpoint needs authentication. All POST bodies are JSON objects with
`Content-Type: application/json`, including the empty interrupt body `{}`.
Errors are `{ "error": "Readable explanation" }` with an appropriate HTTP status.

| Method | Path | Body / response |
| --- | --- | --- |
| GET | `/v1/status` | `{name, bridgeID, paired, version, codexReady}` |
| GET | `/v1/projects` | `{projects: [Project]}`; messages omitted as an empty array |
| POST | `/v1/projects` | `{name}` → 201 `{project}` |
| GET | `/v1/projects/:id` | `{project}` including conversation |
| POST | `/v1/projects/:id/messages` | `{text}` → 202 `{project}` |
| POST | `/v1/projects/:id/interrupt` | `{}` → `{project}` |
| POST | `/v1/projects/:id/approvals/:approvalID` | `{decision: "accept" or "decline", answers?: {questionID: [string]}}` → `{project}` |
| GET | `/v1/projects/:id/artifacts/:artifactID` | APK bytes, `Content-Length`, `X-APK-SHA256` |

Project properties:

```text
id, name, status, createdAt, updatedAt, threadID (nullable),
messages: [{id, role: user|assistant|status, text, createdAt}],
artifacts: [{id, name, bytes, sha256, createdAt, downloadPath}],
approvals: [{id, kind: command|file|permissions|input, title, detail, createdAt,
            questions: [{id, header, question, options: [{label, description}]}]}],
summary: null | {kind: created|updated|edited, features: [string],
                 issues: [string], ideas: [string]},
error: null | string
```

All timestamps are ISO8601 UTC strings. Status is `idle`, `building`,
`awaitingApproval`, `completed`, `failed`, or `interrupted`. Assistant deltas
update the same message ID; polling clients replace snapshots and should discard
older `updatedAt` values. `completed` means the reply ended, while a non-null
`summary` marks a new verified APK delivery. Historical artifacts remain
available after an edit fails or a reply produces no APK.

## Build lifecycle

Each app owns one durable project directory and one persistent Codex thread.
Every build explicitly attaches the installed `/apk` skill using the app-server
skill input. A missing skill produces a setup error before any inference turn.
The device transcript contains the user's text and visible replies. The first
turn's setup asks for Android 16/API 36 and LineageOS compatibility with the
APK Container translation layer; later turns receive the edit/update setup.
This hidden setup is still present in the Mac's normal Codex transcript.

Before each user request the bridge creates and verifies a private checkpoint
of the project and its bridge record under `~/.codex/backups/pre-prompt`.
Checkpoints preserve contents, symlinks, permissions, ACLs, and extended
attributes on macOS, and include hashes and restore guidance. A failed
checkpoint prevents the request from starting. Existing checkpoints are never
automatically expired. New workspace and published artifact destinations are
recorded before creation. Codex's own transcript is append-only and is not
rewound by restoring an app checkpoint.

Codex runs with `workspace-write` and `on-request` approvals. Remote command,
file, permission, and input requests are presented to the paired device.
Approval is scoped to the requested action/turn; the bridge does not apply
session-wide approval or disable the sandbox. Unsupported interactions are
declined with a visible explanation.

Final APKs must be written directly into `dist/`. A current
`dist/build-report.json` should contain the bridge-provided `requestID` and
string arrays `features`, `issues`, and `ideas`. A completion card requires a
successful Codex turn plus an APK whose ZIP directory contains
`AndroidManifest.xml`. New/changed APK bytes qualify; identical rebuild bytes
also require a changed file timestamp and a report matching this request.
Touching an unchanged APK with an old report does not qualify. The immutable
delivery copy is hashed and checked again before download. ZIP validation does
not prove Android installation, signature validity, or device compatibility;
the model must report its actual build/test evidence honestly.

Stopped turns cannot publish APKs or add late approvals. Early notifications
are buffered until `turn/start` identifies the current turn. Delayed events
from previous turns cannot complete a new request. Restarting or closing the
bridge marks active requests interrupted rather than successful.

## Verification

```sh
node --test tests/bridge/*.test.mjs
node tests/bridge/protocol-smoke.mjs
```

The backend suite uses disposable state and mock model responses, including
HTTPS authentication, artifact integrity, backups, and lifecycle races. The
protocol smoke launches the real installed CLI with isolated `CODEX_HOME`,
checks initialize/thread/name/resume/model-list methods, and validates
`turn/start` against a nonexistent thread. It performs no inference and does
not use or change the user's Codex account state.
