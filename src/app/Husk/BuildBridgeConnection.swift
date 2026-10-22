// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import Security
import CryptoKit

/// Every candidate address must present the pairing file's exact certificate
/// before URLSession can send its credential. Redirects never carry credentials.
final class BuildBridgeTLS: NSObject, URLSessionDelegate, URLSessionTaskDelegate {
    private let host: String
    private let pin: String
    private let lock = NSLock()
    private var rejectionCount = 0
    var identityRejections: Int { lock.lock(); defer { lock.unlock() }; return rejectionCount }
    private func rejectIdentity() { lock.lock(); rejectionCount += 1; lock.unlock() }
    init(origin: String, pin: String) {
        host = URL(string: origin)!.host!.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        self.pin = pin.lowercased()
    }
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              challenge.protectionSpace.host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]")) == host,
              let trust = challenge.protectionSpace.serverTrust,
              let certificate = SecTrustGetCertificateAtIndex(trust, 0) else {
            rejectIdentity(); completionHandler(.cancelAuthenticationChallenge, nil); return
        }
        let hash = SHA256.hash(data: SecCertificateCopyData(certificate) as Data).map { String(format: "%02x", $0) }.joined()
        guard hash == pin else { rejectIdentity(); completionHandler(.cancelAuthenticationChallenge, nil); return }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

enum BuildConnectionFailure: LocalizedError {
    case unreachable(String)
    case response(Int, String)
    case invalid(String)

    var errorDescription: String? {
        switch self {
        case .unreachable(let detail), .response(_, let detail), .invalid(let detail): return detail
        }
    }
    var isTransportFailure: Bool { if case .unreachable = self { return true }; return false }
    var needsPairing: Bool { if case .response(let status, _) = self { return status == 401 }; return false }
}

