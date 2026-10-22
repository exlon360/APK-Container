// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

@main
struct APKContainerBridgeApp: App {
    @NSApplicationDelegateAdaptor(BridgeAppDelegate.self) private var delegate
    @StateObject private var bridge = BridgeController.shared

    init() {
        if CommandLine.arguments.contains("--smoke-test") {
            exit(BridgeBundle.smokeTest())
        }
    }

    var body: some Scene {
        WindowGroup("APK Container Bridge") {
            BridgeDashboard(bridge: bridge)
                .frame(minWidth: 680, idealWidth: 720, minHeight: 590, idealHeight: 640)
                .preferredColorScheme(.dark)
                .background(BridgeWindowCapture())
                .task {
                    await bridge.opened()
                    while !Task.isCancelled {
                        do { try await Task.sleep(nanoseconds: 15_000_000_000) } catch { break }
                        await bridge.refresh()
                    }
                }
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) { }
        }
    }
}

final class BridgeAppDelegate: NSObject, NSApplicationDelegate {
    // A paired device should not disconnect because the Mac window was closed.
    // Explicit Stop and Quit still stop only this app's owned server process.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows, let window = BridgeWindowRegistry.shared.window {
            window.makeKeyAndOrderFront(nil)
            return false
        }
        return true
    }
    func applicationWillTerminate(_ notification: Notification) { BridgeController.shared.shutdown() }
}

/// Retain the single dashboard window for Dock reopen without changing SwiftUI's delegate.
@MainActor private final class BridgeWindowRegistry {
    static let shared = BridgeWindowRegistry()
    var window: NSWindow?
}

private struct BridgeWindowCapture: NSViewRepresentable {
    func makeNSView(context: Context) -> BridgeWindowObserver { BridgeWindowObserver() }
    func updateNSView(_ view: BridgeWindowObserver, context: Context) { }
}

private final class BridgeWindowObserver: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window {
            window.isReleasedWhenClosed = false
            BridgeWindowRegistry.shared.window = window
        }
    }
}

private enum BridgeBundle {
    static var resources: URL { Bundle.main.resourceURL! }
    static var node: URL { resources.appendingPathComponent("node/bin/node") }
    static var entry: URL { resources.appendingPathComponent("bridge/bridge.mjs") }
    static var installer: URL { resources.appendingPathComponent("bridge/scripts/install-skill.mjs") }
    static var skill: URL { resources.appendingPathComponent("skills/apk") }

    static func validate() throws {
        for file in [node, entry, installer, skill.appendingPathComponent("SKILL.md")] {
            guard FileManager.default.fileExists(atPath: file.path) else { throw BridgeFailure.missingResources }
        }
        guard FileManager.default.isExecutableFile(atPath: node.path) else { throw BridgeFailure.missingResources }
    }

    static func smokeTest() -> Int32 {
        do {
            try validate()
            for arguments in [["--version"], ["--check", entry.path], ["--check", installer.path], [entry.path, "--help"]] {
                let process = Process()
                process.executableURL = node
                process.arguments = arguments
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                try process.run()
                process.waitUntilExit()
                guard process.terminationStatus == 0 else { throw BridgeFailure.missingResources }
            }
            print("PASS: bundled Node, bridge, skill installer, and /apk resources.")
            return 0
        } catch {
            fputs("FAIL: APK Container Bridge bundle is incomplete or cannot run.\n", stderr)
            return 1
        }
    }
}

private enum BridgeFailure: LocalizedError {
    case missingResources, command(String), malformedReply
    var errorDescription: String? {
        switch self {
        case .missingResources: return "Bridge files are missing. Download the complete APK Container Bridge app again."
        case .command(let message): return message
        case .malformedReply: return "The bridge returned an unreadable response. Restart the bridge and try again."
        }
    }
}

private struct BridgeStatus: Decodable {
    let name: String
    let url: String
    let alternateURLs: [String]?
    let paired: Bool
    let projectsDir: String
}

