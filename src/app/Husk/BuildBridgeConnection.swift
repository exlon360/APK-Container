// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import Security
import CryptoKit
import Network

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

/// Only fixed operation names, origins, timings and numeric error codes belong
/// in a report. Never retain response text, URL error userInfo, or credentials.
private final class BuildConnectionDiagnostics: @unchecked Sendable {
    private struct Entry {
        let date: Date
        let origin: String
        let phase: String
        let milliseconds: Int
        let result: String
    }
    private let lock = NSLock()
    private var entries: [Entry] = []
    func record(origin: String, phase: String, started: Date, error: Error? = nil, status: Int? = nil, evidence: String? = nil) {
        let result: String
        if let evidence { result = evidence }
        else if let error { result = Self.safeResult(error) }
        else { result = status.map { "HTTP \($0)" } ?? "success" }
        let entry = Entry(date: Date(), origin: origin, phase: phase,
            milliseconds: max(0, Int(Date().timeIntervalSince(started) * 1000)), result: result)
        lock.lock(); defer { lock.unlock() }
        entries.append(entry)
        if entries.count > 32 { entries.removeFirst(entries.count - 32) }
    }
    func report() -> String {
        lock.lock(); let snapshot = entries; lock.unlock()
        let formatter = ISO8601DateFormatter()
        let lines = snapshot.map { entry in
            "\(formatter.string(from: entry.date)) | \(entry.origin) | \(entry.phase) | \(entry.milliseconds) ms | \(entry.result)"
        }
        return (["Connection attempts (latest 32; UTC).", "Pairing credentials, prompts and response text are excluded."]
            + (lines.isEmpty ? ["No connection attempt has completed."] : lines)).joined(separator: "\n")
    }
    static func safeResult(_ error: Error) -> String {
        if let failure = error as? BuildConnectionFailure {
            switch failure {
            case .response(let status, _): return "HTTP \(status)"
            case .invalid: return "invalid_bridge_response"
            // Recording happens before describe() maps ordinary URL errors.
            // classify() emits this case only for the exact-certificate rejection.
            case .unreachable: return "secure_identity_rejected"
            }
        }
        if error is CancellationError { return "cancelled" }
        let ns = error as NSError
        let result: String
        switch (error as? URLError)?.code {
        case .timedOut: result = "timed_out"
        case .cannotFindHost, .dnsLookupFailed: result = "hostname_not_resolved"
        case .cannotConnectToHost: result = "connection_not_opened"
        case .notConnectedToInternet: result = "network_path_unavailable"
        case .networkConnectionLost: result = "connection_lost"
        case .cancelled: result = "cancelled"
        default: result = "request_failed"
        }
        // Errors can carry URLs, headers and arbitrary localized descriptions.
        // Inspect only the nested numeric codes, with a fixed domain allowlist.
        let knownDomains = Set([NSURLErrorDomain, NSPOSIXErrorDomain, NSOSStatusErrorDomain, "kCFErrorDomainCFNetwork"])
        var codes: [String] = [], next: NSError? = ns
        for _ in 0..<4 {
            guard let current = next else { break }
            let domain = knownDomains.contains(current.domain) ? current.domain : "OtherError"
            codes.append("\(domain)=\(current.code)")
            next = current.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return result + " (" + codes.joined(separator: ", ") + ")"
    }
}

/// Endpoint-specific evidence only. A generic path failure is not proof that
/// Local Network permission was denied, and TCP readiness is not HTTPS trust.
struct BuildLocalNetworkState {
    enum Outcome: Sendable, Equatable { case ready, denied, failed, timedOut }
    private(set) var localNetworkDenied = false
    mutating func observe(_ state: NWConnection.State, reason: NWPath.UnsatisfiedReason?) -> Outcome? {
        switch state {
        case .ready: localNetworkDenied = false; return .ready
        case .waiting: localNetworkDenied = reason == .localNetworkDenied; return nil
        case .failed: localNetworkDenied = false; return .failed
        default: localNetworkDenied = false; return nil
        }
    }
    var deadlineOutcome: Outcome { localNetworkDenied ? .denied : .timedOut }
}

/// This explicit user-triggered probe never writes to its socket. All state and
/// continuation ownership live on one queue, including cancellation before start.
private final class BuildLocalNetworkProbe: @unchecked Sendable {
    private let connection: NWConnection
    private let origin: String
    private let diagnostics: BuildConnectionDiagnostics
    private let queue = DispatchQueue(label: "apk-container.local-network-test")
    private var continuation: CheckedContinuation<BuildLocalNetworkState.Outcome, Error>?
    private var deadline: DispatchWorkItem?
    private var finished = false
    private var state = BuildLocalNetworkState()
    private let started = Date()

