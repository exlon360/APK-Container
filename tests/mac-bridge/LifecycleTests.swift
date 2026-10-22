// Appended to the production source so tests exercise its actual private controller/window code.
@main
struct BridgeLifecycleTests {
    @MainActor static func wait(_ condition: () -> Bool, _ message: String) async {
        for _ in 0..<120 {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        fatalError(message)
    }
    @MainActor static func main() async {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let controller = BridgeController.shared
        let delegate = BridgeAppDelegate()
        await controller.opened()
        if let error = controller.error { print("Controller setup diagnostic: " + error) }
        await wait({ controller.running }, "Configured app did not start its bridge")
        precondition(controller.keepsMacAwake)
        precondition(!delegate.applicationShouldTerminateAfterLastWindowClosed(app))

        let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 40, height: 40),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "APK bridge disposable lifecycle fixture"
        window.contentView = BridgeWindowObserver()
        precondition(BridgeWindowRegistry.shared.window === window)
        precondition(!window.isReleasedWhenClosed)
        window.close()
        precondition(controller.running, "Window close stopped the bridge")
        precondition(!delegate.applicationShouldHandleReopen(app, hasVisibleWindows: false))
        precondition(window.isVisible, "Dock reopen did not restore the retained dashboard")
        window.orderOut(nil)

        controller.stop()
        await wait({ !controller.running && !controller.stopping }, "Stop did not terminate owned child")
        precondition(!controller.keepsMacAwake)
        await controller.opened()
        try? await Task.sleep(nanoseconds: 150_000_000)
        precondition(!controller.running, "Window reopen reversed an explicit Stop")

        await controller.pairSkill()
        await wait({ controller.running }, "Pairing did not start the bridge")
        precondition(controller.paired)
        controller.stop()
        await wait({ !controller.running && !controller.stopping }, "Stop after pairing failed")

        let destination = URL(fileURLWithPath: ProcessInfo.processInfo.environment["APK_TEST_PROFILE"]!)
        await controller.exportProfile(to: destination)
        await wait({ controller.running }, "Profile export did not start the bridge")
        precondition(FileManager.default.fileExists(atPath: destination.path))
        let attributes = try! FileManager.default.attributesOfItem(atPath: destination.path)
        precondition((attributes[.posixPermissions] as! NSNumber).intValue == 0o600)
        controller.shutdown()
        await wait({ !controller.running }, "Quit cleanup did not end owned bridge")
        precondition(!controller.keepsMacAwake)
        print("Mac bridge lifecycle passed: configured autostart, close/reopen retention, explicit Stop, Pair/export autostart, private profile, and sleep-activity cleanup.")
    }
}
