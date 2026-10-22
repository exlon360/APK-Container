// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import SwiftUI
import Security
import CryptoKit

/// Trust exactly the certificate in the locally transferred pairing file. Credentials
/// never go to a redirected host, and only this dedicated session accepts the pinned cert.
final class BuildBridgeTLS: NSObject, URLSessionDelegate, URLSessionTaskDelegate {
    let host: String
    let pin: String
    init(profile: AgentProfile) {
        host = URL(string: profile.url)!.host!.lowercased()
        pin = profile.certificateSHA256.lowercased()
    }
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              challenge.protectionSpace.host.lowercased() == host,
              let trust = challenge.protectionSpace.serverTrust,
              let certificate = SecTrustGetCertificateAtIndex(trust, 0) else {
            completionHandler(.cancelAuthenticationChallenge, nil); return
        }
        let hash = SHA256.hash(data: SecCertificateCopyData(certificate) as Data).map { String(format: "%02x", $0) }.joined()
        guard hash == pin else { completionHandler(.cancelAuthenticationChallenge, nil); return }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

@MainActor
final class BuildBridgeStore: ObservableObject {
    static let shared = BuildBridgeStore()
    @Published private(set) var profile: AgentProfile?
    @Published private(set) var projects: [BuildProject] = []
    @Published var selectedID: String?
    @Published private(set) var connected = false
    @Published private(set) var paired = false
    @Published private(set) var busy = false
    @Published private(set) var downloading: String?
    @Published var error: String?
    @Published var draft = ""
    private var session: URLSession?
    private var profileGeneration = UUID()
    private var lastRefresh = Date.distantPast
    private static let service = "com.apkcontainer.build-bridge"
    private static let cacheURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("apk-builder-projects.json")

    var selected: BuildProject? { projects.first { $0.id == selectedID } }
    var connectionLabel: String {
        guard profile != nil else { return "Connect your Mac" }
        if !connected { return "Mac offline" }
        return paired ? "Mac connected" : "Run /apk pair on your Mac"
    }

