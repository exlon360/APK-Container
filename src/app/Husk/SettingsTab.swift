// SPDX-License-Identifier: GPL-2.0-or-later
import SwiftUI

/// Native grouped settings, with the app runtime kept separate from the app library.
struct SettingsTab: View {
    @AppStorage(AppWindows.defaultKey) private var multitask = false
    @AppStorage(CompatibilityStore.askKey) private var askCompat = true

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink { AboutSettings() } label: { appCard }
                }

                Section {
                    row(JITSettings(), "bolt.fill", .yellow, "JIT & Sideloading", "Enable JIT and manage your connection")
                } footer: {
                    Text("JIT and extended-memory support remain available for Android apps. StikJIT is built in.")
                }

                Section("Apps") {
                    row(DisplayDefaultsSettingsView(), "rectangle.expand.vertical", .blue, "Display & Resolution", "Device-sized display, quality and per-app overrides")
                    row(LibrarySettings(), "square.stack.3d.up.fill", .indigo, "App Library", "Installed apps and icons")
                    row(DiscoverView(), "sparkle.magnifyingglass", .mint, "Find Apps", "Browse APK repositories")
                    row(FontSettings(), "textformat", .orange, "Fonts", "Chinese, Japanese and Korean text")
                    Toggle(isOn: $multitask) {
                        Label("Open Apps in Windows", systemImage: "macwindow.on.rectangle")
                    }
                }

                Section("General") {
                    row(AppearanceSettings(), "paintbrush.fill", .pink, "Appearance", "Light or dark, accent colour and app icon")
                    row(FAQTab(), "questionmark.circle.fill", .teal, "Help", "Answers to common problems")
                }

                Section {
                    row(AndroidRuntimeSettings(), "shippingbox.fill", .green, "Runtime Setup", "Download and manage the Android runtime")
                    row(PerformanceSettings(), "speedometer", .orange, "Performance", "GPU renderer and sound")
                    row(InputSettings(), "hand.tap.fill", .indigo, "Display & Input", "Runtime resolution, orientation and touch")
                    row(NetworkSettings(), "globe", .green, "Network", "Android internet access")
                    row(SavedMachineSettings(), "externaldrive.fill", .teal, "Saved Runtime", "Snapshots and automatic saving")
                } header: {
                    Text("Compatibility Runtime")
                } footer: {
                    Text("Apps that need a full Android environment can use the compatibility runtime. It starts when an app needs it; your apps stay in the Apps tab.")
                }

                Section {
                    Toggle("Ask How Apps Ran", isOn: $askCompat)
                    Link(destination: CompatibilityStore.site) {
                        Label("Compatibility List", systemImage: "safari")
                    }
                } header: {
                    Text("Compatibility")
                } footer: {
                    Text("Optional reports include your device, iOS version, build and JIT method, and are sent to the upstream compatibility service at antiweb.lol after your confirmation.")
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Settings")
        }
    }

    private var appCard: some View {
        HStack(spacing: 14) {
            Image(systemName: "square.stack.3d.up.fill")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 56, height: 56)
                .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text("APK Container").font(.title3.weight(.semibold))
                Text("Version \(Bundle.main.version)")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 6)
    }

    private func row<D: View>(_ destination: D, _ icon: String, _ tint: Color,
                              _ title: String, _ subtitle: String) -> some View {
        NavigationLink { destination } label: {
            Label {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
            } icon: {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(tint)
                    .frame(width: 30, height: 30)
                    .overlay {
                        Image(systemName: icon)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(.white)
                    }
            }
        }
    }
}

/// A Form, as the system draws one.
private struct HuskForm: ViewModifier {
    func body(content: Content) -> some View {
        content.navigationBarTitleDisplayMode(.inline)
    }
}

extension View {
    func huskForm() -> some View { modifier(HuskForm()) }
}

// MARK: - Library

struct LibrarySettings: View {
    @ObservedObject private var host = AndroidHost.shared
    @State private var working = false

