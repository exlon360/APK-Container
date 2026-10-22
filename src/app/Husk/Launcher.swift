// SPDX-License-Identifier: GPL-2.0-or-later
import SwiftUI

/// APKs supported by the native runtime or the Android compatibility runtime.
enum LibraryItem: Identifiable, Hashable {
    case game(TLApp)
    case app(AndroidHost.Package)

    var id: String {
        switch self {
        case .game(let g): return "tl:" + g.id
        case .app(let p): return "android:" + p.name
        }
    }

    static func == (a: LibraryItem, b: LibraryItem) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }

    var title: String {
        switch self {
        case .game(let g): return g.label
        case .app(let p): return p.label
        }
    }

    var iconPath: String? {
        switch self {
        case .game(let g): return g.iconPath
        case .app(let p): return p.iconPath
        }
    }

    /// Games on the translation layer (a Flutter app is an app unless it calls itself a game), and what Android itself files as a game.
    var isGame: Bool {
        switch self {
        case .game(let g): return (g.report?.nativeEngine != nil && g.report?.nativeEngine != .java && g.report?.nativeEngine != .flutter && g.report?.engine != "Flutter" && g.report?.webKind == nil) || g.isGameCategory
        case .app(let p): return p.category == "Game"
        }
    }

    var packageName: String? {
        switch self {
        case .game(let g): return g.packageName
        case .app(let p): return p.name
        }
    }

    /// A gameplay picture, for apps that have been run on an iPhone (fetched from GitHub; see ShowcaseStore).
    @MainActor var artworkPath: String? {
        return ShowcaseStore.shared.pictures(for: packageName).first
    }

    var runsInAndroid: Bool {
        if case .app = self { return true }
        return false
    }

    var lastUsed: Date? {
        switch self {
        case .game(let g): return g.lastPlayed
        case .app(let p): return p.lastUsed
        }
    }

    var route: LibraryRoute {
        switch self {
        case .game(let g): return .game(g.id)
        case .app(let p): return .android(p)
        }
    }

    /// "Played 2 hours ago", or nothing for what was never opened from Husk.
    var usedText: String? {
        guard let date = lastUsed else { return nil }
        let rel = RelativeDateTimeFormatter()
        rel.unitsStyle = .full
        let ago = date.timeIntervalSinceNow > -60 ? "just now" : rel.localizedString(for: date, relativeTo: Date())
        return "Opened " + ago
    }
}

/// Which items a library page shows.
enum LibraryFilter: String, CaseIterable, Identifiable {
    case all, games, apps
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: return "All"
        case .games: return "Games"
        case .apps: return "Apps"
        }
    }
}

/// Everything, from both stores, in one list.
@MainActor
enum Launcher {
    static func items(store: TranslationLayerStore, host: AndroidHost) -> [LibraryItem] {
        store.apps.map(LibraryItem.game) + host.packages.map(LibraryItem.app)
    }

    /// Most recently used first; never-used ones after, by name.
    static func byRecent(_ items: [LibraryItem]) -> [LibraryItem] {
        items.sorted { a, b in
            switch (a.lastUsed, b.lastUsed) {
            case let (x?, y?): return x > y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
            }
        }
    }

    static var jitOn: Bool { JITBootstrap.available }

    /// Play or open an item: its page, told to start the game as soon as it is up (Android apps just open their page).
    static func play(_ item: LibraryItem, push: (LibraryRoute) -> Void) {
        switch item {
        case .game(let g): Router.shared.autoPlay = g.id
        case .app(let package):
            if AndroidHost.shared.isReady, AndroidHost.shared.busy == nil {
                AndroidHost.shared.launch(package.name) { Router.shared.openGuest() }
                return
            }
        }
        push(item.route)
    }
}


// MARK: - Apps

