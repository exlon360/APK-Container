import Foundation

@main struct BuildBridgeModelTests {
    static func main() throws {
        let valid: [String: Any] = ["format": "apk-container-agent", "version": 1, "bridgeID": "fixture",
            "name": "Fixture Mac", "url": "https://Mac.local:48152", "token": String(repeating: "a", count: 64),
            "certificateSHA256": String(repeating: "b", count: 64), "createdAt": "2026-10-22T00:00:00Z"]
        func decode(_ value: [String: Any]) throws -> AgentProfile { try AgentProfile.read(JSONSerialization.data(withJSONObject: value)) }
        let profile = try decode(valid)
        let endpoint = try profile.endpoint("/v1/status")
        precondition(endpoint.absoluteString == "https://Mac.local:48152/v1/status")
        for url in ["http://Mac.local:48152", "https://user:secret@Mac.local", "https://Mac.local/path", "https://Mac.local?token=a", "https://Mac.local/#fragment", "file:///tmp/a"] {
            var malformed = valid; malformed["url"] = url
            do { _ = try decode(malformed); preconditionFailure("Accepted invalid origin") } catch {}
        }
        for (field, value) in [("token", "short"), ("certificateSHA256", "bad"), ("format", "other-profile"), ("name", "")] {
            var malformed = valid; malformed[field] = value
            do { _ = try decode(malformed); preconditionFailure("Accepted invalid profile") } catch {}
        }
        for path in ["https://evil.test/v1/status", "//evil.test", "/v1/../secret", "/v1/status?redirect=evil"] {
            do { _ = try profile.endpoint(path); preconditionFailure("Accepted unsafe path") } catch {}
        }
        do { _ = try AgentProfile.read(Data(repeating: 0, count: 32_769)); preconditionFailure() } catch {}
        let project = """
        {"id":"id","name":"My App","status":"awaitingApproval","createdAt":"now","updatedAt":"now","threadID":null,"messages":[{"id":"m","role":"user","text":"Build a timer","createdAt":"now"}],"artifacts":[],"approvals":[{"id":"a","kind":"input","title":"Question","detail":"Choose","createdAt":"now","questions":[{"id":"q","header":"Color","question":"Which color?","options":[{"label":"Blue","description":"Blue theme"}]}]}],"summary":null,"error":null}
        """
        let parsed = try JSONDecoder().decode(BuildProject.self, from: Data(project.utf8))
        precondition(parsed.isActive && parsed.statusLabel == "Needs your input")
        precondition(parsed.messages[0].text == "Build a timer" && parsed.approvals[0].questions?[0].options?[0].label == "Blue")
        precondition(BuildSummary(kind: "created", features: [], issues: [], ideas: []).headline == "I've created your app")
        print("Build bridge model tests passed: profile validation, pinned-origin endpoint isolation, real project and approval decoding.")
    }
}