    var body: some View {
        Form {
            Section {
                DetailRow(label: "Apps", value: "\(host.packages.count)", mono: false)
                DetailRow(label: "With icons",
                          value: "\(host.packages.filter { $0.iconPath != nil }.count)",
                          mono: false)
            } footer: {
                Text("The list is written to disk, so it is on screen before Android "
                   + "has finished starting.")
            }

            Section {
                Button {
                    working = true
                    Task { await host.refreshPackages(); working = false }
                } label: {
                    Label(working ? "Refreshing…" : "Refresh from Android",
                          systemImage: "arrow.clockwise")
                }
                .disabled(working || !host.isReady)

                Button {
                    AndroidHost.forgetIcons()
                    working = true
                    Task { await host.refreshPackages(); working = false }
                } label: {
                    Label("Re-fetch icons", systemImage: "photo.on.rectangle")
                }
                .disabled(working || !host.isReady)
            } footer: {
                Text("Names and icons are read from the installed APKs. Re-fetching clears "
                   + "APK Container's cached copies and reads the APK metadata again.")
            }
        }
        .huskForm()
        .navigationTitle("Library")
    }
}

// MARK: - Fonts

/// The Chinese, Japanese and Korean fonts the bundle leaves out (#95: 58 MB of Android's 82 MB of fonts), downloaded on request. Apps
/// on the translation layer find them where Android keeps them, through fonts.xml, which already names the file.
@MainActor
final class CJKFonts: ObservableObject {
    static let shared = CJKFonts()
    static let fileName = "NotoSansCJK-Regular.ttc"
    static let source = URL(string: "https://github.com/notofonts/noto-cjk/raw/main/Sans/OTC/NotoSansCJK-Regular.ttc")!
    nonisolated static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Fonts", isDirectory: true)
    }
    nonisolated static var installed: Bool { FileManager.default.fileExists(atPath: directory.appendingPathComponent(fileName).path) }

    @Published private(set) var isInstalled = CJKFonts.installed
    @Published private(set) var downloading = false
    @Published private(set) var failure: String?

    func download() {
        guard !downloading else { return }
        downloading = true
        failure = nil
        Task {
            do {
                let (temp, response) = try await URLSession.shared.download(from: Self.source)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
                try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
                let dest = Self.directory.appendingPathComponent(Self.fileName)
                try? FileManager.default.removeItem(at: dest)
                try FileManager.default.moveItem(at: temp, to: dest)
                HuskLog.log("fonts", "CJK fonts installed at \(dest.path)")
                isInstalled = true
            } catch {
                failure = "The download failed: \(error.localizedDescription)"
                HuskLog.log("fonts", "CJK font download failed: \(error.localizedDescription)")
            }
            downloading = false
        }
    }

    func remove() {
        try? FileManager.default.removeItem(at: Self.directory.appendingPathComponent(Self.fileName))
        isInstalled = Self.installed
    }
}

struct FontSettings: View {
    @ObservedObject private var fonts = CJKFonts.shared

    var body: some View {
        Form {
            Section {
                if fonts.isInstalled {
                    Label("Installed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    Button(role: .destructive) { fonts.remove() } label: { Label("Remove", systemImage: "trash") }
                } else {
                    Button { fonts.download() } label: {
                        Label(fonts.downloading ? "Downloading…" : "Download (19.5 MB)", systemImage: "arrow.down.circle")
                    }
                    .disabled(fonts.downloading)
                }
                if let failure = fonts.failure { Text(failure).font(.caption).foregroundStyle(.red) }
            } header: {
                Text("Chinese, Japanese and Korean")
            } footer: {
                Text("Noto Sans CJK, the font Android uses for these languages. Games and apps that draw their own text (Unity, Flutter, "
                   + "cocos2d-x) show empty boxes for these characters without it. Takes effect the next time an app opens.")
            }
        }
        .huskForm()
        .navigationTitle("Fonts")
    }
}

// MARK: - Performance

struct PerformanceSettings: View {
    @ObservedObject private var runner = QemuRunner.shared
    @State private var gpuMode =
        UserDefaults.standard.object(forKey: "husk.gpuMode") as? Bool ?? true
    @State private var sound = UserDefaults.standard.bool(forKey: "husk.sound")
    @State private var soundDevice =
        UserDefaults.standard.object(forKey: "husk.soundDevice") as? Bool ?? true

