// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

@main
struct AndroidAppPresentationTests {
    typealias AP = AndroidAppPresentation
    static let pkg = "com.example.app"
    static let ready = "Service package: found\nService activity: found\nService window: found"
    static let home = "com.android.launcher3/.Launcher"
    static let noHome = "No activities found"
    static let noEntry = "No activity found"
    static let main = "com.example.app/.MainActivity"
    static func resolve(_ category: String = "LAUNCHER") -> String {
        "cmd package resolve-activity --components --user 0 -a android.intent.action.MAIN -c android.intent.category.\(category) -p \(pkg)"
    }
    static func launch(_ component: String = main, category: String = "LAUNCHER") -> String {
        "am start -W --user 0 -a android.intent.action.MAIN -c android.intent.category.\(category) -n '\(component)'"
    }

    struct Step {
        let command: String
        let output: String
        var status = 0
        var missingMarker = false
        var cancelAfter = false
        var fail = false
        init(_ command: String, _ output: String, status: Int = 0, missingMarker: Bool = false,
             cancelAfter: Bool = false, fail: Bool = false) {
            self.command = command; self.output = output; self.status = status
            self.missingMarker = missingMarker; self.cancelAfter = cancelAfter; self.fail = fail
        }
    }
    final class MockBridge {
        var steps: [Step]
        var commands: [String] = []
        var cancelled = false
        var pauses = 0
        var logs: [String] = []
        init(_ steps: [Step]) {
            self.steps = steps.flatMap { step in
                step.command.hasPrefix("am start ")
                    ? [Step("input keyevent KEYCODE_WAKEUP", ""), Step("cmd statusbar collapse", ""),
                       Step("wm dismiss-keyguard", ""), step] : [step]
            }
        }
        func run(_ text: String, timeout: TimeInterval) throws -> AP.CommandResult {
            precondition(!steps.isEmpty, "Unexpected command: \(text)")
            let step = steps.removeFirst()
            let divider = text.range(of: "; ")!
            let marker = String(text[text.index(text.startIndex, offsetBy: 5)..<divider.lowerBound])
            let command = String(text[divider.upperBound...])
            precondition(command == step.command, "Expected \(step.command), got \(command)")
            precondition(!command.contains("monkey"))
            commands.append(command)
            if step.cancelAfter { cancelled = true }
            if step.fail { throw NSError(domain: "bridge", code: 1) }
            // A timed-out older command must not supply a component, success, or service result.
            let stale = "com.wrong.package/.Desktop\nStatus: ok\n\(ready)\n"
            return (step.missingMarker ? stale : stale + marker + "\n" + step.output, step.status)
        }
        func start(settings: Bool = false, prepare: ((AP.Session) throws -> AP.Session)? = nil) async throws -> AP.Session {
            try await AP.start(package: pkg, settings: settings, run: run,
                               cancelled: { self.cancelled }, pause: { self.pauses += 1 },
                               log: { self.logs.append($0) }, prepare: prepare)
        }
        func finished() { precondition(steps.isEmpty, "Unused mock commands: \(steps.map(\.command))") }
    }
    static func expectFailure(_ bridge: MockBridge, contains: String) async {
        do { _ = try await bridge.start(); preconditionFailure("Expected failure") }
        catch { precondition(error.localizedDescription.contains(contains), "Wrong failure: \(error)") }
        bridge.finished()
    }

    /// Format follows AOSP DisplayContent.dump and WindowState.dump, including arbitrary titles.
    static func windowReport(owner: String, title: String = "Application dialog", focus: String? = nil,
                             focusedApp: String = pkg + "/.MainActivity", windowDisplay: Int = 0) -> String {
        """
        WINDOW MANAGER DISPLAY CONTENTS (dumpsys window displays)
          Display: mDisplayId=0 (organized)
          mCurrentFocus=\(focus ?? "Window{abc123 u0 " + title + "}")
          mFocusedApp=ActivityRecord{beef u0 \(focusedApp) t7}
        WINDOW MANAGER WINDOWS (dumpsys window windows)
          Window #0 Window{abc123 u0 \(title)}:
            mDisplayId=\(windowDisplay) taskId=7 mSession=Session{abc 123:u0a137}
            mOwnerUid=10137 showForAllUsers=false package=\(owner) appop=NONE
        """
    }

