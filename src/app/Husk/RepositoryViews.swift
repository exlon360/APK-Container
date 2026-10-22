// SPDX-License-Identifier: GPL-2.0-or-later
import SwiftUI

private enum RepositoryVisual {
    static func tint(_ identity: String) -> Color {
        let number = identity.utf8.reduce(UInt64(5381)) { ($0 &* 33) &+ UInt64($1) }
        return Color(hue: Double(number % 360) / 360, saturation: 0.48, brightness: 0.87)
    }
    static func panel(_ identity: String) -> Color { tint(identity).opacity(0.19) }
}

struct RepositoriesScreen: View {
    @ObservedObject private var manager = SourceManager.shared
    @State private var adding = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Repositories").font(.largeTitle.weight(.bold))
                            Text("Your sources for the Store.").font(.subheadline).foregroundColor(.white.opacity(0.55))
                        }
                        Spacer()
                        Button { Task { await manager.fetchSources() } } label: {
                            if manager.isLoading { ProgressView().tint(.white).frame(width: 42, height: 42) }
                            else { Image(systemName: "arrow.clockwise").frame(width: 42, height: 42) }
                        }
                        .disabled(manager.isLoading).accessibilityLabel("Refresh repositories")
                        .background(Color.white.opacity(0.09), in: Circle())
                        Button { adding = true } label: { Image(systemName: "plus").font(.title3.weight(.semibold)).frame(width: 42, height: 42) }
                            .background(Color.white.opacity(0.09), in: Circle()).accessibilityLabel("Add repository")
                    }
                    if manager.sourceURLs.isEmpty {
                        VStack(spacing: 14) {
                            Image(systemName: "externaldrive.connected.to.line.below").font(.system(size: 38)).foregroundColor(.blue)
                            Text("Add your first repository").font(.title3.weight(.semibold))
                            Text("Connect a GitHub project or a compatible JSON catalog to fill your Store.")
                                .font(.subheadline).foregroundColor(.white.opacity(0.55)).multilineTextAlignment(.center)
                            Button("Add Repository") { adding = true }.buttonStyle(.borderedProminent)
                            Button("Restore 10 Included Repositories") { manager.restoreDefaults() }.font(.footnote)
                        }.frame(maxWidth: .infinity).padding(.vertical, 70)
                    } else {
                        LazyVStack(spacing: 12) {
                            ForEach(manager.sourceURLs, id: \.self) { url in RepositoryRow(url: url) }
                        }
                        HStack {
                            Text("\(manager.enabledURLs.count) enabled · \(manager.sourceURLs.count) repositories")
                            Spacer()
                            Menu {
                                Button("Restore Included Repositories") { manager.restoreDefaults() }
                            } label: { Image(systemName: "ellipsis.circle").font(.title3).accessibilityLabel("Repository options") }
                        }.font(.footnote).foregroundColor(.white.opacity(0.45))
                    }
                }.padding(.horizontal, 20).padding(.vertical, 20)
            }
            .background(Color.black.ignoresSafeArea()).foregroundColor(.white)
            .navigationBarHidden(true)
            .sheet(isPresented: $adding) { AddRepositorySheet() }
            .task { await manager.refreshIfNeeded() }
        }.preferredColorScheme(.dark)
    }
}

