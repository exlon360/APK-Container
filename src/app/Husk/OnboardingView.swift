// SPDX-License-Identifier: GPL-2.0-or-later
import SwiftUI

/// What APK Container asks on a first install, and remembers.
///
/// Deliberately versioned rather than a plain "seen it" flag: a later build that
/// adds a question needs to be able to ask it, and existing installs must not be
/// dragged back through the whole flow for one new answer. Bumping
/// `Onboarding.version` is what re-opens it.
enum Onboarding {
    /// Raise this when a question is added that existing installs must answer.
    static let version = 2   // 3.0: everyone goes through the new setup once

    private static let key = "husk.onboardingVersion"

    static var needed: Bool {
        UserDefaults.standard.integer(forKey: key) < version
    }

    static func complete() {
        UserDefaults.standard.set(version, forKey: key)
    }

    /// What apps inside APK Container are told about where you are, chosen in setup.
    // TODO: hand these to the guest (TL locale/time zone and Android's persist.sys.locale / TZ); stored only for now.
    static let languageKey = "husk.guest.language"
    static let regionKey = "husk.guest.region"
    static let timeZoneKey = "husk.guest.timeZone"

    /// Start the guest as soon as the app opens, when JIT is available.
    static var autoStart: Bool {
        UserDefaults.standard.bool(forKey: "husk.autoStart")
    }
}

/// First run: setup in the manner of the iPhone's own -- language, region, time zone, the
/// optional settings, JIT -- and an offer of a walkthrough. Shown once; people who set up an older APK Container get What's New instead.
struct OnboardingView: View {
    let onDone: () -> Void

    private enum Step: Int, CaseIterable {
        case welcome, options, jit, ask, tour
    }

    @State private var step: Step = .welcome
    @State private var forward = true
    @State private var tourPage = 0

    @State private var language = OnboardingView.defaultLanguage
    @State private var region = Locale.current.huskRegionCode ?? "US"
    @State private var timeZone = TimeZone.current.identifier
    @State private var query = ""

    @State private var autoStart = false
    @State private var landscape = UserDefaults.standard.bool(forKey: "husk.landscapeGuest")
    @State private var sound = UserDefaults.standard.bool(forKey: "husk.sound")
    @State private var autoSave = UserDefaults.standard.object(forKey: "husk.autoSave") as? Bool ?? true
    @AppStorage(Theme.Appearance.key) private var appearance = Theme.Appearance.system
    @ObservedObject private var theme = AppTheme.shared
    @ObservedObject private var jit = JITCoordinator.shared
    @State private var settingUpJIT = false

    var body: some View {
        ZStack {
            Theme.backdrop
            setup
        }
        .sheet(isPresented: $settingUpJIT) { JITSetupFlow() }
    }

    // MARK: frame

    private var setup: some View {
        VStack(spacing: 0) {
            HStack {
                if step != .welcome {
                    Button { go(back: true) } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.left").font(.system(size: 16, weight: .semibold))
                            Text("Back")
                        }
                    }
                    .accessibilityLabel("Back")
                }
                Spacer()
            }
            .frame(height: 44)
            .padding(.horizontal, 16)

