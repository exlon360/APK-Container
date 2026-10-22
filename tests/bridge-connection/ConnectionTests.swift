import Foundation
import Network

@main struct ConnectionTests {
    struct Fixture: Decodable { let addresses: [String: String]; let token: String; let pin: String }
    static func main() async throws {
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
        func profile(_ names: [String]) throws -> AgentProfile {
            let addresses = names.map { fixture.addresses[$0]! }
            return try AgentProfile.read(JSONSerialization.data(withJSONObject: [
                "format": "apk-container-agent", "version": 1, "bridgeID": "fixture", "name": "Fixture Mac",
                "url": addresses[0], "alternateURLs": Array(addresses.dropFirst()), "token": fixture.token,
                "certificateSHA256": fixture.pin, "createdAt": "fixture"
            ]))
        }
        let connection = BuildBridgeConnection(profile: try profile(["slow", "good"]), probeSeconds: 1)
        let start = Date()
        let status = try await connection.connect()
        precondition(status.paired && Date().timeIntervalSince(start) < 0.8, "A stalled primary blocked its healthy alternate")
        let address = await connection.activeAddress()
        precondition(address == fixture.addresses["good"])
        let (file, response) = try await connection.download("/v1/artifact")
        precondition((response as? HTTPURLResponse)?.statusCode == 200)
        let artifact = try Data(contentsOf: file)
        precondition(artifact == Data("APK fixture bytes".utf8), "Download did not use the healthy origin")
        try FileManager.default.removeItem(at: file)
        print("PASS pinned fallback and artifact download bypass stalled primary")

        let concurrent = BuildBridgeConnection(profile: try profile(["good", "backup"]), probeSeconds: 1)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<30 { group.addTask { _ = try await concurrent.request("/v1/ok") } }
            try await group.waitForAll()
        }
        await concurrent.close()
        print("PASS concurrent initial requests share a completed connection route")

        do { _ = try await connection.request("/v1/fail"); preconditionFailure("Accepted HTTP failure") }
        catch let failure as BuildConnectionFailure {
            precondition(!failure.isTransportFailure && failure.localizedDescription.contains("reachable"))
        }
        print("PASS HTTP service failure remains distinct from offline")

        let denied = BuildBridgeConnection(profile: try profile(["slow", "unauthorized"]), probeSeconds: 0.4)
        do { _ = try await denied.connect(); preconditionFailure("Accepted expired pairing") }
        catch let failure as BuildConnectionFailure { precondition(failure.needsPairing && !failure.isTransportFailure) }
        await denied.close()
        let deniedDetails = await denied.diagnosticReport()
        precondition(deniedDetails.contains(fixture.addresses["slow"]!) && deniedDetails.contains(fixture.addresses["unauthorized"]!))
        precondition(deniedDetails.contains("HTTP 401") && deniedDetails.contains("NSURLErrorDomain=-1001"), "Lost an alternate origin's failure evidence")
        print("PASS pairing response survives alternate timeout")

        let timeout = BuildBridgeConnection(profile: try profile(["slow"]), probeSeconds: 0.4)
        let timeoutStart = Date()
        do { _ = try await timeout.connect(); preconditionFailure("Stalled connection succeeded") }
        catch let failure as BuildConnectionFailure {
            precondition(failure.isTransportFailure && Date().timeIntervalSince(timeoutStart) < 1.2)
            precondition(failure.localizedDescription.contains("Local Network"))
        }
        await timeout.close()
        let timeoutDetails = await timeout.diagnosticReport()
        precondition(timeoutDetails.contains("timed_out (NSURLErrorDomain=-1001)") && timeoutDetails.contains("status probe"))
        print("PASS bounded timeout supplies network and permission actions")

        for kind in ["wrongPin", "invalid", "wrongID"] {
            let rejected = BuildBridgeConnection(profile: try profile([kind]), probeSeconds: 1)
            do { _ = try await rejected.connect(); preconditionFailure("Accepted " + kind) }
            catch let failure as BuildConnectionFailure {
                if kind == "wrongPin" { precondition(failure.localizedDescription.contains("identity")) }
                else { precondition(!failure.isTransportFailure) }
            }
            await rejected.close()
            let rejectedDetails = await rejected.diagnosticReport()
            precondition(rejectedDetails.contains(kind == "wrongPin" ? "secure_identity_rejected" : "invalid_bridge_response"))
        }
        print("PASS wrong certificate, unreadable status, and wrong bridge identity rejected")