private struct RepositoryRow: View {
    let url: String
    @ObservedObject private var manager = SourceManager.shared
    private var source: AppSource? { manager.sources.first { $0.identifier == url } }
    private var enabled: Bool { manager.isEnabled(url) }
    private var title: String { source?.name ?? RepositoryCatalog.name(for: url) }
    private var address: String { RepositoryCatalog.projectURL(for: url)?.absoluteString.replacingOccurrences(of: "https://", with: "") ?? url }

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: "shippingbox.fill")
                .font(.system(size: 23, weight: .medium)).foregroundColor(RepositoryVisual.tint(url))
                .frame(width: 54, height: 54)
                .background(Color.black.opacity(0.32), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.headline).lineLimit(2)
                Text(address).font(.caption).foregroundColor(.white.opacity(0.42)).lineLimit(1).truncationMode(.middle)
                if manager.loadingSources.contains(url) {
                    Text("Refreshing…").font(.caption).foregroundColor(.white.opacity(0.6))
                } else if let error = manager.fetchErrors[url] {
                    Text(error).font(.caption).foregroundColor(.orange).lineLimit(3)
                } else if let source {
                    Text("\(source.apps.count) app\(source.apps.count == 1 ? "" : "s")\(enabled ? "" : " · Disabled")")
                        .font(.caption).foregroundColor(.white.opacity(0.5))
                } else {
                    Text(enabled ? "Waiting to refresh" : "Disabled").font(.caption).foregroundColor(.white.opacity(0.5))
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            Toggle("Enable \(title)", isOn: Binding(get: { enabled }, set: { manager.setEnabled($0, url: url) }))
                .labelsHidden().tint(RepositoryVisual.tint(url)).fixedSize()
            Menu {
                Button { Task { await manager.fetchSource(urlString: url) } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .disabled(!enabled || manager.loadingSources.contains(url))
                if let project = RepositoryCatalog.projectURL(for: url) { Link(destination: project) { Label("Open Repository", systemImage: "arrow.up.right.square") } }
                Button(role: .destructive) { manager.removeSource(urlString: url) } label: { Label("Remove Repository", systemImage: "trash") }
            } label: { Image(systemName: "ellipsis").frame(width: 28, height: 40).accessibilityLabel("Options for \(title)") }
        }
        .padding(16).background(RepositoryVisual.panel(url), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

private struct AddRepositorySheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var manager = SourceManager.shared
    @State private var url = ""
    @State private var error: String?
    @State private var adding = false
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://github.com/owner/project", text: $url)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                } header: { Text("Repository URL") } footer: {
                    Text("Add a GitHub repository with APK releases, an F-Droid index-v1.json URL, or an APK Container JSON catalog. HTTPS is required.")
                }
                if let error { Section { Text(error).foregroundColor(.red) } }
                Section {
                    Text("Repositories supply their own apps and release information. Downloading opens the normal APK import choices.")
                        .font(.footnote).foregroundColor(.secondary)
                }
            }
            .navigationTitle("Add Repository").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) { Button("Cancel") { dismiss() }.disabled(adding) }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(adding ? "Adding…" : "Add") {
                        adding = true; error = nil
                        Task {
                            do { try await manager.addRepository(url); dismiss() }
                            catch { self.error = error.localizedDescription; adding = false }
                        }
                    }.disabled(adding || url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }.preferredColorScheme(.dark)
    }
}

struct RepositoryStoreScreen: View {
    var body: some View {
        NavigationStack { RepositoryStoreContent().navigationBarHidden(true) }.preferredColorScheme(.dark)
    }
}

private struct RepositoryEntry: Identifiable {
    let source: AppSource
    let app: SourceApp
    var id: String { source.identifier + "#" + app.id }
}

