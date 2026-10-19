import Foundation

@main struct AndroidPolicyEpochTests {
    typealias AP = AndroidAppPresentation
    typealias Guard = AndroidPolicyEpochGuard
    static let package = "com.example.app"

    static func focus(_ pid: Int) -> String {
        """
        APK_SYSTEM_SERVER_BEGIN=\(pid)
        WINDOW MANAGER DISPLAY CONTENTS (dumpsys window displays)
          Display: mDisplayId=0
          mCurrentFocus=Window{abc123 u0 com.example.app/.MainActivity}
          mFocusedApp=ActivityRecord{beef u0 com.example.app/.MainActivity t1}
        APK_SYSTEM_SERVER_END=\(pid)
        """
    }
    static let owner = """
    WINDOW MANAGER WINDOWS (dumpsys window windows)
      Window #0 Window{abc123 u0 com.example.app/.MainActivity}:
        mDisplayId=0
        mOwnerUid=10100 package=com.example.app
    """

    final class Bridge {
        var pids: [Int]
        var commands: [String] = []
        init(_ pids: [Int]) { self.pids = pids }
        func run(_ text: String, _ timeout: TimeInterval) throws -> AP.CommandResult {
            let divider = text.range(of: "; ")!
            let marker = String(text[text.index(text.startIndex, offsetBy: 5)..<divider.lowerBound])
            let command = String(text[divider.upperBound...])
            commands.append(command)
            let output: String
            if command == Guard.focusCommand {
                precondition(!pids.isEmpty)
                output = focus(pids.removeFirst())
            } else {
                precondition(command == AP.ownershipCommand)
                output = owner
            }
            return ("old output\n" + marker + "\n" + output, 0)
        }
    }

