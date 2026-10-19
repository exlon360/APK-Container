// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// Guest-side app-only policy. HOME packages are disabled without uninstalling them or
/// touching their data. Core Android UI stays installed for permissions, pickers and unlocking.
/// The caller must durably record every original setting before this helper changes it.
enum AndroidAppOnlyPolicy {
    typealias Run = (String, TimeInterval) throws -> (out: String, status: Int)

    struct Report {
        let homePackages: Set<String>
        let disabledPackages: Set<String>
        let residualHomeComponents: Set<String>
        let chromeDisabledVerified: Bool
        let chromeRestoreCommand: String
    }

    enum Failure: LocalizedError {
        case message(String)
        var errorDescription: String? {
            if case .message(let message) = self { return message }
            return nil
        }
    }

    static let protectedPackages: Set<String> = [
        "android", "com.android.settings", "com.android.systemui",
        "com.android.permissioncontroller", "com.google.android.permissioncontroller",
        "com.android.packageinstaller", "com.google.android.packageinstaller",
        "com.android.documentsui", "com.google.android.documentsui",
        "com.android.providers.media", "com.android.providers.media.module",
        "com.google.android.providers.media.module", "com.android.externalstorage",
        "com.android.providers.downloads", "com.android.providers.downloads.ui",
    ]
    private static let allowedCoreHomes: Set<String> = [
        "com.android.settings/.FallbackHome",
        "com.android.settings/com.android.settings.FallbackHome",
    ]

    // MATCH_DISABLED_COMPONENTS includes launchers already disabled on an earlier boot.
    static let allHomesCommand = "cmd package query-activities --components --query-flags 512 --user 0 -a android.intent.action.MAIN -c android.intent.category.HOME"
    static let enabledHomesCommand = "cmd package query-activities --components --user 0 -a android.intent.action.MAIN -c android.intent.category.HOME"
    static let chromeReadCommand = "dumpsys statusbar | grep -E "
        + "\"^[[:space:]]*(displayId=|mDisabled1=|mDisabled2=|mDisableRecords.size=|mCurrentUserId=|\\[[0-9]+\\] userId=)\""

    // Android16 StatusBarShellCommand keeps its static Binder token inside system_server.
    // These flags survive the client shell and SystemUI restarting, but must be reapplied
    // after system_server restarts. They disable controls/icons, not the bar's insets or Back.
    private static let chromeFlags: [(name: String, mask1: UInt32, mask2: UInt32)] = [
        ("home", 0x00200000, 0), ("recents", 0x01000000, 0), ("search", 0x02000000, 0),
        ("notification-alerts", 0x00040000, 0), ("statusbar-expansion", 0x00010000, 0),
        ("system-icons", 0x00100000, 0), ("clock", 0x00800000, 0),
        ("notification-icons", 0x00020000, 0), ("quick-settings", 0, 1),
    ]
    static let chromeDisableCommand = "cmd statusbar send-disable-flag " + chromeFlags.map(\.name).joined(separator: " ")
    static let chromeMask1: UInt32 = 0x03B70000
    static let chromeMask2: UInt32 = 0x00000001

    static func packageStateCommand(_ package: String) -> String {
        "dumpsys package '\(package)' | grep -E '^[[:space:]]*User 0:'"
    }

    static func disableCommand(_ package: String) -> String {
        "pm disable-user --user 0 '\(package)'"
    }

    /// Restore only deliberately, using the original state saved in the ledger.
    static func restorePackageCommand(package: String, originalState: Int) throws -> String {
        guard validPackage(package), let operation = [0: "default-state", 1: "enable",
            2: "disable", 3: "disable-user", 4: "disable-until-used"][originalState] else {
            throw Failure.message("The saved Android package setting is invalid.")
        }
        return "pm \(operation) --user 0 '\(package)'"
    }