/// A native, searchable app library. The same flexible rows fit phones, tablets,
/// Split View and large accessibility text without fixing the interface to a phone canvas.
struct LibraryScreen: View {
    @ObservedObject private var router = Router.shared
    @ObservedObject private var store = TranslationLayerStore.shared
    @ObservedObject private var host = AndroidHost.shared
    @ObservedObject private var incoming = IncomingFiles.shared
    @ObservedObject private var jit = JITCoordinator.shared
    @ObservedObject private var downloads = Downloads.shared
    @ObservedObject private var guest = GuestImage.shared
    @ObservedObject private var runner = QemuRunner.shared
    @State private var query = ""
    @State private var selectedItemID: String?
    @Environment(\.horizontalSizeClass) private var sizeClass
    @AppStorage("apkcontainer.library.sortRecent") private var sortRecent = false

    private var allItems: [LibraryItem] { Launcher.items(store: store, host: host) }
    private var items: [LibraryItem] {
        let filtered = allItems.filter {
            (router.libraryFilter == .all || (router.libraryFilter == .games) == $0.isGame)
                && matches(query, $0.title, $0.packageName ?? "")
        }
        return sortRecent ? Launcher.byRecent(filtered)
            : filtered.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    private var sidePadding: CGFloat { sizeClass == .regular ? 24 : 16 }
    private var hasWorkStatus: Bool {
        !Launcher.jitOn || jit.busy || jit.error != nil || incoming.preparing != nil
            || store.busy != nil || host.busy != nil || !incoming.forAndroid.isEmpty
            || (router.androidStarted && !host.isReady)
            || downloads.jobs.contains(where: { !$0.complete })
    }

    var body: some View {
        NavigationStack(path: $router.library) {
            VStack(spacing: 0) {
                libraryControls
                    .padding(.horizontal, sidePadding)
                    .padding(.top, 4)
                    .padding(.bottom, 14)
                ScrollView {
                    LazyVStack(spacing: 11) {
                        if hasWorkStatus { workStatus }
                        if allItems.isEmpty {
                            emptyLibrary
                        } else if items.isEmpty {
                            if query.trimmingCharacters(in: .whitespaces).isEmpty {
                                VStack(spacing: 12) {
                                    Text("No apps in this filter.").foregroundStyle(.secondary)
                                    Button("Show All Apps") { router.libraryFilter = .all }
                                }
                                .padding(.vertical, 48)
                            } else {
                                NoResults(query: query)
                            }
                        } else {
                            ForEach(items) { item in
                                ContainerAppRow(item: item, selected: selectedItemID == item.id,
                                    select: { selectedItemID = item.id },
                                    push: { router.library.append($0) })
                            }
                        }
                        Text(query.isEmpty && router.libraryFilter == .all
                             ? "\(items.count) \(items.count == 1 ? "App" : "Apps") in total"
                             : "\(items.count) of \(allItems.count) apps")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 16)
                            .padding(.bottom, 24)
                    }
                    .padding(.horizontal, sidePadding)
                }
                .huskDismissKeyboardOnScroll()
            }
            .background(Console.page)
            .navigationTitle("Apps")
            .huskNavigationBar(hidden: true)
            .libraryDestinations()
        }
    }

