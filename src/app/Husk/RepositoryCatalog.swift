// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

struct AppSource: Identifiable, Equatable, Codable {
    let name: String
    let identifier: String
    var apps: [SourceApp]
    var fetchedAt: Date? = nil
    var etag: String? = nil
    var id: String { identifier }
}

struct SourceApp: Identifiable, Equatable, Codable {
    let name: String
    let bundleIdentifier: String
    let version: String
    let downloadURL: String
    let iconURL: String
    let localizedDescription: String
    var sha256: String? = nil
    var downloadSize: Int64? = nil
    var projectURL: String? = nil
    var assetName: String? = nil
    var iconSymbol: String? = nil
    var id: String { bundleIdentifier }
}

/// Public repository input is data, never shell text or instructions.
/// Parsing is shared by the app and the standalone regression suite.
enum RepositoryCatalog {
    struct Seed {
        let repository: String
        let name: String
        let package: String
        let summary: String
        let symbol: String
        var url: String { "https://api.github.com/repos/\(repository)/releases/latest" }
        var projectURL: String { "https://github.com/\(repository)" }
    }
    static let seeds: [Seed] = [
        .init(repository: "TeamNewPipe/NewPipe", name: "NewPipe", package: "org.schabi.newpipe", summary: "A lightweight video and audio client.", symbol: "play.rectangle.fill"),
        .init(repository: "beemdevelopment/Aegis", name: "Aegis", package: "com.beemdevelopment.aegis", summary: "An open-source authenticator for your accounts.", symbol: "lock.shield.fill"),
        .init(repository: "tasks/tasks", name: "Tasks.org", package: "org.tasks", summary: "To-do lists, reminders, and recurring tasks.", symbol: "checklist"),
        .init(repository: "gsantner/markor", name: "Markor", package: "net.gsantner.markor", summary: "Plain text, Markdown, and to-do editing.", symbol: "doc.text.fill"),
        .init(repository: "zhanghai/MaterialFiles", name: "Material Files", package: "me.zhanghai.android.files", summary: "Browse and manage Android files.", symbol: "folder.fill"),
        .init(repository: "localsend/localsend", name: "LocalSend", package: "org.localsend.localsend_app", summary: "Share files with nearby devices on your network.", symbol: "arrow.up.arrow.down.circle.fill"),
        .init(repository: "ankidroid/Anki-Android", name: "AnkiDroid", package: "com.ichi2.anki", summary: "Flashcards and spaced-repetition study.", symbol: "rectangle.stack.fill"),
        .init(repository: "FossifyOrg/Gallery", name: "Fossify Gallery", package: "org.fossify.gallery", summary: "An offline gallery for photos and videos.", symbol: "photo.on.rectangle.angled"),
        .init(repository: "FossifyOrg/File-Manager", name: "Fossify File Manager", package: "org.fossify.filemanager", summary: "A simple file manager for Android storage.", symbol: "externaldrive.fill"),
        .init(repository: "FossifyOrg/Calendar", name: "Fossify Calendar", package: "org.fossify.calendar", summary: "Calendar, events, and reminders.", symbol: "calendar")
    ]

    enum Failure: LocalizedError {
        case message(String)
        var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
    }

    static func httpsURL(_ value: String) -> URL? {
        guard let url = URL(string: value), url.scheme?.lowercased() == "https",
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil,
              url.fragment == nil else { return nil }
        return url
    }

    static func canonicalURL(_ raw: String) throws -> String {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = httpsURL(text) else { throw Failure.message("Enter an HTTPS GitHub repository or JSON index URL.") }
        let parts = url.path.split(separator: "/").map(String.init)
        if url.host?.lowercased() == "github.com" {
            guard url.query == nil, parts.count >= 2,
                  parts.count == 2 || Array(parts.dropFirst(2)) == ["releases"] || Array(parts.dropFirst(2)) == ["releases", "latest"] else {
                throw Failure.message("Use a GitHub repository URL, such as https://github.com/owner/project.")
            }
            let repo = parts[1].hasSuffix(".git") ? String(parts[1].dropLast(4)) : parts[1]
            guard safeGitHubPart(parts[0]), safeGitHubPart(repo) else { throw Failure.message("That GitHub repository URL is invalid.") }
            return "https://api.github.com/repos/\(parts[0])/\(repo)/releases/latest"
        }
        if url.host?.lowercased() == "api.github.com" {
            guard url.query == nil, parts.count == 5, parts[0] == "repos", parts[3] == "releases", parts[4] == "latest",
                  safeGitHubPart(parts[1]), safeGitHubPart(parts[2]) else {
                throw Failure.message("Use a GitHub latest-release endpoint or the repository's web URL.")
            }
            return "https://api.github.com/repos/\(parts[1])/\(parts[2])/releases/latest"
        }
        return url.absoluteString
    }