    static func reportParts(_ report: String) -> (focus: String, owners: String) {
        let divider = report.range(of: "WINDOW MANAGER WINDOWS")!
        return (String(report[..<divider.lowerBound]), String(report[divider.lowerBound...]))
    }

    static func probeChecks() throws {
        let appReport = reportParts(windowReport(owner: pkg, title: "Arbitrary title without a slash"))
        let homeReport = reportParts(windowReport(owner: "com.example.home", title: "Home")
            .replacingOccurrences(of: "abc123", with: "def456"))
        let nullReport = reportParts(windowReport(owner: pkg, focus: "null"))
        let probe = AP.Probe()
        let bridge = MockBridge([
            Step(AP.focusCommand, appReport.focus), Step(AP.ownershipCommand, appReport.owners),
            // An unchanged WindowState needs one fresh focus read, not another full owner dump.
            Step(AP.focusCommand, appReport.focus), Step(AP.focusCommand, appReport.focus),
            // A different window must never inherit the previous app's verified ownership.
            Step(AP.focusCommand, homeReport.focus), Step(AP.ownershipCommand, homeReport.owners),
            Step(AP.focusCommand, nullReport.focus),
            // Even the same identity is revalidated after an intervening null focus.
            Step(AP.focusCommand, homeReport.focus), Step(AP.ownershipCommand, homeReport.owners),
        ])
        for expected in [pkg, pkg, pkg, "com.example.home", nil, "com.example.home"] as [String?] {
            let result = try probe.observe(run: bridge.run)
            precondition(result.package == expected)
        }
        bridge.finished()
        precondition(bridge.commands.filter { $0 == AP.ownershipCommand }.count == 3)

        // Activity changes can race the two dumps. Cover a mismatched pair, then recover using
        // a fresh matching pair; the failed ownership must never enter the cache.
        let raced = AP.Probe()
        let raceBridge = MockBridge([
            Step(AP.focusCommand, appReport.focus), Step(AP.ownershipCommand, homeReport.owners),
            Step(AP.focusCommand, homeReport.focus), Step(AP.ownershipCommand, homeReport.owners),
        ])
        let unmatched = try raced.observe(run: raceBridge.run)
        precondition(unmatched.state == .unrecognized)
        let matched = try raced.observe(run: raceBridge.run)
        precondition(matched.package == "com.example.home")
        raceBridge.finished()

        // Nonzero status, a malformed focus, and a thrown read all invalidate cached ownership.
        for badRead in [Step(AP.focusCommand, "Can't find service: window", status: 1),
                        Step(AP.focusCommand, "unrecognized display response"),
                        Step(AP.focusCommand, "", fail: true)] {
            let recovering = AP.Probe()
            let badBridge = MockBridge([
                Step(AP.focusCommand, appReport.focus), Step(AP.ownershipCommand, appReport.owners),
                badRead,
                Step(AP.focusCommand, appReport.focus), Step(AP.ownershipCommand, appReport.owners),
            ])
            let before = try recovering.observe(run: badBridge.run)
            precondition(before.package == pkg)
            do {
                let failed = try recovering.observe(run: badBridge.run)
                precondition(failed.package == nil)
                precondition(!badRead.fail)
            } catch { precondition(badRead.fail) }
            let after = try recovering.observe(run: badBridge.run)
            precondition(after.package == pkg)
            badBridge.finished()
        }

        let failedOwner = AP.Probe()
        let ownerBridge = MockBridge([
            Step(AP.focusCommand, appReport.focus), Step(AP.ownershipCommand, "service stopped", status: 1),
            Step(AP.focusCommand, appReport.focus), Step(AP.ownershipCommand, appReport.owners),
        ])
        let ownerFailure = try failedOwner.observe(run: ownerBridge.run)
        precondition(ownerFailure.state == .readFailure)
        let ownerRecovery = try failedOwner.observe(run: ownerBridge.run)
        precondition(ownerRecovery.package == pkg)
        ownerBridge.finished()

        let oneShot = MockBridge([Step(AP.focusCommand, appReport.focus), Step(AP.ownershipCommand, appReport.owners)])
        let observed = try AP.observe(run: oneShot.run)
        precondition(observed.package == pkg); oneShot.finished()

        // Insets must be verified on every dump, including an otherwise cached window owner.
        var validDisplay = true
        let validated = AP.Probe(validateDisplay: { _ in validDisplay })
        let displayBridge = MockBridge([
            Step(AP.focusCommand, appReport.focus), Step(AP.ownershipCommand, appReport.owners),
            Step(AP.focusCommand, appReport.focus),
            Step(AP.focusCommand, appReport.focus), Step(AP.ownershipCommand, appReport.owners),
        ])
        let initialDisplay = try validated.observe(run: displayBridge.run)
        precondition(initialDisplay.package == pkg)
        validDisplay = false
        let invalidDisplay = try validated.observe(run: displayBridge.run)
        precondition(invalidDisplay.state == .unrecognized)
        validDisplay = true
        let recoveredDisplay = try validated.observe(run: displayBridge.run)
        precondition(recoveredDisplay.package == pkg)
        displayBridge.finished()
    }