    /// Execute the production shell text with restricted-guest service fixtures.
    /// This catches shell status/newline bugs that mocked final strings cannot.
    static func shell(_ command: String, before: String = "733", after: String = "733",
                      beforeStatus: Int = 0, afterStatus: Int = 0,
                      displayStatus: Int = 0) throws -> AP.CommandResult {
        func quote(_ value: String) -> String {
            "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }
        let fixture = """
        apk_fixture_phase=before
        pidof() { return 1; }
        dumpsys() {
            if [ "$1" = "--pid" ] && [ "$2" = "window" ]; then
                if [ "$apk_fixture_phase" = "after" ]; then
                    printf '%s' \(quote(after)); return \(afterStatus)
                fi
                printf '%s' \(quote(before)); return \(beforeStatus)
            fi
            if [ "$1" = "window" ] && [ "$2" = "displays" ]; then
                apk_fixture_phase=after
                printf '%s' 'WINDOW MANAGER DISPLAY CONTENTS'
                return \(displayStatus)
            fi
            return 99
        }
        \(command)
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", fixture]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (String(decoding: output, as: UTF8.self), Int(process.terminationStatus))
    }

    static func restrictedShellChecks() throws {
        let procLookup = try shell("pidof system_server")
        precondition(procLookup.status == 1 && procLookup.out.isEmpty)
        let binderLookup = try shell(Guard.epochCommand)
        precondition(binderLookup.status == 0 && Guard.epoch(binderLookup.out) == 733,
                     "A healthy Binder service must work when /proc enumeration is unavailable")
        let prepared = Guard()
        _ = try prepared.prepare(readEpoch: {
            let result = try shell(Guard.epochCommand)
            return result.status == 0 ? Guard.epoch(result.out) : nil
        }, apply: {})
        let observed = try shell(Guard.focusCommand)
        precondition(observed.status == 0 && prepared.accepts(observed.out),
                     "Service output without final newlines must not merge epoch markers")
        for result in [try shell(Guard.focusCommand, beforeStatus: 1),
                       try shell(Guard.focusCommand, afterStatus: 1),
                       try shell(Guard.focusCommand, displayStatus: 1)] {
            precondition(result.status != 0, "Every subcommand failure must survive the final PID read")
        }
        for value in ["", "733\nservice warning", "Can't find service: window", "733 744"] {
            let bad = try shell(Guard.focusCommand, before: value)
            precondition(bad.status != 0 && Guard.epochInFocusReport(bad.out) == nil,
                         "Diagnostics or partial PID output must not authorize the display")
        }
        let restart = try shell(Guard.focusCommand, after: "744")
        precondition(restart.status == 0 && Guard.epochInFocusReport(restart.out) == nil)
        let unavailable = Guard()
        var mutations = 0
        do {
            _ = try unavailable.prepare(readEpoch: { nil }, apply: { mutations += 1 })
            preconditionFailure("Missing Binder PID should request startup recovery")
        } catch Guard.Failure.unavailable {}
        precondition(mutations == 0 && unavailable.preparedEpoch == nil && unavailable.needsPreparation)
        _ = try unavailable.prepare(readEpoch: { 733 }, apply: { mutations += 1 })
        precondition(mutations == 1 && unavailable.accepts(observed.out))
    }

    static func main() async throws {
        try restrictedShellChecks()
        precondition(Guard.epoch("123\n") == 123)
        for invalid in ["", "0", "-1", "12 34", "unavailable", "12junk"] {
            precondition(Guard.epoch(invalid) == nil)
        }
        precondition(Guard.epochInFocusReport(focus(123)) == 123)
        precondition(Guard.epochInFocusReport(focus(123) + "\nAPK_SYSTEM_SERVER_BEGIN=123") == nil)
        precondition(Guard.epochInFocusReport(focus(123).replacingOccurrences(of: "END=123", with: "END=124")) == nil)
        precondition(Guard.epochInFocusReport("WINDOW MANAGER DISPLAY CONTENTS") == nil)

        let stable = Guard()
        var preparations = 0
        _ = try stable.prepare(readEpoch: { 100 }, apply: { preparations += 1 })
        precondition(stable.accepts(focus(100)) && !stable.needsPreparation)
        precondition(preparations == 1)
        precondition(!stable.accepts(focus(200)) && stable.needsPreparation)
        precondition(preparations == 1, "An observation may schedule recovery but must not mutate before the cover")
        _ = try stable.prepare(readEpoch: { 200 }, apply: { preparations += 1 })
        precondition(stable.accepts(focus(200)) && preparations == 2)

        let raced = Guard()
        var reads = 0
        do {
            _ = try raced.prepare(readEpoch: { reads += 1; return reads == 1 ? 100 : 200 }, apply: {})
            preconditionFailure("A restart during policy preparation must remain untrusted")
        } catch Guard.Failure.restarted {}
        precondition(raced.preparedEpoch == nil && raced.needsPreparation)
        _ = try raced.prepare(readEpoch: { 200 }, apply: {})
        precondition(raced.accepts(focus(200)))

        // The production monitor must deliver covered BEFORE the next probe reapplies policy.
        // Even a restart fully between successful reads is detected. Owner/insets are then freshly checked.
        let gate = Guard()
        _ = try gate.prepare(readEpoch: { 100 }, apply: {})
        let bridge = Bridge([100, 200, 200])
        var events: [String] = []
        var visibleCount = 0
        var cancelled = false
        var displayChecks = 0
        let probe = AP.Probe(validateDisplay: { _ in displayChecks += 1; return true }, policyEpoch: gate, restorePolicy: {
            precondition(events.last == "covered", "Policy mutation preceded the native cover")
            events.append("prepare")
            _ = try gate.prepare(readEpoch: { 200 }, apply: {})
        })
        do {
            try await AP.monitor(requested: package, session: .init(homePackages: [], homesVerified: true),
                installedPackages: [package], allowSettings: false,
                read: { try probe.observe(run: bridge.run) }, now: { 0 }, pause: { _ in },
                cancelled: { cancelled }, event: { event in
                    switch event {
                    case .visible:
                        events.append("visible")
                        visibleCount += 1
                        if visibleCount == 2 { cancelled = true }
                    case .covered: events.append("covered")
                    case .homeBlocked, .unavailable: preconditionFailure("Unexpected recovery notification")
                    }
                })
            preconditionFailure("Expected cancellation")
        } catch is CancellationError {}
        precondition(events == ["visible", "covered", "prepare", "visible"])
        precondition(displayChecks == 2, "Untrusted epoch must never supply display geometry")
        precondition(bridge.commands.filter { $0 == AP.ownershipCommand }.count == 2)
        precondition(bridge.pids.isEmpty)

        // Failure while restoring leaves the policy gate pending; no fresh focus can become visible.
        let failed = Guard()
        _ = try failed.prepare(readEpoch: { 100 }, apply: {})
        let failBridge = Bridge([200])
        var attempted = 0
        let failingProbe = AP.Probe(policyEpoch: failed, restorePolicy: {
            attempted += 1
            throw Guard.Failure.unavailable
        })
        let denied = try failingProbe.observe(run: failBridge.run)
        precondition(denied.state == .readFailure)
        do { _ = try failingProbe.observe(run: failBridge.run); preconditionFailure("Expected restore failure") }
        catch Guard.Failure.unavailable {}
        precondition(attempted == 1 && failed.needsPreparation && failBridge.commands.count == 1)

        // The checked host closure can cancel a pending restore before any follow-up shell command.
        let cancelProbe = AP.Probe(policyEpoch: failed, restorePolicy: { throw CancellationError() })
        do { _ = try cancelProbe.observe(run: failBridge.run); preconditionFailure("Expected cancellation") }
        catch is CancellationError {}
        precondition(failBridge.commands.count == 1)
        print("Android policy epoch tests passed: restricted-proc Binder lookup, shell status/newline validation, stable startup, restart between polls, cover-before-restore, fresh display/owner checks, failure and cancellation.")
    }
}
