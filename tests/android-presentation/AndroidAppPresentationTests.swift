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
                step.command.hasPrefix("am start ") ? [Step("input keyevent KEYCODE_WAKEUP", ""), step] : [step]
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
        func start(settings: Bool = false) async throws -> AP.Session {
            try await AP.start(package: pkg, settings: settings, run: run,
                               cancelled: { self.cancelled }, pause: { self.pauses += 1 },
                               log: { self.logs.append($0) })
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

    final class Timeline {
        var observations: [AP.Observation]
        var time: TimeInterval = 0
        var events: [String] = []
        var readCount = 0
        var cancel = false
        var cancelOnCover = false
        var throwFirstRead = false
        init(_ observations: [AP.Observation]) { self.observations = observations }
        func run() async throws {
            try await AP.monitor(requested: pkg, session: AP.Session(homePackages: ["com.example.home"], homesVerified: true),
                                 installedPackages: [pkg, "com.example.browser", "com.example.home"], allowSettings: false,
                                 read: {
                self.readCount += 1
                if self.throwFirstRead && self.readCount == 1 { throw NSError(domain: "bridge", code: 1) }
                let value = self.observations.first!
                if self.observations.count > 1 { self.observations.removeFirst() }
                return value
            }, now: { self.time }, pause: { self.time += $0 }, cancelled: { self.cancel }, event: { event in
                switch event {
                case .visible: self.events.append("visible")
                case .covered:
                    self.events.append("covered")
                    if self.cancelOnCover { self.cancel = true }
                case .returnedHome: self.events.append("home")
                case .timedOut(let observation):
                    precondition(!observation.diagnostic.isEmpty)
                    self.events.append("timeout")
                }
            })
        }
    }

    static func foregroundChecks() async throws {
        let app = AP.observation(windowReport(owner: pkg, title: "AnkiDroid"))
        let home = AP.observation(windowReport(owner: "com.example.home", title: "Home"))
        let unknown = AP.observation(windowReport(owner: pkg, focus: "null"))
        let locked = AP.observation(windowReport(owner: "com.android.systemui", title: "NotificationShade"))
        precondition(app.package == pkg)
        precondition(app.diagnostic.contains("mOwnerUid="))
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
        let probe = MockBridge([Step(AP.foregroundCommand, windowReport(owner: pkg, title: "Arbitrary title without a slash"))])
        let observed = try AP.observe(run: probe.run)
        precondition(observed.package == pkg); probe.finished()
        let failedProbe = MockBridge([Step(AP.foregroundCommand, "Can't find service: window", status: 1)])
        let failedObservation = try AP.observe(run: failedProbe.run)
        precondition(failedObservation.state == .readFailure); failedProbe.finished()
        precondition(AP.observation(String(repeating: "bad response ", count: 1000)).diagnostic.count <= 700)

        // The tested monitor is the same loop AndroidHost uses. An initial old HOME stays covered.
        let initial = Timeline([home, unknown, app, home])
        try await initial.run()
        precondition(initial.events == ["covered", "covered", "visible", "home"])
        let recovered = Timeline([app, unknown, app, home])
        try await recovered.run()
        precondition(recovered.events == ["visible", "covered", "visible", "home"])
        let serviceRecovery = Timeline([app, home])
        serviceRecovery.throwFirstRead = true
        try await serviceRecovery.run()
        precondition(serviceRecovery.events == ["covered", "visible", "home"])
        let lockedRecovery = Timeline([app, locked, unknown, app, home])
        try await lockedRecovery.run()
        precondition(lockedRecovery.events == ["visible", "covered", "covered", "visible", "home"])
        for observation in [unknown, locked, AP.observation("unknown report")] {
            let timeout = Timeline([observation])
            try await timeout.run()
            precondition(timeout.events.last == "timeout" && !timeout.events.contains("visible"))
            precondition(timeout.time >= 30 && timeout.time < 31)
        }
        let recoveryTimeout = Timeline([app, unknown])
        try await recoveryTimeout.run()
        precondition(recoveryTimeout.events.first == "visible" && recoveryTimeout.events.last == "timeout")
        precondition(recoveryTimeout.time >= 31 && recoveryTimeout.time < 32)
        let cancelled = Timeline([unknown, app])
        cancelled.cancelOnCover = true
        do { try await cancelled.run(); preconditionFailure("Expected monitor cancellation") }
        catch is CancellationError {} catch { preconditionFailure("Wrong monitor cancellation") }
        precondition(cancelled.events == ["covered"] && cancelled.readCount == 1)
        for owner in ["com.android.settings", "android", "com.android.permissioncontroller"] {
            let dialog = AP.observation(windowReport(owner: owner, title: "Permission or error dialog"))
            let handoff = Timeline([app, dialog, app, home])
            try await handoff.run()
            precondition(handoff.events == ["visible", "visible", "visible", "home"])
        }
        let customHome = Timeline([app, mislabeled])
        try await customHome.run()
        precondition(customHome.events == ["visible", "home"])
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
        for denied in [nil, "org.lineageos.trebuchet", "com.example.launcher", "com.android.launcher3", "com.android.systemui", "com.unknown.app"] as [String?] {
            precondition(!allowed(denied))
        }
        precondition(allowed("com.android.permissioncontroller", launching: true))
        precondition(allowed("com.google.android.packageinstaller"))
        precondition(allowed("com.android.documentsui"))
        precondition(allowed("com.android.settings", settings: true, launching: true))
        precondition(allowed("com.android.settings", launching: true))
        precondition(allowed("android", launching: true))
        precondition(!allowed("com.example.browser", launching: true))
        precondition(allowed("com.example.browser"))
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

        let settings = MockBridge([Step(AP.readinessCommand, ready), Step(AP.homeCommand, noHome),
                                   Step("am start -W --user 0 -a android.settings.APPLICATION_DETAILS_SETTINGS -d package:\(pkg)", "Status: ok")])
        _ = try await settings.start(settings: true); settings.finished()
        try await foregroundChecks()
        print("Android app presentation checks passed: direct launch/wake pipeline, window-owner identity, display scope, temporary-cover recovery, permission dialogs, cancellation, service recovery, and HOME rejection.")
    }
}
