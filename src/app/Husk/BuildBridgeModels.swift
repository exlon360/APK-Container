// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

struct AgentProfile: Codable, Equatable, Sendable {
    let format: String
    let version: Int
    let bridgeID: String
    let name: String
    let url: String
    let token: String
    let certificateSHA256: String
    let createdAt: String
    let alternateURLs: [String]?

    var origins: [String] {
        ([url] + (alternateURLs ?? [])).compactMap(Self.origin).reduce(into: []) { result, origin in
            if !result.contains(origin) { result.append(origin) }
        }
    }

    static func origin(_ value: String) -> String? {
        guard var parts = URLComponents(string: value), parts.scheme?.lowercased() == "https",
              let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.path.isEmpty || parts.path == "/",
              parts.port == nil || (1...65535).contains(parts.port!) else { return nil }
        parts.scheme = "https"; parts.path = ""
        return parts.url?.absoluteString
    }

    static func read(_ data: Data) throws -> AgentProfile {
        guard data.count <= 32_768 else { throw BuildBridgeError.message("This pairing file is too large.") }
        let value = try JSONDecoder().decode(AgentProfile.self, from: data)
        guard value.format == "apk-container-agent", value.version == 1,
              !value.bridgeID.isEmpty, value.bridgeID.count <= 128,
              !value.name.isEmpty, value.name.count <= 128,
              Self.origin(value.url) != nil,
              (value.alternateURLs?.count ?? 0) <= 5,
              (value.alternateURLs ?? []).allSatisfy({ Self.origin($0) != nil }),
              value.token.range(of: #"^[A-Za-z0-9_-]{32,256}$"#, options: .regularExpression) != nil,
              value.certificateSHA256.range(of: #"^[a-fA-F0-9]{64}$"#, options: .regularExpression) != nil else {
            throw BuildBridgeError.message("This isn't a valid APK Container Bridge pairing file. Generate a new agent.prf on your Mac.")
        }
        return value
    }

    func replacingAddress(_ address: String) throws -> AgentProfile {
        var text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.contains("://") { text = "https://" + text }
        guard var components = URLComponents(string: text) else { throw BuildBridgeError.message("Enter the Mac address shown in APK Container Bridge.") }
        if components.port == nil { components.port = URLComponents(string: url)?.port ?? 48152 }
        guard let origin = components.string.flatMap(Self.origin) else {
            throw BuildBridgeError.message("Use an HTTPS Mac address without a path, such as https://192.168.1.20:48152.")
        }
        return AgentProfile(format: format, version: version, bridgeID: bridgeID, name: name,
            url: origin, token: token, certificateSHA256: certificateSHA256, createdAt: createdAt,
            alternateURLs: Array(origins.filter { $0 != origin }.prefix(5)))
    }

    func endpoint(_ path: String, origin: String? = nil) throws -> URL {
        let selected = origin ?? url
        guard path.hasPrefix("/v1/"), !path.contains(".."), !path.contains("?"), !path.contains("#"),
              let normalized = Self.origin(selected), origins.contains(normalized),
              var parts = URLComponents(string: normalized) else { throw BuildBridgeError.message("Invalid bridge request.") }
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
