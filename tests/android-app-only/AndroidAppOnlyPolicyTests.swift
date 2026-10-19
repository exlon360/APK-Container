// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

@main
enum AndroidAppOnlyPolicyTests {
    typealias P = AndroidAppOnlyPolicy
    static let launcher = "com.android.launcher3"
    static let target = "com.example.app"
    static let home = launcher + "/.Launcher"
    static let fallback = "com.android.settings/.FallbackHome"

    static func state(_ enabled: Int, user: Int = 0) -> String {
        "  User \(user): ceDataInode=234 installed=true hidden=false suspended=false stopped=false enabled=\(enabled) instant=false"
    }

    // Exact package-state payload reported by the user; the second User 0:
    // comes from a separate shared-user permission section in dumpsys package.
    static let reportedDeviceLockState = """
    User 0: ceDatalnode=426469 deDatalnode=33254 installed=true hidden=false suspended=false distractionFlags=0 stopped=false notLaunched=false enabled=2 instant=false virtual=false quarantined=false
    User 0:
    """

    static func chrome(mask1: UInt32 = 0, mask2: UInt32 = 0, user: Int = 0,
                       shell1: UInt32? = nil, shell2: UInt32 = 0) -> String {
        var result = "  displayId=0\n    mDisabled1=0x\(String(mask1, radix: 16))\n    mDisabled2=0x\(String(mask2, radix: 16))\n  mCurrentUserId=\(user)\n"
        if let shell1 {
            result += "    [0] userId=0 what1=0x\(String(shell1, radix: 16)) what2=0x\(String(shell2, radix: 16)) pkg=android token=com.android.server.statusbar.StatusBarShellCommand$StatusBarShellCommandToken@123\n"
        }
        return result
    }

    static let applied = chrome(mask1: P.chromeMask1, mask2: P.chromeMask2,
                                shell1: P.chromeMask1, shell2: P.chromeMask2)

    struct Step {
        let command: String
        let output: String
        var status = 0
        var fails = false
        init(_ command: String, _ output: String = "", status: Int = 0, fails: Bool = false) {
            self.command = command; self.output = output; self.status = status; self.fails = fails
        }
    }
    final class Mock {
        var steps: [Step]
        var journal: [String: Int] = [:]
        var chromeSnapshots: [String] = []
        var commands: [String] = []
        var failPackageSave = false
        var failChromeSave = false
        init(_ steps: [Step]) { self.steps = steps }
        func run(_ command: String, _ timeout: TimeInterval) throws -> (out: String, status: Int) {
            precondition(!steps.isEmpty, "Unexpected command: \(command)")
            let step = steps.removeFirst()
            precondition(step.command == command, "Expected \(step.command), got \(command)")
            precondition(!command.contains("uninstall") && !command.contains("pm clear")
                         && !command.contains("task lock") && !command.contains("policy_control"))
            if command == P.disableCommand(launcher) {
                precondition(journal[launcher] != nil, "Package state must be durable before mutation")
            }
            if command == P.chromeDisableCommand {
                precondition(!chromeSnapshots.isEmpty, "Chrome snapshot must be durable before mutation")
            }
            commands.append(command)
            if step.fails { throw NSError(domain: "bridge", code: 1) }
            return (step.output, step.status)
        }
        func prepare(requested: String? = target) throws -> P.Report {
            try P.prepare(requested: requested, run: run, saveOriginal: { package, state in
                if self.failPackageSave { throw NSError(domain: "disk-full", code: 2) }
                // The original state is never replaced by a policy-created state on a later run.
                if self.journal[package] == nil { self.journal[package] = state }
            }, saveChromeOriginal: { snapshot in
                if self.failChromeSave { throw NSError(domain: "disk-full", code: 3) }
                self.chromeSnapshots.append(snapshot)
            })
        }
        func finished() { precondition(steps.isEmpty, "Unused commands: \(steps.map(\.command))") }
    }

    static func chromeSteps(before: String = chrome()) -> [Step] {
        [Step(P.chromeReadCommand, before), Step(P.chromeDisableCommand),
         Step(P.chromeReadCommand, applied), Step("cmd statusbar collapse")]
    }

    static func expectFailure(_ mock: Mock, contains: String? = nil, requested: String? = target) {
        do { _ = try mock.prepare(requested: requested); preconditionFailure("Expected failure") }
        catch {
            if let contains { precondition(error.localizedDescription.contains(contains), "Wrong failure: \(error)") }
        }
        mock.finished()
    }