    var body: some View {
        Form {
            Section {
                Picker("Renderer", selection: $gpuMode) {
                    Text("GPU").tag(true)
                    Text("CPU").tag(false)
                }
                .pickerStyle(.segmented)
                .onChange(of: gpuMode) { v in
                    UserDefaults.standard.set(v, forKey: "husk.gpuMode")
                    HuskLog.log("ui", v ? "GPU renderer selected" : "CPU renderer selected")
                }
            } header: {
                Text("Renderer")
            } footer: {
                Text(gpuMode
                     ? "Android uses the GPU through Metal. This is the default renderer."
                     : "Every pixel is drawn by the emulated CPU. Much slower, and only "
                     + "worth choosing if the GPU misbehaves.")
            }

            Section {
                DetailRow(label: "Frame rate",
                          value: runner.fps > 0
                                 ? String(format: "%.0f fps", runner.fps) : "—")
                DetailRow(label: "Guest screen",
                          value: "\(QemuRunner.lastGuestRes.w)×\(QemuRunner.lastGuestRes.h)")
            } header: {
                Text("Now")
            }

            Section {
                Toggle("Sound", isOn: $sound)
                    .onChange(of: sound) { v in
                        UserDefaults.standard.set(v, forKey: "husk.sound")
                        HuskLog.log("ui", v ? "sound on" : "sound off")
                    }
                if sound {
                    Toggle("Attach the sound device", isOn: $soundDevice)
                        .onChange(of: soundDevice) { v in
                            UserDefaults.standard.set(v, forKey: "husk.soundDevice")
                        }
                }
            } header: {
                Text("Sound")
            } footer: {
                Text("Adds a sound device. While it is attached Android cannot be "
                   + "saved — QEMU refuses to snapshot a machine with one — so every "
                   + "launch boots from cold. Turning it on or off costs a cold boot "
                   + "either way.")
            }
        }
        .huskForm()
        .navigationTitle("Performance")
    }
}

// MARK: - Input

struct InputSettings: View {
    @State private var preset: RuntimeDisplayConfiguration.Preset
    @State private var orientation: RuntimeDisplayConfiguration.Orientation
    @State private var widthText: String
    @State private var heightText: String
    @State private var viewport: RuntimeDisplayConfiguration.Viewport

    init() {
        let metrics = Self.viewports()
        let preferences = RuntimeDisplayConfiguration.Preferences.current.resolved(for: metrics.device)
        _preset = State(initialValue: preferences.preset)
        _orientation = State(initialValue: preferences.orientation)
        _widthText = State(initialValue: String(preferences.customWidth > 0 ? preferences.customWidth : 720))
        _heightText = State(initialValue: String(preferences.customHeight > 0 ? preferences.customHeight : 1280))
        _viewport = State(initialValue: metrics.window)
    }

    private static func viewports() -> (window: RuntimeDisplayConfiguration.Viewport,
                                       device: RuntimeDisplayConfiguration.Viewport) {
        let window = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first(where: \.isKeyWindow)
        let screen = window?.screen ?? UIScreen.main
        let bounds = window?.bounds ?? screen.bounds
        return (.init(width: Double(bounds.width), height: Double(bounds.height), nativeScale: Double(screen.nativeScale)),
                .init(width: Double(screen.bounds.width), height: Double(screen.bounds.height), nativeScale: Double(screen.nativeScale)))
    }

    private var custom: (w: Int, h: Int)? {
        QemuRunner.validResolution(w: Int(widthText) ?? 0, h: Int(heightText) ?? 0)
    }

    private var preview: RuntimeDisplayConfiguration {
        .make(viewport: viewport, preferences: .init(preset: preset, orientation: orientation,
            customWidth: Int(widthText) ?? 0, customHeight: Int(heightText) ?? 0))
    }

