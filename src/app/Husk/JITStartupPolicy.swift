// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// A host's CS_DEBUGGED flag does not establish that our JIT script is serving
/// traps. Opening the native library must not probe that debugger.
enum JITStartupPolicy {
    static func isHosted(environment: [String: String]) -> Bool {
        environment["LC_HOME_PATH"] != nil || environment["LP_HOME_PATH"] != nil
    }

    static func permitsPreparation(isHosted: Bool, runtimeRequested: Bool,
                                   explicitJITRequested: Bool, automaticStart: Bool) -> Bool {
        !isHosted || runtimeRequested || explicitJITRequested || automaticStart
    }
}

/// Kept only in this process: a StikDebug foreground handoff retains the user's
/// request, but an unrelated cold launch must never inherit it.
struct JITPreparationIntent {
    private(set) var pending = false
    private var externalHandoff = false

    mutating func request() { pending = true; externalHandoff = false }
    mutating func handedOff() { externalHandoff = pending }
    mutating func cancel() { pending = false; externalHandoff = false }
    mutating func consume() { cancel() }

    mutating func returnedToForeground(hasJIT: Bool) {
        guard externalHandoff else { return }
        externalHandoff = false
        // Cancel/back in the other app must not arm a later passive opening.
        if !hasJIT { cancel() }
    }
}