/// Pins a short list of explicit addresses, remembers the working route, and
/// retries reads only. A timed-out mutation may already have reached the Mac.
actor BuildBridgeConnection {
    struct Status: Decodable, Sendable {
        let bridgeID: String
        let paired: Bool
    }
    struct Reachable: Sendable { let status: Status; let origin: String }
    private enum ProbeResult: @unchecked Sendable {
        case ready(Reachable)
        case failed(Error)
        func reachable() throws -> Reachable {
            switch self { case .ready(let result): return result; case .failed(let error): throw error }
        }
    }
    private struct Route: @unchecked Sendable { let session: URLSession; let trust: BuildBridgeTLS }
    private struct Probe { let id: UUID; let task: Task<Reachable, Error> }
    private let profile: AgentProfile
    private let routes: [String: Route]
    private let probeSeconds: Double
    private var selectedOrigin: String?
    private var connectionTask: Probe?
    private var latestProbeID: UUID?
    private var closed = false

    init(profile: AgentProfile, probeSeconds: Double = 5) {
        self.profile = profile; self.probeSeconds = probeSeconds
        routes = Dictionary(uniqueKeysWithValues: profile.origins.map { origin in
            let configuration = URLSessionConfiguration.ephemeral
            configuration.waitsForConnectivity = true
            configuration.timeoutIntervalForRequest = 20
            configuration.timeoutIntervalForResource = 600
            configuration.httpShouldSetCookies = false
            configuration.urlCredentialStorage = nil
            let trust = BuildBridgeTLS(origin: origin, pin: profile.certificateSHA256)
            return (origin, Route(session: URLSession(configuration: configuration, delegate: trust, delegateQueue: nil), trust: trust))
        })
    }
    func close() {
        closed = true; connectionTask?.task.cancel(); connectionTask = nil; selectedOrigin = nil
        for route in routes.values { route.session.invalidateAndCancel() }
    }
    func activeAddress() -> String? { selectedOrigin }

    func connect() async throws -> Status {
        guard !closed else { throw CancellationError() }
        let probe: Probe
        if let existing = connectionTask { probe = existing }
        else {
            let profile = self.profile, routes = self.routes, duration = probeSeconds
            let task = Task<Reachable, Error> {
                let result = await withTaskGroup(of: ProbeResult.self) { group in
                    for origin in profile.origins {
                        group.addTask {
                            do {
                                let bytes = try await Self.withDeadline(seconds: duration) {
                                    try await Self.read(profile: profile, route: routes[origin]!, origin: origin,
                                        path: "/v1/status", method: "GET", body: nil, timeout: duration)
                                }
                                let status: Status
                                do { status = try JSONDecoder().decode(Status.self, from: bytes) }
                                catch { throw BuildConnectionFailure.invalid("The Mac answered, but its bridge status was unreadable. Update APK Container Bridge on the Mac.") }
                                guard status.bridgeID == profile.bridgeID else {
                                    throw BuildConnectionFailure.invalid("This address belongs to a different Mac bridge. Import the correct agent.prf.")
                                }
                                return .ready(Reachable(status: status, origin: origin))
                            } catch { return .failed(error) }
                        }
                    }
                    var failures: [Error] = []
                    for await result in group {
                        switch result {
                        case .ready: group.cancelAll(); return result
                        case .failed(let error): failures.append(error)
                        }
                    }
                    // Each probe has its own deadline, so a slow alternate cannot
                    // replace an actionable HTTP/pairing error with a generic timeout.
                    let useful = failures.first { $0 is BuildConnectionFailure } ?? failures.first ?? URLError(.cannotConnectToHost)
                    return .failed(useful)
                }
                try Task.checkCancellation()
                return try result.reachable()
            }
            probe = Probe(id: UUID(), task: task)
            latestProbeID = probe.id; connectionTask = probe
        }
        defer { if connectionTask?.id == probe.id { connectionTask = nil } }
        do {
            let result = try await probe.task.value
            guard !closed else { throw CancellationError() }
            // Every coalesced caller installs the route before it can send a request.
            if latestProbeID == probe.id { selectedOrigin = result.origin }
            return result.status
        } catch {
            if latestProbeID == probe.id { selectedOrigin = nil }
            throw Self.describe(error)
        }
    }
    func request(_ path: String, method: String = "GET", body: Data? = nil) async throws -> Data {
        if selectedOrigin == nil { _ = try await connect() }
        guard let origin = selectedOrigin else { throw Self.describe(URLError(.cannotConnectToHost)) }
        do {
            return try await execute(path, method: method, body: body, origin: origin)
        } catch {
            guard method == "GET", Self.isNetworkError(error) else { throw Self.describe(error) }
            selectedOrigin = nil
            _ = try await connect()
            guard let replacement = selectedOrigin else { throw Self.describe(error) }
            do { return try await execute(path, method: method, body: body, origin: replacement) }
            catch { throw Self.describe(error) }
        }
    }
    private func execute(_ path: String, method: String, body: Data?, origin: String) async throws -> Data {
        let profile = self.profile, route = routes[origin]!
        let duration: Double = method == "GET" ? 12 : 600
        return try await Self.withDeadline(seconds: duration) {
            try await Self.read(profile: profile, route: route, origin: origin, path: path, method: method, body: body, timeout: duration)
        }
    }
    func download(_ path: String) async throws -> (URL, URLResponse) {
        if selectedOrigin == nil { _ = try await connect() }
        guard let origin = selectedOrigin else { throw Self.describe(URLError(.cannotConnectToHost)) }
        var request = URLRequest(url: try profile.endpoint(path, origin: origin))
        request.timeoutInterval = 60
        request.setValue("Bearer " + profile.token, forHTTPHeaderField: "Authorization")
        let route = routes[origin]!, rejections = routes[origin]!.trust.identityRejections
        do { return try await route.session.download(for: request) }
        catch { throw Self.describe(Self.classify(error, route: route, previousRejections: rejections)) }
    }
    private static func read(profile: AgentProfile, route: Route, origin: String,
                             path: String, method: String, body: Data?, timeout: Double) async throws -> Data {
        var request = URLRequest(url: try profile.endpoint(path, origin: origin))
        request.httpMethod = method; request.timeoutInterval = timeout
        request.setValue("Bearer " + profile.token, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body { request.httpBody = body; request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let previousRejections = route.trust.identityRejections
        let data: Data, response: URLResponse
        do { (data, response) = try await route.session.data(for: request) }
        catch { throw classify(error, route: route, previousRejections: previousRejections) }
        guard data.count <= 8 * 1024 * 1024 else { throw BuildConnectionFailure.invalid("The Mac answered with an oversized response.") }
        guard let response = response as? HTTPURLResponse else { throw BuildConnectionFailure.invalid("The Mac sent an unreadable response.") }
        guard (200...299).contains(response.statusCode) else {
            let reported = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            let message = response.statusCode == 401 ? "The Mac is reachable, but this pairing is no longer accepted. Import its current agent.prf."
                : reported ?? "The Mac is reachable, but couldn't complete this request (HTTP \(response.statusCode))."
            throw BuildConnectionFailure.response(response.statusCode, message)
        }
        return data
    }
    private static func classify(_ error: Error, route: Route, previousRejections: Int) -> Error {
        if Task.isCancelled { return CancellationError() }
        if route.trust.identityRejections > previousRejections {
            return BuildConnectionFailure.unreachable("The Mac's secure identity could not be verified. Import agent.prf from the running bridge; its certificate must match.")
        }
        return error
    }
    private static func withDeadline<T: Sendable>(seconds: Double, operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask(operation: operation)
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw URLError(.timedOut)
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }
    static func isCancellation(_ error: Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled
    }
    private static func isNetworkError(_ error: Error) -> Bool {
        if isCancellation(error) { return false }
        return error is URLError
    }
    static func describe(_ error: Error) -> Error {
        if isCancellation(error) { return CancellationError() }
        if error is BuildConnectionFailure { return error }
        guard let urlError = error as? URLError else { return error }
        switch urlError.code {
        case .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot,
             .serverCertificateNotYetValid, .secureConnectionFailed, .clientCertificateRejected, .userAuthenticationRequired:
            return BuildConnectionFailure.unreachable("The Mac's secure identity could not be verified. Import agent.prf from the running bridge; its certificate must match.")
        default:
            return BuildConnectionFailure.unreachable("Couldn't reach the Mac. Keep APK Container Bridge running on the same Wi-Fi or a reachable VPN. Allow Local Network access for APK Container—or LiveContainer if it hosts this app. Use the Mac address shown in the bridge, or import a newly generated agent.prf.")
        }
    }
}
