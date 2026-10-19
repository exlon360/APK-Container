// SPDX-License-Identifier: GPL-2.0-or-later
import SwiftUI
import UIKit

/// What a person can change about how one game runs here, kept in the game's own folder (`settings.json`) so it goes when the game
/// does. Like LiveContainer's per-app settings: each game has its own, and nothing here touches another game.
struct TLAppSettings: Codable, Equatable {
    /// Which way up the screen is while the game runs.
    enum Orientation: String, Codable, CaseIterable, Identifiable {
        /// What the game asks for (its manifest), landscape when it does not say.
        case auto, landscape, portrait
        var id: String { rawValue }
        var title: String {
            switch self {
            case .auto: return "Automatic"
            case .landscape: return "Landscape"
            case .portrait: return "Portrait"
            }
        }
    }

    typealias Resolution = APKDisplayResolution.Preset

    /// When the on-screen controller is offered.
    enum PadMode: String, Codable, CaseIterable, Identifiable {
        /// For the games that cannot be played without a controller (Unreal, PC games through DXVK), when none is connected.
        case auto, always, never
        var id: String { rawValue }
        var title: String {
            switch self {
            case .auto: return "Automatic"
            case .always: return "Always"
            case .never: return "Never"
            }
        }
    }

    /// Where the app opens: full screen, or a window over Husk that can be moved, resized and minimised (Multitasking).
    enum WindowMode: String, Codable, CaseIterable, Identifiable {
        /// As Settings › Multitasking says for every app.
        case auto, window, fullScreen
        var id: String { rawValue }
        var title: String {
            switch self {
            case .auto: return "Default"
            case .window: return "Window"
            case .fullScreen: return "Full Screen"
            }
        }
    }

    var orientation: Orientation = .auto
    var window: WindowMode = .auto
    var resolution: Resolution = .automatic
    var maximumRenderEdge: Int = APKDisplayResolution.defaultMaximumEdge
    /// The frames-per-second readout in the top bar.
    var showStats = true
    /// Start with nothing over the picture: no bar, no controller, no readout. Three fingers tapped together bring them back.
    var cleanView = false
    /// Stop the screen from dimming and locking while the game is on.
    var keepAwake = true
    var pad: PadMode = .auto
    /// Whether the controller is showing right now (the Pad button in the top bar toggles it).
    var padShown = true
    var padOpacity = 1.0
    var haptics = true
    /// Geometry Dash only: load Geode, its mod loader (Geode.swift).
    var geode = false

    init() {}

    // Settings written by an older Husk lack the keys a newer one added; each falls back to its default.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        orientation = try c.decodeIfPresent(Orientation.self, forKey: .orientation) ?? .auto
        resolution = try c.decodeIfPresent(Resolution.self, forKey: .resolution) ?? .automatic
        maximumRenderEdge = APKDisplayResolution.clampedMaximumEdge(
            try c.decodeIfPresent(Int.self, forKey: .maximumRenderEdge) ?? APKDisplayResolution.defaultMaximumEdge)
        showStats = try c.decodeIfPresent(Bool.self, forKey: .showStats) ?? true
        cleanView = try c.decodeIfPresent(Bool.self, forKey: .cleanView) ?? false
        keepAwake = try c.decodeIfPresent(Bool.self, forKey: .keepAwake) ?? true
        pad = try c.decodeIfPresent(PadMode.self, forKey: .pad) ?? .auto
        padShown = try c.decodeIfPresent(Bool.self, forKey: .padShown) ?? true
        padOpacity = try c.decodeIfPresent(Double.self, forKey: .padOpacity) ?? 1.0
        haptics = try c.decodeIfPresent(Bool.self, forKey: .haptics) ?? true
        geode = try c.decodeIfPresent(Bool.self, forKey: .geode) ?? false
        window = try c.decodeIfPresent(WindowMode.self, forKey: .window) ?? .auto
    }

    private static func url(_ id: String) -> URL {
        TranslationLayer.root.appendingPathComponent(id, isDirectory: true).appendingPathComponent("settings.json")
    }

    static func load(_ id: String) -> TLAppSettings {
        (try? Data(contentsOf: url(id))).flatMap { try? JSONDecoder().decode(TLAppSettings.self, from: $0) } ?? TLAppSettings()
    }

    func save(_ id: String) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        // The folder is gone when the app was removed while its settings page was open.
        guard FileManager.default.fileExists(atPath: Self.url(id).deletingLastPathComponent().path),
              let data = try? encoder.encode(self) else { return }
        try? data.write(to: Self.url(id), options: .atomic)
    }
}

// MARK: - The settings page

/// One game's settings, opened from its page or from its tile's menu.
struct TLAppSettingsView: View {
    let app: TLApp

    @ObservedObject private var store = TranslationLayerStore.shared
    @ObservedObject private var geode = GeodeSupport.shared
    @State private var settings: TLAppSettings
    @State private var name: String
    @State private var dataSize: String = "…"
    @State private var confirmReset = false
    @FocusState private var nameFocused: Bool