struct RepositoryStoreContent: View {
    @ObservedObject private var manager = SourceManager.shared
    @State private var query = ""
    @State private var selectedSource: String?
    @State private var selectedApp: RepositoryEntry?
    private var entries: [RepositoryEntry] {
        manager.enabledSources.filter { selectedSource == nil || selectedSource == $0.identifier }
            .flatMap { source in source.apps.map { RepositoryEntry(source: source, app: $0) } }
            .filter { query.isEmpty || "\($0.app.name) \($0.app.bundleIdentifier) \($0.source.name)".localizedCaseInsensitiveContains(query) }
            .sorted { $0.app.name.localizedCaseInsensitiveCompare($1.app.name) == .orderedAscending }
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Store").font(.largeTitle.weight(.bold))
                        Text("Find your next app.").font(.subheadline).foregroundColor(.white.opacity(0.55))
                    }
                    Spacer()
                    Button { Task { await manager.fetchSources() } } label: {
                        if manager.isLoading { ProgressView().tint(.white).frame(width: 44, height: 44) }
                        else { Image(systemName: "arrow.clockwise").frame(width: 44, height: 44) }
                    }.background(Color.white.opacity(0.09), in: Circle()).disabled(manager.isLoading).accessibilityLabel("Refresh Store")
                }
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").foregroundColor(.white.opacity(0.4))
                    TextField("Search apps", text: $query).textInputAutocapitalization(.never).autocorrectionDisabled()
                    if !query.isEmpty { Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundColor(.white.opacity(0.4)) }.accessibilityLabel("Clear search") }
                }.padding(14).background(Color.white.opacity(0.08), in: Capsule())
                if manager.enabledSources.count > 1 {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            filterPill("All Repositories", id: nil)
                            ForEach(manager.enabledSources) { source in filterPill(source.name, id: source.identifier) }
                        }
                    }
                }
                if entries.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: query.isEmpty ? "shippingbox" : "magnifyingglass").font(.system(size: 36)).foregroundColor(.white.opacity(0.4))
                        Text(query.isEmpty ? "Your Store is waiting" : "No matching apps").font(.title3.weight(.semibold))
                        Text(query.isEmpty ? "Enable a repository in Repositories, then refresh to load its apps." : "Try another name or repository.")
                            .font(.subheadline).foregroundColor(.white.opacity(0.5)).multilineTextAlignment(.center)
                    }.frame(maxWidth: .infinity).padding(.vertical, 54)
                } else {
                    LazyVStack(spacing: 12) {
                        ForEach(entries) { entry in
                            RepositoryAppRow(entry: entry, showDetails: { selectedApp = entry })
                        }
                    }
                }
                if manager.fetchErrors.keys.contains(where: { manager.enabledURLs.contains($0) }) {
                    VStack(alignment: .leading, spacing: 7) {
                        Label("Some repositories could not refresh", systemImage: "exclamationmark.triangle")
                            .font(.footnote.weight(.semibold)).foregroundColor(.orange)
                        Text("Cached apps are still shown. Open Repositories for details.").font(.caption).foregroundColor(.white.opacity(0.5))
                    }.padding(15).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 17))
                }
                Text("\(entries.count) apps · Compatibility varies by app and runtime")
                    .font(.footnote).foregroundColor(.white.opacity(0.4)).frame(maxWidth: .infinity).padding(.vertical, 10)
            }.padding(.horizontal, 20).padding(.vertical, 20)
        }
        .background(Color.black.ignoresSafeArea()).foregroundColor(.white)
        .task { await manager.refreshIfNeeded() }
        .onChange(of: manager.enabledURLs) { enabled in if let selectedSource, !enabled.contains(selectedSource) { self.selectedSource = nil } }
        .sheet(item: $selectedApp) { RepositoryAppDetail(entry: $0) }
    }
    private func filterPill(_ title: String, id: String?) -> some View {
        Button { selectedSource = id } label: {
            Text(title).font(.footnote.weight(.semibold)).lineLimit(1).padding(.horizontal, 15).padding(.vertical, 10)
                .foregroundColor(selectedSource == id ? .white : .white.opacity(0.55))
                .background(selectedSource == id ? Color.blue.opacity(0.38) : Color.white.opacity(0.07), in: Capsule())
        }.buttonStyle(.plain)
    }
}

private struct RepositoryAppIcon: View {
    let app: SourceApp
    let identity: String
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.black.opacity(0.35))
            if let url = RepositoryCatalog.httpsURL(app.iconURL) {
                AsyncImage(url: url) { image in image.resizable().scaledToFit().padding(5) } placeholder: { symbol }
            } else { symbol }
        }.frame(width: 58, height: 58).clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
    private var symbol: some View {
        Image(systemName: app.iconSymbol ?? "app.fill").font(.system(size: 28, weight: .medium)).foregroundColor(RepositoryVisual.tint(identity))
    }
}