final class BridgeController: ObservableObject {
    static let shared = BridgeController()
    @Published private(set) var running = false
    @Published private(set) var starting = false
    @Published private(set) var stopping = false
    @Published private(set) var busy = false
    @Published private(set) var paired = false
    @Published private(set) var configured = false
    @Published private(set) var address = "Start the bridge to set up this Mac"
    @Published private(set) var alternateAddresses: [String] = []
    @Published private(set) var keepsMacAwake = false
    @Published private(set) var message = "Create apps from APK Container on your iPhone or iPad."
    @Published private(set) var error: String?
    private var projectsPath: String?
    private var ownedProcess: Process?
    private var processID: UUID?
    private var outputPipe: Pipe?
    private var outputBuffer = Data()
    private var openedOnce = false
    private var refreshing = false
    private var activity: NSObjectProtocol?
    private let statePath = ProcessInfo.processInfo.environment["APK_CONTAINER_BRIDGE_STATE_DIR"]

    var stateDirectory: URL {
        if let statePath { return URL(fileURLWithPath: statePath, isDirectory: true) }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/APK Container Bridge", isDirectory: true)
    }
    var statusTitle: String {
        if stopping { return "Stopping bridge" }
        if starting { return "Starting bridge" }
        if running { return "Bridge is running" }
        return configured ? "Bridge is stopped" : "Ready to set up"
    }
    private var stateArguments: [String] {
        statePath.map { ["--state-dir", $0] } ?? []
    }

    @MainActor func opened() async {
        // Reopening the window after an explicit Stop must not start it again.
        guard !openedOnce else { return }
        openedOnce = true
        await refresh()
        if configured { await start() }
    }

    @MainActor func refresh() async {
        guard !busy, !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        guard FileManager.default.fileExists(atPath: stateDirectory.appendingPathComponent("configuration.json").path) else { return }
        do { apply(try await statusCommand("status")) }
        catch { self.error = error.localizedDescription }
    }

    @MainActor private func apply(_ status: BridgeStatus) {
        configured = true
        address = status.url
        alternateAddresses = (status.alternateURLs ?? []).filter { $0 != status.url }
        paired = status.paired
        projectsPath = status.projectsDir
    }