        do { _ = try await connection.request("/v1/redirect"); preconditionFailure("Followed redirect") }
        catch let failure as BuildConnectionFailure { if case .response(302, _) = failure {} else { preconditionFailure("Unexpected redirect failure") } }
        do { _ = try await connection.request("/v1/drop-post", method: "POST", body: Data("{\"text\":\"private-user-prompt\"}".utf8)); preconditionFailure("Dropped POST succeeded") }
        catch let failure as BuildConnectionFailure { precondition(failure.isTransportFailure) }
        let countData = try await connection.request("/v1/counts")
        let counts = try JSONSerialization.jsonObject(with: countData) as! [String: [String: Int]]
        precondition(counts["good"]?["/v1/status"] == 2, "Concurrent callers did not coalesce their initial status probes")
        precondition(counts["good"]?["/v1/drop-post"] == 1, "A mutation was replayed")
        precondition(counts["wrongPin"] == nil, "Authorization reached the wrong certificate")
        precondition(counts["redirectTarget"] == nil, "Authorization reached a redirect target")
        let details = await connection.diagnosticReport()
        for privateValue in [fixture.token, fixture.pin, "private-server-response", "private-user-prompt", "/v1/"] {
            precondition(!details.contains(privateValue), "Connection report exposed private request or response information")
        }
        precondition(details.contains("HTTP 503") && details.contains("build action"))
        print("PASS no POST replay, pin credential leak, or redirect credential leak")

        let dnsFailure = BuildBridgeConnection.describe(URLError(.cannotFindHost)).localizedDescription
        let pathFailure = BuildBridgeConnection.describe(URLError(.notConnectedToInternet)).localizedDescription
        let refusedFailure = BuildBridgeConnection.describe(URLError(.cannotConnectToHost)).localizedDescription
        precondition(dnsFailure.contains("hostname") && dnsFailure.contains("-1003"))
        precondition(pathFailure.contains("network path") && pathFailure.contains("-1009"))
        precondition(refusedFailure.contains("connection") && refusedFailure.contains("-1004"))
        precondition(pathFailure.contains("VPN on"))
        print("PASS connection evidence is sanitized and DNS/path/connection failures remain distinct")

        let reroute = BuildBridgeConnection(profile: try profile(["good", "backup"]), probeSeconds: 1)
        _ = try await reroute.connect()
        let firstAddress = await reroute.activeAddress()
        precondition(firstAddress == fixture.addresses["good"])
        _ = try await reroute.request("/v1/drop-read")
        let recoveredAddress = await reroute.activeAddress()
        precondition(recoveredAddress == fixture.addresses["backup"], "Read did not recover after route loss")
        await reroute.close(); await connection.close()
        print("PASS idempotent GET reconnects after selected route fails")

        // Permission classification is based only on per-endpoint Network.framework
        // evidence. These tests do not change the host's real privacy settings.
        var evidence = BuildLocalNetworkState()
        precondition(evidence.observe(.preparing, reason: .localNetworkDenied) == nil)
        precondition(evidence.deadlineOutcome == .timedOut, "A non-waiting path was mislabeled as permission denial")
        precondition(evidence.observe(.waiting(.posix(.ENETDOWN)), reason: .localNetworkDenied) == nil)
        precondition(evidence.deadlineOutcome == .denied)
        precondition(evidence.observe(.ready, reason: nil) == .ready && !evidence.localNetworkDenied, "Allowing permission could not recover the same probe")
        _ = evidence.observe(.waiting(.posix(.ENETUNREACH)), reason: .notAvailable)
        precondition(evidence.deadlineOutcome == .timedOut, "A generic path failure was mislabeled as permission denial")
        _ = evidence.observe(.waiting(.posix(.ENETDOWN)), reason: .localNetworkDenied)
        _ = evidence.observe(.waiting(.posix(.ECONNREFUSED)), reason: nil)
        precondition(evidence.deadlineOutcome == .timedOut, "Stale permission evidence survived a new path state")
        _ = evidence.observe(.waiting(.posix(.ENETDOWN)), reason: .localNetworkDenied)
        _ = evidence.observe(.preparing, reason: .localNetworkDenied)
        precondition(evidence.deadlineOutcome == .timedOut, "Stale permission evidence survived a renewed connection attempt")
        print("PASS only endpoint waiting/localNetworkDenied proves denial; permission can recover")