            ZStack {
                page(step)
                    .id(step)
                    .transition(.asymmetric(insertion: .move(edge: forward ? .trailing : .leading).combined(with: .opacity),
                                            removal: .move(edge: forward ? .leading : .trailing).combined(with: .opacity)))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()

            if step != .ask {
                VStack(spacing: 14) {
                    dots
                    Button(step == .tour && tourPage == Self.tour.count - 1 ? "Start Using APK Container" : "Continue") { next() }
                        .buttonStyle(PrimaryButtonStyle())
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 24)
                .padding(.top, 8)
            }
        }
        .frame(maxWidth: 560)
    }

    private var dots: some View {
        let count = step == .tour ? Self.tour.count : Step.ask.rawValue + 1
        let current = step == .tour ? tourPage : step.rawValue
        return HStack(spacing: 6) {
            ForEach(0..<count, id: \.self) { i in
                Capsule()
                    .fill(i == current ? Theme.text : Color.secondary.opacity(0.3))
                    .frame(width: i == current ? 18 : 6, height: 6)
            }
        }
        .animation(.snappy, value: current)
    }

    private func next() {
        if step == .tour {
            if tourPage < Self.tour.count - 1 { withAnimation(.snappy) { tourPage += 1 } } else { finish() }
            return
        }
        query = ""
        forward = true
        withAnimation(.snappy) { step = Step(rawValue: step.rawValue + 1) ?? .ask }
    }

    private func go(back: Bool) {
        query = ""
        forward = false
        withAnimation(.snappy) {
            if step == .tour, tourPage > 0 { tourPage -= 1; return }
            step = Step(rawValue: step.rawValue - 1) ?? .welcome
        }
    }

    private func finish() {
        let d = UserDefaults.standard
        d.set(autoStart, forKey: "husk.autoStart")
        d.set(landscape, forKey: "husk.landscapeGuest")
        d.set(sound, forKey: "husk.sound")
        d.set(autoSave, forKey: "husk.autoSave")
        d.set(language, forKey: Onboarding.languageKey)
        d.set(region, forKey: Onboarding.regionKey)
        d.set(timeZone, forKey: Onboarding.timeZoneKey)
        Onboarding.complete()
        WhatsNew.markSeen()
        HuskLog.log("ui", "setup complete: language=\(language) region=\(region) timeZone=\(timeZone) autoStart=\(autoStart) "
                        + "landscape=\(landscape) sound=\(sound) autoSave=\(autoSave)")
        onDone()
    }

    // MARK: pages

    @ViewBuilder
    private func page(_ step: Step) -> some View {
        switch step {
        case .welcome: welcome
        case .options: options
        case .jit: jitPage
        case .ask: ask
        case .tour: tourCard(Self.tour[tourPage]).id(tourPage)
        }
    }

    private func header(_ symbol: String, _ title: String, _ subtitle: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 50, weight: .regular))
                .foregroundStyle(Theme.accent)
                .frame(height: 60)
            Text(title)
                .font(.system(size: 32, weight: .bold))
                .multilineTextAlignment(.center)
            Text(subtitle)
                .font(.system(size: 16))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12)
        }
        .padding(.horizontal, 24)
        .padding(.top, 8)
    }

    private var welcome: some View {
        VStack(spacing: 18) {
            Spacer()
            HuskMark(size: 110)
            Text("Welcome to APK Container")
                .font(.system(size: 34, weight: .bold))
            Text("Android apps, on your iPhone and iPad.")
                .font(.title3).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Text("A few quick choices first. Everything here can be changed later in Settings.")
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 36)
            Spacer()
        }
    }

    /// A list to choose one from, searchable, with the choice ticked.
    private func picker(symbol: String, title: String, subtitle: String, rows: [SetupChoice],
                        selection: Binding<String>) -> some View {
        let shown = rows.filter { matches(query, $0.name, $0.id) }
        return VStack(spacing: 16) {
            header(symbol, title, subtitle)
            SearchField(text: $query, prompt: "Search")
                .padding(.horizontal, 20)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(shown) { row in
                            Button { selection.wrappedValue = row.id } label: {
                                HStack {
                                    Text(row.name).foregroundStyle(Theme.text)
                                    Spacer()
                                    if selection.wrappedValue == row.id {
                                        Image(systemName: "checkmark").font(.body.weight(.semibold)).foregroundStyle(Theme.accent)
                                    }
                                }
                                .padding(.horizontal, 16)
                                .frame(height: 46)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .id(row.id)
                            if row.id != shown.last?.id { RowDivider().padding(.leading, -46) }
                        }
                    }
                    .huskCard()
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)
                }
                .huskDismissKeyboardOnScroll()
                .onAppear { proxy.scrollTo(selection.wrappedValue, anchor: .center) }
            }
        }
    }

    private var options: some View {
        ScrollView {
            VStack(spacing: 16) {
                header("slider.horizontal.3", "Make It Yours", "All optional. You can change these any time in Settings.")

                VStack(alignment: .leading, spacing: 12) {
                    Text("Appearance").font(.headline)
                    Picker("Appearance", selection: $appearance) {
                        ForEach(Theme.Appearance.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: appearance) { Theme.apply($0) }
                    Text("Accent Colour").font(.headline).padding(.top, 4)
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 5), spacing: 12) {
                        ForEach(AppTheme.presets) { preset in
                            let selected = preset.color.themeHex == theme.accentColor.themeHex
                            Button { theme.accentColor = preset.color } label: {
                                Circle().fill(preset.color)
                                    .frame(width: 34, height: 34)
                                    .overlay(Circle().stroke(Theme.text, lineWidth: selected ? 2.5 : 0).padding(-4))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(preset.name)
                        }
                    }
                }
                .padding(16)
                .huskCard()

                choice(icon: "speaker.wave.2.fill", title: "Android Sound",
                       detail: "Adds a sound device to the emulator. It can't be saved while this is on, so it boots from cold.",
                       isOn: $sound)
                choice(icon: "externaldrive.badge.checkmark", title: "Save Android Automatically",
                       detail: "Saves the emulator once it settles, so later starts take seconds.",
                       isOn: $autoSave)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
        }
    }

    private func choice(icon: String, title: String, detail: String, isOn: Binding<Bool>, caution: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: caution ? "exclamationmark.triangle.fill" : icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(caution ? Color.orange : Theme.accent)
                .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.body.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(caution ? Color.orange : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Toggle("", isOn: isOn).labelsHidden().tint(Theme.accent)
        }
        .padding(16)
        .huskCard()
    }

    /// What the JIT page says is already in place, if anything.
    private var jitState: String? {
        if JITBootstrap.ready { return "JIT is on." }
        if jit.method == .stikDebug { return "APK Container will use StikDebug." }
        if jit.method == .trollStore { return "APK Container will use TrollStore." }
        switch jit.pairingSource {
        case .onDevice: return "Paired on this device."
        case .imported: return "Pairing file imported."
        case nil: return nil
        }
    }

    private var jitPage: some View {
        VStack(spacing: 18) {
            header("bolt.fill", "Turn On JIT",
                   "Games need JIT, which iOS only grants to an attached debugger. StikJIT is built into APK Container and turns it on from "
                 + "inside the app, with no computer. StikDebug and TrollStore work too.")
            if let state = jitState {
                Label(state, systemImage: "checkmark.circle.fill")
                    .font(.callout.weight(.medium)).foregroundStyle(.green)
            }
            Button(jitState == nil ? "Set Up StikJIT Now" : "Change JIT Setup") { settingUpJIT = true }
                .font(.body.weight(.semibold))
                .foregroundStyle(Theme.accent)
            Text("You can skip this: APK Container asks again when a game needs it, and it is in Settings › JIT & Sideload.")
                .font(.footnote).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 36)
            Spacer()
        }
    }

    private var ask: some View {
        VStack(spacing: 18) {
            Spacer()
            header("map.circle.fill", "Would you like a walkthrough?", "A quick look at how APK Container works: where your games are, how to add more, and where the settings live.")
            Spacer()
            VStack(spacing: 12) {
                Button("Show Me Around") {
                    forward = true
                    tourPage = 0
                    withAnimation(.snappy) { step = .tour }
                }
                .buttonStyle(PrimaryButtonStyle())
                Button("Not Now") { finish() }
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 24)
        }
    }

    private struct TourCard { let symbol: String; let title: String; let text: String }

    private static let tour: [TourCard] = [
        TourCard(symbol: "square.stack.3d.up.fill", title: "Apps",
                 text: "Your installed Android apps in one list. Search by name, tap an app to open it, and use its menu for settings, reports and save backups."),
        TourCard(symbol: "plus.circle.fill", title: "Import APKs",
                 text: "Tap + to add an APK or a split bundle (.xapk, .apkm or .apks). You can also share these files from Files or Safari."),
        TourCard(symbol: "arrow.up.left.and.arrow.down.right", title: "Display",
                 text: "Apps use the device's native display by default. Choose a lower resolution in Settings or an app's own settings to reduce graphics work."),
        TourCard(symbol: "bolt.fill", title: "JIT & Settings",
                 text: "Enable JIT in Settings › JIT & Sideload. Android Runtime settings prepare the optional compatibility runtime for apps that need it."),
    ]

    private func tourCard(_ card: TourCard) -> some View {
        VStack(spacing: 22) {
            Spacer()
            Image(systemName: card.symbol)
                .font(.system(size: 44, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .frame(width: 96, height: 96)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
            Text(card.title).font(.system(size: 32, weight: .bold))
            Text(card.text)
                .font(.system(size: 17))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 32)
            Spacer()
        }
        .transition(.opacity)
    }

    // MARK: lists

    private static var defaultLanguage: String {
        let preferred = Locale.preferredLanguages.first ?? "en"
        if preferred.hasPrefix("zh-Hant") || preferred.hasPrefix("zh-TW") || preferred.hasPrefix("zh-HK") { return "zh-Hant" }
        if preferred.hasPrefix("zh") { return "zh-Hans" }
        if preferred.hasPrefix("pt-BR") { return "pt-BR" }
        let code = Locale.current.huskLanguageCode ?? "en"
        return languages.contains { $0.id == code } ? code : "en"
    }

    private static let languages: [SetupChoice] = {
        let codes = ["en", "es", "fr", "de", "it", "pt", "pt-BR", "ru", "uk", "pl", "nl", "sv", "da", "nb", "fi", "tr", "el",
                     "cs", "hu", "ro", "ar", "he", "hi", "th", "vi", "id", "ms", "ja", "ko", "zh-Hans", "zh-Hant"]
        return codes.map { code in
            let native = Locale(identifier: code).localizedString(forIdentifier: code) ?? code
            let here = Locale.current.localizedString(forIdentifier: code) ?? code
            return SetupChoice(id: code, name: native == here ? native.capitalized : "\(native.capitalized) – \(here)")
        }
    }()

    private static let regions: [SetupChoice] = {
        Locale.isoRegionCodes
            .compactMap { code in Locale.current.localizedString(forRegionCode: code).map { SetupChoice(id: code, name: $0) } }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }()

    private static let timeZones: [SetupChoice] = {
        TimeZone.knownTimeZoneIdentifiers.map { id in
            let city = id.split(separator: "/").last.map { $0.replacingOccurrences(of: "_", with: " ") } ?? id
            let tz = TimeZone(identifier: id)
            let offset = tz.map { z -> String in
                let s = z.secondsFromGMT()
                return String(format: "GMT%@%d:%02d", s >= 0 ? "+" : "-", abs(s) / 3600, abs(s) % 3600 / 60)
            } ?? ""
            return SetupChoice(id: id, name: "\(city) (\(offset)) · \(id)")
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }()
}

/// One row of a setup list: what is stored, and what is shown.
struct SetupChoice: Identifiable { let id: String; let name: String }