    init(app: TLApp) {
        self.app = app
        _settings = State(initialValue: TLAppSettings.load(app.id))
        _name = State(initialValue: app.label)
    }

    /// The game is loaded in this run of Husk, so what it keeps cannot be swapped from under it.
    private var inUse: Bool {
        guard let loaded = husk_native_loaded_apk().map({ String(cString: $0) }), let apk = app.apks.first else { return false }
        return loaded == apk
    }

    private var dataDirs: [URL] {
        let dir = TranslationLayer.root.appendingPathComponent(app.id, isDirectory: true)
        return ["unity-data", "cocos-data", "minecraft-data", "sdl-data", "ue4-data", "gta-data", "na-data", "godot-data", "flutter-data", "gm-data", "web"]
            .map { dir.appendingPathComponent($0, isDirectory: true) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    private var resolutionPreview: String {
        let screen = UIScreen.main
        let short = min(screen.bounds.width, screen.bounds.height)
        let long = max(screen.bounds.width, screen.bounds.height)
        let portrait = app.drawsPortrait(settings)
        guard let surface = APKDisplayResolution.surface(width: Double(portrait ? short : long),
                                                         height: Double(portrait ? long : short),
                                                         nativeScale: Double(screen.nativeScale), preset: settings.resolution,
                                                         maximumEdge: settings.maximumRenderEdge,
                                                         defaultPreset: APKDisplayResolution.defaultPreset) else { return "Unavailable" }
        return "\(surface.width) × \(surface.height)"
    }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    AppIcon(path: app.iconPath, size: 52)
                    TextField("Name", text: $name)
                        .focused($nameFocused)
                        .submitLabel(.done)
                        .onSubmit { rename() }
                        .font(.system(size: 18, weight: .semibold))
                }
                .padding(.vertical, 2)
            } footer: {
                Text("The app's name in APK Container. The Android app itself is not changed.")
            }

            Section {
                Picker("Orientation", selection: $settings.orientation) {
                    ForEach(TLAppSettings.Orientation.allCases) { Text($0.title).tag($0) }
                }
                Picker("Resolution", selection: $settings.resolution) {
                    ForEach(TLAppSettings.Resolution.allCases) {
                        Text($0 == .automatic ? "Default (\(APKDisplayResolution.defaultPreset.title))" : $0.title).tag($0)
                    }
                }
                if settings.resolution == .custom {
                    Stepper("Maximum edge: \(settings.maximumRenderEdge) px", value: $settings.maximumRenderEdge,
                            in: APKDisplayResolution.customRange, step: 80)
                    Picker("Pixel limit", selection: $settings.maximumRenderEdge) {
                        ForEach(Array(Set([720, 1080, 1440, 1920, 2560, 3072, 4096, settings.maximumRenderEdge])).sorted(), id: \.self) {
                            Text("\($0) px").tag($0)
                        }
                    }
                }
                DetailRow(label: "Full-screen preview", value: resolutionPreview)
                Toggle("Performance readout", isOn: $settings.showStats)
                Toggle("Keep the screen on", isOn: $settings.keepAwake)
            } header: {
                Text("Display")
            } footer: {
                Text("\(settings.resolution.detail) Phone and iPad proportions are preserved. Lower resolutions reduce pixel workload; "
                   + "actual speed depends on the app. Changes apply on the next launch; close APK Container completely first if this app is already loaded.")
            }

            Section {
                Picker("Open In", selection: $settings.window) {
                    ForEach(TLAppSettings.WindowMode.allCases) { m in
                        Text(m == .auto ? "Default (\(AppWindows.defaultWindowed ? "Window" : "Full Screen"))" : m.title).tag(m)
                    }
                }
            } header: {
                Text("Multitasking")
            } footer: {
                Text("Tap with three fingers for window controls. Choose Arrange Window to move or resize the app, or Minimize App to keep it in the dock while using APK Container.")
            }

            Section {
                Text("Tap with three fingers for app controls.")
            } header: {
                Text("App Controls")
            } footer: {
                Text("Host toolbars stay hidden while the app runs. App Files, keyboard controls, and Return to Apps are available in the controls sheet.")
            }

            if app.packageName == GeodeSupport.gamePackage {
                Section {
                    Toggle("Geode", isOn: $settings.geode)
                    if settings.geode { geodeStatus }
                } header: {
                    Text("Mods")
                } footer: {
                    Text("Geode is the mod loader for Geometry Dash. With it on, APK Container downloads Geode for this version of the "
                       + "game, and mods are found and installed in the game itself, from Geode's button on the main menu. "
                       + "Applies the next time the game starts.")
                }
            }