    private init() {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service, kSecAttrAccount as String: "profile",
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
           let data = result as? Data, let saved = try? AgentProfile.read(data) {
            profile = saved
            if let bytes = try? Data(contentsOf: Self.cacheURL), let cache = try? JSONDecoder().decode(Cache.self, from: bytes),
               cache.bridgeID == saved.bridgeID { projects = cache.projects }
        }
    }
    private struct Cache: Codable { let bridgeID: String; let projects: [BuildProject] }
    private func saveCache() {
        guard let profile, let data = try? JSONEncoder().encode(Cache(bridgeID: profile.bridgeID, projects: projects)) else { return }
        try? FileManager.default.createDirectory(at: Self.cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: Self.cacheURL, options: [.atomic, .completeFileProtectionUnlessOpen])
    }
    func importProfile(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            let value = try AgentProfile.read(data)
            let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: Self.service, kSecAttrAccount as String: "profile"]
            let attrs: [String: Any] = [kSecValueData as String: try JSONEncoder().encode(value),
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
            var status = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
            if status == errSecItemNotFound {
                status = SecItemAdd(query.merging(attrs) { _, new in new } as CFDictionary, nil)
            }
            guard status == errSecSuccess else { throw BuildBridgeError.message("Couldn't save the pairing securely (\(status)).") }
            if profile?.bridgeID != value.bridgeID { projects = []; selectedID = nil }
            profileGeneration = UUID()
            profile = value; session?.invalidateAndCancel(); session = nil
            connected = false; paired = false; error = nil
            saveCache()
            Task { await refresh() }
        } catch { self.error = error.localizedDescription }
    }
    func forgetMac() {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service, kSecAttrAccount as String: "profile"]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { error = "Couldn't remove the saved pairing."; return }
        profileGeneration = UUID()
        session?.invalidateAndCancel(); session = nil; profile = nil; connected = false; paired = false
        projects = []; selectedID = nil; draft = ""
        try? FileManager.default.removeItem(at: Self.cacheURL)
    }
    private func client(_ profile: AgentProfile) -> URLSession {
        if let session { return session }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 600
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        let result = URLSession(configuration: configuration, delegate: BuildBridgeTLS(profile: profile), delegateQueue: nil)
        session = result
        return result
    }
    private func request(_ path: String, method: String = "GET", body: [String: Any]? = nil) async throws -> Data {
        guard let profile else { throw BuildBridgeError.message("Import agent.prf to connect your Mac.") }
        var request = URLRequest(url: try profile.endpoint(path))
        let generation = profileGeneration
        request.httpMethod = method
        if method != "GET" { request.timeoutInterval = 600 }
        request.setValue("Bearer " + profile.token, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body); request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        do {
            let (data, response) = try await client(profile).data(for: request)
            guard profileGeneration == generation else { throw CancellationError() }
            guard data.count <= 8 * 1024 * 1024 else { throw BuildBridgeError.message("The Mac sent an oversized response.") }
            guard let response = response as? HTTPURLResponse, (200...299).contains(response.statusCode) else {
                let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
                throw BuildBridgeError.message(message ?? "The Mac couldn't complete this request. Check APK Container Bridge.")
            }
            return data
        } catch {
            if profileGeneration != generation || Self.isCancellation(error) { throw CancellationError() }
            throw error
        }
    }
    private static func isCancellation(_ error: Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled
    }
    private struct Status: Decodable { let bridgeID: String; let paired: Bool }
    private struct Projects: Decodable { let projects: [BuildProject] }
    private struct Project: Decodable { let project: BuildProject }
    func refresh() async {
        guard profile != nil, !busy else { return }
        do {
            let status = try JSONDecoder().decode(Status.self, from: await request("/v1/status"))
            guard status.bridgeID == profile?.bridgeID else { throw BuildBridgeError.message("This pairing belongs to a different Mac bridge.") }
            connected = true; paired = status.paired
            let listed = try JSONDecoder().decode(Projects.self, from: await request("/v1/projects")).projects
            projects = listed.map { compact in
                guard let cached = projects.first(where: { $0.id == compact.id }) else { return compact }
                if cached.updatedAt > compact.updatedAt { return cached }
                var value = compact
                value.messages = cached.messages
                return value
            }.sorted { $0.updatedAt > $1.updatedAt }
            if let id = selectedID, projects.contains(where: { $0.id == id }) {
                upsert(try JSONDecoder().decode(Project.self, from: await request("/v1/projects/" + id)).project)
            }
            lastRefresh = Date(); error = nil; saveCache()
        } catch is CancellationError { }
        catch { connected = false; self.error = error.localizedDescription }
    }
    func poll() async {
        if selected?.isActive != true || !connected {
            if Date().timeIntervalSince(lastRefresh) > 8 { await refresh() }
            return
        }
        guard let id = selectedID, !busy else { return }
        do { upsert(try JSONDecoder().decode(Project.self, from: await request("/v1/projects/" + id)).project); connected = true }
        catch is CancellationError { }
        catch { connected = false; self.error = error.localizedDescription }
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
            catch { self.error = error.localizedDescription }
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
        catch { self.error = error.localizedDescription }
    }
    func interrupt(_ project: BuildProject) async {
        do { upsert(try JSONDecoder().decode(Project.self, from: await request("/v1/projects/" + project.id + "/interrupt", method: "POST", body: [:])).project) }
        catch is CancellationError { }
        catch { self.error = error.localizedDescription }
    }
    func approve(_ approval: BuildApproval, project: BuildProject, accept: Bool, answers: [String: [String]] = [:]) async {
        do {
            upsert(try JSONDecoder().decode(Project.self, from: await request("/v1/projects/" + project.id + "/approvals/" + approval.id,
                method: "POST", body: ["decision": accept ? "accept" : "decline", "answers": answers])).project)
        } catch is CancellationError { }
        catch { self.error = error.localizedDescription }
    }
    func install(_ artifact: BuildArtifact, project: BuildProject) async {
        guard let profile, downloading == nil else { return }
        let generation = profileGeneration
        downloading = artifact.id; error = nil
        defer { downloading = nil }
        do {
            guard artifact.bytes > 0, artifact.bytes <= 1_073_741_824,
                  artifact.sha256.range(of: #"^[0-9a-fA-F]{64}$"#, options: .regularExpression) != nil,
                  artifact.downloadPath == "/v1/projects/\(project.id)/artifacts/\(artifact.id)" else {
                throw BuildBridgeError.message("The Mac sent invalid APK metadata.")
            }
            var request = URLRequest(url: try profile.endpoint(artifact.downloadPath))
            request.timeoutInterval = 60
            request.setValue("Bearer " + profile.token, forHTTPHeaderField: "Authorization")
            let (file, response) = try await client(profile).download(for: request)
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
            if profileGeneration == generation && !Self.isCancellation(error) { self.error = error.localizedDescription }
        }
    }
}