    init(origin: String, diagnostics: BuildConnectionDiagnostics) {
        self.origin = origin; self.diagnostics = diagnostics
        let url = URLComponents(string: origin)!
        let host = url.host!.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: UInt16(url.port ?? 443))!, using: .tcp)
    }
    func run(timeout: TimeInterval) async throws -> BuildLocalNetworkState.Outcome {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async { [self] in
                    guard !self.finished else { continuation.resume(throwing: CancellationError()); return }
                    self.continuation = continuation
                    self.connection.stateUpdateHandler = { [weak self] state in self?.changed(state) }
                    let deadline = DispatchWorkItem { [weak self] in
                        guard let self, !self.finished else { return }
                        // Re-read current per-endpoint state at the deadline:
                        // an earlier denied path may have changed after the alert.
                        if let outcome = self.state.observe(self.connection.state, reason: self.connection.currentPath?.unsatisfiedReason) {
                            self.record(outcome == .ready ? "tcp_ready_unverified" : "tcp_failed")
                            self.finish(.success(outcome)); return
                        }
                        let outcome = self.state.deadlineOutcome
                        self.record(outcome == .denied ? "local_network_denied" : "tcp_no_response_before_deadline")
                        self.finish(.success(outcome))
                    }
                    self.deadline = deadline
                    self.queue.asyncAfter(deadline: .now() + max(0.01, timeout), execute: deadline)
                    self.connection.start(queue: self.queue)
                }
            }
        } onCancel: {
            self.queue.async {
                guard !self.finished else { return }
                self.record("tcp_cancelled")
                self.finish(.failure(CancellationError()))
            }
        }
    }
    private func changed(_ newState: NWConnection.State) {
        guard !finished else { return }
        let reason = connection.currentPath?.unsatisfiedReason
        let outcome = state.observe(newState, reason: reason)
        switch newState {
        case .ready: record("tcp_ready_unverified")
        case .waiting(let error): record("tcp_waiting", error: error)
        case .failed(let error): record("tcp_failed", error: error)
        case .preparing: record("tcp_preparing")
        case .cancelled: finish(.failure(CancellationError())); return
        default: break
        }
        // A denied path can recover when the user answers the system alert.
        // Keep it alive until ready, failure, cancellation, or the user-test deadline.
        if let outcome { finish(.success(outcome)) }
    }
    private func record(_ event: String, error: NWError? = nil) {
        var evidence = event
        if let path = connection.currentPath {
            let status: String
            switch path.status {
            case .satisfied: status = "satisfied"
            case .unsatisfied: status = "unsatisfied"
            case .requiresConnection: status = "requires_connection"
            @unknown default: status = "unknown"
            }
            evidence += " path=" + status
            if state.localNetworkDenied { evidence += " reason=local_network_denied" }
        }
        if let error {
            switch error {
            case .posix(let code): evidence += " NSPOSIXErrorDomain=\(code.rawValue)"
            case .dns(let code): evidence += " DNSServiceError=\(code)"
            case .tls(let code): evidence += " NSOSStatusErrorDomain=\(code)"
            default: evidence += " network_error"
            }
        }
        diagnostics.record(origin: origin, phase: "local network test (TCP only)", started: started, evidence: evidence)
    }
    private func finish(_ result: Result<BuildLocalNetworkState.Outcome, Error>) {
        guard !finished else { return }
        finished = true; deadline?.cancel(); deadline = nil
        connection.stateUpdateHandler = nil; connection.cancel()
        let continuation = self.continuation; self.continuation = nil
        continuation?.resume(with: result)
    }
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
    private struct AccessTest { let id: UUID; let task: Task<Void, Error> }
    private let profile: AgentProfile
    private let routes: [String: Route]
    private let probeSeconds: Double
    private var selectedOrigin: String?
    private var connectionTask: Probe?
    private var accessTest: AccessTest?
    private var latestProbeID: UUID?
    private var closed = false
    private let diagnostics = BuildConnectionDiagnostics()

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
    func close() async {
        closed = true; connectionTask?.task.cancel(); connectionTask = nil; selectedOrigin = nil
        let accessTask = accessTest?.task
        accessTask?.cancel(); accessTest = nil
        for route in routes.values { route.session.invalidateAndCancel() }
        // Cancelled sockets finish recording before the store copies the report.
        _ = await accessTask?.result
    }
    func activeAddress() -> String? { selectedOrigin }
    func diagnosticReport() -> String { diagnostics.report() }

    /// Call only from an explicit user action. It allows time for the system
    /// permission alert; the caller must still perform the normal pinned HTTPS check.
    func testLocalNetworkAccess(timeout: TimeInterval = 20) async throws {
        try Task.checkCancellation()
        guard !closed else { throw CancellationError() }
        accessTest?.task.cancel()
        let origins = profile.origins, diagnostics = self.diagnostics
        let task = Task<Void, Error> {
            let outcomes = try await withThrowingTaskGroup(of: BuildLocalNetworkState.Outcome.self) { group in
                for origin in origins {
                    group.addTask { try await BuildLocalNetworkProbe(origin: origin, diagnostics: diagnostics).run(timeout: timeout) }
                }
                var outcomes: [BuildLocalNetworkState.Outcome] = []
                while let outcome = try await group.next() {
                    if outcome == .ready { group.cancelAll(); return [outcome] }
                    outcomes.append(outcome)
                }
                return outcomes
            }
            try Task.checkCancellation()
            if outcomes.contains(.ready) { return }
            if outcomes.contains(.denied) {
                throw BuildConnectionFailure.unreachable("Local Network access to the Mac is blocked or still awaiting permission. Allow access for APK Container—or LiveContainer if it hosts this app. If LiveContainer is missing from Settings, launch through its main app and try Allow Local Network again. Keep StikDebug/JIT enabled.")
            }
            if outcomes.contains(.timedOut) {
                throw BuildConnectionFailure.unreachable("The device could not open a TCP connection to the Mac before the test ended. This does not prove a permission or VPN problem. Check the Mac address and Wi-Fi, and copy Connection Details. Keep StikDebug/JIT enabled.")
            }
            throw BuildConnectionFailure.unreachable("The device could not open a TCP connection to the Mac. Copy Connection Details for the network error code. Keep StikDebug/JIT enabled.")
        }
        let test = AccessTest(id: UUID(), task: task); accessTest = test
        defer { if accessTest?.id == test.id { accessTest = nil } }
        try await withTaskCancellationHandler {
            try await task.value
            try Task.checkCancellation()
            guard !closed else { throw CancellationError() }
        } onCancel: { task.cancel() }
    }

    func connect() async throws -> Status {
        guard !closed else { throw CancellationError() }
        let probe: Probe
        if let existing = connectionTask { probe = existing }
        else {
            let profile = self.profile, routes = self.routes, duration = probeSeconds, diagnostics = self.diagnostics
            let task = Task<Reachable, Error> {
                let result = await withTaskGroup(of: ProbeResult.self) { group in
                    for origin in profile.origins {
                        group.addTask {
                            let started = Date()
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
                                diagnostics.record(origin: origin, phase: "status probe", started: started, status: 200)
                                return .ready(Reachable(status: status, origin: origin))
                            } catch {
                                diagnostics.record(origin: origin, phase: "status probe", started: started, error: error)
                                return .failed(error)
                            }
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
        let started = Date(), phase = method == "GET" ? "read request" : "build action"
        do {
            let data = try await Self.withDeadline(seconds: duration) {
                try await Self.read(profile: profile, route: route, origin: origin, path: path, method: method, body: body, timeout: duration)
            }
            diagnostics.record(origin: origin, phase: phase, started: started)
            return data
        } catch {
            diagnostics.record(origin: origin, phase: phase, started: started, error: error)
            throw error
        }
    }
    func download(_ path: String) async throws -> (URL, URLResponse) {
        if selectedOrigin == nil { _ = try await connect() }
        guard let origin = selectedOrigin else { throw Self.describe(URLError(.cannotConnectToHost)) }
        var request = URLRequest(url: try profile.endpoint(path, origin: origin))
        request.timeoutInterval = 60
        request.setValue("Bearer " + profile.token, forHTTPHeaderField: "Authorization")
        let route = routes[origin]!, rejections = routes[origin]!.trust.identityRejections
        let started = Date()
        do {
            let result = try await route.session.download(for: request)
            diagnostics.record(origin: origin, phase: "APK download", started: started, status: (result.1 as? HTTPURLResponse)?.statusCode)
            return result
        } catch {
            let classified = Self.classify(error, route: route, previousRejections: rejections)
            diagnostics.record(origin: origin, phase: "APK download", started: started, error: classified)
            throw Self.describe(classified)
        }
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
        case .timedOut:
            return BuildConnectionFailure.unreachable("The Mac didn't answer before the connection timed out. Check Local Network access for APK Container—or LiveContainer if it hosts the app—and the Mac address. Keep the StikDebug/JIT VPN on. Copy Connection Details if it continues.")
        case .cannotFindHost, .dnsLookupFailed:
            return BuildConnectionFailure.unreachable("The Mac hostname couldn't be resolved (\(urlError.code.rawValue)). Use the numeric address shown in APK Container Bridge, then reconnect. Keep the StikDebug/JIT VPN on.")
        case .cannotConnectToHost:
            return BuildConnectionFailure.unreachable("A connection to the Mac address couldn't be opened (\(urlError.code.rawValue)). Check that the bridge is running and its displayed address matches. Copy Connection Details if it continues.")
        case .notConnectedToInternet:
            return BuildConnectionFailure.unreachable("The device reports no usable network path (\(urlError.code.rawValue)). Check Wi-Fi and Local Network access for APK Container—or LiveContainer if it hosts the app. Keep the StikDebug/JIT VPN on.")
        case .networkConnectionLost:
            return BuildConnectionFailure.unreachable("The connection to the Mac was interrupted (\(urlError.code.rawValue)). Tap Reconnect. Check My Apps before resending a build request; it may already have reached the Mac.")
        default:
            return BuildConnectionFailure.unreachable("The Mac connection failed (NSURLErrorDomain \(urlError.code.rawValue)). Keep your StikDebug/JIT VPN on and copy Connection Details so the actual failure can be checked.")
        }
    }
}
