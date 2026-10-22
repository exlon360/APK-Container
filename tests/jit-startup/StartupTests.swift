import Foundation

@main struct StartupTests {
    @MainActor static func scenario(_ name: String, _ operation: () throws -> Void) throws {
        try Fixture.reset()
        try operation()
        print("PASS " + name)
    }
    @MainActor static func attached() {
        JITBootstrap.available = true
        JITBootstrap.debuggedFlag = true
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
    }
    @MainActor static func main() throws {
        for (name, environment, hosted) in [
            ("standalone", [:], false),
            ("LiveContainer", ["LC_HOME_PATH": "/fixture/lc"], true),
            ("LiveProcess", ["LP_HOME_PATH": "/fixture/lp"], true),
            ("both host markers", ["LC_HOME_PATH": "", "LP_HOME_PATH": ""], true)
        ] {
            precondition(JITStartupPolicy.isHosted(environment: environment) == hosted)
            for runtime in [false, true] {
                for manual in [false, true] {
                    for auto in [false, true] {
                        let allowed = JITStartupPolicy.permitsPreparation(isHosted: hosted,
                            runtimeRequested: runtime, explicitJITRequested: manual, automaticStart: auto)
                        if hosted && !runtime && !manual && !auto {
                            precondition(!allowed, "Passive launch/foreground may not probe hosted JIT")
                        } else { precondition(allowed, "An authorized runtime/JIT/autostart request was blocked") }
                    }
                }
            }
            print("PASS " + name + " passive, foreground, runtime, manual JIT and autostart policy")
        }

        var intent = JITPreparationIntent()
        precondition(!intent.pending)
        intent.request(); intent.handedOff(); intent.returnedToForeground(hasJIT: true)
        precondition(intent.pending, "Successful handoff lost explicit preparation intent")
        intent.consume(); intent.returnedToForeground(hasJIT: true)
        precondition(!intent.pending, "A consumed request was rearmed by foregrounding")
        intent.request(); intent.handedOff(); intent.returnedToForeground(hasJIT: false)
        precondition(!intent.pending, "Cancelled external handoff armed a later passive opening")
        intent.request(); intent.cancel(); intent.returnedToForeground(hasJIT: true)
        precondition(!intent.pending)
        intent.request(); intent.handedOff()
        precondition(!JITPreparationIntent().pending, "A new cold launch inherited process-only intent")
        print("PASS intent handoff, consumption, cancellation and cold-launch isolation")

        try scenario("hosted automatic setup never reads action-time ready or opens a helper") {
            JITBootstrap.isHosted = true
            JITBootstrap.isInstalledWithTrollStore = true
            Fixture.defaults.set(true, forKey: JITCoordinator.autoEnableKey)
            try Fixture.pair()
            let jit = JITCoordinator()
            jit.enableAtLaunchIfAsked(); jit.returnedToForeground(); jit.enableAtLaunchIfAsked()
            precondition(JITBootstrap.readyReads == 0 && JITBootstrap.attachRequests == 0 && JITBootstrap.trollStoreRequests == 0)
            precondition(HuskBuiltInJIT.requests == 0 && !jit.preparationRequested && !jit.busy)
        }
        try scenario("explicit Enable on an already debugged process signals preparation exactly once") {
            JITBootstrap.available = true
            let jit = JITCoordinator()
            jit.enable()
            precondition(jit.attachGeneration == 1 && jit.preparationRequested)
            precondition(HuskBuiltInJIT.requests == 0 && JITBootstrap.attachRequests == 0)
            jit.consumePreparationRequest(); jit.returnedToForeground()
            precondition(!jit.preparationRequested && jit.attachGeneration == 1)
            precondition(!JITCoordinator().preparationRequested)
        }
        try scenario("failed external attach clears intent; a later foreground cannot rearm it") {
            let jit = JITCoordinator(); jit.method = .stikDebug; jit.enable()
            precondition(!jit.preparationRequested && jit.error != nil && jit.showSetup)
            JITBootstrap.available = true; jit.returnedToForeground()
            precondition(!jit.preparationRequested && jit.attachGeneration == 0)
            JITBootstrap.available = false; jit.method = .trollStore; jit.enable()
            precondition(!jit.preparationRequested && jit.error != nil && !jit.busy)
        }
        try scenario("StikDebug foreground handoff preserves success and clears cancellation") {
            JITBootstrap.attachSucceeds = true
            let jit = JITCoordinator(); jit.method = .stikDebug; jit.enable()
            precondition(jit.preparationRequested)
            jit.returnedToForeground()
            precondition(!jit.preparationRequested)
            jit.enable(); JITBootstrap.available = true; jit.returnedToForeground()
            precondition(jit.preparationRequested)
            jit.consumePreparationRequest(); jit.returnedToForeground()
            precondition(!jit.preparationRequested)
        }
        try scenario("foregrounding during a busy TrollStore attachment retains intent until completion") {
            JITBootstrap.trollStoreSucceeds = true
            let jit = JITCoordinator(); jit.method = .trollStore; jit.enable()
            precondition(jit.busy && jit.preparationRequested)
            jit.returnedToForeground()
            precondition(jit.preparationRequested, "The foreground callback cancelled an in-flight attachment")
            attached()
            precondition(!jit.busy && jit.attachGeneration == 1 && jit.preparationRequested)
            jit.consumePreparationRequest()
            precondition(!jit.preparationRequested)
        }
        try scenario("StikDebug fallback to TrollStore waits through an early foreground callback") {
            JITBootstrap.attachSucceeds = false; JITBootstrap.trollStoreSucceeds = true
            let jit = JITCoordinator(); jit.method = .stikDebug; jit.enable()
            precondition(JITBootstrap.attachRequests == 1 && JITBootstrap.trollStoreRequests == 1)
            precondition(jit.busy && jit.preparationRequested, "TrollStore fallback did not begin its attachment wait")
            jit.returnedToForeground()
            precondition(jit.preparationRequested)
            attached()
            precondition(!jit.busy && jit.attachGeneration == 1 && jit.preparationRequested)
            jit.consumePreparationRequest()
        }
        try scenario("unavailable, unpaired and missing-script built-in setup clear intent") {
            let jit = JITCoordinator(); jit.method = .builtIn
            HuskBuiltInJIT.isAvailable = false; jit.enable()
            precondition(!jit.preparationRequested && !jit.busy)
            HuskBuiltInJIT.isAvailable = true; jit.enable()
            precondition(!jit.preparationRequested && !jit.busy)
            try Fixture.pair(); jit.refreshPairingStatus(); JITBootstrap.scriptBase64 = nil
            jit.enableBuiltIn()
            precondition(!jit.preparationRequested && !jit.busy && jit.error != nil)
            precondition(HuskBuiltInJIT.requests == 0)
        }
        try scenario("built-in helper rejection and transport failure clear explicit intent") {
            try Fixture.pair()
            let jit = JITCoordinator(); jit.method = .builtIn; jit.enable()
            precondition(jit.busy && jit.preparationRequested)
            HuskBuiltInJIT.completion?(.success(.init(success: false, message: "fixture rejection", txmPresent: true)))
            precondition(!jit.busy && !jit.preparationRequested && jit.error != nil)
            jit.enable()
            HuskBuiltInJIT.completion?(.failure(NSError(domain: "Fixture", code: 1)))
            precondition(!jit.busy && !jit.preparationRequested && jit.attachGeneration == 0)
        }
        try scenario("built-in success signals preparation; a late helper response cannot finish twice") {
            try Fixture.pair()
            let jit = JITCoordinator(); jit.method = .builtIn; jit.enable()
            jit.returnedToForeground()
            precondition(jit.busy && jit.preparationRequested)
            attached()
            precondition(!jit.busy && jit.attachGeneration == 1 && jit.preparationRequested)
            HuskBuiltInJIT.completion?(.success(.init(success: false, message: "late response", txmPresent: true)))
            precondition(jit.attachGeneration == 1 && jit.error == nil && jit.preparationRequested)
            jit.consumePreparationRequest()
            precondition(!jit.preparationRequested)
        }
        try scenario("standalone opt-in autostart still requests built-in JIT once") {
            try Fixture.pair(); Fixture.defaults.set(true, forKey: JITCoordinator.autoEnableKey)
            let jit = JITCoordinator(); jit.enableAtLaunchIfAsked()
            precondition(jit.busy && jit.preparationRequested && HuskBuiltInJIT.requests == 1)
            jit.enableAtLaunchIfAsked()
            precondition(HuskBuiltInJIT.requests == 1)
            HuskBuiltInJIT.completion?(.failure(NSError(domain: "Fixture", code: 2)))
            precondition(!jit.preparationRequested)
        }
    }
}