    var body: some View {
        GeometryReader { geometry in
            Form {
                Section {
                    Picker("Pixel Budget", selection: $preset) {
                        ForEach(RuntimeDisplayConfiguration.Preset.allCases) { Text($0.title).tag($0) }
                    }
                    .onChange(of: preset) { _ in storeSelection() }
                    if preset != .custom {
                        Picker("Orientation", selection: $orientation) {
                            ForEach(RuntimeDisplayConfiguration.Orientation.allCases) { Text($0.title).tag($0) }
                        }
                        .onChange(of: orientation) { _ in storeSelection() }
                    } else {
                        HStack {
                            Text("Width")
                            Spacer()
                            TextField("720", text: $widthText)
                                .keyboardType(.numberPad).multilineTextAlignment(.trailing)
                                .font(.technical()).frame(width: 90)
                                .onChange(of: widthText) { _ in storeCustom() }
                        }
                        HStack {
                            Text("Height")
                            Spacer()
                            TextField("1280", text: $heightText)
                                .keyboardType(.numberPad).multilineTextAlignment(.trailing)
                                .font(.technical()).frame(width: 90)
                                .onChange(of: heightText) { _ in storeCustom() }
                        }
                        if custom == nil {
                            Text("Both sides must be between 240 and 2560 pixels. The last valid size is kept while editing.")
                                .font(.caption).foregroundStyle(.orange)
                        }
                    }
                    Button("Fit Current Window") {
                        viewport = Self.viewports().window
                        preset = .balanced
                        orientation = .device
                        storeSelection()
                    }
                    if preset != .custom || custom != nil {
                        DetailRow(label: "Next boot", value: preview.summary)
                    }
                    DetailRow(label: "Running now", value: QemuRunner.runtimeDisplaySummary)
                } header: {
                    Text("Android Runtime Display")
                } footer: {
                    Text("Balanced matches this window's proportions with a 1280-pixel longest edge. "
                       + "Lower budgets reduce rendering work; actual speed depends on the app. "
                       + "Android's interface density scales with the panel so controls stay readable. "
                       + "Custom sizes keep the shape you enter; sizes are rounded to a multiple of eight.")
                }
                Section {
                    Text("Changes apply at the next runtime boot. Close APK Container completely and reopen it. "
                       + "The running panel keeps its shape when the iPad or iPhone rotates; the picture fits without stretching.")
                    Text("Older Device Maximum and Device 50% presets now follow the current window orientation. "
                       + "Other saved custom dimensions are preserved.")
                } header: {
                    Text("Applying Changes")
                }
                Section {
                    Text("Touch follows the displayed image. Use the keyboard and rotate controls at the bottom of the app screen.")
                } header: {
                    Text("Controls")
                }
            }
            .huskForm()
            .onChange(of: geometry.size) { _ in viewport = Self.viewports().window }
            .onAppear { viewport = Self.viewports().window }
        }
        .navigationTitle("Runtime Display & Input")
    }

    private func storeSelection() {
        UserDefaults.standard.set(preset.rawValue, forKey: RuntimeDisplayConfiguration.Preferences.presetKey)
        UserDefaults.standard.set(orientation.rawValue, forKey: RuntimeDisplayConfiguration.Preferences.orientationKey)
        if preset == .custom { storeCustom() }
    }

    private func storeCustom() {
        guard let size = custom else { return }
        UserDefaults.standard.set(size.w, forKey: "husk.resWidth")
        UserDefaults.standard.set(size.h, forKey: "husk.resHeight")
    }
}

// MARK: - Network

struct NetworkSettings: View {
    var body: some View {
        Form {
            Section {
                Text("Android reaches the internet through a virtual ethernet card "
                   + "on QEMU's own network. Nothing on your phone's network can see "
                   + "the guest, and the guest cannot see it.")
                    .font(.footnote).foregroundStyle(.secondary)
            } header: {
                Text("How it connects")
            }
        }
        .huskForm()
        .navigationTitle("Network")
    }
}

// MARK: - JIT and sideloading

struct JITSettings: View {
    @ObservedObject private var runner = QemuRunner.shared
    @ObservedObject private var jit = JITCoordinator.shared
    @State private var autoStart = Onboarding.autoStart
    @AppStorage(JITCoordinator.autoEnableKey) private var autoJIT = false
    @AppStorage(JITCoordinator.trollStoreAutoKey) private var trollStoreJIT = true
    @State private var keepAttached = JITBootstrap.keepDebuggerAttached