    private func execute(_ arguments: [String], failure: String) async throws -> Data {
        try BridgeBundle.validate()
        let executable = BridgeBundle.node
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                let output = Pipe()
                process.executableURL = executable
                process.arguments = arguments
                process.standardOutput = output
                // Credentials and arbitrary child output never enter dashboard logs or error text.
                process.standardError = FileHandle.nullDevice
                do {
                    try process.run()
                    let result = output.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    guard process.terminationStatus == 0 else { throw BridgeFailure.command(failure) }
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: BridgeFailure.command(failure))
                }
            }
        }
    }

    private func command(_ name: String, extra: [String] = [], failure: String) async throws -> Data {
        try await execute([BridgeBundle.entry.path, name] + stateArguments + extra, failure: failure)
    }

    private func statusCommand(_ name: String) async throws -> BridgeStatus {
        let result = try await command(name, failure: "Mac setup could not finish. Check that Codex is installed, then try again.")
        guard let value = try? JSONDecoder().decode(BridgeStatus.self, from: result) else { throw BridgeFailure.malformedReply }
        return value
    }

    @MainActor func start() async {
        guard !busy, ownedProcess == nil else { return }
        busy = true; error = nil
        defer { busy = false }
        do {
            apply(try await statusCommand("init"))
            let process = Process()
            let pipe = Pipe()
            let identity = UUID()
            process.executableURL = BridgeBundle.node
            process.arguments = [BridgeBundle.entry.path, "start"] + stateArguments
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { [weak self] process in
                DispatchQueue.main.async { self?.finished(identity, exitCode: process.terminationStatus) }
            }
            pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                DispatchQueue.main.async { self?.receive(data, identity: identity) }
            }
            outputBuffer = Data()
            outputPipe = pipe
            ownedProcess = process
            processID = identity
            starting = true
            do { try process.run() }
            catch {
                pipe.fileHandleForReading.readabilityHandler = nil
                ownedProcess = nil; processID = nil; outputPipe = nil; starting = false
                throw BridgeFailure.command("The bridge could not start. Reopen APK Container Bridge and try again.")
            }
            message = "Connect your device to the same network. The bridge stays available when this window is closed."
        } catch { self.error = error.localizedDescription }
    }

    @MainActor private func receive(_ data: Data, identity: UUID) {
        guard processID == identity else { return }
        outputBuffer.append(data)
        // The server emits one public listening event; never display unrecognized output.
        if outputBuffer.count > 16_384 { outputBuffer.removeAll(); return }
        while let end = outputBuffer.firstIndex(of: 10) {
            let line = outputBuffer.prefix(upTo: end)
            outputBuffer.removeSubrange(...end)
            guard let event = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                  event["event"] as? String == "listening" else { continue }
            running = true; starting = false
            if activity == nil {
                activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .automaticTerminationDisabled],
                    reason: "Keep the paired APK Container build bridge reachable")
                keepsMacAwake = true
            }
        }
    }

    private func endActivity() {
        if let activity { ProcessInfo.processInfo.endActivity(activity); self.activity = nil }
        keepsMacAwake = false
    }

    @MainActor private func finished(_ identity: UUID, exitCode: Int32) {
        guard processID == identity else { return }
        let requested = stopping
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        outputPipe = nil; ownedProcess = nil; processID = nil
        running = false; starting = false; stopping = false
        endActivity()
        if requested { message = "Bridge stopped. Your apps and chats are saved." }
        else {
            error = exitCode == 0 ? "The bridge stopped. Click Start Bridge to reconnect."
                : "The bridge could not stay running. Check Codex is installed and another bridge is not already using port 48152."
        }
    }

    @MainActor func stop() {
        guard let process = ownedProcess, process.isRunning else { return }
        stopping = true
        process.terminate()
    }

    func shutdown() {
        endActivity()
        // This app never terminates a bridge or Codex process started elsewhere.
        if let process = ownedProcess, process.isRunning { process.terminate() }
    }

    @MainActor func generateProfile() async {
        guard !busy else { return }
        let panel = NSSavePanel()
        panel.title = "Generate agent.prf"
        panel.message = "Import this file in APK Container → Build on your iPhone or iPad."
        panel.nameFieldStringValue = "agent.prf"
        panel.allowedContentTypes = [UTType(filenameExtension: "prf") ?? .data]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        await exportProfile(to: destination)
    }

    @MainActor func exportProfile(to destination: URL) async {
        guard !busy else { return }
        busy = true; error = nil
        var generated = false
        do {
            apply(try await statusCommand("init"))
            _ = try await command("profile", extra: ["--out", destination.path], failure: "The pairing file could not be saved. Choose a writable folder and try again.")
            generated = true
        } catch { self.error = error.localizedDescription }
        busy = false
        if generated {
            await start()
            message = "Saved \(destination.lastPathComponent). Import it in Build on your device."
        }
    }

    @MainActor func pairSkill() async {
        guard !busy else { return }
        busy = true; error = nil
        var pairedSuccessfully = false
        do {
            apply(try await statusCommand("init"))
            _ = try await execute([BridgeBundle.installer.path, BridgeBundle.skill.path], failure: "The /apk skill could not be installed. Check your Codex skills folder is writable and try again.")
            apply(try await statusCommand("pair"))
            pairedSuccessfully = true
        } catch { self.error = error.localizedDescription }
        busy = false
        if pairedSuccessfully {
            await start()
            message = "/apk is installed and paired. Import agent.prf in Build on your device."
        }
    }

    @MainActor func openProjects() {
        let path = projectsPath ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/ChatGPT/apk files", isDirectory: true).path
        guard FileManager.default.fileExists(atPath: path) else {
            message = "Start Bridge to create your apk files folder."; return
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: path, isDirectory: true))
    }

    @MainActor func openCodex() {
        let applications = ["/Applications/Codex.app", "/Applications/ChatGPT.app"]
        guard let path = applications.first(where: FileManager.default.fileExists(atPath:)) else {
            error = "Install Codex on this Mac, sign in, then open it again."; return
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: path, isDirectory: true))
    }
}