    private static func safeGitHubPart(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 100 && value != "." && value != ".."
            && value.range(of: #"^[A-Za-z0-9_.-]+$"#, options: .regularExpression) != nil
    }

    static func seed(for url: String) -> Seed? { seeds.first { $0.url.lowercased() == url.lowercased() } }
    static func name(for url: String) -> String {
        if let seed = seed(for: url) { return seed.name }
        if let parsed = URL(string: url), parsed.host == "api.github.com" {
            let parts = parsed.path.split(separator: "/")
            if parts.count >= 3 { return String(parts[1]) + "/" + parts[2] }
        }
        return URL(string: url)?.host ?? url
    }
    static func projectURL(for url: String) -> URL? {
        guard let parsed = httpsURL(url) else { return nil }
        if parsed.host == "api.github.com" {
            let parts = parsed.path.split(separator: "/")
            guard parts.count >= 3 else { return nil }
            return URL(string: "https://github.com/\(parts[1])/\(parts[2])")
        }
        return parsed
    }

    static func validHash(_ value: String?) throws -> String? {
        guard let value else { return nil }
        let hash = value.lowercased().hasPrefix("sha256:") ? String(value.dropFirst(7)) : value
        guard hash.count == 64, hash.allSatisfy({ $0.isASCII && $0.isHexDigit }) else {
            throw Failure.message("The repository supplied an invalid SHA-256 checksum.")
        }
        return hash.lowercased()
    }

    static func parse(_ data: Data, sourceURL: String) throws -> AppSource {
        let canonical = try canonicalURL(sourceURL)
        let decoder = JSONDecoder()
        let source: AppSource
        if URL(string: canonical)?.host == "api.github.com" {
            let release = try decoder.decode(GitHubRelease.self, from: data)
            guard !release.draft, !release.prerelease else { throw Failure.message("This repository has no stable release.") }
            let choices = release.assets.compactMap { asset -> (GitHubAsset, Int)? in
                guard asset.state == nil || asset.state == "uploaded", let score = apkScore(asset.name),
                      httpsURL(asset.browser_download_url) != nil, asset.size > 0 else { return nil }
                return (asset, score)
            }.sorted { a, b in a.1 == b.1 ? a.0.name < b.0.name : a.1 > b.1 }
            guard let asset = choices.first?.0 else { throw Failure.message("The latest release has no standalone ARM64 or universal APK.") }
            let preset = seed(for: canonical)
            let repoName = name(for: canonical)
            let package = preset?.package ?? "github." + repoName.replacingOccurrences(of: "/", with: ".")
            let app = SourceApp(name: preset?.name ?? repoName, bundleIdentifier: package,
                version: String(release.tag_name.prefix(100)), downloadURL: asset.browser_download_url, iconURL: "",
                localizedDescription: preset?.summary ?? String((release.body ?? "APK published by \(repoName).").prefix(4000)),
                sha256: try validHash(asset.digest), downloadSize: asset.size,
                projectURL: httpsURL(release.html_url)?.absoluteString ?? projectURL(for: canonical)?.absoluteString,
                assetName: asset.name, iconSymbol: preset?.symbol)
            source = AppSource(name: preset?.name ?? repoName, identifier: canonical, apps: [app])
        } else if let fdroid = try? decoder.decode(FDroidIndex.self, from: data) {
            guard let base = httpsURL(fdroid.repo.address) else { throw Failure.message("The repository APK address must use HTTPS.") }
            guard fdroid.apps.count <= 20_000 else { throw Failure.message("This repository contains too many apps.") }
            var apps: [SourceApp] = []
            for app in fdroid.apps {
                let packages = (fdroid.packages[app.packageName] ?? []).filter {
                    ($0.minSdkVersion ?? 1) <= 36 && ($0.nativecode == nil || $0.nativecode!.isEmpty || $0.nativecode!.contains("arm64-v8a"))
                }.sorted { ($0.versionCode ?? 0) > ($1.versionCode ?? 0) }
                guard let package = packages.first, safeFileName(package.apkName) else { continue }
                let loc = app.localized?["en-US"] ?? app.localized?.sorted(by: { $0.key < $1.key }).first?.value
                let icon = app.icon ?? loc?.icon
                let iconURL = icon.flatMap { safeRelativePath($0) ? base.appendingPathComponent("icons").appendingPathComponent($0).absoluteString : nil } ?? ""
                apps.append(SourceApp(name: String((app.name ?? loc?.name ?? app.packageName).prefix(120)),
                    bundleIdentifier: app.packageName, version: package.versionName,
                    downloadURL: base.appendingPathComponent(package.apkName).absoluteString, iconURL: iconURL,
                    localizedDescription: String((app.summary ?? loc?.summary ?? app.description ?? loc?.description ?? "").prefix(4000)),
                    sha256: package.hashType == "sha256" ? try validHash(package.hash) : nil,
                    downloadSize: package.size, projectURL: base.absoluteString, assetName: package.apkName))
            }
            source = AppSource(name: String(fdroid.repo.name.prefix(120)), identifier: canonical, apps: apps)
        } else {
            let simple = try decoder.decode(SimpleIndex.self, from: data)
            guard simple.apps.count <= 20_000 else { throw Failure.message("This repository contains too many apps.") }
            let apps = try simple.apps.map { app -> SourceApp in
                guard let download = httpsURL(app.downloadURL), download.path.lowercased().hasSuffix(".apk"),
                      !app.bundleIdentifier.isEmpty, app.bundleIdentifier.count <= 240 else {
                    throw Failure.message("A repository entry has an invalid APK URL or identifier.")
                }
                return SourceApp(name: String(app.name.prefix(120)), bundleIdentifier: app.bundleIdentifier,
                    version: String(app.version.prefix(100)), downloadURL: download.absoluteString,
                    iconURL: app.iconURL.flatMap { httpsURL($0)?.absoluteString } ?? "",
                    localizedDescription: String((app.localizedDescription ?? "").prefix(4000)),
                    sha256: try validHash(app.sha256), downloadSize: app.size,
                    projectURL: projectURL(for: canonical)?.absoluteString, assetName: download.lastPathComponent)
            }
            source = AppSource(name: String(simple.name.prefix(120)), identifier: canonical, apps: apps)
        }
        guard Set(source.apps.map(\.id)).count == source.apps.count else {
            throw Failure.message("This repository contains duplicate app identifiers.")
        }
        return source
    }

    static func apkScore(_ name: String) -> Int? {
        let value = name.lowercased()
        guard value.hasSuffix(".apk"), !["x86", "x64", "arm32", "armeabi", "armv7", "parallel", "nominify", "debug"].contains(where: value.contains),
              !value.hasPrefix("dev-") else { return nil }
        if value.contains("arm64") || value.contains("aarch64") { return 100 }
        if value.contains("universal") { return 90 }
        if value.contains("fdroid") || value.contains("f-droid") { return 80 }
        if value.contains("foss") { return 70 }
        if value.contains("google") || value.contains("amazon") { return -10 }
        return 10
    }
    private static func safeFileName(_ value: String) -> Bool {
        !value.isEmpty && value.lowercased().hasSuffix(".apk") && !value.contains("/") && !value.contains("\\") && value != ".."
    }
    private static func safeRelativePath(_ value: String) -> Bool {
        !value.hasPrefix("/") && !value.contains("\\") && !value.split(separator: "/").contains("..")
    }

    private struct GitHubRelease: Decodable {
        let tag_name: String; let html_url: String; let body: String?; let draft: Bool; let prerelease: Bool; let assets: [GitHubAsset]
    }
    private struct GitHubAsset: Decodable {
        let name: String; let browser_download_url: String; let size: Int64; let digest: String?; let state: String?
    }
    private struct FDroidIndex: Decodable { let repo: FDroidRepo; let apps: [FDroidApp]; let packages: [String: [FDroidPackage]] }
    private struct FDroidRepo: Decodable { let name: String; let address: String }
    private struct FDroidApp: Decodable {
        let packageName: String; let name: String?; let summary: String?; let description: String?; let icon: String?; let localized: [String: FDroidLocalized]?
    }
    private struct FDroidLocalized: Decodable { let name: String?; let summary: String?; let description: String?; let icon: String? }
    private struct FDroidPackage: Decodable {
        let apkName: String; let versionName: String; let versionCode: Int64?; let nativecode: [String]?; let minSdkVersion: Int?; let hash: String?; let hashType: String?; let size: Int64?
    }
    private struct SimpleIndex: Decodable { let name: String; let apps: [SimpleApp] }
    private struct SimpleApp: Decodable {
        let name: String; let bundleIdentifier: String; let version: String; let downloadURL: String; let iconURL: String?; let localizedDescription: String?; let sha256: String?; let size: Int64?
    }
}
