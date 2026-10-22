// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import CryptoKit

/// Check repository bytes before they enter the existing APK importer.
enum RepositoryArtifact {
    static func verify(_ file: URL, expectedSHA256: String?, expectedSize: Int64?) throws {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let length = try handle.seekToEnd()
        guard length >= 22, length <= 512 * 1024 * 1024 else {
            throw RepositoryCatalog.Failure.message("The downloaded APK is empty or exceeds 512 MB.")
        }
        if let expectedSize, expectedSize > 0, UInt64(expectedSize) != length {
            throw RepositoryCatalog.Failure.message("The APK's size does not match the repository. Try refreshing the repository.")
        }
        if let expected = try RepositoryCatalog.validHash(expectedSHA256) {
            try handle.seek(toOffset: 0)
            var hash = SHA256()
            while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty { hash.update(data: chunk) }
            let actual = hash.finalize().map { String(format: "%02x", $0) }.joined()
            guard actual == expected else { throw RepositoryCatalog.Failure.message("The APK checksum did not match. The file was not imported.") }
        }
        guard try containsAndroidManifest(handle, length: length) else {
            throw RepositoryCatalog.Failure.message("The downloaded file is not an APK with an Android manifest.")
        }
    }

    private static func containsAndroidManifest(_ file: FileHandle, length: UInt64) throws -> Bool {
        let tailCount = Int(min(length, 65_557))
        try file.seek(toOffset: length - UInt64(tailCount))
        guard let tail = try file.read(upToCount: tailCount), tail.count == tailCount else { return false }
        let bytes = [UInt8](tail)
        var end: Int?
        for index in stride(from: bytes.count - 22, through: 0, by: -1) {
            if u32(bytes, index) == 0x06054b50 && index + 22 + Int(u16(bytes, index + 20)) == bytes.count { end = index; break }
        }
        guard let end, u16(bytes, end + 4) == 0, u16(bytes, end + 6) == 0 else { return false }
        let entries = Int(u16(bytes, end + 10)), size = UInt64(u32(bytes, end + 12)), offset = UInt64(u32(bytes, end + 16))
        guard entries > 0, entries != 65_535, size <= 32 * 1024 * 1024,
              offset + size <= length - UInt64(tailCount) + UInt64(end) else { return false }
        try file.seek(toOffset: offset)
        guard let data = try file.read(upToCount: Int(size)), data.count == Int(size) else { return false }
        let directory = [UInt8](data)
        var position = 0, manifests = 0
        for _ in 0..<entries {
            guard position + 46 <= directory.count, u32(directory, position) == 0x02014b50 else { return false }
            let nameLength = Int(u16(directory, position + 28)), extra = Int(u16(directory, position + 30)), comment = Int(u16(directory, position + 32))
            let next = position + 46 + nameLength + extra + comment
            guard next <= directory.count else { return false }
            let name = String(decoding: directory[(position + 46)..<(position + 46 + nameLength)], as: UTF8.self)
            if name == "AndroidManifest.xml" { manifests += 1 }
            position = next
        }
        return manifests == 1 && position == directory.count
    }
    private static func u16(_ bytes: [UInt8], _ index: Int) -> UInt16 { UInt16(bytes[index]) | UInt16(bytes[index + 1]) << 8 }
    private static func u32(_ bytes: [UInt8], _ index: Int) -> UInt32 {
        UInt32(bytes[index]) | UInt32(bytes[index + 1]) << 8 | UInt32(bytes[index + 2]) << 16 | UInt32(bytes[index + 3]) << 24
    }
}