private struct BridgeDashboard: View {
    @ObservedObject var bridge: BridgeController
    private let blue = Color(red: 0.30, green: 0.61, blue: 1)
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 16) {
                    Image(systemName: "shippingbox.fill")
                        .font(.system(size: 32, weight: .semibold))
                        .frame(width: 72, height: 72)
                        .background(LinearGradient(colors: [blue, blue.opacity(0.65)], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 19))
                    VStack(alignment: .leading, spacing: 5) {
                        Text("APK Container Bridge").font(.system(size: 26, weight: .bold))
                        Text("Build on your Mac. Run on your device.")
                            .font(.system(size: 14)).foregroundColor(.secondary)
                    }
                    Spacer()
                }
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Circle().fill(bridge.running ? Color.green : Color.secondary)
                            .frame(width: 9, height: 9)
                        Text(bridge.statusTitle).font(.headline)
                        Spacer()
                        if bridge.running || bridge.starting || bridge.stopping {
                            Button(bridge.stopping ? "Stopping…" : "Stop Bridge") { bridge.stop() }
                                .disabled(bridge.stopping)
                        } else {
                            Button("Start Bridge") { Task { await bridge.start() } }
                                .buttonStyle(.borderedProminent).tint(blue).disabled(bridge.busy)
                        }
                    }
                    Text(bridge.address).font(.system(size: 12, design: .monospaced))
                        .foregroundColor(.secondary).textSelection(.enabled)
                    if !bridge.alternateAddresses.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Other addresses").font(.caption.weight(.semibold)).foregroundColor(.secondary)
                            ForEach(bridge.alternateAddresses, id: \.self) { address in
                                Text(address).font(.system(size: 12, design: .monospaced))
                                    .foregroundColor(.secondary).textSelection(.enabled)
                            }
                        }
                    }
                    Text(bridge.message).font(.system(size: 13)).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(20).background(blue.opacity(0.13), in: RoundedRectangle(cornerRadius: 22))

                VStack(spacing: 0) {
                    step("1", title: "Generate agent.prf", detail: "Send this pairing file to your iPhone or iPad, then import it in Build.") {
                        Button("Generate agent.prf") { Task { await bridge.generateProfile() } }.disabled(bridge.busy)
                    }
                    Divider().padding(.horizontal, 20)
                    step("2", title: "Pair Skill /apk", detail: bridge.paired ? "/apk is paired with this Mac." : "Install the /apk skill and connect it to this bridge.") {
                        Button(bridge.paired ? "Pair Again" : "Pair Skill /apk") { Task { await bridge.pairSkill() } }.disabled(bridge.busy)
                    }
                    Divider().padding(.horizontal, 20)
                    step("3", title: "Build your app", detail: "Open Build on your device, describe an app, and watch Codex work.") {
                        Button("Open Codex") { bridge.openCodex() }
                    }
                }
                .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 22))

                if let error = bridge.error {
                    Label(error, systemImage: "exclamationmark.circle.fill")
                        .foregroundColor(.orange).font(.system(size: 13))
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Button { bridge.openProjects() } label: { Label("Open apk files", systemImage: "folder") }
                    Spacer()
                    if bridge.busy { ProgressView().controlSize(.small) }
                    Text(bridge.keepsMacAwake ? "Mac stays awake; the display can sleep. Stop or Quit to disconnect."
                         : "A configured bridge starts when this app opens.")
                        .font(.caption).foregroundColor(.secondary).multilineTextAlignment(.trailing)
                }
            }
            .padding(28)
        }
        .background(Color(red: 0.035, green: 0.04, blue: 0.055))
        .tint(blue)
    }

    private func step<Controls: View>(_ number: String, title: String, detail: String, @ViewBuilder controls: () -> Controls) -> some View {
        HStack(spacing: 14) {
            Text(number).font(.system(size: 13, weight: .bold))
                .frame(width: 30, height: 30).background(Color.white.opacity(0.08), in: Circle())
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.system(size: 14, weight: .semibold))
                Text(detail).font(.system(size: 12)).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 20)
            controls().controlSize(.large)
        }
        .padding(20)
    }
}