    /// `run` must return only this invocation's output (the host uses its unique command marker).
    /// A callback failure stops before the corresponding mutation. Partial progress remains
    /// recoverable from the ledger; this helper never silently rolls back newer user state.
    static func prepare(requested: String?, run: Run,
                        saveOriginal: (String, Int) throws -> Void,
                        saveChromeOriginal: (String) throws -> Void,
                        log: (String) -> Void = { _ in }) throws -> Report {
        if let requested, !validPackage(requested) {
            throw Failure.message("The requested Android package name is invalid.")
        }
        let allHomes = try readHomes(command: allHomesCommand, run: run)
        let homePackages = Set(allHomes.map(packageOf))
        if let requested, homePackages.contains(requested) {
            throw Failure.message("Android home apps cannot be opened in APK Container.")
        }
        let initiallyEnabled = try readHomes(command: enabledHomesCommand, run: run)
        try validateProtectedHomes(initiallyEnabled)

        var disabled: Set<String> = []
        for package in homePackages.subtracting(protectedPackages).sorted() {
            let before = try readPackageState(package, run: run)
            // 2/3 are already disabled; 4 is disabled-until-used and should not be touched.
            if before == 2 || before == 3 || before == 4 {
                disabled.insert(package)
                continue
            }
            try saveOriginal(package, before)
            let changed = try run(disableCommand(package), 20)
            guard changed.status == 0,
                  changed.out.trimmingCharacters(in: .whitespacesAndNewlines)
                    == "Package \(package) new state: disabled-user" else {
                throw Failure.message("Android could not disable home app \(package) (\(detail(changed))).")
            }
            guard try readPackageState(package, run: run) == 3 else {
                throw Failure.message("Android did not retain the disabled state for home app \(package).")
            }
            disabled.insert(package)
            log("Disabled Android HOME package \(package); original enabled state \(before) saved.")
        }

        // Requery the actual enabled resolver list; an exit code alone does not prove HOME removal.
        let remainingHomes = try readHomes(command: enabledHomesCommand, run: run)
        try validateProtectedHomes(remainingHomes)
        let remainingDesktops = remainingHomes.filter { !allowedCoreHomes.contains($0) }
        guard remainingDesktops.isEmpty else {
            throw Failure.message("Android still has an enabled home app: \(remainingDesktops.sorted().joined(separator: ", ")).")
        }

        let restoreChrome = try enforceChrome(run: run, saveChromeOriginal: saveChromeOriginal, log: log)
        return Report(homePackages: homePackages, disabledPackages: disabled,
            residualHomeComponents: remainingHomes, chromeDisabledVerified: true,
            chromeRestoreCommand: restoreChrome)
    }

