import Foundation

@MainActor final class Router {
    enum Tab { case build }
    static let shared = Router()
    var tab = Tab.build
}
@MainActor final class IncomingFiles {
    static let shared = IncomingFiles()
    func receive(_ url: URL) { preconditionFailure("Cancelled download must not be imported") }
}

@main struct StoreTests {
    struct Fixture: Decodable { let profile: AgentProfile; let control: String }
    struct Snapshot: Decodable { let counts: [String: Int]; let pending: [String] }
    @MainActor static func main() async throws {
        let file = URL(fileURLWithPath: CommandLine.arguments[1])
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: file))
        func control(_ path: String = "/snapshot") async throws -> Snapshot {
            let (data, _) = try await URLSession.shared.data(from: URL(string: fixture.control + path)!)
            return try JSONDecoder().decode(Snapshot.self, from: data)
        }
        func waitFor(_ kind: String) async throws {
            for _ in 0..<100 {
                if try await control().pending.contains(kind) { return }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            preconditionFailure("Fixture did not receive pending " + kind)
        }
        func assertStatusCount(_ expected: Int, _ message: String = "Unexpected status request count") async throws {
            let value = try await control().counts["/v1/status"]
            precondition(value == expected, message)
        }
        let cache = file.deletingLastPathComponent().appendingPathComponent("cache/projects.json")
        let store = BuildBridgeStore(testProfile: fixture.profile, cacheURL: cache)
        await store.refresh()
        precondition(store.connected && store.paired && store.projects.count == 1)
        store.selectedID = "project-fixture"; store.draft = "Keep my unsent prompt"
        let oldPoll = Task { await store.poll() }
        try await waitFor("read")
        precondition(store.canReconnect, "Pending read must not disable explicit reconnect")
        await store.reconnect()
        let currentReport = store.connectionDiagnostics
        _ = try await control("/release/read")
        await oldPoll.value
        precondition(store.connected && store.paired && !store.checkingConnection)
        precondition(store.profile == fixture.profile && store.selectedID == "project-fixture" && store.draft == "Keep my unsent prompt")
        precondition(store.selected?.status == "completed" && store.selected?.error == nil && store.error == nil)
        precondition(store.connectionDiagnostics == currentReport, "Cancelled poll overwrote new diagnostics")
        try await assertStatusCount(2, "Reconnect was dropped while polling")
        let cached = try JSONSerialization.jsonObject(with: Data(contentsOf: cache)) as! [String: Any]
        precondition(cached["bridgeID"] as? String == fixture.profile.bridgeID && (cached["projects"] as? [Any])?.count == 1)
        print("PASS reconnect cancels pending poll, rejects stale reply/diagnostics, and preserves app/draft/pairing/cache")

        _ = try await control("/hold-status")
        let oldRefresh = Task { await store.refresh() }
        try await waitFor("status")
        precondition(store.checkingConnection && store.canReconnect, "A stalled check must be restartable")
        await store.reconnect()
        _ = try await control("/release/status")
        await oldRefresh.value
        precondition(store.connected && store.paired && !store.checkingConnection && store.error == nil)
        try await assertStatusCount(4)
        print("PASS explicit reconnect replaces a stalled status check")

        let project = store.selected!
        let approval = BuildApproval(id: "approval-fixture", kind: "command", title: "Allow", detail: "Fixture", questions: nil, createdAt: "fixture")
        let approve = Task { await store.approve(approval, project: project, accept: true) }
        try await waitFor("approval")
        precondition(!store.canReconnect)
        await store.reconnect()
        try await assertStatusCount(4, "Reconnect interrupted an approval")
        _ = try await control("/release/approval"); await approve.value
        precondition(store.canReconnect)
        let interrupt = Task { await store.interrupt(project) }
        try await waitFor("interrupt")
        precondition(!store.canReconnect); await store.reconnect()
        try await assertStatusCount(4, "Reconnect interrupted a mutation")
        _ = try await control("/release/interrupt"); await interrupt.value
        precondition(store.canReconnect)
        print("PASS reconnect cannot cancel or replay pending approval/interrupt POSTs")

        let send = Task { await store.send() }
        try await waitFor("send")
        precondition(store.busy && !store.canReconnect); await store.reconnect()
        try await assertStatusCount(4)
        _ = try await control("/release/send"); await send.value
        precondition(!store.busy && store.canReconnect)
        let counts = try await control().counts
        precondition(counts["/v1/projects/project-fixture/approvals/approval-fixture"] == 1)
        precondition(counts["/v1/projects/project-fixture/interrupt"] == 1)
        precondition(counts["/v1/projects/project-fixture/messages"] == 1)
        print("PASS reconnect cannot cancel an app send; every mutation reached fixture exactly once")

        let artifact = BuildArtifact(id: "artifact-fixture", name: "Fixture.apk", bytes: 1,
            sha256: String(repeating: "0", count: 64), downloadPath: "/v1/projects/project-fixture/artifacts/artifact-fixture", createdAt: "fixture")
        let download = Task { await store.install(artifact, project: project) }
        try await waitFor("download")
        precondition(store.downloading != nil && !store.canReconnect); await store.reconnect()
        try await assertStatusCount(4)
        download.cancel(); await download.value
        precondition(store.downloading == nil && store.canReconnect)
        _ = try await control("/release/download")
        print("PASS reconnect leaves a pending APK download alone")
    }
}