            Section {
                Picker("On-screen controller", selection: $settings.pad) {
                    ForEach(TLAppSettings.PadMode.allCases) { Text($0.title).tag($0) }
                }
                if settings.pad != .never {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Opacity")
                        Slider(value: $settings.padOpacity, in: 0.3...1)
                    }
                    Toggle("Vibrate on a press", isOn: $settings.haptics)
                }
            } header: {
                Text("Controller")
            } footer: {
                Text("Automatic offers the controller for games that cannot be played without one (Unreal Engine games), when no real "
                   + "controller is connected. Always offers it for any game that understands one. A paired controller is always used.")
            }

            Section {
                Button { AppClip.generate(for: app) } label: {
                    Label("Generate App Clip", systemImage: "apps.iphone.badge.plus")
                }
            } header: {
                Text("Home Screen")
            } footer: {
                Text("Puts \(app.label) on your Home Screen with its own icon. Tapping it opens APK Container straight into the app. APK Container "
                   + "downloads a profile: open Settings, tap Profile Downloaded, then Install.")
            }

            Section {
                DetailRow(label: "Saved by the app", value: dataSize, mono: false)
                Button(role: .destructive) { confirmReset = true } label: {
                    Label("Reset App Data", systemImage: "arrow.counterclockwise")
                }
                .disabled(inUse || dataDirs.isEmpty)
            } header: {
                Text("Data")
            } footer: {
                Text(inUse ? "The app is loaded in this session. Close APK Container completely and open it again to reset its data."
                           : "Deletes what the app saved and downloaded here: saves, settings and caches. The app itself stays.")
            }
        }
        .huskForm()
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: settings) { $0.save(app.id) }
        .onChange(of: settings.geode) { on in
            if on { Task { await geode.prepare(app) } } else { geode.remove(app) }
        }
        .onChange(of: nameFocused) { focused in if !focused { rename() } }
        .onDisappear { rename() }
        .task { dataSize = await Self.measure(dataDirs) }
        .confirmationDialog("Reset the data of \(app.label)?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Reset App Data", role: .destructive) {
                for dir in dataDirs { try? FileManager.default.removeItem(at: dir) }
                HuskLog.log("tl", "reset the data of \(app.label)")
                Task { dataSize = await Self.measure(dataDirs) }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Saves, settings and caches the app made here are deleted.")
        }
    }

    @ViewBuilder
    private var geodeStatus: some View {
        switch geode.current(app) {
        case .idle:
            Button("Download Geode") { Task { await geode.prepare(app) } }
        case .working(let what):
            HStack(spacing: 10) { ProgressView(); Text(what).foregroundStyle(.secondary) }
        case .ready(let version):
            LabeledContent("Geode", value: "v\(version), ready")
        case .failed(let why):
            VStack(alignment: .leading, spacing: 6) {
                Text(why).font(.footnote).foregroundStyle(.orange)
                Button("Try Again") { Task { await geode.prepare(app) } }
            }
        }
    }

    private func rename() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != app.label else { return }
        store.rename(app, to: trimmed)
    }

    private static func measure(_ dirs: [URL]) async -> String {
        await Task.detached(priority: .utility) {
            var bytes: Int64 = 0
            for dir in dirs {
                let walker = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey])
                while let url = walker?.nextObject() as? URL {
                    let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                    if values?.isRegularFile == true { bytes += Int64(values?.fileSize ?? 0) }
                }
            }
            return bytes == 0 ? "nothing" : ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        }.value
    }
}

/// Default render density for apps that have not chosen an override. The rendering view resolves the actual screen at launch.
struct DisplayDefaultsSettingsView: View {
    @AppStorage(APKDisplayResolution.defaultsKey) private var storedPreset = APKDisplayResolution.Preset.native.rawValue

    private var selection: Binding<APKDisplayResolution.Preset> {
        Binding(get: { APKDisplayResolution.defaultPreset }, set: { storedPreset = $0.rawValue })
    }

    var body: some View {
        Form {
            Section {
                Picker("Default Resolution", selection: selection) {
                    ForEach(APKDisplayResolution.defaultChoices) { Text($0.title).tag($0) }
                }
                DetailRow(label: "Device pixels",
                          value: "\(Int(UIScreen.main.nativeBounds.width)) × \(Int(UIScreen.main.nativeBounds.height))")
            } header: {
                Text("Native App Rendering")
            } footer: {
                Text("\(APKDisplayResolution.defaultPreset.detail) Applies to apps using the native renderer. "
                   + "A smaller pixel budget can reduce GPU and memory use; performance depends on the app and device.")
            }
            Section {
                NavigationLink("Android Runtime Display & Input") { InputSettings() }
                Text("Apps using the compatibility runtime share a separate panel and pixel budget. Change their resolution and interface size here.")
                    .font(.footnote).foregroundStyle(.secondary)
            } header: {
                Text("Compatibility Runtime")
            }
            Section {
                Text("Open an app's settings to choose its orientation, a different resolution, or a custom longest-edge limit from 320 to 4096 pixels. "
                   + "The other edge is calculated automatically to keep the image in proportion.")
                Text("Resolution changes apply when the app next starts. If it is already loaded, close APK Container completely and reopen it. "
                   + "Apps with a fixed rendering surface keep their original proportions when a window is resized.")
            } header: {
                Text("Per-App Settings")
            }
        }
        .huskForm()
        .navigationTitle("Display & Resolution")
    }
}
