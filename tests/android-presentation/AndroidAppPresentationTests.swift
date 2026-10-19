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
        init(_ steps: [Step]) { self.steps = steps }
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
        let report = "  mCurrentFocus=Window{a02ab34 u0 com.example.app/.MainActivity}"
        precondition(AP.foregroundPackage(report) == pkg)
        precondition(AP.foregroundPackage("topResumedActivity=ActivityRecord{ff12 u0 com.example.app/.MainActivity t9}") == pkg)
        precondition(AP.foregroundPackage("mResumedActivity: ActivityRecord{ff12 u0 com.example.app/.MainActivity t9}") == pkg)
        precondition(AP.foregroundPackage("mCurrentFocus=null\ntopResumedActivity=ActivityRecord{ff12 u0 com.example.app/.MainActivity t9}") == nil)
        precondition(AP.foregroundPackage(report + "\nmCurrentFocus=Window{def u0 org.lineageos.trebuchet/.Launcher}") == nil)
        precondition(AP.foregroundPackage("window service unavailable") == nil)
        precondition(allowed(pkg, launching: true))
        for denied in [nil, "org.lineageos.trebuchet", "com.example.launcher", "com.android.launcher3", "com.android.systemui", "com.android.settings", "com.unknown.app"] as [String?] {
            precondition(!allowed(denied))
        }
        precondition(allowed("com.android.permissioncontroller", launching: true))
        precondition(allowed("com.google.android.packageinstaller"))
        precondition(allowed("com.android.documentsui"))
        precondition(allowed("com.android.settings", settings: true, launching: true))
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
        print("Android app presentation checks passed: real command pipeline, zero/failed HOME queries, explicit activities/aliases, service recovery, cancellation, launch failures, stale responses, and covered desktops.")
    }
}
