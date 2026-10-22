// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import SwiftUI
import Security
import CryptoKit

@MainActor
final class BuildBridgeStore: ObservableObject {
    static let shared = BuildBridgeStore()
    @Published private(set) var profile: AgentProfile?
    @Published private(set) var projects: [BuildProject] = []
    @Published var selectedID: String?
    @Published private(set) var connected = false
    @Published private(set) var paired = false
    @Published private(set) var checkingConnection = false
    @Published private(set) var connectedAddress: String?
    @Published private(set) var connectionDiagnostics = "No connection test yet."
    @Published private(set) var busy = false
    @Published private(set) var downloading: String?
    @Published private var reconnecting = false
    @Published private var mutationCount = 0
    @Published var error: String?
    @Published var draft = ""
    private var connection: BuildBridgeConnection?
    private var refreshID: UUID?
    private var pollID: UUID?
    private var profileGeneration = UUID()
    private var lastRefresh = Date.distantPast
    private static let service = "com.apkcontainer.build-bridge"
    private let cacheURL: URL
    private static let defaultCacheURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("apk-builder-projects.json")

    var selected: BuildProject? { projects.first { $0.id == selectedID } }
    var canReconnect: Bool { profile != nil && !busy && downloading == nil && mutationCount == 0 && !reconnecting }
    var connectionLabel: String {
        guard profile != nil else { return "Connect your Mac" }
        if !connected { return checkingConnection ? "Connecting…" : "Connection issue" }
        return paired ? "Mac connected" : "Run /apk pair on your Mac"
    }