    final class Timeline {
        let observations: [AP.Observation]
        var time: TimeInterval = 0
        var events: [String] = []
        var visiblePackages: [String] = []
        var readCount = 0
        var cancel = false
        var cancelOnCover = false
        var throwFirstRead = false
        var homesVerified = true
        var cancelledAtEnd = false
        init(_ observations: [AP.Observation]) { self.observations = observations }
        func run() async throws {
            do {
                try await AP.monitor(requested: pkg, session: .init(homePackages: ["com.example.home"], homesVerified: homesVerified),
                    installedPackages: [pkg], allowSettings: false,
                    read: {
                        let index = self.readCount
                        self.readCount += 1
                        if self.throwFirstRead && index == 0 { throw NSError(domain: "bridge", code: 1) }
                        return self.observations[index]
                    }, now: { self.time }, pause: { self.time += $0 },
                    cancelled: { self.cancel || self.readCount >= self.observations.count }, event: { event in
                        switch event {
                        case .visible(let observation): self.events.append("visible"); self.visiblePackages.append(observation.package!)
                        case .covered: self.events.append("covered"); if self.cancelOnCover { self.cancel = true }
                        case .homeBlocked: self.events.append("homeBlocked")
                        case .unavailable: self.events.append("unavailable")
                        }
                    })
                preconditionFailure("A session must never end itself")
            } catch is CancellationError {
                cancelledAtEnd = true
            }
        }
    }

