import Foundation
// The manager's persistence is exercised independently of UIKit and the Android runtime.
enum HuskLog { static func log(_ category: String, _ message: String) {} }
@MainActor final class IncomingFiles {
    static let shared = IncomingFiles()
    private(set) var received: [URL] = []
    func receive(_ url: URL) { received.append(url) }
}
