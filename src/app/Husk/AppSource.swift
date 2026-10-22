// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import Combine

/// Saved repositories, a usable offline catalog, and verified APK handoff to the
/// existing import chooser. No repository can invoke a shell or start an app.
@MainActor
final class SourceManager: ObservableObject {
    static let shared = SourceManager()
    @Published private(set) var sources: [AppSource] = []
    @Published private(set) var loadingSources: Set<String> = []
    @Published private(set) var fetchErrors: [String: String] = [:]
    @Published private(set) var downloadProgress: [String: Double] = [:]
    @Published private(set) var downloadErrors: [String: String] = [:]
    @Published private(set) var disabledSources: Set<String> = []
    @Published var problem: String?
    @Published var sourceURLs: [String] = [] {
        didSet {
            guard !hydrating else { return }
            defaults.set(sourceURLs, forKey: "HuskSourceURLs")
            sources.removeAll { !sourceURLs.contains($0.identifier) }
            disabledSources = disabledSources.intersection(sourceURLs)
            defaults.set(Array(disabledSources), forKey: "apkcontainer.repositories.disabled")
            saveCache()
        }
    }
    private var hydrating = true
    private let defaults: UserDefaults
    private let cacheURL: URL
    private var downloads: [String: Task<Void, Never>] = [:]
    private var attempts: [String: Date] = [:]
    var isLoading: Bool { !loadingSources.isEmpty }
    var enabledURLs: [String] { sourceURLs.filter { !disabledSources.contains($0) } }
    var enabledSources: [AppSource] {
        sources.filter { enabledURLs.contains($0.identifier) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
    private static var defaultCacheURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Repositories/catalog.json")
    }
    private static var decoder: JSONDecoder { let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601; return decoder }

    init(defaults: UserDefaults = .standard, cacheURL: URL? = nil, seedCatalog: Data? = nil) {
        self.defaults = defaults
        self.cacheURL = cacheURL ?? Self.defaultCacheURL
        var saved = defaults.stringArray(forKey: "HuskSourceURLs") ?? []
        if !defaults.bool(forKey: "apkcontainer.repositories.seeded.v1") {
            for seed in RepositoryCatalog.seeds where !saved.contains(where: { (try? RepositoryCatalog.canonicalURL($0).lowercased()) == seed.url.lowercased() }) { saved.append(seed.url) }
            defaults.set(true, forKey: "apkcontainer.repositories.seeded.v1")
        }
        sourceURLs = saved
        defaults.set(saved, forKey: "HuskSourceURLs")
        disabledSources = Set(defaults.stringArray(forKey: "apkcontainer.repositories.disabled") ?? []).intersection(saved)
        attempts = (defaults.dictionary(forKey: "apkcontainer.repositories.attempts") ?? [:]).compactMapValues {
            ($0 as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
        }
        if let data = try? Data(contentsOf: self.cacheURL), let cached = try? Self.decoder.decode([AppSource].self, from: data) {
            sources = cached.filter { saved.contains($0.identifier) }
        }
        // These are actual release snapshots, including their published digests.
        // Refreshing replaces them; they are not compatibility endorsements.
        let bundled = seedCatalog ?? Bundle.main.url(forResource: "RepositorySeedCatalog", withExtension: "json").flatMap { try? Data(contentsOf: $0) }
        if let data = bundled, let seeds = try? Self.decoder.decode([AppSource].self, from: data) {
            for source in seeds where saved.contains(source.identifier) && !sources.contains(where: { $0.identifier == source.identifier }) {
                sources.append(source)
            }
        }
        hydrating = false
        saveCache()
    }

    func isEnabled(_ url: String) -> Bool { !disabledSources.contains(url) }
    func setEnabled(_ enabled: Bool, url: String) {
        if enabled { disabledSources.remove(url) } else { disabledSources.insert(url) }
        defaults.set(Array(disabledSources), forKey: "apkcontainer.repositories.disabled")
        if enabled { Task { await refreshIfNeeded() } }
    }
    func refreshIfNeeded() async { await refresh(force: false) }
    func fetchSources() async { await refresh(force: true) }
    private func refresh(force: Bool) async {
        let now = Date()
        let wanted = enabledURLs.filter { url in
            guard !loadingSources.contains(url) else { return false }
            let last = max(attempts[url] ?? .distantPast, sources.first(where: { $0.identifier == url })?.fetchedAt ?? .distantPast)
            return force || now.timeIntervalSince(last) >= 15 * 60
        }
        // At most three concurrent requests, and at most one request per source.
        for start in stride(from: 0, to: wanted.count, by: 3) {
            let batch = wanted[start..<min(start + 3, wanted.count)]
            await withTaskGroup(of: Void.self) { group in
                for url in batch { group.addTask { await self.fetchSource(urlString: url) } }
            }
        }
    }
    func addRepository(_ raw: String) async throws {
        let url = try RepositoryCatalog.canonicalURL(raw)
        guard !sourceURLs.contains(where: { $0.lowercased() == url.lowercased() }) else {
            throw RepositoryCatalog.Failure.message("That repository is already in your list.")
        }
        sourceURLs.append(url)
        await fetchSource(urlString: url)
    }
    func addSource(urlString: String) async {
        do { try await addRepository(urlString) } catch { problem = error.localizedDescription }
    }
    func restoreDefaults() {
        for seed in RepositoryCatalog.seeds where !sourceURLs.contains(where: { $0.lowercased() == seed.url.lowercased() }) { sourceURLs.append(seed.url) }
        Task { await refreshIfNeeded() }
    }
    func fetchSource(urlString: String) async {
        guard !loadingSources.contains(urlString), sourceURLs.contains(urlString), isEnabled(urlString) else { return }
        loadingSources.insert(urlString)
        attempts[urlString] = Date()
        defaults.set(attempts.mapValues(\.timeIntervalSince1970), forKey: "apkcontainer.repositories.attempts")
        fetchErrors.removeValue(forKey: urlString)
        defer { loadingSources.remove(urlString) }
        do {
            let canonical = try RepositoryCatalog.canonicalURL(urlString)
            var request = URLRequest(url: URL(string: canonical)!)
            request.setValue("APK-Container/1.0", forHTTPHeaderField: "User-Agent")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            if let etag = sources.first(where: { $0.identifier == urlString })?.etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
            let response = try await RepositoryTransfer().download(request, maximum: 32 * 1024 * 1024)
            if response.status == 304 {
                if let index = sources.firstIndex(where: { $0.identifier == urlString }) { sources[index].fetchedAt = Date(); saveCache() }
                return
            }
            guard let file = response.file else { throw RepositoryCatalog.Failure.message("The repository returned no catalog.") }
            defer { try? FileManager.default.removeItem(at: file) }
            let data = try Data(contentsOf: file)
            var source = try RepositoryCatalog.parse(data, sourceURL: canonical)
            // Keep the saved identity for legacy index URLs, including their exact spelling.
            source = AppSource(name: source.name, identifier: urlString, apps: source.apps, fetchedAt: Date(), etag: response.etag)
            guard sourceURLs.contains(urlString) else { return }
            if let index = sources.firstIndex(where: { $0.identifier == urlString }) { sources[index] = source }
            else { sources.append(source) }
            saveCache()
        } catch is CancellationError {
        } catch {
            if !Task.isCancelled, sourceURLs.contains(urlString) { fetchErrors[urlString] = String(error.localizedDescription.prefix(300)) }
            HuskLog.log("repositories", "Could not refresh \(RepositoryCatalog.name(for: urlString)): \(error.localizedDescription)")
        }
    }
    func removeSource(urlString: String) {
        sourceURLs.removeAll { $0 == urlString }
        fetchErrors.removeValue(forKey: urlString)
        attempts.removeValue(forKey: urlString)
    }
    private func saveCache() {
        do {
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(sources)
            try FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: cacheURL, options: .atomic)
        } catch { HuskLog.log("repositories", "Could not save catalog cache: \(error.localizedDescription)") }
    }

    func downloadAndInstall(app: SourceApp) {
        guard downloads[app.id] == nil else { return }
        downloadErrors.removeValue(forKey: app.id)
        downloadProgress[app.id] = 0
        downloads[app.id] = Task {
            defer { downloads.removeValue(forKey: app.id); downloadProgress.removeValue(forKey: app.id) }
            var downloaded: URL?
            do {
                guard let url = RepositoryCatalog.httpsURL(app.downloadURL) else { throw RepositoryCatalog.Failure.message("The APK download must use HTTPS.") }
                var request = URLRequest(url: url)
                request.setValue("APK-Container/1.0", forHTTPHeaderField: "User-Agent")
                let response = try await RepositoryTransfer().download(request, maximum: 512 * 1024 * 1024, progress: { value in
                    Task { @MainActor in
                        if self.downloads[app.id] != nil { self.downloadProgress[app.id] = value }
                    }
                })
                guard let file = response.file else { throw RepositoryCatalog.Failure.message("The repository returned no APK.") }
                downloaded = file
                try Task.checkCancellation()
                try await Task.detached(priority: .utility) { try RepositoryArtifact.verify(file, expectedSHA256: app.sha256, expectedSize: app.downloadSize) }.value
                try Task.checkCancellation()
                // IncomingFiles copies into its own staging area and lets the user choose
                // translation-layer or Android import. It never guesses an app activity.
                IncomingFiles.shared.receive(file)
                downloaded = nil // Retained cache until the asynchronous importer has copied it.
            } catch is CancellationError {
            } catch {
                if !Task.isCancelled { downloadErrors[app.id] = String(error.localizedDescription.prefix(300)) }
            }
            if let downloaded { try? FileManager.default.removeItem(at: downloaded) }
        }
    }
    func cancelDownload(_ app: SourceApp) { downloads[app.id]?.cancel() }
}