    static func foregroundChecks() async throws {
        let app = AP.observation(windowReport(owner: pkg, title: "AnkiDroid"))
        let home = AP.observation(windowReport(owner: "com.example.home", title: "Home"))
        let unknown = AP.observation(windowReport(owner: pkg, focus: "null"))
        let locked = AP.observation(windowReport(owner: "com.android.systemui", title: "NotificationShade"))
        precondition(app.package == pkg && app.diagnostic.contains("mOwnerUid="))
        precondition(locked.package == "com.android.systemui")
        precondition(AP.observation(windowReport(owner: pkg, windowDisplay: 1)).state == .unrecognized)
        precondition(AP.observation(windowReport(owner: pkg, focus: "Window{deadbeef u0 unrelated}")).state == .unrecognized)
        let mislabeled = AP.observation(windowReport(owner: "com.example.home", title: pkg + "/.MainActivity"))
        precondition(mislabeled.package == "com.example.home")
        let otherDisplay = windowReport(owner: pkg).replacingOccurrences(of: "WINDOW MANAGER WINDOWS", with:
            "  Display: mDisplayId=1\n  mCurrentFocus=Window{cafe u0 com.android.launcher3/.Launcher}\nWINDOW MANAGER WINDOWS")
        precondition(AP.observation(otherDisplay).package == pkg)
        let ambiguous = windowReport(owner: pkg) + "\n  Window #1 Window{abc123 u0 duplicate}:\n    mDisplayId=0\n    mOwnerUid=1000 package=com.android.systemui appop=NONE"
        precondition(AP.observation(ambiguous).state == .unrecognized)
        precondition(AP.observation(String(repeating: "bad response ", count: 1000)).diagnostic.count <= 700)
        try probeChecks()

        // A sentinel final observation lets cancellation occur only after all meaningful
        // input was consumed; returning on HOME or timeout fails inside Timeline.run().
        let sustained = Timeline([app] + Array(repeating: home, count: 45) + [app, app])
        try await sustained.run()
        precondition(sustained.cancelledAtEnd && sustained.visiblePackages == [pkg, pkg])
        precondition(sustained.events.filter { $0 == "homeBlocked" }.count == 1)
        precondition(sustained.events.filter { $0 == "unavailable" }.count == 1)
        let outage = Timeline([app] + Array(repeating: unknown, count: 45) + [app, app])
        try await outage.run()
        precondition(outage.visiblePackages == [pkg, pkg] && outage.events.contains("unavailable"))
        precondition(!outage.events.contains("homeBlocked"))
        let transient = Timeline([app, home, home, unknown, app, app])
        try await transient.run()
        precondition(transient.visiblePackages == [pkg, pkg] && !transient.events.contains("homeBlocked"))
        let initial = Timeline([home, unknown, locked, app, app])
        try await initial.run()
        precondition(initial.visiblePackages == ["com.android.systemui", pkg])
        let failedRead = Timeline([unknown, app, app]); failedRead.throwFirstRead = true
        try await failedRead.run()
        precondition(failedRead.visiblePackages == [pkg])
        let cancelled = Timeline([unknown, app]); cancelled.cancelOnCover = true
        try await cancelled.run()
        precondition(cancelled.events == ["covered"] && cancelled.readCount == 1)
        for owner in ["com.android.settings", "android", "com.android.permissioncontroller", "com.android.systemui",
                      "org.lineageos.setupwizard", "com.vendor.nonCatalogActivity"] {
            let dialog = AP.observation(windowReport(owner: owner, title: "Permission or file window"))
            let handoff = Timeline([app, unknown, dialog, unknown, app, app])
            try await handoff.run()
            precondition(handoff.visiblePackages == [pkg, owner, pkg])
            precondition(!handoff.events.contains("homeBlocked") && !handoff.events.contains("unavailable"))
        }
        let uncataloged = AP.observation(windowReport(owner: "org.lineageos.setupwizard"))
        let restricted = Timeline([uncataloged, app, uncataloged, app, app]); restricted.homesVerified = false
        try await restricted.run()
        precondition(restricted.visiblePackages == [pkg, pkg])
        let settingsPermission = AP.observation(windowReport(owner: "com.android.settings", title: "Permission dialog",
            focusedApp: "com.android.settings/.Settings$AppManageExternalStorageActivity"))
        precondition(!AP.isHome(settingsPermission.package, component: settingsPermission.component, homePackages: ["com.android.settings"]))
        for activity in ["com.android.settings/.FallbackHome", "com.android.settings/com.android.settings.FallbackHome"] {
            let fallback = AP.observation(windowReport(owner: "com.android.settings", title: "Fallback", focusedApp: activity))
            precondition(AP.isHome(fallback.package, component: fallback.component, homePackages: ["com.android.settings"]))
            let covered = Timeline([app] + Array(repeating: fallback, count: 5) + [app, app])
            try await covered.run()
            precondition(covered.events.contains("homeBlocked") && covered.visiblePackages == [pkg, pkg])
        }
    }

