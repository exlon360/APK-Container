// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// Apply Android UI density once at boot, before an APK is opened. The panel's
/// pixel budget and the size of text/buttons must change together.
enum RuntimeDisplayDensity {
    typealias Run = (String, TimeInterval) throws -> (out: String, status: Int)

    enum Failure: LocalizedError {
        case invalidTarget, invalidReport, rejected, notApplied
        var errorDescription: String? {
            switch self {
            case .invalidTarget: return "The requested Android density is outside the supported range."
            case .invalidReport: return "Android did not report a valid display density."
            case .rejected: return "Android rejected the display-density request."
            case .notApplied: return "Android did not apply the requested display density."
            }
        }
    }

    static func effectiveDensity(_ output: String) -> Int? {
        var physical: Int?
        var override: Int?
        for raw in output.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let pieces = line.split(separator: ":", maxSplits: 1)
            guard pieces.count == 2,
                  let value = Int(pieces[1].trimmingCharacters(in: .whitespaces)), value > 0 else { continue }
            if pieces[0] == "Physical density" { physical = value }
            if pieces[0] == "Override density" { override = value }
        }
        guard physical != nil else { return nil }
        return override ?? physical
    }

    /// Returns false when the existing density already matches. A successful
    /// shell exit alone is not enough: read the effective setting back.
    @discardableResult
    static func reconcile(target: Int, run: Run) throws -> Bool {
        guard (120...640).contains(target) else { throw Failure.invalidTarget }
        let before = try run("wm density", 20)
        guard before.status == 0, let current = effectiveDensity(before.out) else { throw Failure.invalidReport }
        if current == target { return false }
        let changed = try run("wm density \(target)", 20)
        guard changed.status == 0,
              changed.out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw Failure.rejected }
        let after = try run("wm density", 20)
        guard after.status == 0, effectiveDensity(after.out) == target else { throw Failure.notApplied }
        return true
    }
}
