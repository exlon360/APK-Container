import Foundation

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
        print("PASS pairing response survives alternate timeout")

        let timeout = BuildBridgeConnection(profile: try profile(["slow"]), probeSeconds: 0.4)
        let timeoutStart = Date()
        do { _ = try await timeout.connect(); preconditionFailure("Stalled connection succeeded") }
        catch let failure as BuildConnectionFailure {
            precondition(failure.isTransportFailure && Date().timeIntervalSince(timeoutStart) < 1.2)
            precondition(failure.localizedDescription.contains("Local Network"))
        }
        await timeout.close()
        print("PASS bounded timeout supplies network and permission actions")

        for kind in ["wrongPin", "invalid", "wrongID"] {
            let rejected = BuildBridgeConnection(profile: try profile([kind]), probeSeconds: 1)
            do { _ = try await rejected.connect(); preconditionFailure("Accepted " + kind) }
            catch let failure as BuildConnectionFailure {
                if kind == "wrongPin" { precondition(failure.localizedDescription.contains("identity")) }
                else { precondition(!failure.isTransportFailure) }
            }
            await rejected.close()
        }
        print("PASS wrong certificate, unreadable status, and wrong bridge identity rejected")

        do { _ = try await connection.request("/v1/redirect"); preconditionFailure("Followed redirect") }
        catch let failure as BuildConnectionFailure { if case .response(302, _) = failure {} else { preconditionFailure("Unexpected redirect failure") } }
        do { _ = try await connection.request("/v1/drop-post", method: "POST", body: Data("{}".utf8)); preconditionFailure("Dropped POST succeeded") }
        catch let failure as BuildConnectionFailure { precondition(failure.isTransportFailure) }
        let countData = try await connection.request("/v1/counts")
        let counts = try JSONSerialization.jsonObject(with: countData) as! [String: [String: Int]]
        precondition(counts["good"]?["/v1/status"] == 2, "Concurrent callers did not coalesce their initial status probes")
        precondition(counts["good"]?["/v1/drop-post"] == 1, "A mutation was replayed")
        precondition(counts["wrongPin"] == nil, "Authorization reached the wrong certificate")
        precondition(counts["redirectTarget"] == nil, "Authorization reached a redirect target")
        print("PASS no POST replay, pin credential leak, or redirect credential leak")

        let reroute = BuildBridgeConnection(profile: try profile(["good", "backup"]), probeSeconds: 1)
        _ = try await reroute.connect()
        let firstAddress = await reroute.activeAddress()
        precondition(firstAddress == fixture.addresses["good"])
        _ = try await reroute.request("/v1/drop-read")
        let recoveredAddress = await reroute.activeAddress()
        precondition(recoveredAddress == fixture.addresses["backup"], "Read did not recover after route loss")
        await reroute.close(); await connection.close()
        print("PASS idempotent GET reconnects after selected route fails")
    }
}
