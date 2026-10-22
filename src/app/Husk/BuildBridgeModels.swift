// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

struct AgentProfile: Codable, Equatable {
    let format: String
    let version: Int
    let bridgeID: String
    let name: String
    let url: String
    let token: String
    let certificateSHA256: String
    let createdAt: String

    static func read(_ data: Data) throws -> AgentProfile {
        guard data.count <= 32_768 else { throw BuildBridgeError.message("This pairing file is too large.") }
        let value = try JSONDecoder().decode(AgentProfile.self, from: data)
        guard value.format == "apk-container-agent", value.version == 1,
              !value.bridgeID.isEmpty, value.bridgeID.count <= 128,
              !value.name.isEmpty, value.name.count <= 128,
              let url = URLComponents(string: value.url), url.scheme == "https",
              let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.path.isEmpty || url.path == "/",
              url.port == nil || (1...65535).contains(url.port!),
              value.token.range(of: #"^[A-Za-z0-9_-]{32,256}$"#, options: .regularExpression) != nil,
              value.certificateSHA256.range(of: #"^[a-fA-F0-9]{64}$"#, options: .regularExpression) != nil else {
            throw BuildBridgeError.message("This isn't a valid APK Container Bridge pairing file. Generate a new agent.prf on your Mac.")
        }
        return value
    }

    func endpoint(_ path: String) throws -> URL {
        guard path.hasPrefix("/v1/"), !path.contains(".."), !path.contains("?"), !path.contains("#"),
              let base = URLComponents(string: url) else { throw BuildBridgeError.message("Invalid bridge request.") }
        var parts = base
        parts.path = path
        guard let result = parts.url else { throw BuildBridgeError.message("Invalid bridge address.") }
        return result
    }
}

enum BuildBridgeError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

struct BuildMessage: Codable, Identifiable, Equatable {
    let id: String
    let role: String
    var text: String
    let createdAt: String
}
struct BuildArtifact: Codable, Identifiable, Equatable {
    let id: String
    let name: String
    let bytes: Int64
    let sha256: String
    let downloadPath: String
    let createdAt: String
}
struct BuildApproval: Codable, Identifiable, Equatable {
    struct Question: Codable, Identifiable, Equatable {
        struct Option: Codable, Equatable { let label: String; let description: String }
        let id: String
        let header: String?
        let question: String
        let options: [Option]?
    }
    let id: String
    let kind: String
    let title: String
    let detail: String
    let questions: [Question]?
    let createdAt: String
}
struct BuildSummary: Codable, Equatable {
    let kind: String
    let features: [String]
    let issues: [String]
    let ideas: [String]
    var headline: String {
        switch kind {
        case "created": return "I've created your app"
        case "edited": return "I've edited your app"
        default: return "I've updated your app"
        }
    }
}
struct BuildProject: Codable, Identifiable, Equatable {
    let id: String
    let name: String
    let status: String
    let createdAt: String
    let updatedAt: String
    let threadID: String?
    var messages: [BuildMessage]
    let artifacts: [BuildArtifact]
    let approvals: [BuildApproval]
    let summary: BuildSummary?
    let error: String?
    var isActive: Bool { status == "building" || status == "awaitingApproval" }
    var statusLabel: String {
        switch status {
        case "building": return "Building"
        case "awaitingApproval": return "Needs your input"
        case "completed": return artifacts.isEmpty ? "Ready" : "APK ready"
        case "failed": return "Needs attention"
        case "interrupted": return "Stopped"
        default: return "Ready to build"
        }
    }
}