    private init() {
        cacheURL = Self.defaultCacheURL
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service, kSecAttrAccount as String: "profile",
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
           let data = result as? Data, let saved = try? AgentProfile.read(data) {
            profile = saved
            if let bytes = try? Data(contentsOf: cacheURL), let cache = try? JSONDecoder().decode(Cache.self, from: bytes),
               cache.bridgeID == saved.bridgeID { projects = cache.projects }
        }
    }
    #if BUILD_BRIDGE_TESTS
    /// Isolated integration tests inject credentials and cache paths; no Keychain access.
    init(testProfile: AgentProfile, cacheURL: URL) {
        self.cacheURL = cacheURL; profile = testProfile
    }
    #endif
    private struct Cache: Codable { let bridgeID: String; let projects: [BuildProject] }
    private func saveCache() {
        guard let profile, let data = try? JSONEncoder().encode(Cache(bridgeID: profile.bridgeID, projects: projects)) else { return }
        try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: cacheURL, options: [.atomic, .completeFileProtectionUnlessOpen])
    }
    func importProfile(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            let value = try AgentProfile.read(data)
            try saveProfile(value)
            Task { await refresh() }
        } catch { report(error) }
    }
    private func saveProfile(_ value: AgentProfile) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service, kSecAttrAccount as String: "profile"]
        let attrs: [String: Any] = [kSecValueData as String: try JSONEncoder().encode(value),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        var status = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        if status == errSecItemNotFound { status = SecItemAdd(query.merging(attrs) { _, new in new } as CFDictionary, nil) }
        guard status == errSecSuccess else { throw BuildBridgeError.message("Couldn't save the pairing securely (\(status)).") }
        if profile?.bridgeID != value.bridgeID { projects = []; selectedID = nil }
        resetConnection()
        profile = value; error = nil; saveCache()
    }
    func updateAddress(_ address: String) async {
        guard let profile, canReconnect else { return }
        do { try saveProfile(profile.replacingAddress(address)); await refresh() }
        catch { report(error) }
    }
    private func resetConnection() {
        if let previous = invalidateConnection() { Task { await previous.close() } }
    }
    private func invalidateConnection() -> BuildBridgeConnection? {
        profileGeneration = UUID()
        let previous = connection
        connection = nil; connected = false; paired = false; connectedAddress = nil
        checkingConnection = false; refreshID = nil; pollID = nil; lastRefresh = .distantPast
        return previous
    }
    /// An explicit retry replaces a stalled URLSession and cancels old reads.
    /// Never cancel a send, approval, interrupt, or APK download to reconnect.
    func reconnect() async {
        guard canReconnect else { return }
        reconnecting = true
        defer { reconnecting = false }
        let previous = invalidateConnection()
        if let previous { await previous.close() }
        await performRefresh()
    }
    func forgetMac() {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service, kSecAttrAccount as String: "profile"]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { error = "Couldn't remove the saved pairing."; return }
        resetConnection(); profile = nil; error = nil
        connectionDiagnostics = "No connection test yet."
        projects = []; selectedID = nil; draft = ""
        try? FileManager.default.removeItem(at: cacheURL)
    }
    private func transport(_ profile: AgentProfile) -> BuildBridgeConnection {
        if let connection { return connection }
        let result = BuildBridgeConnection(profile: profile)
        connection = result
        return result
    }
    private func request(_ path: String, method: String = "GET", body: [String: Any]? = nil) async throws -> Data {
        guard let profile else { throw BuildBridgeError.message("Import agent.prf to connect your Mac.") }
        let generation = profileGeneration
        let bytes = try body.map { try JSONSerialization.data(withJSONObject: $0) }
        let usedTransport = transport(profile)
        let mutating = method != "GET"
        if mutating { mutationCount += 1 }
        defer { if mutating { mutationCount -= 1 } }
        do {
            let data = try await usedTransport.request(path, method: method, body: bytes)
            guard profileGeneration == generation else { throw CancellationError() }
            if mutating {
                await captureDiagnostics(usedTransport, generation: generation)
                guard profileGeneration == generation else { throw CancellationError() }
            }
            return data
        } catch {
            if profileGeneration != generation || Self.isCancellation(error) { throw CancellationError() }
            if mutating {
                await captureDiagnostics(usedTransport, generation: generation)
                guard profileGeneration == generation else { throw CancellationError() }
            }
            throw error
        }
    }
    private static func isCancellation(_ error: Error) -> Bool { BuildBridgeConnection.isCancellation(error) }
    private func report(_ failure: Error) {
        guard !Self.isCancellation(failure) else { return }
        if let failure = failure as? BuildConnectionFailure {
            if failure.isTransportFailure { connected = false; connectedAddress = nil }
            if case .response = failure { connected = true }
            if failure.needsPairing { paired = false }
        }
        error = failure is DecodingError
            ? "The Mac answered, but its reply couldn't be read. Update APK Container Bridge on the Mac, then reconnect."
            : failure.localizedDescription
    }
    private struct Projects: Decodable { let projects: [BuildProject] }
    private struct Project: Decodable { let project: BuildProject }
    func refresh() async {
        guard !reconnecting else { return }
        await performRefresh()
    }
    private func captureDiagnostics(_ transport: BuildBridgeConnection, generation: UUID) async {
        let report = await transport.diagnosticReport()
        guard profileGeneration == generation else { return }
        connectionDiagnostics = report
    }
    private func performRefresh() async {
        guard let profile, !busy, mutationCount == 0, refreshID == nil, pollID == nil else { return }
        let id = UUID(), generation = profileGeneration
        let transport = transport(profile)
        refreshID = id; checkingConnection = true; lastRefresh = Date()
        defer { if refreshID == id { refreshID = nil; checkingConnection = false } }
        do {
            let status = try await transport.connect()
            guard profileGeneration == generation else { throw CancellationError() }
            let address = await transport.activeAddress()
            guard profileGeneration == generation else { throw CancellationError() }
            connected = true; paired = status.paired; connectedAddress = address
            let listed = try JSONDecoder().decode(Projects.self, from: await request("/v1/projects")).projects
            guard profileGeneration == generation else { throw CancellationError() }
            projects = listed.map { compact in
                guard let cached = projects.first(where: { $0.id == compact.id }) else { return compact }
                if cached.updatedAt > compact.updatedAt { return cached }
                var value = compact
                value.messages = cached.messages
                return value
            }.sorted { $0.updatedAt > $1.updatedAt }
            if let id = selectedID, projects.contains(where: { $0.id == id }) {
                let project = try JSONDecoder().decode(Project.self, from: await request("/v1/projects/" + id)).project
                guard profileGeneration == generation else { throw CancellationError() }
                upsert(project)
            }
            error = nil; saveCache()
        } catch {
            if profileGeneration == generation { report(error) }
        }
        await captureDiagnostics(transport, generation: generation)
    }
    func poll() async {
        guard !reconnecting, !busy, mutationCount == 0, refreshID == nil, pollID == nil else { return }
        if selected?.isActive != true || !connected {
            if Date().timeIntervalSince(lastRefresh) > 8 { await refresh() }
            return
        }
        guard let projectID = selectedID, let profile else { return }
        let id = UUID(), generation = profileGeneration
        let transport = transport(profile)
        pollID = id
        defer { if pollID == id { pollID = nil } }
        do {
            let project = try JSONDecoder().decode(Project.self, from: await request("/v1/projects/" + projectID)).project
            guard profileGeneration == generation else { throw CancellationError() }
            let address = await transport.activeAddress()
            guard profileGeneration == generation else { throw CancellationError() }
            upsert(project); connected = true; error = nil; connectedAddress = address
        } catch {
            if profileGeneration == generation { report(error) }
        }
        await captureDiagnostics(transport, generation: generation)
    }
    private func upsert(_ project: BuildProject) {
        if let cached = projects.first(where: { $0.id == project.id }), cached.updatedAt > project.updatedAt { return }
        projects.removeAll { $0.id == project.id }; projects.append(project)
        projects.sort { $0.updatedAt > $1.updatedAt }; saveCache()
    }
    func newChat() { guard !busy else { return }; selectedID = nil; draft = ""; error = nil; Router.shared.tab = .build }
    func open(_ project: BuildProject) {
        guard !busy else { return }
        selectedID = project.id; draft = ""; Router.shared.tab = .build
        Task {
            do { upsert(try JSONDecoder().decode(Project.self, from: await request("/v1/projects/" + project.id)).project) }
            catch is CancellationError { }
            catch { report(error) }
        }
    }
    func send() async {
        let submittedDraft = draft
        let text = submittedDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 20_000, !busy, selected?.isActive != true else { return }
        guard connected && paired else { error = "Connect your Mac and choose Pair Skill /apk in APK Container Bridge first."; return }
        busy = true; error = nil
        defer { busy = false }
        do {
            if selectedID == nil {
                let name = String(text.split(separator: "\n").first.map(String.init)?.prefix(60) ?? "New app".prefix(60))
                let created = try JSONDecoder().decode(Project.self, from: await request("/v1/projects", method: "POST", body: ["name": name])).project
                selectedID = created.id; upsert(created)
            }
            guard let id = selectedID else { return }
            let project = try JSONDecoder().decode(Project.self, from: await request("/v1/projects/" + id + "/messages", method: "POST", body: ["text": text])).project
            upsert(project)
            if draft == submittedDraft { draft = "" }
        } catch is CancellationError { }
        catch { report(error) }
    }
    func interrupt(_ project: BuildProject) async {
        do { upsert(try JSONDecoder().decode(Project.self, from: await request("/v1/projects/" + project.id + "/interrupt", method: "POST", body: [:])).project) }
        catch is CancellationError { }
        catch { report(error) }
    }
    func approve(_ approval: BuildApproval, project: BuildProject, accept: Bool, answers: [String: [String]] = [:]) async {
        do {
            upsert(try JSONDecoder().decode(Project.self, from: await request("/v1/projects/" + project.id + "/approvals/" + approval.id,
                method: "POST", body: ["decision": accept ? "accept" : "decline", "answers": answers])).project)
        } catch is CancellationError { }
        catch { report(error) }
    }
    func install(_ artifact: BuildArtifact, project: BuildProject) async {
        guard let profile, downloading == nil else { return }
        let generation = profileGeneration
        let usedTransport = transport(profile)
        downloading = artifact.id; error = nil
        defer { downloading = nil }
        do {
            guard artifact.bytes > 0, artifact.bytes <= 1_073_741_824,
                  artifact.sha256.range(of: #"^[0-9a-fA-F]{64}$"#, options: .regularExpression) != nil,
                  artifact.downloadPath == "/v1/projects/\(project.id)/artifacts/\(artifact.id)" else {
                throw BuildBridgeError.message("The Mac sent invalid APK metadata.")
            }
            let (file, response) = try await usedTransport.download(artifact.downloadPath)
            guard profileGeneration == generation else {
                try? FileManager.default.removeItem(at: file)
                throw CancellationError()
            }
            defer { try? FileManager.default.removeItem(at: file) }
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw BuildBridgeError.message("The APK download failed.") }
            let expectedBytes = artifact.bytes, expectedHash = artifact.sha256.lowercased()
            try await Task.detached(priority: .utility) {
                let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard Int64(size) == expectedBytes else { throw BuildBridgeError.message("The APK download is incomplete.") }
                let handle = try FileHandle(forReadingFrom: file); defer { try? handle.close() }
                var hash = SHA256()
                while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
                    try Task.checkCancellation()
                    hash.update(data: data)
                }
                guard hash.finalize().map({ String(format: "%02x", $0) }).joined() == expectedHash else {
                    throw BuildBridgeError.message("APK verification failed. Download it again.")
                }
            }.value
            guard profileGeneration == generation else { throw CancellationError() }
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Built-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let destination = folder.appendingPathComponent("Built-App.apk")
            try FileManager.default.moveItem(at: file, to: destination)
            IncomingFiles.shared.receive(destination)
        } catch {
            if profileGeneration == generation { report(error) }
        }
        await captureDiagnostics(usedTransport, generation: generation)
    }
}