    static func journalChecks() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("apk-container-journal-test-" + UUID().uuidString)
        try manager.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? manager.removeItem(at: root) }
        let guest = root.appendingPathComponent("guest-data.fixture")
        let originalGuest = Data("Unchanged guest image fixture".utf8)
        try originalGuest.write(to: guest)
        let directory = root.appendingPathComponent("originals")
        let journal = try AndroidPolicyRestoreJournal(directory: directory, guestPath: guest.path)
        try journal.saveOriginal(package: launcher, state: 0)
        try journal.saveOriginal(package: launcher, state: 3)
        try journal.saveOriginal(package: "com.example.otherhome", state: 1)
        let first = chrome()
        let second = chrome(mask1: 0x00200000, shell1: 0x00200000)
        try journal.saveChromeOriginal(first)
        try journal.saveChromeOriginal(second)
        try journal.saveChromeOriginal(second)
        try journal.saveChromeOriginal(first)
        let files = try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        precondition(files.count == 1)
        let file = files[0]
        let data = try Data(contentsOf: file)
        let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let packages = object["packages"] as! [String: Int]
        precondition(packages[launcher] == 0 && packages["com.example.otherhome"] == 1,
                     "Preserve the first original state across repeated policy runs")
        let commands = object["packageRestoreCommands"] as! [String: String]
        precondition(commands[launcher] == "pm default-state --user 0 '\(launcher)'")
        precondition(commands["com.example.otherhome"] == "pm enable --user 0 'com.example.otherhome'")
        let snapshots = object["chrome"] as! [[String: Any]]
        precondition(snapshots.map { $0["snapshot"] as! String } == [first, second, first],
                     "Keep chronological originals, coalescing only consecutive duplicates")
        precondition(snapshots.map { $0["restoreCommand"] as! String } == [
            "cmd statusbar send-disable-flag", "cmd statusbar send-disable-flag home", "cmd statusbar send-disable-flag"])
        precondition(object["guestPath"] as? String == guest.path)
        let directoryMode = try manager.attributesOfItem(atPath: directory.path)[.posixPermissions] as! NSNumber
        let fileMode = try manager.attributesOfItem(atPath: file.path)[.posixPermissions] as! NSNumber
        precondition(directoryMode.intValue & 0o777 == 0o700 && fileMode.intValue & 0o777 == 0o600)
        let unchangedGuest = try Data(contentsOf: guest)
        precondition(unchangedGuest == originalGuest)
        // A corrupt existing backup must block the next change, never be discarded and replaced.
        for corrupt in [Data("invalid json".utf8), Data("{\"packages\":{}}".utf8)] {
            try corrupt.write(to: file)
            do { try journal.saveOriginal(package: "com.example.newhome", state: 1); preconditionFailure("Corrupt journal accepted") }
            catch {}
            let preservedCorruptData = try Data(contentsOf: file)
            precondition(preservedCorruptData == corrupt)
        }
    }

    static func main() throws {
        try journalChecks()
        precondition(P.homeComponents("No activities found") == [])
        precondition(P.homeComponents(home + "\n" + fallback) == [home, fallback])
        for invalid in ["", "Error: missing service", home + "; reboot", home + "\nnot a component"] {
            precondition(P.homeComponents(invalid) == nil)
        }
        precondition(P.enabledState(state(0)) == 0)
        precondition(P.enabledState(state(1) + "\n" + state(3, user: 10)) == 1)
        precondition(P.enabledState(state(1) + "\n" + state(0)) == nil)
        precondition(P.enabledState(state(5)) == nil)
        precondition(P.enabledState("enabled=1") == nil)
        precondition(P.enabledState(reportedDeviceLockState) == 2)
        for enabled in 0...4 {
            let withHeadings = "  User 0:  \r\n" + state(enabled) + "\r\n\tUser 0:\t\r\n"
            precondition(P.enabledState(withHeadings) == enabled)
        }
        for invalid in ["User 0:", "User 0:\n  User 0:",
                        state(2) + "\nUser 0: installed=true",
                        state(2) + "\n" + state(2),
                        state(2) + " enabled=3", state(2) + " enabled=invalid",
                        "User 0: enabled=20", "User 0: enabled=", "User 0: enabled=invalid",
                        "User 0: enabled=+2", "User 0: enabled=02"] {
            precondition(P.enabledState(invalid) == nil, "Ambiguous or malformed state accepted: \(invalid)")
        }

        // Never take another display's aggregate flags or a transient app's flags as our policy.
        precondition(P.chromeIsDisabled(applied))
        precondition(!P.chromeIsDisabled(chrome(mask1: P.chromeMask1, mask2: P.chromeMask2)))
        precondition(!P.chromeIsDisabled(applied.replacingOccurrences(of: "displayId=0", with: "displayId=1")))
        precondition(!P.chromeIsDisabled(applied.replacingOccurrences(of: "mCurrentUserId=0", with: "mCurrentUserId=10")))
        let otherDisplay = chrome() + applied.replacingOccurrences(of: "displayId=0", with: "displayId=1")
        precondition(!P.chromeIsDisabled(otherDisplay))
        let partial = chrome(mask1: P.chromeMask1, mask2: 0, shell1: P.chromeMask1)
        precondition(!P.chromeIsDisabled(partial))
        let restoreDefault = try P.restorePackageCommand(package: launcher, originalState: 0)
        let restoreEnabled = try P.restorePackageCommand(package: launcher, originalState: 1)
        precondition(restoreDefault == "pm default-state --user 0 '\(launcher)'")
        precondition(restoreEnabled == "pm enable --user 0 '\(launcher)'")
        do { _ = try P.restorePackageCommand(package: "x';reboot", originalState: 1); preconditionFailure() } catch {}
        let restoreChrome = try P.restoreChromeCommand(snapshot: chrome(shell1: 0x00200000, shell2: 1))
        precondition(restoreChrome == "cmd statusbar send-disable-flag home quick-settings")
        let aggregate = try P.restoreChromeCommand(snapshot: chrome(mask1: P.chromeMask1, mask2: P.chromeMask2))
        precondition(aggregate == "cmd statusbar send-disable-flag", "Do not restore another app's flags under our token")

        // Already launcher-free runtimes work; no launcher is installed or invoked.
        let empty = Mock([Step(P.allHomesCommand, "No activities found"),
                          Step(P.enabledHomesCommand, "No activities found"),
                          Step(P.enabledHomesCommand, "No activities found")] + chromeSteps())
        let emptyReport = try empty.prepare()
        precondition(emptyReport.homePackages.isEmpty && emptyReport.chromeDisabledVerified)
        precondition(empty.journal.isEmpty); empty.finished()

        // Real policy pipeline: record original exact enabled state, disable and read it back,
        // then verify resolver removal. Settings/FallbackHome remains so Android can boot safely.
        for original in [0, 1] {
            let mock = Mock([Step(P.allHomesCommand, home + "\n" + fallback),
                             Step(P.enabledHomesCommand, home + "\n" + fallback),
                             Step(P.packageStateCommand(launcher), state(original) + "\nUser 0:"),
                             Step(P.disableCommand(launcher), "Package \(launcher) new state: disabled-user"),
                             Step(P.packageStateCommand(launcher), state(3) + "\nUser 0:"),
                             Step(P.enabledHomesCommand, fallback)] + chromeSteps())
            let report = try mock.prepare()
            precondition(mock.journal[launcher] == original)
            precondition(report.homePackages == [launcher, "com.android.settings"])
            precondition(report.disabledPackages == [launcher] && report.residualHomeComponents == [fallback])
            precondition(!mock.commands.contains(where: { $0.contains("disable-user") && $0.contains("com.android.settings") }))
            mock.finished()
        }

        // The reported DeviceLock HOME component is already disabled. Its extra
        // permission heading must not block preparing a normal APK or mutate that package.
        let deviceLock = "com.android.devicelockcontroller"
        let deviceLockHome = deviceLock + "/.activities.LockedHomeActivity"
        let withDeviceLock = Mock([
            Step(P.allHomesCommand, deviceLockHome + "\n" + home + "\n" + fallback),
            Step(P.enabledHomesCommand, home + "\n" + fallback),
            Step(P.packageStateCommand(deviceLock), reportedDeviceLockState),
            Step(P.packageStateCommand(launcher), state(0) + "\nUser 0:"),
            Step(P.disableCommand(launcher), "Package \(launcher) new state: disabled-user"),
            Step(P.packageStateCommand(launcher), state(3) + "\nUser 0:"),
            Step(P.enabledHomesCommand, fallback)] + chromeSteps())
        let deviceLockReport = try withDeviceLock.prepare()
        precondition(deviceLockReport.disabledPackages == [deviceLock, launcher])
        precondition(deviceLockReport.chromeDisabledVerified)
        precondition(withDeviceLock.journal == [launcher: 0])
        precondition(!withDeviceLock.commands.contains(P.disableCommand(deviceLock)))
        withDeviceLock.finished()

        // A real conflicting state still blocks before any package or chrome mutation.
        let conflictingState = Mock([
            Step(P.allHomesCommand, home), Step(P.enabledHomesCommand, home),
            Step(P.packageStateCommand(launcher), state(0) + "\nUser 0:\n" + state(3))])
        expectFailure(conflictingState, contains: "could not read the original state")
        precondition(conflictingState.journal.isEmpty && conflictingState.chromeSnapshots.isEmpty)

        // The persisted disabled package remains in MATCH_DISABLED_COMPONENTS inventory, but a
        // repeat run must not replace its pre-policy original setting with disabled-user.
        let repeated = Mock([Step(P.allHomesCommand, home), Step(P.enabledHomesCommand, "No activities found"),
                             Step(P.packageStateCommand(launcher), state(3)),
                             Step(P.enabledHomesCommand, "No activities found")] + chromeSteps(before: applied))
        repeated.journal[launcher] = 0
        _ = try repeated.prepare()
        precondition(repeated.journal[launcher] == 0)
        precondition(!repeated.commands.contains(P.disableCommand(launcher))); repeated.finished()

        // A requested APK that also declares HOME is rejected before any package/chrome mutation.
        expectFailure(Mock([Step(P.allHomesCommand, target + "/.Home")]), contains: "home apps")
        for protected in ["com.android.systemui/.Home", "android/.Home", "com.android.settings/.MainHome",
                          "com.android.documentsui/.Home", "com.android.permissioncontroller/.Home"] {
            let mock = Mock([Step(P.allHomesCommand, protected), Step(P.enabledHomesCommand, protected)])
            expectFailure(mock, contains: "core home activity")
            precondition(mock.journal.isEmpty)
        }

        // Failed enumeration cannot silently fall back to desktop access.
        for step in [Step(P.allHomesCommand, "No activities found", status: 20),
                     Step(P.allHomesCommand, ""), Step(P.allHomesCommand, "", fails: true)] {
            expectFailure(Mock([step]))
        }
        let unsafeState = Mock([Step(P.allHomesCommand, home), Step(P.enabledHomesCommand, home),
                                Step(P.packageStateCommand(launcher), "missing User 0")])
        expectFailure(unsafeState, contains: "original state")
        precondition(unsafeState.journal.isEmpty)

        let noLedger = Mock([Step(P.allHomesCommand, home), Step(P.enabledHomesCommand, home),
                             Step(P.packageStateCommand(launcher), state(0))])
        noLedger.failPackageSave = true
        expectFailure(noLedger)
        precondition(!noLedger.commands.contains(P.disableCommand(launcher)))

        let rejected = Mock([Step(P.allHomesCommand, home), Step(P.enabledHomesCommand, home),
                             Step(P.packageStateCommand(launcher), state(0)),
                             Step(P.disableCommand(launcher), "Security exception: protected package", status: 1)])
        expectFailure(rejected, contains: "could not disable")
        precondition(rejected.journal[launcher] == 0, "Failed changes still have a restore record")
        let noChange = Mock([Step(P.allHomesCommand, home), Step(P.enabledHomesCommand, home),
                             Step(P.packageStateCommand(launcher), state(0)),
                             Step(P.disableCommand(launcher), "Package \(launcher) new state: disabled-user"),
                             Step(P.packageStateCommand(launcher), state(0))])
        expectFailure(noChange, contains: "did not retain")

        let residual = Mock([Step(P.allHomesCommand, home), Step(P.enabledHomesCommand, home),
                             Step(P.packageStateCommand(launcher), state(3)), Step(P.enabledHomesCommand, home)])
        expectFailure(residual, contains: "still has an enabled home")

        let base = [Step(P.allHomesCommand, "No activities found"),
                    Step(P.enabledHomesCommand, "No activities found"),
                    Step(P.enabledHomesCommand, "No activities found")]
        let noChromeLedger = Mock(base + [Step(P.chromeReadCommand, chrome())])
        noChromeLedger.failChromeSave = true
        expectFailure(noChromeLedger)
        precondition(!noChromeLedger.commands.contains(P.chromeDisableCommand))
        let failedChrome = Mock(base + [Step(P.chromeReadCommand, chrome()),
                                       Step(P.chromeDisableCommand, "Unknown command", status: 1)])
        expectFailure(failedChrome, contains: "did not accept")
        let ineffectiveChrome = Mock(base + [Step(P.chromeReadCommand, chrome()), Step(P.chromeDisableCommand),
                                            Step(P.chromeReadCommand, partial)])
        expectFailure(ineffectiveChrome, contains: "did not confirm")
        let unsupportedOriginal = Mock(base + [Step(P.chromeReadCommand, chrome(shell1: 0x00400000))])
        expectFailure(unsupportedOriginal, contains: "cannot be safely restored")
        precondition(unsupportedOriginal.chromeSnapshots.isEmpty)
        // A framework restart loses only service-owned chrome flags; recovery need not query or
        // mutate package states again. This is the same method called by initial preparation.
        let restart = Mock(chromeSteps())
        let restored = try P.enforceChrome(run: restart.run, saveChromeOriginal: { restart.chromeSnapshots.append($0) })
        precondition(restored == "cmd statusbar send-disable-flag")
        precondition(restart.journal.isEmpty)
        restart.finished()
        print("App-only policy tests passed: durable pre-change state, persistent package disable/readback, core protection, requested-HOME rejection, no-data-deletion, resolver verification, stable chrome token and failures.")
    }
}
