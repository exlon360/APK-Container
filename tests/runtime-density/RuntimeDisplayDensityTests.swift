import Foundation

@main struct RuntimeDisplayDensityTests {
    static func main() throws {
        typealias D = RuntimeDisplayDensity
        precondition(D.effectiveDensity("Physical density: 160\n") == 160)
        precondition(D.effectiveDensity("Physical density: 160\nOverride density: 298\n") == 298)
        precondition(D.effectiveDensity("Can't find service: window") == nil)
        precondition(D.effectiveDensity("Override density: 298\n") == nil)
        precondition(D.effectiveDensity("Physical density: 0") == nil)

        var commands: [String] = []
        let changed = try D.reconcile(target: 298) { command, _ in
            commands.append(command)
            if commands.count == 1 { return ("Physical density: 160\n", 0) }
            if commands.count == 2 { return ("", 0) }
            return ("Physical density: 160\nOverride density: 298\n", 0)
        }
        precondition(changed && commands == ["wm density", "wm density 298", "wm density"])

        commands = []
        let unchanged = try D.reconcile(target: 298) { command, _ in
            commands.append(command)
            return ("Physical density: 160\nOverride density: 298", 0)
        }
        precondition(!unchanged && commands == ["wm density"])

        for (output, status) in [("Error: service unavailable", 0), ("", 1)] {
            var calls = 0
            do {
                _ = try D.reconcile(target: 200) { _, _ in
                    calls += 1
                    return calls == 1 ? ("Physical density: 160", 0) : (output, status)
                }
                preconditionFailure("Rejected changes must not pass")
            } catch D.Failure.rejected { precondition(calls == 2) }
        }
        var calls = 0
        do {
            _ = try D.reconcile(target: 200) { _, _ in
                calls += 1
                return calls == 2 ? ("", 0) : ("Physical density: 160", 0)
            }
            preconditionFailure("A silent no-op must fail verification")
        } catch D.Failure.notApplied { precondition(calls == 3) }
        do {
            _ = try D.reconcile(target: 200) { _, _ in ("Window service restarting", 0) }
            preconditionFailure("Missing density must not cause a blind write")
        } catch D.Failure.invalidReport {}
        do {
            _ = try D.reconcile(target: 0) { _, _ in preconditionFailure("Invalid input must not run a command") }
            preconditionFailure("Invalid target accepted")
        } catch D.Failure.invalidTarget {}
        print("Runtime density tests passed: readback, no-op, malformed response, rejection and validation.")
    }
}