    private var pairingLabel: String {
        switch jit.pairingSource {
        case .onDevice: return "paired on this device"
        case .imported: return "file imported"
        case nil: return "not set up"
        }
    }

    var body: some View {
        Form {
            Section {
                JITCard()
            }
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)

            Section {
                Picker("Method", selection: $jit.method) {
                    ForEach(JITMethod.allCases) { Text($0.title).tag($0) }
                }
                DetailRow(label: "StikDebug",
                          value: JITBootstrap.isStikDebugInstalled ? "installed" : "not found", mono: false)
                DetailRow(label: "TrollStore",
                          value: JITBootstrap.isTrollStoreInstalled ? "installed" : "not found", mono: false)
                DetailRow(label: "Installed with TrollStore",
                          value: JITBootstrap.isInstalledWithTrollStore ? "yes" : "no", mono: false)
                DetailRow(label: "Jailbreak",
                          value: JITBootstrap.debuggedAtLaunch ? "JIT allowed for apps"
                               : JITBootstrap.isJailbroken ? "found" : "not found", mono: false)
                DetailRow(label: "Built-in pairing", value: pairingLabel, mono: false)
                Button {
                    jit.showSetup = true
                } label: {
                    Label("Set up JIT", systemImage: "wand.and.stars")
                }
            } header: {
                Text("Other Ways to Turn On JIT")
            } footer: {
                Text(jit.method == .automatic
                     ? jit.automaticDescription + " Built-in StikJIT needs iOS 26, LocalDevVPN, and a "
                       + "pairing file, which APK Container can make itself on iOS 27."
                     : HuskBuiltInJIT.unavailableReason ?? "Built-in StikJIT needs LocalDevVPN and a pairing "
                       + "file, which APK Container can make itself on iOS 27.")
            }

            Section {
                DetailRow(label: "Debugger",
                          value: JITBootstrap.isDebuggerAttached ? "attached" : "not attached",
                          mono: false)
                DetailRow(label: "Executable memory",
                          value: JITBootstrap.isLive ? "granted" : "not claimed", mono: false)
                // The two routes, named separately. Either one is enough, and
                // when someone reports "JIT does not work" these two rows are
                // the whole diagnosis.
                DetailRow(label: "Trap servicer",
                          value: husk_ios_jit_self_route() != nil ? "not needed"
                               : JITBootstrap.prewarmed ? "answering" : "not answering",
                          mono: false)
                if let route = husk_ios_jit_self_route() {
                    DetailRow(label: "Made by APK Container",
                              value: String(cString: route) == "MAP_JIT" ? "MAP_JIT (TrollStore entitlement)" : "plain memory (debugged or jailbroken)",
                              mono: false)
                }
                // Cached answer only: running the probe from a view body
                // could freeze the app (see JITBootstrap.mapJITWorks).
                DetailRow(label: "MAP_JIT",
                          value: JITBootstrap.deviceEnforcesTXM ? "not used (TXM)"
                               : JITBootstrap.mapJITResult.map { $0 ? "executes" : "refused" }
                                 ?? "not tested",
                          mono: false)
                DetailRow(label: "Debugger after setup",
                          value: JITBootstrap.detached ? "detached" : "attached",
                          mono: false)
                if let why = JITBootstrap.lastFailure {
                    Text(why).font(.caption).foregroundStyle(.orange)
                }
                if !JITBootstrap.ready {
                    Button {
                        jit.enable()
                    } label: {
                        Label("Enable JIT with \(jit.resolvedMethod.title)", systemImage: "bolt.fill")
                    }
                    .disabled(jit.busy)
                    Button {
                        _ = JITBootstrap.requestTrollStoreAttach()
                    } label: {
                        Label("Enable JIT with TrollStore", systemImage: "sparkles")
                    }
                }
            } header: {
                Text("JIT")
            } footer: {
                Text("APK Container needs memory it can write and then execute, which on iOS "
                   + "takes an attached debugger. There are two ways to get it: a "
                   + "debugger that services trap requests, or a MAP_JIT mapping, "
                   + "which the kernel allows any debugged process. Either one is "
                   + "enough — which is available depends on the device and the iOS "
                   + "version, so APK Container tests both rather than assuming.")
            }

            if JITBootstrap.isInstalledWithTrollStore {
                Section {
                    Toggle("Turn On JIT with TrollStore at Launch", isOn: $trollStoreJIT)
                } footer: {
                    Text("Each time APK Container opens without JIT, it asks TrollStore to turn it on. TrollStore's URL Scheme setting must be on.")
                }
            }

            Section {
                Toggle("Turn On JIT at Launch", isOn: $autoJIT)
                    .disabled(!HuskBuiltInJIT.isAvailable)
            } footer: {
                Text(HuskBuiltInJIT.isAvailable
                     ? "Each time APK Container opens without JIT, it asks the built-in StikJIT to turn it on, so games are ready "
                       + "without a tap. Needs StikJIT set up once (paired) first."
                     : "Needs the built-in StikJIT, which is available on iOS 26 and later.")
            }

            Section {
                Toggle("Prewarm compatibility runtime", isOn: $autoStart)
                    .onChange(of: autoStart) { v in
                        UserDefaults.standard.set(v, forKey: "husk.autoStart")
                    }
            } footer: {
                Text("Starts the compatibility runtime in the background when APK Container opens and JIT is available.")
            }

            Section {
                Toggle("Keep debugger attached", isOn: $keepAttached)
                    .onChange(of: keepAttached) { v in JITBootstrap.keepDebuggerAttached = v }
            } footer: {
                Text("Off by default. APK Container detaches StikDebug as soon as the "
                   + "JIT region is held, because a debugger that iOS has suspended "
                   + "stops the whole app the next time it is needed. Turn this on "
                   + "only to collect StikDebug's own logs.")
            }

            Section {
                Text("APKs install from the Library's + button or from the Files tab. "
                   + "Split sets — a base APK plus its config pieces — must be picked "
                   + "together; installing the base alone fails on missing native "
                   + "libraries.")
                    .font(.footnote).foregroundStyle(.secondary)
            } header: {
                Text("Sideloading")
            }
        }
        .huskForm()
        .navigationTitle("JIT & sideload")
    }
}