    static func main() async throws {
        let homes: Set<String> = ["org.lineageos.trebuchet", "com.example.launcher"]
        let installed: Set<String> = [pkg, "com.example.browser", "com.example.launcher"]
        func allowed(_ foreground: String?, settings: Bool = false, launching: Bool = false,
                     homePackages: Set<String> = homes, verified: Bool = true) -> Bool {
            AP.allows(foreground, requested: pkg, homePackages: homePackages,
                      installedPackages: installed, allowSettings: settings, launching: launching,
                      homesVerified: verified)
        }
        precondition(AP.validPackage("com.example.app_2"))
        for bad in ["", "com.example;reboot", "com.example app", "com.example/Activity", "../app", "app\nfoo"] {
            precondition(!AP.validPackage(bad))
        }
        precondition(AP.componentPackages("2 activities found:\norg.lineageos.trebuchet/.Launcher\ncom.example.launcher/com.example.launcher.Home") == homes)
        let report = windowReport(owner: pkg, title: "AnkiDroid permissions")
        precondition(AP.observation(report).package == pkg)
        precondition(AP.observation(windowReport(owner: pkg, focus: "null")).state == .noFocus)
        precondition(AP.observation("window service unavailable").state == .readFailure)
        precondition(allowed(pkg, launching: true))
        for denied in [nil, "org.lineageos.trebuchet", "com.example.launcher", "com.android.launcher3"] as [String?] {
            precondition(!allowed(denied))
        }
        precondition(allowed("com.android.permissioncontroller", launching: true))
        precondition(allowed("com.google.android.packageinstaller"))
        precondition(allowed("com.android.documentsui"))
        precondition(allowed("com.android.settings", settings: true, launching: true))
        precondition(allowed("com.android.settings", launching: true))
        precondition(allowed("android", launching: true))
        precondition(allowed("com.android.systemui", launching: true))
        precondition(!allowed("com.example.browser", launching: true))
        precondition(allowed("com.example.browser"))
        precondition(allowed("com.unknown.app"))
        precondition(!allowed("com.unknown.app", launching: true))
        precondition(!allowed("com.unknown.app", verified: false))
        precondition(allowed(pkg, launching: true, homePackages: []))
        precondition(allowed(pkg, launching: true, homePackages: [], verified: false))
        precondition(!allowed("com.example.launcher", homePackages: [], verified: false))
        precondition(!allowed("com.example.browser", homePackages: [], verified: false))
        precondition(!allowed("com.android.launcher3", homePackages: [], verified: false))
        precondition(AP.launchSucceeded(status: 0, output: "Starting: Intent {}\nStatus: ok\nComplete"))
        for error in ["", "Events injected: 1", "Status: timeout", "Status: ok\nError: missing activity", "java.lang.SecurityException"] {
            precondition(!AP.launchSucceeded(status: 0, output: error))
        }
        precondition(!AP.launchSucceeded(status: 1, output: "Status: ok"))
        precondition(AP.launchSucceeded(status: 0, output: "Status: ok\nActivity: com.example.app/.ExceptionActivity"))
        precondition(!AP.launchSucceeded(status: 0, output: "Status: ok\njava.lang.SecurityException: access denied"))
        precondition(AP.resolvedComponent("com.example.app/.Alias$One", package: pkg) == "com.example.app/.Alias$One")
        for bad in ["com.other/.Main", main + "\n" + main, main + ";reboot", main + "'", "No activity found"] {
            precondition(AP.resolvedComponent(bad, package: pkg) == nil)
        }

        // No HOME app installed: the APK's explicit component still opens.
        let emptyHomes = MockBridge([Step(AP.readinessCommand, ready), Step(AP.homeCommand, noHome),
                                    Step(resolve(), main), Step(launch(), "Status: ok")])
        let empty = try await emptyHomes.start()
        precondition(empty.homePackages.isEmpty && empty.homesVerified); emptyHomes.finished()

        // A policy failure must stop before resolving or starting an activity. A successful
        // policy can add disabled HOME packages to the session's permanent denylist.
        let policy = MockBridge([Step(AP.readinessCommand, ready), Step(AP.homeCommand, noHome),
                                 Step(resolve(), main), Step(launch(), "Status: ok")])
        let prepared = try await policy.start(prepare: { session in
            precondition(policy.commands == [AP.readinessCommand, AP.homeCommand])
            return .init(homePackages: session.homePackages.union(["com.example.disabledhome"]), homesVerified: true)
        })
        precondition(prepared.homePackages.contains("com.example.disabledhome")); policy.finished()
        let failedPolicy = MockBridge([Step(AP.readinessCommand, ready), Step(AP.homeCommand, noHome)])
        do {
            _ = try await failedPolicy.start(prepare: { _ in throw AP.LaunchError.message("Restore checkpoint failed") })
            preconditionFailure("An unverified policy must prevent launch")
        } catch { precondition(error.localizedDescription == "Restore checkpoint failed") }
        failedPolicy.finished()

        // Failed/unsupported HOME enumeration does not block the requested APK or expose another app.
        for step in [Step(AP.homeCommand, "Can't find service: package", status: 20),
                     Step(AP.homeCommand, "", fail: true), Step(AP.homeCommand, "", missingMarker: true),
                     Step(AP.homeCommand, "Error: service failed while listing com.example.home/.Main")] {
            let bridge = MockBridge([Step(AP.readinessCommand, ready), step,
                                     Step(resolve(), main), Step(launch(), "Status: ok")])
            let session = try await bridge.start()
            precondition(!session.homesVerified && session.homePackages.isEmpty); bridge.finished()
        }

        // Activity aliases and TV-only entry points resolve without running a desktop or monkey.
        let alias = "com.example.app/.ExceptionActivity$One"
        let tv = MockBridge([Step(AP.readinessCommand, ready), Step(AP.homeCommand, noHome),
                             Step(resolve(), noEntry), Step(resolve("LEANBACK_LAUNCHER"), alias),
                             Step(launch(alias, category: "LEANBACK_LAUNCHER"), "Status: ok")])
        _ = try await tv.start(); tv.finished()

        let noActivity = MockBridge([Step(AP.readinessCommand, ready), Step(AP.homeCommand, noHome),
                                     Step(resolve(), noEntry), Step(resolve("LEANBACK_LAUNCHER"), noEntry),
                                     Step(AP.readinessCommand, ready)])
        await expectFailure(noActivity, contains: "no enabled activity")
        precondition(!noActivity.commands.contains { $0.hasPrefix("am start") })

        let desktop = MockBridge([Step(AP.readinessCommand, ready), Step(AP.homeCommand, "com.example.app/.Desktop")])
        await expectFailure(desktop, contains: "home apps are hidden")

        // A framework restart clears services; boot_completed alone must never trigger launch.
        let recovered = MockBridge([Step(AP.readinessCommand, "Service package: not found\nService activity: not found\nService window: not found"),
                                    Step(AP.readinessCommand, ready), Step(AP.homeCommand, home),
                                    Step(resolve(), main), Step(launch(), "Status: ok")])
        _ = try await recovered.start(); precondition(recovered.pauses == 1); recovered.finished()
        let incomplete = MockBridge([Step(AP.readinessCommand, "", missingMarker: true),
                                     Step(AP.readinessCommand, ready), Step(AP.homeCommand, noHome),
                                     Step(resolve(), main), Step(launch(), "Status: ok")])
        _ = try await incomplete.start(); precondition(incomplete.pauses == 1); incomplete.finished()
        let resolvingRestart = MockBridge([Step(AP.readinessCommand, ready), Step(AP.homeCommand, home),
                                           Step(resolve(), "Can't find service: package", status: 20),
                                           Step(AP.readinessCommand, ready), Step(AP.homeCommand, home),
                                           Step(resolve(), main), Step(launch(), "Status: ok")])
        _ = try await resolvingRestart.start(); precondition(resolvingRestart.pauses == 1); resolvingRestart.finished()
        let launchRestart = MockBridge([Step(AP.readinessCommand, ready), Step(AP.homeCommand, home),
                                        Step(resolve(), main), Step(launch(), "DeadSystemException", status: 1),
                                        Step(AP.readinessCommand, "Service window: not found"),
                                        Step(AP.readinessCommand, ready), Step(AP.homeCommand, home),
                                        Step(resolve(), main), Step(launch(), "Status: ok")])
        _ = try await launchRestart.start(); precondition(launchRestart.pauses == 1); launchRestart.finished()
        let unavailable = MockBridge((0..<8).map { _ in Step(AP.readinessCommand, "Service package: not found") })
        await expectFailure(unavailable, contains: "still restarting or unavailable")
        precondition(unavailable.pauses == 7)

        // A command failure never permits the display, even with shell exit status zero.
        let launchFailed = MockBridge([Step(AP.readinessCommand, ready), Step(AP.homeCommand, home),
                                       Step(resolve(), main), Step(launch(), "Error: Activity class does not exist"),
                                       Step(AP.readinessCommand, ready)])
        await expectFailure(launchFailed, contains: "could not open this app")
        let cancelled = MockBridge([Step(AP.readinessCommand, ready), Step(AP.homeCommand, noHome),
                                    Step(resolve(), main, cancelAfter: true)])
        do { _ = try await cancelled.start(); preconditionFailure("Expected cancellation") }
        catch is CancellationError {} catch { preconditionFailure("Wrong cancellation error") }
        cancelled.finished()
        precondition(!cancelled.commands.contains { $0.hasPrefix("am start") })

        // A device may reject either optional panel request. It must still launch and allow user interaction.
        for failedCommand in ["input keyevent KEYCODE_WAKEUP", "cmd statusbar collapse", "wm dismiss-keyguard"] {
            for throwsError in [false, true] {
                let optionalUI = MockBridge([Step(AP.readinessCommand, ready), Step(AP.homeCommand, noHome),
                                             Step(resolve(), main), Step(launch(), "Status: ok")])
                let index = optionalUI.steps.firstIndex { $0.command == failedCommand }!
                optionalUI.steps[index] = Step(failedCommand, "SecurityException: request unavailable", status: 1, fail: throwsError)
                _ = try await optionalUI.start(); optionalUI.finished()
                precondition(!optionalUI.logs.isEmpty)
            }
        }
        let cancelledUnlock = MockBridge([Step(AP.readinessCommand, ready), Step(AP.homeCommand, noHome),
                                           Step(resolve(), main), Step("input keyevent KEYCODE_WAKEUP", ""),
                                           Step("cmd statusbar collapse", ""), Step("wm dismiss-keyguard", "", cancelAfter: true)])
        do { _ = try await cancelledUnlock.start(); preconditionFailure("Expected cancellation during unlock") }
        catch is CancellationError {} catch { preconditionFailure("Wrong unlock cancellation error") }
        cancelledUnlock.finished()
        precondition(!cancelledUnlock.commands.contains { $0.hasPrefix("am start") })

        let settings = MockBridge([Step(AP.readinessCommand, ready), Step(AP.homeCommand, noHome),
                                   Step("am start -W --user 0 -a android.settings.APPLICATION_DETAILS_SETTINGS -d package:\(pkg)", "Status: ok")])
        _ = try await settings.start(settings: true); settings.finished()
        try await foregroundChecks()
        print("Android app presentation checks passed: direct launch/wake pipeline, window-owner identity, display scope, temporary-cover recovery, permission dialogs, cancellation, service recovery, and HOME rejection.")
    }
}
