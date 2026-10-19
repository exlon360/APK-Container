// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// Resolves an APK's own entry activity and keeps Android's desktop covered.
/// No HOME app or desktop icon cache is required to open an Android app.
enum AndroidAppPresentation {
    typealias CommandResult = (out: String, status: Int)
    typealias RunCommand = (String, TimeInterval) throws -> CommandResult

    struct Session {
        let homePackages: Set<String>
        let homesVerified: Bool
    }

    enum LaunchError: LocalizedError {
        case message(String)
        var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
    }

    private struct IncompleteResponse: LocalizedError {
        var errorDescription: String? { "Android returned an incomplete command response." }
    }

    static let systemDialogs: Set<String> = [
        "com.android.permissioncontroller", "com.google.android.permissioncontroller",
        "com.android.packageinstaller", "com.google.android.packageinstaller",
        "com.android.documentsui", "com.google.android.documentsui",
    ]
    static let knownLaunchers: Set<String> = [
        "com.android.launcher", "com.android.launcher3", "org.lineageos.trebuchet",
        "com.google.android.apps.nexuslauncher",
    ]
    static let homeCommand = "cmd package query-activities --components --user 0 -a android.intent.action.MAIN -c android.intent.category.HOME"
    static let readinessCommand = "service check package; service check activity; service check window"

    static func validPackage(_ package: String) -> Bool {
        package.range(of: #"^[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z_][A-Za-z0-9_]*)+$"#,
                      options: .regularExpression) != nil
    }