// MARK: - Saved machine

struct SavedMachineSettings: View {
    @ObservedObject private var runner = QemuRunner.shared
    @State private var autoSave =
        UserDefaults.standard.object(forKey: "husk.autoSave") as? Bool ?? true
    @State private var askWhichToDelete = false
    @State private var deleteResult: String?
    @State private var askRemoveAndroid = false
    @State private var removeResult: String?
    @State private var androidBytes = GuestImage.shared.androidBytes
    @AppStorage(GuestImage.askUpdatesKey) private var askUpdates = true

    var body: some View {
        Form {
            Section {
                Toggle("Save software runtime automatically", isOn: $autoSave)
                    .onChange(of: autoSave) { v in
                        UserDefaults.standard.set(v, forKey: "husk.autoSave")
                        HuskLog.log("ui", v ? "automatic saving on" : "automatic saving off")
                    }
                Button {
                    QemuRunner.shared.saveState(reason: "asked from settings")
                } label: {
                    Label(runner.isSavingState ? "Saving…" : "Save now",
                          systemImage: "externaldrive.badge.checkmark")
                }
                .disabled(runner.isSavingState || !runner.isRunning || !runner.snapshotSavingSupported)
            } footer: {
                Text("GPU runtime snapshots are disabled because stopping Android’s display "
                   + "can crash its apps. Installed APKs and app data remain on the Android disk. "
                   + "Software runtime snapshots are available; restoring one returns Android "
                   + "and its app data to the saved point.")
            }

            Section {
                Button(role: .destructive) { askWhichToDelete = true } label: {
                    Label("Delete saved machine", systemImage: "trash")
                }
                .disabled(!QemuRunner.shared.hasSnapshot)
                if let deleteResult {
                    Text(deleteResult).font(.caption).foregroundStyle(.secondary)
                }
            } footer: {
                Text(QemuRunner.shared.hasSnapshot
                     ? "Currently saved: "
                     + (RuntimeSnapshotPolicy.displayMode(of: QemuRunner.shared.snapshotDisplay ?? "sw") == "gl"
                        ? "GPU" : "software") + "."
                     : "Nothing is saved, so Android boots from cold.")
            }

            Section {
                Label("Start from the Android disk", systemImage: "internaldrive")
            } footer: {
                Text("Older and downloaded RAM snapshots are incompatible with this build. "
                   + "Android starts from its current disk, keeping installed APKs and app data. "
                   + "The first start can take several minutes.")
            }

            Section {
                Button(role: .destructive) { askRemoveAndroid = true } label: {
                    Label("Remove Android", systemImage: "trash.slash")
                }
                .disabled(runner.isRunning || androidBytes == 0)
                if let removeResult {
                    Text(removeResult).font(.caption).foregroundStyle(.secondary)
                }
            } footer: {
                Text(androidBytes > 0
                     ? "Android's system, its data and the saved machine take \(ByteCountFormatter.string(fromByteCount: androidBytes, countStyle: .file)). "
                     + "Apps and games on the translation layer do not need them. Android downloads again the next time it is started."
                     : "Android is not downloaded.")
            }

            Section {
                Toggle("Ask about Android updates", isOn: $askUpdates)
            } footer: {
                Text("When a new Android system image is published, APK Container asks once whether to download it. "
                   + "Never asked before Android has been downloaded.")
            }
        }
        .huskForm()
        .navigationTitle("Saved machine")
        .confirmationDialog("Which saved machine?", isPresented: $askWhichToDelete,
                            titleVisibility: .visible) {
            Button("GPU machine", role: .destructive) { forget("gl", "GPU") }
            Button("Software machine", role: .destructive) { forget("sw", "software") }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Android will boot from its current disk. This does not remove installed APKs or app data.")
        }
        .confirmationDialog("Remove Android?", isPresented: $askRemoveAndroid, titleVisibility: .visible) {
            Button("Remove Android", role: .destructive) {
                let freed = GuestImage.shared.removeAll()
                androidBytes = GuestImage.shared.androidBytes
                removeResult = "Freed \(ByteCountFormatter.string(fromByteCount: freed, countStyle: .file))."
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Everything installed or saved inside Android is deleted. Translation layer apps keep their data.")
        }
    }

    private func forget(_ mode: String, _ name: String) {
        if QemuRunner.shared.forgetSnapshot(mode: mode) {
            deleteResult = "Deleted the \(name) machine. The next launch boots from cold."
        } else {
            deleteResult = "No \(name) machine is saved, so nothing was deleted."
        }
    }
}

// MARK: - Appearance

struct AppearanceSettings: View {
    @State private var appIcon = HuskAppIcon.current
    @AppStorage(Theme.Appearance.key) private var appearance = Theme.Appearance.system
    @ObservedObject private var theme = AppTheme.shared
    @Environment(\.colorScheme) private var scheme
    @State private var custom: Color = AppTheme.shared.accentColor