private struct RepositoryAppRow: View {
    let entry: RepositoryEntry
    let showDetails: () -> Void
    @ObservedObject private var manager = SourceManager.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 14) {
                Button(action: showDetails) {
                    HStack(spacing: 14) {
                        RepositoryAppIcon(app: entry.app, identity: entry.source.identifier)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(entry.app.name).font(.headline).foregroundColor(.white).lineLimit(2)
                            Text("\(entry.app.version) · \(entry.source.name)").font(.caption).foregroundColor(.white.opacity(0.42)).lineLimit(1)
                            Text(entry.app.localizedDescription).font(.caption).foregroundColor(.white.opacity(0.55)).lineLimit(2)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain)
                RepositoryGetButton(app: entry.app, tint: RepositoryVisual.tint(entry.source.identifier))
            }
            if let error = manager.downloadErrors[entry.app.id] { Text(error).font(.caption).foregroundColor(.orange).padding(.leading, 72) }
        }.padding(16).background(RepositoryVisual.panel(entry.source.identifier), in: RoundedRectangle(cornerRadius: 23, style: .continuous))
    }
}

private struct RepositoryGetButton: View {
    let app: SourceApp
    let tint: Color
    @ObservedObject private var manager = SourceManager.shared
    var body: some View {
        if let progress = manager.downloadProgress[app.id] {
            Button { manager.cancelDownload(app) } label: {
                VStack(spacing: 4) {
                    ProgressView(value: progress).tint(tint).frame(width: 62)
                    Text("Cancel").font(.caption2)
                }.frame(width: 78, height: 40)
            }.accessibilityLabel("Cancel downloading \(app.name)")
        } else {
            Button { manager.downloadAndInstall(app: app) } label: {
                Text("Get").font(.body.weight(.semibold)).foregroundColor(.white)
                    .frame(minWidth: 52).padding(.horizontal, 12).padding(.vertical, 9)
                    .background(tint.opacity(0.3), in: Capsule())
            }.buttonStyle(.plain).accessibilityLabel("Get \(app.name)")
        }
    }
}

private struct RepositoryAppDetail: View {
    let entry: RepositoryEntry
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var manager = SourceManager.shared
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    HStack(spacing: 16) {
                        RepositoryAppIcon(app: entry.app, identity: entry.source.identifier)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(entry.app.name).font(.title2.weight(.bold))
                            Text(entry.app.version).font(.subheadline).foregroundColor(.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        RepositoryGetButton(app: entry.app, tint: RepositoryVisual.tint(entry.source.identifier))
                    }
                    Text(entry.app.localizedDescription).font(.body)
                    VStack(alignment: .leading, spacing: 10) {
                        Label(entry.source.name, systemImage: "shippingbox")
                        if let size = entry.app.downloadSize { Label(ByteCountFormatter.string(fromByteCount: size, countStyle: .file), systemImage: "arrow.down.circle") }
                        Label(entry.app.sha256 == nil ? "No checksum supplied by this repository" : "SHA-256 checked before import", systemImage: entry.app.sha256 == nil ? "info.circle" : "checkmark.shield")
                        if let date = entry.source.fetchedAt { Text("Catalog updated \(date.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundColor(.secondary) }
                    }.font(.subheadline).padding(16).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 18))
                    Text("Choose the translation layer or Android when importing. A listed release is not a guarantee of compatibility with APK Container.")
                        .font(.footnote).foregroundColor(.secondary)
                    if let error = manager.downloadErrors[entry.app.id] { Text(error).foregroundColor(.orange).font(.footnote) }
                    if let url = entry.app.projectURL.flatMap(RepositoryCatalog.httpsURL) {
                        Link(destination: url) { Label("View Release", systemImage: "arrow.up.right.square") }
                    }
                }.padding(22)
            }
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("App Details").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .navigationBarTrailing) { Button("Done") { dismiss() } } }
        }.preferredColorScheme(.dark)
    }
}