    /// Reapply after detecting a new system_server instance, before exposing its next window.
    /// Package disabled states persist across that restart; the service-owned Binder token does not.
    static func enforceChrome(run: Run, saveChromeOriginal: (String) throws -> Void,
                              log: (String) -> Void = { _ in }) throws -> String {
        let beforeChrome = try readChrome(run: run)
        let restoreChrome = try restoreChromeCommand(snapshot: beforeChrome)
        try saveChromeOriginal(beforeChrome)
        let changedChrome = try run(chromeDisableCommand, 15)
        guard changedChrome.status == 0,
              changedChrome.out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Failure.message("Android did not accept the app-only system controls (\(detail(changedChrome))).")
        }
        let afterChrome = try readChrome(run: run)
        guard chromeIsDisabled(afterChrome) else {
            throw Failure.message("Android did not confirm that Home, Overview and status controls are disabled.")
        }
        // A previously open notification shade is not closed merely by disabling future expansion.
        let collapsed = try run("cmd statusbar collapse", 10)
        guard collapsed.status == 0, collapsed.out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Failure.message("Android could not close its notification panel (\(detail(collapsed))).")
        }
        log("App-only controls verified; Android system bar insets remain for the host renderer to remove.")
        return restoreChrome
    }

    static func homeComponents(_ output: String) -> Set<String>? {
        let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if text == "No activities found" { return [] }
        let lines = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        guard !lines.isEmpty, lines.allSatisfy({ line in
            line.range(of: #"^[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z_][A-Za-z0-9_]*)*/\.?[A-Za-z_$][A-Za-z0-9_$]*(\.[A-Za-z_$][A-Za-z0-9_$]*)*$"#,
                       options: .regularExpression) != nil
        }) else { return nil }
        return Set(lines)
    }

    static func enabledState(_ output: String) -> Int? {
        let users = output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("User 0:") }
        guard users.count == 1,
              let state = capture(#"(?:^|\s)enabled=([0-4])(?:\s|$)"#, in: users[0]) else { return nil }
        return Int(state)
    }

    static func chromeIsDisabled(_ output: String) -> Bool {
        guard let state = chromeState(output), state.currentUser == 0,
              (try? restoreChromeCommand(snapshot: output)) == chromeDisableCommand else { return false }
        return state.mask1 & chromeMask1 == chromeMask1 && state.mask2 & chromeMask2 == chromeMask2
    }

    /// Only restore this shell command's token, never aggregate flags owned by keyguard or another app.
    static func restoreChromeCommand(snapshot: String) throws -> String {
        guard let state = chromeState(snapshot), state.currentUser == 0 else {
            throw Failure.message("Android did not provide a valid status-control snapshot for user 0.")
        }
        let records = snapshot.split(separator: "\n").map(String.init).filter {
            $0.contains("StatusBarShellCommand$StatusBarShellCommandToken")
                && capture(#"(?:^|\s)userId=(\d+)"#, in: $0) == "0"
        }
        guard records.count <= 1 else { throw Failure.message("Android reported ambiguous shell status-control records.") }
        var mask1: UInt32 = 0, mask2: UInt32 = 0
        if let record = records.first {
            guard let first = capture(#"(?:^|\s)what1=0x([0-9a-fA-F]+)"#, in: record).flatMap({ UInt32($0, radix: 16) }),
                  let second = capture(#"(?:^|\s)what2=0x([0-9a-fA-F]+)"#, in: record).flatMap({ UInt32($0, radix: 16) }),
                  first & ~chromeMask1 == 0, second & ~chromeMask2 == 0 else {
                throw Failure.message("The existing shell status controls cannot be safely restored by this Android command.")
            }
            mask1 = first; mask2 = second
        }
        let flags = chromeFlags.filter { (mask1 & $0.mask1 != 0) || (mask2 & $0.mask2 != 0) }.map(\.name)
        return "cmd statusbar send-disable-flag" + (flags.isEmpty ? "" : " " + flags.joined(separator: " "))
    }

    private struct ChromeState { let mask1: UInt32; let mask2: UInt32; let currentUser: Int }
    private static func chromeState(_ output: String) -> ChromeState? {
        var display: Int?
        var first: [UInt32] = [], second: [UInt32] = [], users: [Int] = []
        for raw in output.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if let value = capture(#"^displayId=(\d+)$"#, in: line) { display = Int(value) }
            else if let value = capture(#"^mCurrentUserId=(\d+)$"#, in: line), let user = Int(value) { users.append(user) }
            else if display == 0, let hex = capture(#"^mDisabled1=0x([0-9a-fA-F]+)$"#, in: line), let value = UInt32(hex, radix: 16) { first.append(value) }
            else if display == 0, let hex = capture(#"^mDisabled2=0x([0-9a-fA-F]+)$"#, in: line), let value = UInt32(hex, radix: 16) { second.append(value) }
        }
        guard first.count == 1, second.count == 1, users.count == 1 else { return nil }
        return ChromeState(mask1: first[0], mask2: second[0], currentUser: users[0])
    }

    private static func readChrome(run: Run) throws -> String {
        let result = try run(chromeReadCommand, 15)
        guard result.status == 0, let state = chromeState(result.out), state.currentUser == 0 else {
            throw Failure.message("Android's status controls are unavailable (\(detail(result))).")
        }
        return result.out
    }

    private static func readHomes(command: String, run: Run) throws -> Set<String> {
        let result = try run(command, 20)
        guard result.status == 0, let components = homeComponents(result.out) else {
            throw Failure.message("Android could not verify its home activities (\(detail(result))).")
        }
        return components
    }

    private static func readPackageState(_ package: String, run: Run) throws -> Int {
        let result = try run(packageStateCommand(package), 15)
        guard result.status == 0, let state = enabledState(result.out) else {
            throw Failure.message("Android could not read the original state of \(package) (\(detail(result))).")
        }
        return state
    }

    private static func validateProtectedHomes(_ components: Set<String>) throws {
        let unsupported = components.filter { protectedPackages.contains(packageOf($0)) && !allowedCoreHomes.contains($0) }
        guard unsupported.isEmpty else {
            throw Failure.message("Android exposed an unsupported core home activity; core permission and system services were kept intact: \(unsupported.sorted().joined(separator: ", ")).")
        }
    }

    private static func packageOf(_ component: String) -> String { String(component.split(separator: "/", maxSplits: 1)[0]) }
    private static func validPackage(_ package: String) -> Bool {
        package.range(of: #"^[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z_][A-Za-z0-9_]*)*$"#, options: .regularExpression) != nil
    }
    private static func capture(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }
    private static func detail(_ result: (out: String, status: Int)) -> String {
        "exit \(result.status): " + result.out.replacingOccurrences(of: "\n", with: " | ").prefix(240)
    }
}