        let tcp = BuildBridgeConnection(profile: try profile(["tcpOnly"]), probeSeconds: 0.2)
        try await tcp.testLocalNetworkAccess(timeout: 1)
        let tcpAddress = await tcp.activeAddress()
        precondition(tcpAddress == nil, "TCP readiness selected an authenticated route")
        let tcpDetails = await tcp.diagnosticReport()
        precondition(tcpDetails.contains("tcp_ready_unverified") && tcpDetails.contains("TCP only"))
        let reader = BuildBridgeConnection(profile: try profile(["backup"]), probeSeconds: 1)
        let rawTCPData = try await reader.request("/v1/tcp-counts")
        let rawTCPCounts = try JSONSerialization.jsonObject(with: rawTCPData) as! [String: Int]
        precondition(rawTCPCounts["connections"] == 1 && rawTCPCounts["bytes"] == 0, "A TCP permission test sent application data")
        precondition(rawTCPCounts["closed"] == 1, "A completed TCP permission test left its socket open")
        do { _ = try await tcp.connect(); preconditionFailure("TCP readiness bypassed HTTPS") }
        catch let failure as BuildConnectionFailure { precondition(failure.isTransportFailure) }
        await tcp.close(); await reader.close()
        print("PASS real loopback TCP probe sends zero bytes, closes, and cannot bypass HTTPS")

        let tcpAlternate = BuildBridgeConnection(profile: try profile(["closedPort", "tcpOnly"]), probeSeconds: 1)
        let alternateStart = Date()
        try await tcpAlternate.testLocalNetworkAccess(timeout: 20)
        precondition(Date().timeIntervalSince(alternateStart) < 1, "A waiting TCP origin blocked a reachable alternate")
        let alternateAddress = await tcpAlternate.activeAddress()
        precondition(alternateAddress == nil)
        let alternateDetails = await tcpAlternate.diagnosticReport()
        precondition(alternateDetails.contains("tcp_ready_unverified") && alternateDetails.contains("tcp_cancelled"))
        await tcpAlternate.close()
        print("PASS TCP alternate readiness cancels waiting origins without selecting an authenticated route")

        let tcpPin = BuildBridgeConnection(profile: try profile(["wrongPin"]), probeSeconds: 1)
        try await tcpPin.testLocalNetworkAccess(timeout: 1)
        do { _ = try await tcpPin.connect(); preconditionFailure("TCP readiness bypassed the certificate pin") }
        catch let failure as BuildConnectionFailure { precondition(failure.localizedDescription.contains("identity")) }
        let tcpPinDetails = await tcpPin.diagnosticReport()
        precondition(tcpPinDetails.contains("tcp_ready_unverified") && tcpPinDetails.contains("secure_identity_rejected"))
        for privateValue in [fixture.token, fixture.pin, "/v1/"] { precondition(!tcpPinDetails.contains(privateValue)) }
        await tcpPin.close()
        print("PASS raw TCP readiness still requires the exact pinned HTTPS identity")

        let bounded = BuildBridgeConnection(profile: try profile(["closedPort"]), probeSeconds: 1)
        let boundedStart = Date()
        do { try await bounded.testLocalNetworkAccess(timeout: 0.15); preconditionFailure("Closed TCP port succeeded") }
        catch let failure as BuildConnectionFailure {
            precondition(failure.isTransportFailure && !failure.localizedDescription.contains("iOS denied"))
            precondition(Date().timeIntervalSince(boundedStart) < 1)
        }
        let boundedDetails = await bounded.diagnosticReport()
        precondition(boundedDetails.contains("NSPOSIXErrorDomain=") && !boundedDetails.contains("reason=local_network_denied"))
        await bounded.close()
        print("PASS closed loopback port is bounded and is not falsely called permission denial")

        for cancelWithClose in [false, true] {
            let cancellable = BuildBridgeConnection(profile: try profile(["closedPort"]), probeSeconds: 1)
            let pending = Task { try await cancellable.testLocalNetworkAccess(timeout: 20) }
            for _ in 0..<100 {
                if await cancellable.diagnosticReport().contains("tcp_waiting") { break }
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            let cancelStart = Date()
            if cancelWithClose { await cancellable.close() } else { pending.cancel() }
            do { try await pending.value; preconditionFailure("Cancelled network test succeeded") }
            catch { precondition(BuildBridgeConnection.isCancellation(error)) }
            precondition(Date().timeIntervalSince(cancelStart) < 0.5, "Cancellation waited for the permission deadline")
            let cancelledDetails = await cancellable.diagnosticReport()
            precondition(cancelledDetails.contains("tcp_cancelled"), "Cancellation evidence was unavailable after completion")
            await cancellable.close()
        }
        print("PASS caller cancellation and transport close cancel live TCP probes and preserve evidence")
    }
}
