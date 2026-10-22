// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import CryptoKit

@main enum RepositoryTests {
    typealias R = RepositoryCatalog
    static func data(_ object: Any) throws -> Data { try JSONSerialization.data(withJSONObject: object) }
    static func fail(_ block: () throws -> Void) { do { try block(); preconditionFailure("Expected rejection") } catch {} }
    @MainActor static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let fixture = try Data(contentsOf: root.appendingPathComponent("tests/repositories/fixtures/releases.json"))
        let releases = try JSONSerialization.jsonObject(with: fixture) as! [String: Any]
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let bundled = try decoder.decode([AppSource].self, from: Data(contentsOf: root.appendingPathComponent("src/app/Husk/Resources/RepositorySeedCatalog.json")))
        precondition(R.seeds.count == 10 && Set(R.seeds.map(\.url)).count == 10 && bundled.count == 10)
        for seed in R.seeds {
            let parsed = try R.parse(data(releases[seed.url]!), sourceURL: seed.url)
            let cached = bundled.first { $0.identifier == seed.url }!
            precondition(parsed.apps == cached.apps && parsed.name == seed.name)
            precondition(parsed.apps.count == 1 && parsed.apps[0].sha256?.count == 64)
            precondition(R.httpsURL(parsed.apps[0].downloadURL) != nil)
        }
        let anki = bundled.first { $0.name == "AnkiDroid" }!.apps[0]
        precondition(anki.assetName!.contains("arm64") && !anki.assetName!.contains("parallel"))
        let tasks = bundled.first { $0.name == "Tasks.org" }!.apps[0]
        precondition(tasks.assetName!.contains("fdroid"))
        let local = bundled.first { $0.name == "LocalSend" }!.apps[0]
        precondition(local.assetName!.contains("arm64"))

        let canonical = try R.canonicalURL(" https://github.com/TeamNewPipe/NewPipe/releases/ ")
        precondition(canonical == R.seeds[0].url)
        let gitURL = try R.canonicalURL("https://github.com/TeamNewPipe/NewPipe.git")
        precondition(gitURL == canonical)
        for invalid in ["http://example.org/index.json", "file:///tmp/index.json", "https://user:pass@example.org/index.json", "https://github.com/a/b/tree/main", "https://api.github.com/repos/a/b/issues", "https://example.org/a#secret"] {
            fail { _ = try R.canonicalURL(invalid) }
        }
        for invalid in ["", "sha256:bad", String(repeating: "z", count: 64)] { fail { _ = try R.validHash(invalid) } }
        let normalizedHash = try R.validHash("sha256:" + String(repeating: "AB", count: 32))
        precondition(normalizedHash == String(repeating: "ab", count: 32))
        for invalid in ["app-x86.apk", "app-x64.apk", "app-arm32.apk", "app-armeabi-v7a.apk", "dev-app-universal.apk", "app.parallel.A.apk", "app.aab"] { precondition(R.apkScore(invalid) == nil) }

        var badRelease = releases[R.seeds[0].url] as! [String: Any]
        badRelease["draft"] = true
        fail { _ = try R.parse(data(badRelease), sourceURL: R.seeds[0].url) }
        badRelease["draft"] = false
        badRelease["assets"] = [["name":"app-arm64.apk", "browser_download_url":"http://example.org/app.apk", "size":100, "state":"uploaded"]]
        fail { _ = try R.parse(data(badRelease), sourceURL: R.seeds[0].url) }

        let simple: [String: Any] = ["name":"Example", "apps":[["name":"Example", "bundleIdentifier":"org.example.app", "version":"1", "downloadURL":"https://example.org/app.apk"]]]
        let simpleResult = try R.parse(data(simple), sourceURL:"https://example.org/index.json")
        precondition(simpleResult.apps.count == 1 && simpleResult.apps[0].sha256 == nil)
        var duplicate = simple; duplicate["apps"] = (simple["apps"] as! [[String:Any]]) + (simple["apps"] as! [[String:Any]])
        fail { _ = try R.parse(data(duplicate), sourceURL:"https://example.org/index.json") }