    private let iconColumns = [GridItem(.adaptive(minimum: 92), spacing: 14)]

    var body: some View {
        Form {
            Section {
                Picker("Appearance", selection: $appearance) {
                    ForEach(Theme.Appearance.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .onChange(of: appearance) { v in
                    HuskLog.log("ui", "appearance: \(v.rawValue)")
                }
            } header: {
                Text("Theme")
            } footer: {
                Text("System follows the phone: light by day, dark by night. The guest's own "
                   + "screen stays dark either way — it is a picture of another phone. "
                   + "Your selected appearance applies throughout APK Container.")
            }

            Section {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 5), spacing: 14) {
                    ForEach(AppTheme.presets) { preset in
                        Button {
                            theme.accentColor = preset.color
                            custom = preset.color
                        } label: {
                            swatch(preset.color, selected: preset.color.themeHex == theme.accentColor.themeHex)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(preset.name)
                    }
                }
                .padding(.vertical, 6)

                ColorPicker("Custom Colour", selection: $custom, supportsOpacity: false)
                    .onChange(of: custom) { theme.accentColor = $0 }
            } header: {
                Text("Accent Colour")
            } footer: {
                Text("Tints buttons, switches and selected states throughout the app.")
            }

            Section {
                LazyVGrid(columns: iconColumns, spacing: 14) {
                    ForEach(HuskAppIcon.allCases) { icon in
                        Button {
                            appIcon = icon
                            HuskAppIcon.apply(icon)
                        } label: {
                            VStack(spacing: 8) {
                                if let art = icon.preview(dark: scheme == .dark) {
                                    Image(uiImage: art)
                                        .resizable().scaledToFit()
                                        .frame(width: 60, height: 60)
                                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                                            .strokeBorder(appIcon == icon ? Color.accentColor : .clear, lineWidth: 3))
                                }
                                Text(icon.title)
                                    .font(.caption)
                                    .foregroundStyle(appIcon == icon ? Color.accentColor : .primary)
                                    .lineLimit(1)
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 6)
            } header: {
                Text("App Icon")
            } footer: {
                Text("Automatic follows the system appearance — light, dark and tinted. The others pin "
                   + "one look. iOS shows its own confirmation after a change; that alert cannot be turned off.")
            }
        }
        .navigationTitle("Appearance")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func swatch(_ color: Color, selected: Bool) -> some View {
        Circle()
            .fill(color)
            .frame(width: 34, height: 34)
            .overlay(Circle().strokeBorder(Color.primary.opacity(0.9), lineWidth: selected ? 2 : 0).padding(-4))
            .overlay {
                if selected {
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(color.isLight ? .black : .white)
                }
            }
            .frame(maxWidth: .infinity)
    }
}

// MARK: - About

struct AboutSettings: View {
    @ObservedObject private var runner = QemuRunner.shared
    @State private var showLogs = false
    @AppStorage(TranslationLayer.devInfoKey) private var devInfo = false

    var body: some View {
        List {
            Section {
                VStack(spacing: 8) {
                    HuskMark(size: 84)
                    Text("APK Container").font(.title2.weight(.semibold))
                    Text("Version \(Bundle.main.version)")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .listRowBackground(Color.clear)
            }

            Section {
                LabeledContent("Build", value: Bundle.main.commit)
                LabeledContent("Guest image", value: GuestImage.imageVersion)
                LabeledContent("Renderer",
                               value: runner.displayKind == .gl ? "GPU"
                                    : runner.displayKind == .software ? "CPU"
                                    : "Not started")
            }

            Section {
                Toggle(isOn: $devInfo) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Developer Info")
                        Text("Technical detail in the Android Translation Layer screens: "
                           + "library reports, device checks and run logs.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if devInfo {
                    NavigationLink { TLChecksView() } label: {
                        Label("Device Checks", systemImage: "stethoscope")
                    }
                    NavigationLink { MassTestView() } label: {
                        Label("Mass Test", systemImage: "square.stack.3d.down.forward")
                    }
                }
                Button { showLogs = true } label: {
                    Label("Open Console", systemImage: "terminal")
                }
            } footer: {
                Text("APK Container runs Android APKs with a native translation layer and an optional Android compatibility runtime on iPhone and iPad. "
                   + "The console shows APK Container's live log, the guest's serial output and QEMU's own "
                   + "output — the three files any problem here is diagnosed from.")
            }
        }
        .navigationTitle("About")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showLogs) { LogView() }
    }
}

extension Bundle {
    var version: String {
        (infoDictionary?["CFBundleShortVersionString"] as? String) ?? "?"
    }
    var commit: String {
        (infoDictionary?["HuskBuildCommit"] as? String) ?? "?"
    }
}