    static func componentPackages(_ text: String) -> Set<String> {
        let pattern = #"([A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)*)/[A-Za-z0-9_.$]+"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return Set(regex.matches(in: text, range: range).compactMap {
            Range($0.range(at: 1), in: text).map { String(text[$0]) }
        })
    }

    /// --components returns a single flattened component, including activity aliases.
    /// Match the whole line and requested package before quoting it into an am command.
    static func resolvedComponent(_ text: String, package: String) -> String? {
        let pattern = #"^[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z_][A-Za-z0-9_]*)+/\.?[A-Za-z_$][A-Za-z0-9_$]*(\.[A-Za-z_$][A-Za-z0-9_$]*)*$"#
        let components = text.split(separator: "\n").map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { $0.range(of: pattern, options: .regularExpression) != nil }
        guard components.count == 1, let component = components.first,
              component.hasPrefix(package + "/") else { return nil }
        return component
    }

    enum FocusState: Equatable {
        case window(package: String, component: String?)
        case noFocus
        case unrecognized
        case readFailure
    }

    struct Observation: Equatable {
        let state: FocusState
        /// Bounded raw evidence for the diagnostic log, never a user-facing error message.
        let diagnostic: String
        var package: String? {
            if case .window(let package, _) = state { return package }
            return nil
        }
        var reason: String {
            switch state {
            case .window(let package, _): return "Android is showing \(package)."
            case .noFocus: return "Android has not focused an app window yet."
            case .unrecognized: return "Android's focused window could not be identified."
            case .readFailure: return "Android's window service did not answer."
            }
        }
    }

    enum MonitorEvent {
        case visible(Observation)
        case covered(Observation)
        case returnedHome(Observation)
        case timedOut(Observation)
    }

    // `visible` includes framework dialogs; `visible-apps` would exclude windows without ActivityRecord.
    // The display report supplies focus, the visible-window report supplies the actual owning package.
    // Neither subcommand includes the cached LAST ANR section of the unrestricted window dump.
    static let foregroundCommand = "(dumpsys window displays; dumpsys window visible) | grep -E "
        + "\"^WINDOW MANAGER (DISPLAY CONTENTS|WINDOWS)|Display: mDisplayId=|^[[:space:]]*mCurrentFocus=|^[[:space:]]*mFocusedApp=|^[[:space:]]*Window #[0-9]+|^[[:space:]]*mDisplayId=|^[[:space:]]*mOwnerUid=|NO DISPLAY|Can't find service|Permission Denial|Exception|Error\""

    private static func capture(_ pattern: String, in text: String, group: Int = 1) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: group), in: text) else { return nil }
        return String(text[range])
    }

    /// Identify the owner of the focused window on the physical guest display. A window title is
    /// arbitrary text, not a package identity; mFocusedApp can sit behind keyguard or another window.
    static func observation(_ text: String) -> Observation {
        struct WindowOwner {
            let id: String
            var display: Int?
            var package: String?
            var evidence = ""
        }
        var currentDisplay: Int?
        var defaultFocus: [String] = []
        var focusedApps: [String] = []
        var inWindows = false
        var sawDisplays = false
        var sawWindows = false
        var owners: [WindowOwner] = []
        var currentOwner: WindowOwner?
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("WINDOW MANAGER DISPLAY CONTENTS") {
                sawDisplays = true; inWindows = false; currentDisplay = nil
            } else if line.hasPrefix("WINDOW MANAGER WINDOWS") {
                sawWindows = true; inWindows = true
            } else if !inWindows, let display = capture(#"^Display: mDisplayId=(\d+)"#, in: line) {
                currentDisplay = Int(display)
            } else if !inWindows, currentDisplay == 0, line.hasPrefix("mCurrentFocus=") {
                defaultFocus.append(line)
            } else if !inWindows, currentDisplay == 0, line.hasPrefix("mFocusedApp=") {
                focusedApps.append(line)
            } else if inWindows, let id = capture(#"^Window #[0-9]+ Window\{([0-9a-fA-F]+) "#, in: line) {
                if let currentOwner { owners.append(currentOwner) }
                currentOwner = WindowOwner(id: id)
            } else if inWindows, let display = capture(#"^mDisplayId=(\d+)"#, in: line) {
                currentOwner?.display = Int(display)
            } else if inWindows, line.hasPrefix("mOwnerUid="),
                      let package = capture(#"(?:^|\s)package=([A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)*)(?:\s|$)"#, in: line) {
                currentOwner?.package = package
                currentOwner?.evidence = line
            }
        }
        if let currentOwner { owners.append(currentOwner) }
        let focusEvidence = defaultFocus.joined(separator: " | ")
        func result(_ state: FocusState, _ detail: String) -> Observation {
            Observation(state: state, diagnostic: String(detail.prefix(700)))
        }
        guard sawDisplays else {
            return result(.readFailure, "No live display report: " + text.replacingOccurrences(of: "\n", with: " | "))
        }
        guard defaultFocus.count == 1, let focus = defaultFocus.first else {
            return result(.unrecognized, "Expected one display-0 focus; got \(defaultFocus.count). " + focusEvidence)
        }
        if focus == "mCurrentFocus=null" { return result(.noFocus, focus) }
        guard let id = capture(#"^mCurrentFocus=Window\{([0-9a-fA-F]+) "#, in: focus), sawWindows else {
            return result(.unrecognized, "Missing focus identity or visible-window report. " + focus)
        }
        let matching = owners.filter { $0.id == id && $0.display == 0 }
        guard matching.count == 1, let owner = matching.first, let package = owner.package else {
            return result(.unrecognized, "No unique visible owner for display-0 focus. " + focus)
        }
        // Component names are useful diagnostics, but only after the window's actual owner is known.
        let componentPattern = #"([A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)*/[A-Za-z0-9_.$]+)"#
        let candidate = capture(componentPattern, in: focus)
            ?? focusedApps.compactMap { capture(componentPattern, in: $0) }.first
        let component = candidate?.hasPrefix(package + "/") == true ? candidate : nil
        return result(.window(package: package, component: component), focus + " | " + owner.evidence)
    }

    static func observe(run: RunCommand) throws -> Observation {
        let result = try execute(foregroundCommand, timeout: 15, run: run)
        guard result.status == 0 else {
            return Observation(state: .readFailure, diagnostic: String(diagnostic(result).prefix(700)))
        }
        return observation(result.out)
    }

    /// Production presentation state machine. Unknown observations cover the surface and recover;
    /// they do not discard a running app after one transient focus change or failed bridge read.
    static func monitor(requested: String, session: Session, installedPackages: Set<String>,
                        allowSettings: Bool, read: () throws -> Observation,
                        now: () -> TimeInterval, pause: (TimeInterval) async throws -> Void,
                        cancelled: () -> Bool, event: (MonitorEvent) async -> Void) async throws {
        var presented = false
        var unknownSince: TimeInterval? = now()
        while true {
            if cancelled() { throw CancellationError() }
            let observation: Observation
            do { observation = try read() }
            catch is CancellationError { throw CancellationError() }
            catch {
                observation = Observation(state: .readFailure,
                    diagnostic: String(error.localizedDescription.prefix(700)))
            }
            if cancelled() { throw CancellationError() }
            let home = observation.package.map {
                knownLaunchers.contains($0) || session.homePackages.contains($0)
            } ?? false
            let allowed = allows(observation.package, requested: requested,
                                 homePackages: session.homePackages, installedPackages: installedPackages,
                                 allowSettings: allowSettings, launching: !presented,
                                 homesVerified: session.homesVerified)
            if allowed {
                presented = true
                unknownSince = nil
                await event(.visible(observation))
            } else if home && presented {
                await event(.returnedHome(observation))
                return
            } else {
                // HOME can still be the previous window just after am start returns. Never expose it.
                await event(.covered(observation))
                if unknownSince == nil { unknownSince = now() }
                if now() - (unknownSince ?? now()) >= 30 {
                    await event(.timedOut(observation))
                    return
                }
            }
            if cancelled() { throw CancellationError() }
            try await pause(allowed ? 1 : 0.4)
        }
    }

    static func hasErrorLine(_ output: String) -> Bool {
        output.split(separator: "\n").contains { raw in
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let lower = line.lowercased()
            return lower.hasPrefix("error:") || lower.hasPrefix("exception ")
                || lower.hasPrefix("exception:") || lower.hasPrefix("security exception:")
                || line.range(of: #"^(?:[A-Za-z_$][A-Za-z0-9_$]*\.)*[A-Za-z_$][A-Za-z0-9_$]*(?:Exception|Error)(?::|\s|$)"#,
                              options: .regularExpression) != nil
        }
    }

    static func launchSucceeded(status: Int, output: String) -> Bool {
        let lines = output.lowercased().split(separator: "\n").map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return status == 0 && lines.contains("status: ok") && !lines.contains("status: timeout")
            && !hasErrorLine(output)
    }

    static func servicesReady(_ result: CommandResult) -> Bool {
        let lines = Set(result.out.split(separator: "\n").map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        })
        return result.status == 0 && ["package", "activity", "window"].allSatisfy {
            lines.contains("Service \($0): found")
        }
    }

    /// The bridge may retain a timed-out command's output. Only consume this invocation's response.
    static func execute(_ command: String, timeout: TimeInterval, run: RunCommand) throws -> CommandResult {
        let marker = "APK_COMMAND_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let result = try run("echo \(marker); \(command)", timeout)
        guard let range = result.out.range(of: marker, options: .backwards) else {
            throw IncompleteResponse()
        }
        return (String(result.out[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines), result.status)
    }

    static func diagnostic(_ result: CommandResult) -> String {
        "exit \(result.status): " + result.out.replacingOccurrences(of: "\n", with: " | ").prefix(400)
    }

    /// This is the production command pipeline, with its bridge and delays injected for regression tests.
    /// A package/activity service can disappear during an Android framework restart even after boot_completed=1.
    static func start(package: String, settings: Bool, run: RunCommand,
                      cancelled: () -> Bool, pause: () async throws -> Void,
                      log: (String) -> Void) async throws -> Session {
        func checkCancellation() throws { if cancelled() { throw CancellationError() } }
        guard validPackage(package), !knownLaunchers.contains(package) else {
            throw LaunchError.message("Choose an Android app from Apps to open it.")
        }
        var lastFailure = "Android's package, activity, or window service is not ready."
        // Bounded recovery covers a framework restart without relaunching indefinitely.
        for attempt in 0..<8 {
            try checkCancellation()
            if attempt > 0 { try await pause(); try checkCancellation() }
            do {
                let ready = try execute(readinessCommand, timeout: 10, run: run)
                try checkCancellation()
                guard servicesReady(ready) else {
                    lastFailure = "Android services are restarting (\(diagnostic(ready)))."
                    log(lastFailure)
                    continue
                }
                var homes = Session(homePackages: [], homesVerified: false)
                // HOME is an optional denylist, never a prerequisite for launching an APK.
                do {
                    let result = try execute(homeCommand, timeout: 10, run: run)
                    let packages = componentPackages(result.out)
                    let lines = result.out.split(separator: "\n").map(String.init)
                    let componentList = !lines.isEmpty && lines.allSatisfy { line in
                        guard let package = line.split(separator: "/").first.map(String.init) else { return false }
                        return resolvedComponent(line, package: package) != nil
                    }
                    let verified = result.status == 0 && (componentList || result.out == "No activities found")
                    homes = Session(homePackages: verified ? packages : [], homesVerified: verified)
                    if !verified { log("HOME enumeration unavailable; restricting app handoffs (\(diagnostic(result))).") }
                } catch {
                    log("HOME enumeration unavailable; restricting app handoffs: \(error.localizedDescription)")
                }
                try checkCancellation()
                guard !homes.homePackages.contains(package) else {
                    throw LaunchError.message("Android home apps are hidden. Choose an APK from Apps instead.")
                }
                let command: String
                if settings {
                    command = "am start -W --user 0 -a android.settings.APPLICATION_DETAILS_SETTINGS -d package:\(package)"
                } else {
                    var component: String?
                    var entryCategory = "LAUNCHER"
                    var resolutionFailed = false
                    // LAUNCHER describes an APK entry point; it does not invoke or require a desktop app.
                    for category in ["LAUNCHER", "LEANBACK_LAUNCHER"] {
                        let result = try execute("cmd package resolve-activity --components --user 0 -a android.intent.action.MAIN -c android.intent.category.\(category) -p \(package)", timeout: 20, run: run)
                        try checkCancellation()
                        guard result.status == 0, !hasErrorLine(result.out) else {
                            lastFailure = "Android could not resolve the app while its services are starting (\(diagnostic(result)))."
                            log(lastFailure)
                            resolutionFailed = true
                            break
                        }
                        if let found = resolvedComponent(result.out, package: package) {
                            component = found
                            entryCategory = category
                            break
                        }
                        guard result.out == "No activity found" else {
                            lastFailure = "Android returned an unverified app entry (\(diagnostic(result)))."
                            log(lastFailure)
                            resolutionFailed = true
                            break
                        }
                    }
                    if resolutionFailed { continue }
                    guard let component else {
                        // A fresh service check distinguishes an app without an entry from a framework restart.
                        let ready = try execute(readinessCommand, timeout: 10, run: run)
                        try checkCancellation()
                        guard servicesReady(ready) else { lastFailure = "Android services restarted while resolving the app."; continue }
                        throw LaunchError.message("This APK has no enabled activity that can be opened. It may be a service, plugin, or incomplete split APK.")
                    }
                    command = "am start -W --user 0 -a android.intent.action.MAIN -c android.intent.category.\(entryCategory) -n '\(component)'"
                }
                try checkCancellation()
                // Explicit launch intent wakes a sleeping display without dismissing a secure keyguard
                // or changing the user's permanent screen-timeout settings.
                let wake = try execute("input keyevent KEYCODE_WAKEUP", timeout: 15, run: run)
                try checkCancellation()
                if wake.status != 0 { log("Android wake request: \(diagnostic(wake))") }
                let launched = try execute(command, timeout: 60, run: run)
                try checkCancellation()
                guard launchSucceeded(status: launched.status, output: launched.out) else {
                    log("App start failed: \(diagnostic(launched))")
                    let ready = try execute(readinessCommand, timeout: 10, run: run)
                    try checkCancellation()
                    if !servicesReady(ready) || launched.out.contains("DeadSystemException")
                        || launched.out.contains("DeadObjectException") || launched.out.contains("Can't find service") {
                        lastFailure = "Android services restarted while opening the app (\(diagnostic(launched)))."
                        continue
                    }
                    throw LaunchError.message("Android could not open this app (\(diagnostic(launched))).")
                }
                return homes
            } catch is CancellationError { throw CancellationError() }
            catch let error as LaunchError { throw error }
            catch {
                lastFailure = "The Android runtime did not answer: \(error.localizedDescription)"
                log(lastFailure)
            }
        }
        throw LaunchError.message("The Android runtime is still restarting or unavailable. Try again after it finishes starting. \(lastFailure)")
    }

    static func allows(_ foreground: String?, requested: String, homePackages: Set<String>,
                       installedPackages: Set<String>, allowSettings: Bool, launching: Bool,
                       homesVerified: Bool = true) -> Bool {
        guard let foreground, !homePackages.contains(foreground),
              !knownLaunchers.contains(foreground) else { return false }
        // APK permission flows open Settings, and framework-owned dialogs can have arbitrary titles.
        // These identities come from the matched window owner, never from an underlying activity.
        if foreground == "com.android.settings" || foreground == "android" { return true }
        if foreground == requested || systemDialogs.contains(foreground) { return true }
        // Without a verified HOME denylist, unrelated apps could be a custom desktop.
        return !launching && homesVerified && installedPackages.contains(foreground)
    }
}