        let fdroid: [String: Any] = ["repo":["name":"Example","address":"https://example.org/repo"],
            "apps":[["packageName":"org.example.app","name":"Example"]],
            "packages":["org.example.app":[
                ["apkName":"old.apk","versionName":"1","versionCode":1,"hashType":"sha256","hash":String(repeating:"a",count:64)],
                ["apkName":"new.apk","versionName":"2","versionCode":2,"nativecode":["arm64-v8a"],"minSdkVersion":36],
                ["apkName":"future.apk","versionName":"3","versionCode":3,"minSdkVersion":37],
                ["apkName":"x86.apk","versionName":"4","versionCode":4,"nativecode":["x86"]]]]]
        let parsedFDroid = try R.parse(data(fdroid), sourceURL:"https://example.org/index-v1.json")
        precondition(parsedFDroid.apps[0].version == "2" && parsedFDroid.apps[0].downloadURL == "https://example.org/repo/new.apk")
        var insecure = fdroid; insecure["repo"] = ["name":"Example","address":"http://example.org/repo"]
        fail { _ = try R.parse(data(insecure), sourceURL:"https://example.org/index-v1.json") }

        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("apk-repository-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: temp) }
        let suite = "apk-repository-tests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let custom = "https://example.org/custom-index.json"
        defaults.set([custom], forKey: "HuskSourceURLs")
        let seedData = try Data(contentsOf: root.appendingPathComponent("src/app/Husk/Resources/RepositorySeedCatalog.json"))
        let cache = temp.appendingPathComponent("catalog/cache.json")
        let manager = SourceManager(defaults: defaults, cacheURL: cache, seedCatalog: seedData)
        precondition(manager.sourceURLs.count == 11 && manager.sourceURLs.contains(custom))
        precondition(manager.enabledSources.count == 10)
        manager.setEnabled(false, url: R.seeds[0].url)
        precondition(manager.sources.count == 10 && manager.enabledSources.count == 9)
        let restored = SourceManager(defaults: defaults, cacheURL: cache, seedCatalog: seedData)
        precondition(!restored.isEnabled(R.seeds[0].url) && restored.sourceURLs.contains(custom))
        restored.removeSource(urlString: R.seeds[1].url)
        let afterRemoval = SourceManager(defaults: defaults, cacheURL: cache, seedCatalog: seedData)
        precondition(!afterRemoval.sourceURLs.contains(R.seeds[1].url) && afterRemoval.sources.count == 9)
        afterRemoval.sourceURLs = []
        let emptyManager = SourceManager(defaults: defaults, cacheURL: cache, seedCatalog: seedData)
        precondition(emptyManager.sourceURLs.isEmpty && emptyManager.sources.isEmpty, "Removing all sources must persist without reseeding")

        let apk = temp.appendingPathComponent("app.apk")
        let valid = zip(name: "AndroidManifest.xml")
        try valid.write(to: apk)
        let hash = SHA256.hash(data: valid).map { String(format:"%02x",$0) }.joined()
        try RepositoryArtifact.verify(apk, expectedSHA256: hash, expectedSize: Int64(valid.count))
        fail { try RepositoryArtifact.verify(apk, expectedSHA256: String(repeating:"0",count:64), expectedSize:nil) }
        fail { try RepositoryArtifact.verify(apk, expectedSHA256: nil, expectedSize: Int64(valid.count + 1)) }
        try zip(name:"source.txt").write(to:apk)
        fail { try RepositoryArtifact.verify(apk, expectedSHA256:nil, expectedSize:nil) }
        try Data("<html>not an APK</html>".utf8).write(to:apk)
        fail { try RepositoryArtifact.verify(apk, expectedSHA256:nil, expectedSize:nil) }
        try valid.dropLast().write(to:apk)
        fail { try RepositoryArtifact.verify(apk, expectedSHA256:nil, expectedSize:nil) }
        if CommandLine.arguments.contains("--live") {
            var request = URLRequest(url: URL(string: R.seeds[0].url)!)
            request.setValue("APK-Container-Repository-Test", forHTTPHeaderField: "User-Agent")
            let response = try await RepositoryTransfer(destinationDirectory: temp).download(request, maximum: 2 * 1024 * 1024)
            guard let metadata = response.file else { preconditionFailure("No live metadata") }
            let live = try R.parse(Data(contentsOf: metadata), sourceURL: R.seeds[0].url)
            precondition(live.apps.count == 1 && live.apps[0].sha256 != nil)
            if let etag = response.etag {
                request.setValue(etag, forHTTPHeaderField: "If-None-Match")
                let cached = try await RepositoryTransfer(destinationDirectory: temp).download(request, maximum: 2 * 1024 * 1024)
                precondition(cached.status == 304 && cached.file == nil, "ETag must preserve cached metadata")
            }
            let app = live.apps[0]
            let apkResponse = try await RepositoryTransfer(destinationDirectory: temp).download(URLRequest(url: URL(string: app.downloadURL)!), maximum: 128 * 1024 * 1024)
            guard let package = apkResponse.file else { preconditionFailure("No live APK") }
            try RepositoryArtifact.verify(package, expectedSHA256: app.sha256, expectedSize: app.downloadSize)
            do {
                _ = try await RepositoryTransfer(destinationDirectory: temp).download(URLRequest(url: URL(string: app.downloadURL)!), maximum: 100)
                preconditionFailure("Oversized response accepted")
            } catch {}
            print("Live transfer checks passed: GitHub HTTPS metadata, ETag304, APK redirect/download, published SHA256 and manifest, size-limit refusal. No APK installed.")
        }
        print("Repository checks passed: ten verified release fixtures, ARM64 selection, HTTPS/schema validation, F-Droid version selection, checksum/size and APK manifest validation.")
    }
    static func zip(name: String) -> Data {
        var bytes: [UInt8] = []
        func u16(_ value: Int) { bytes += [UInt8(value & 255),UInt8((value >> 8) & 255)] }
        func u32(_ value: Int) { u16(value & 65_535); u16((value >> 16) & 65_535) }
        let nameBytes = Array(name.utf8)
        u32(0x04034b50); u16(20); u16(0); u16(0); u16(0); u16(0); u32(0); u32(0); u32(0); u16(nameBytes.count); u16(0); bytes += nameBytes
        let offset = bytes.count
        u32(0x02014b50); u16(20); u16(20); u16(0); u16(0); u16(0); u16(0); u32(0); u32(0); u32(0); u16(nameBytes.count); u16(0); u16(0); u16(0); u16(0); u32(0); u32(0); bytes += nameBytes
        let size = bytes.count - offset
        u32(0x06054b50); u16(0); u16(0); u16(1); u16(1); u32(size); u32(offset); u16(0)
        return Data(bytes)
    }
}
