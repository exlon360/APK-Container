// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// A status-bar shell token belongs to system_server. Reapply it after that process
/// changes, including a restart that completes between otherwise successful focus polls.
/// One guard belongs to one serial presentation task, never shared between requests.
final class AndroidPolicyEpochGuard {
    // The guest's init-spawned shell does not necessarily inherit adbd's readproc
    // group. pidof can therefore report nothing while system_server is healthy.
    // Binder DEBUG_PID_TRANSACTION asks the window service for its own PID and
    // needs neither /proc access nor a full service dump.
    static let epochCommand = "dumpsys --pid window"
    static let beginMarker = "APK_SYSTEM_SERVER_BEGIN="
    static let endMarker = "APK_SYSTEM_SERVER_END="
    static let focusCommand = epochRead(variable: "apk_policy_before", marker: beginMarker)
        + "dumpsys window displays; apk_policy_display_status=$?; "
        + epochRead(variable: "apk_policy_after", marker: endMarker)
        + "[ \"$apk_policy_before_status\" -eq 0 ] && "
        + "[ \"$apk_policy_display_status\" -eq 0 ] && "
        + "[ \"$apk_policy_after_status\" -eq 0 ]"

    /// Keep each marker on its own line even when a service omits a trailing
    /// newline, and retain failure from every command, not just the last one.
    /// Reject diagnostic/multiline output instead of treating its first PID as
    /// authority. A failed observation remains covered and can be retried.
    private static func epochRead(variable: String, marker: String) -> String {
        "\(variable)=$(\(epochCommand) 2>&1); \(variable)_status=$?; "
            + "case \"$\(variable)\" in ''|*[!0-9]*) \(variable)=; \(variable)_status=1;; esac; "
            + "printf '\\n\(marker)%s\\n' \"$\(variable)\"; "
    }

    private(set) var preparedEpoch: Int?
    private(set) var needsPreparation = false

    enum Failure: LocalizedError {
        case unavailable, restarted
        var errorDescription: String? {
            switch self {
            case .unavailable: return "Android's system service is restarting."
            case .restarted: return "Android restarted while restoring app-only controls."
            }
        }
    }

    static func epoch(_ output: String) -> Int? {
        let value = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.allSatisfy({ $0.isASCII && $0.isNumber }),
              let pid = Int(value), pid > 0 else { return nil }
        return pid
    }

    static func epochInFocusReport(_ report: String) -> Int? {
        let lines = report.split(separator: "\n").map(String.init)
        let first = lines.filter { $0.hasPrefix(beginMarker) }
        let last = lines.filter { $0.hasPrefix(endMarker) }
        guard first.count == 1, last.count == 1,
              let before = epoch(String(first[0].dropFirst(beginMarker.count))),
              let after = epoch(String(last[0].dropFirst(endMarker.count))), before == after else { return nil }
        return before
    }

    /// Verify that the policy was applied to the same server that is still running.
    /// A failed/mismatched preparation leaves the previous policy untrusted.
    @discardableResult
    func prepare<Value>(readEpoch: () throws -> Int?, apply: () throws -> Value) throws -> Value {
        needsPreparation = true
        preparedEpoch = nil
        guard let before = try readEpoch() else { throw Failure.unavailable }
        let value = try apply()
        guard let after = try readEpoch() else { throw Failure.unavailable }
        guard before == after else { throw Failure.restarted }
        preparedEpoch = after
        needsPreparation = false
        return value
    }

    /// This only schedules recovery. The caller must publish a covered observation
    /// before calling prepare on its next probe; mutations never precede that cover.
    func accepts(_ focusReport: String) -> Bool {
        guard let observed = Self.epochInFocusReport(focusReport) else { return false }
        guard observed == preparedEpoch, !needsPreparation else {
            needsPreparation = true
            return false
        }
        return true
    }
}
