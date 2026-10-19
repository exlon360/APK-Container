// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// Durable, private originals written before changing guest launcher/chrome state.
/// Nothing is restored automatically: a later user change must never be overwritten.
final class AndroidPolicyRestoreJournal {
    private static let lock = NSLock()
    private let url: URL
    private let guestPath: String

    private struct Chrome: Codable {
        let utc: String
        let snapshot: String
        let restoreCommand: String?
    }
    private struct Record: Codable {
        let createdUTC: String
        let guestPath: String
        var packages: [String: Int]
        var chrome: [Chrome]
        var restoreInstructions = "Review current guest state before restoring. Package values are original Android enabled states. Use the recorded restore commands deliberately; never restore automatically or delete guest app data."
        var packageRestoreCommands: [String: String] = [:]
    }

    init(directory: URL, guestPath: String) throws {
        self.guestPath = guestPath
        let attributes = try FileManager.default.attributesOfItem(atPath: guestPath)
        let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        let created = (attributes[.creationDate] as? Date)?.timeIntervalSince1970 ?? 0
        url = directory.appendingPathComponent("guest-\(inode)-\(Int(created)).json")
    }

    func saveOriginal(package: String, state: Int) throws {
        try update { record in
            guard record.packages[package] == nil else { return }
            let command = try AndroidAppOnlyPolicy.restorePackageCommand(package: package, originalState: state)
            record.packages[package] = state
            record.packageRestoreCommands[package] = command
        }
    }

    func saveChromeOriginal(_ snapshot: String) throws {
        try update { record in
            guard record.chrome.last?.snapshot != snapshot else { return }
            record.chrome.append(.init(utc: Self.timestamp(), snapshot: snapshot,
                restoreCommand: try AndroidAppOnlyPolicy.restoreChromeCommand(snapshot: snapshot)))
        }
    }

    private static func timestamp() -> String { ISO8601DateFormatter().string(from: Date()) }

    private func update(_ modify: (inout Record) throws -> Void) throws {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        let manager = FileManager.default
        let directory = url.deletingLastPathComponent()
        try manager.createDirectory(at: directory, withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
        var record: Record
        if manager.fileExists(atPath: url.path) {
            record = try JSONDecoder().decode(Record.self, from: Data(contentsOf: url))
        } else {
            record = Record(createdUTC: Self.timestamp(), guestPath: guestPath, packages: [:], chrome: [])
        }
        try modify(&record)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(record)
        try data.write(to: url, options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        guard try Data(contentsOf: url) == data else { throw CocoaError(.fileWriteUnknown) }
    }
}