    private var libraryControls: some View {
        HStack(spacing: 10) {
            Button { router.addSomething() } label: { controlIcon("plus") }
                .buttonStyle(.plain)
                .accessibilityLabel("Import APK")
            Menu {
                Picker("Sort Apps", selection: $sortRecent) {
                    Text("Name").tag(false)
                    Text("Recently Opened").tag(true)
                }
                Picker("Show", selection: $router.libraryFilter) {
                    ForEach(LibraryFilter.allCases) { Text($0.title).tag($0) }
                }
                Divider()
                Button { jit.showSetup = true } label: {
                    Label(Launcher.jitOn ? "JIT Enabled" : "JIT Setup", systemImage: "bolt.fill")
                }
                Button { router.showFiles = true } label: { Label("App Files", systemImage: "folder") }
                Button { router.showDownloads = true } label: { Label("Downloads", systemImage: "arrow.down.circle") }
            } label: { controlIcon("line.3.horizontal.decrease.circle") }
            .accessibilityLabel("Library Options")

            HStack(spacing: 9) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search apps", text: $query)
                    .submitLabel(.search)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                            .frame(minWidth: 32, minHeight: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 46)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.1), lineWidth: 1))
        }
    }

    private func controlIcon(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 22, weight: .regular))
            .foregroundStyle(.primary)
            .frame(width: 46, height: 46)
            .background(.ultraThinMaterial, in: Circle())
            .overlay(Circle().strokeBorder(Color.primary.opacity(0.1), lineWidth: 1))
    }

    private var emptyLibrary: some View {
        VStack(spacing: 16) {
            Image(systemName: "square.stack.3d.up.fill")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(Color.accentColor)
            Text("Your apps, together").font(.title2.weight(.semibold))
            Text("Import an APK, discover one in Store, or build your own.")
                .font(.subheadline).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button { router.addSomething() } label: { Label("Import APK", systemImage: "plus") }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .controlSize(.large)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 56)
        .padding(.horizontal, 24)
        .background(Console.card, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private var workStatus: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !Launcher.jitOn || jit.busy || jit.error != nil { JITStatusRow() }
            if let busy = incoming.preparing { progressRow(busy) }
            if let busy = store.busy { progressRow(busy) }
            if let busy = host.busy { progressRow(busy) }
            runtimeActivity
            if downloads.jobs.contains(where: { !$0.complete }) {
                Button { router.showDownloads = true } label: {
                    Label("Downloads", systemImage: "arrow.down.circle")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(Console.card, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    @ViewBuilder
    private var runtimeActivity: some View {
        if router.androidStarted && !host.isReady {
            VStack(alignment: .leading, spacing: 8) {
                progressRow("Starting compatibility runtime…")
                if runner.bootProgress > 0 {
                    ProgressView(value: Double(runner.bootProgress), total: 100)
                }
                Text("Your app opens after startup. The first start can take several minutes.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } else if !incoming.forAndroid.isEmpty {
            switch guest.state {
            case .downloading(let progress, _, _):
                VStack(alignment: .leading, spacing: 8) {
                    Text("Downloading compatibility runtime").font(.subheadline)
                    ProgressView(value: progress)
                }
            case .installing:
                progressRow("Preparing compatibility runtime…")
            case .failed(let message):
                NavigationLink { AndroidRuntimeSettings() } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Label("Runtime Download Failed", systemImage: "exclamationmark.circle")
                        Text(message).font(.caption).foregroundStyle(.secondary)
                        Text("Tap to retry.").font(.caption)
                    }
                }
            case .missing:
                NavigationLink { AndroidRuntimeSettings() } label: {
                    Label("Set Up Compatibility Runtime", systemImage: "shippingbox")
                }
            case .ready:
                if !Launcher.jitOn {
                    Text("Your import is waiting for JIT. Enable it above to continue.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func progressRow(_ text: String) -> some View {
        HStack(spacing: 12) {
            ProgressView()
            Text(text).font(.subheadline).foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

private struct ContainerAppRow: View {
    let item: LibraryItem
    let selected: Bool
    let select: () -> Void
    let push: (LibraryRoute) -> Void
    @State private var confirmRemove = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.colorScheme) private var colorScheme

    private var subtitle: String {
        if case .app(let package) = item, let version = package.version, !version.isEmpty {
            return "\(version) · \(package.name)"
        }
        return item.packageName ?? "Android app"
    }

    /// Stable tints give each app its own row without decoding full icons during layout.
    private var tint: Color {
        let palette: [Color] = [.cyan, .mint, .blue, .green, .orange, .yellow, .indigo, .pink, .red, .purple]
        let value = (item.packageName ?? item.id).utf8.reduce(UInt64(14695981039346656037)) {
            ($0 ^ UInt64($1)) &* 1099511628211
        }
        return selected ? .accentColor : palette[Int(value % UInt64(palette.count))]
    }

    private var details: some View {
        Button {
            select()
            push(item.route)
        } label: {
            HStack(spacing: 14) {
                ItemIcon(item: item, size: sizeClass == .regular ? 64 : 56)
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 2)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Text(item.usedText ?? (item.runsInAndroid ? "Compatibility Runtime" : "Translation Layer"))
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(item.title), details")
        .accessibilityHint("Touch and hold for app settings and actions")
    }

    private var run: some View {
        Button {
            select()
            Launcher.play(item, push: push)
        } label: {
            Text("Run")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .padding(.horizontal, 22)
                .frame(minHeight: 44)
                .background(tint.opacity(colorScheme == .dark ? 0.3 : 0.2), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Run \(item.title)")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                details
                if !dynamicTypeSize.isAccessibilitySize { run }
            }
            if dynamicTypeSize.isAccessibilitySize { run }
        }
        .padding(sizeClass == .regular ? 18 : 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Console.card)
                .overlay {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .fill(tint.opacity(selected ? 0.38 : colorScheme == .dark ? 0.13 : 0.09))
                }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(Color.primary.opacity(selected ? 0.12 : 0.035), lineWidth: 1)
        }
        .contextMenu {
            LibraryItemActions(item: item, showsDetails: true, push: push) { confirmRemove = true }
        }
        .accessibilityAction(named: Text("App Settings")) {
            if case .game(let app) = item { push(.gameSettings(app.id)) }
            else { push(item.route) }
        }
        .removeItemDialog(item, isPresented: $confirmRemove)
        .accessibilityIdentifier("container.app." + item.id)
    }
}

private struct JITStatusRow: View {
    @ObservedObject private var jit = JITCoordinator.shared

    var body: some View {
        Button {
            if Launcher.jitOn { jit.showSetup = true }
            else { jit.enable() }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: Launcher.jitOn ? "bolt.circle.fill" : "bolt.circle")
                    .font(.title2)
                    .foregroundStyle(Launcher.jitOn ? Color.green : Color.orange)
                VStack(alignment: .leading, spacing: 3) {
                    Text(Launcher.jitOn ? "JIT Enabled" : "Enable JIT")
                        .font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                    Text(jit.busy ? (jit.status ?? "Enabling JIT…")
                         : Launcher.jitOn ? "Ready to launch your apps" : "Required to run Android apps")
                        .font(.caption).foregroundStyle(.secondary)
                    if let error = jit.error {
                        Text(error).font(.caption).foregroundStyle(.orange)
                    }
                }
                Spacer(minLength: 0)
                if jit.busy { ProgressView() }
                else { Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary) }
            }
            .padding(.vertical, 3)
        }
        .buttonStyle(.plain)
        .disabled(jit.busy)
    }
}

struct IconBackdrop: View {
    let path: String?
    var fallback: Color = Color(uiColor: .secondarySystemBackground)

    var body: some View {
        ZStack {
            fallback
            if path != nil {
                AppIcon(path: path, size: 120)
                    .scaleEffect(3.2)
                    .blur(radius: 28)
                    .saturation(1.3)
                    .opacity(0.9)
            }
        }
        .clipped()
        // Scaled up, the icon reaches far past the card; clipping hides that but does not stop it taking touches, and a
        // tap on one cover used to land on its neighbour's backdrop.
        .allowsHitTesting(false)
    }
}

/// What sits behind an item's name: its gameplay picture when Husk ships one, its blurred icon otherwise.
struct ItemBackdrop: View {
    let item: LibraryItem
    var pixels: Int = 1200
    var fallback: Color = Color(uiColor: .secondarySystemBackground)
    @ObservedObject private var showcase = ShowcaseStore.shared

    var body: some View {
        Group {
            if let art = item.artworkPath {
                Color.clear.overlay { PictureView(path: art, pixels: pixels) }.clipped()
            } else {
                IconBackdrop(path: item.iconPath, fallback: fallback)
            }
        }
        .allowsHitTesting(false)
    }
}

/// An item's icon: the app's own, or Android's mark for Android itself.
struct ItemIcon: View {
    let item: LibraryItem
    let size: CGFloat

    var body: some View {
        AppIcon(path: item.iconPath, size: size)
            .overlay {
                RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
            }
    }
}

/// Android itself, as an icon.
struct AndroidMark: View {
    static let green = Color(red: 0.24, green: 0.86, blue: 0.52)
    var size: CGFloat = 64

    var body: some View {
        Image(systemName: "apps.iphone")
            .font(.system(size: size * 0.46, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Self.green.huskGradient, in: RoundedRectangle(cornerRadius: size * 0.225, style: .continuous))
    }
}

/// "Opens inside Android".
struct AndroidBadge: View {
    var body: some View {
        Text("ANDROID")
            .font(.system(size: 8, weight: .heavy, design: .rounded))
            .tracking(0.4)
            .foregroundStyle(Color(red: 0.03, green: 0.13, blue: 0.06))
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(AndroidMark.green, in: Capsule())
    }
}

// MARK: - shared pieces

/// One app in a grid, as a home screen draws it: the icon, and its name under it.
struct LauncherTile: View {
    let title: String
    let iconPath: String?
    var item: LibraryItem? = nil
    var caption: String? = nil
    var size: CGFloat = 64
    @ObservedObject private var statuses = GameStatusStore.shared

    /// How the game did last time it was played, when Husk has seen it played.
    private var result: GameStatusStore.Result? {
        guard case .game(let g)? = item else { return nil }
        return statuses.status(g.id)?.result
    }

    var body: some View {
        VStack(spacing: 7) {
            Group {
                Group { if let item { ItemIcon(item: item, size: size) } else { AppIcon(path: iconPath, size: size) } }.snowCap(height: 7)
            }
            .shadow(color: .black.opacity(0.14), radius: 6, y: 3)
            .overlay(alignment: .bottom) {
                if item?.runsInAndroid == true { AndroidBadge().offset(y: 6) }
            }
            .overlay(alignment: .topTrailing) {
                if let result { GameStatusBadge(result: result).offset(x: 5, y: -5) }
            }
            VStack(spacing: 1) {
                Text(title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                if let caption {
                    Text(caption).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .padding(.top, item?.runsInAndroid == true ? 3 : 0)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }
}

/// What can be done with a library item: play or open it, its page, its settings, and removing it. Shared by the long press
/// on a tile and Home's "⋯" button.
struct LibraryItemActions: View {
    let item: LibraryItem
    var showsDetails = false
    let push: (LibraryRoute) -> Void
    let askRemove: () -> Void

    var body: some View {
        Button { Launcher.play(item, push: push) } label: {
            Label("Open", systemImage: "play.fill")
        }
        if showsDetails {
            Button { push(item.route) } label: { Label("Details", systemImage: "info.circle") }
        }
        if case .game(let g) = item {
            Button { push(.gameSettings(g.id)) } label: { Label("Settings", systemImage: "slider.horizontal.3") }
            Divider()
            Button(role: .destructive) { askRemove() } label: { Label("Remove", systemImage: "trash") }
        } else if case .app(let p) = item {
            Button { push(item.route) } label: { Label("App Settings", systemImage: "slider.horizontal.3") }
            if AndroidHost.shared.isReady {
                Divider()
                Button(role: .destructive) { askRemove() } label: { Label("Uninstall", systemImage: "trash") }
                    .disabled(AndroidHost.shared.busy != nil)
                    .accessibilityHint("Removes \(p.label) from Android")
            }
        }
    }
}

/// Asking before an item is removed, and removing it.
private struct RemoveItemDialog: ViewModifier {
    let item: LibraryItem
    @Binding var isPresented: Bool

    func body(content: Content) -> some View {
        content
            .confirmationDialog(removeTitle, isPresented: $isPresented, titleVisibility: .visible) {
                Button(removeVerb, role: .destructive) {
                    switch item {
                    case .game(let g): TranslationLayerStore.shared.remove(g)
                    case .app(let p): AndroidHost.shared.uninstall(p.name)
                    }
                }
            } message: {
                Text(removeMessage)
            }
    }

    private var removeVerb: String { if case .app = item { return "Uninstall" }; return "Remove" }
    private var removeTitle: String { "\(removeVerb) \(item.title)?" }
    private var removeMessage: String {
        if case .app = item { return "It is uninstalled from Android, with its data." }
        return "Its files and saved progress are deleted from APK Container."
    }
}

/// Long-press on a library tile: play or open it, its settings, and removing it -- what iOS puts on a home screen icon.
private struct LibraryItemMenu: ViewModifier {
    let item: LibraryItem
    let push: (LibraryRoute) -> Void
    @State private var confirmRemove = false

    func body(content: Content) -> some View {
        content
            .contextMenu { LibraryItemActions(item: item, push: push) { confirmRemove = true } }
            .removeItemDialog(item, isPresented: $confirmRemove)
    }
}

extension View {
    func libraryItemMenu(_ item: LibraryItem, push: @escaping (LibraryRoute) -> Void) -> some View {
        modifier(LibraryItemMenu(item: item, push: push))
    }

    func removeItemDialog(_ item: LibraryItem, isPresented: Binding<Bool>) -> some View {
        modifier(RemoveItemDialog(item: item, isPresented: isPresented))
    }
}

/// A round glyph button in a screen's header.
struct HeaderButton: View {
    let systemImage: String
    let action: () -> Void
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(enabled ? Color.accentColor : Color.secondary)
                .frame(width: 38, height: 38)
                .background(Color(uiColor: .tertiarySystemFill), in: Circle())
        }
        .buttonStyle(.plain)
    }
}

/// Work under way, said in one line.
struct BusyStrip: View {
    let text: String

    var body: some View {
        HStack(spacing: 12) {
            ProgressView()
            Text(text).font(.subheadline).lineLimit(2)
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

/// A search field as the system draws one.
struct SearchField: View {
    @Binding var text: String
    let prompt: String
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.secondary)
                TextField(prompt, text: $text)
                    .focused($focused)
                    .submitLabel(.search)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                if !text.isEmpty {
                    Button { text = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear")
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 38)
            .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            if focused {
                Button("Cancel") { text = ""; focused = false }
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.2), value: focused)
    }
}

/// Nothing matches the search.
struct NoResults: View {
    let query: String
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 28, weight: .light)).foregroundStyle(.secondary)
            Text("No Results").font(.headline)
            Text("Nothing here is called “\(query)”.").font(.subheadline).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
    }
}

/// Whether a name matches what was searched for.
func matches(_ query: String, _ names: String...) -> Bool {
    let q = query.trimmingCharacters(in: .whitespaces)
    return q.isEmpty || names.contains { $0.localizedCaseInsensitiveContains(q) }
}

extension View {
    /// The pages an item opens, for whichever stack shows it.
    func libraryDestinations() -> some View {
        huskDestination(for: LibraryRoute.self) { route in
            LibraryRouteView(route: route).huskNavigationBar(hidden: false)
        }
    }
}

private struct LibraryRouteView: View {
    let route: LibraryRoute
    @ObservedObject private var store = TranslationLayerStore.shared

    var body: some View {
        switch route {
        case .game(let id):
            if let app = store.apps.first(where: { $0.id == id }) { GamePage(app: app) } else { GoneView() }
        case .gameSettings(let id):
            if let app = store.apps.first(where: { $0.id == id }) { TLAppSettingsView(app: app) } else { GoneView() }
        case .gameReport(let id):
            if let app = store.apps.first(where: { $0.id == id }) { TLTechnicalView(app: app) } else { GoneView() }
        case .android(let pkg):
            AndroidAppPage(app: pkg)
        }
    }
}

private struct GoneView: View {
    var body: some View {
        Text("This was removed.").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
