import Foundation

// No real preferences, application URLs, debugger, device pairing or helper is used.
final class MemoryDefaults {
    private var values: [String: Any] = [:]
    func object(forKey key: String) -> Any? { values[key] }
    func string(forKey key: String) -> String? { values[key] as? String }
    func bool(forKey key: String) -> Bool { values[key] as? Bool ?? false }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
}

enum Fixture {
    static var defaults = MemoryDefaults()
    static let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    static func reset() throws {
        defaults = MemoryDefaults()
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
        JITBootstrap.reset()
        HuskBuiltInJIT.reset()
    }
    static func pair() throws {
        let data = try PropertyListSerialization.data(fromPropertyList: [
            "public_key": Data(repeating: 1, count: 32),
            "private_key": Data(repeating: 2, count: 32),
            "identifier": "isolated-fixture-only"
        ], format: .binary, options: 0)
        try JITPairingFileStore.store(data, source: .imported)
    }
}

enum JITBootstrap {
    static var isHosted = false
    static var available = false
    static var debuggedFlag = false
    static var readyReads = 0
    static var ready: Bool { readyReads += 1; return available }
    static var isStikDebugInstalled = false
    static var isTrollStoreInstalled = false
    static var isJailbroken = false
    static var isInstalledWithTrollStore = false
    static var scriptBase64: String? = "fixture-script"
    static var attachSucceeds = false
    static var trollStoreSucceeds = false
    static var attachRequests = 0
    static var trollStoreRequests = 0
    static func requestAttach() -> Bool { attachRequests += 1; return attachSucceeds }
    static func requestTrollStoreAttach() -> Bool { trollStoreRequests += 1; return trollStoreSucceeds }
    static func reset() {
        isHosted = false; available = false; debuggedFlag = false; readyReads = 0
        isStikDebugInstalled = false; isTrollStoreInstalled = false; isJailbroken = false
        isInstalledWithTrollStore = false; scriptBase64 = "fixture-script"
        attachSucceeds = false; trollStoreSucceeds = false; attachRequests = 0; trollStoreRequests = 0
    }
}

enum HuskBuiltInJIT {
    enum Request {
        case prepare(pairingData: Data)
        case enable(targetPID: Int32, pairingData: Data, scriptBase64: String)
        case resetDDI
    }
    struct Response { let success: Bool; let message: String; let txmPresent: Bool }
    static var isAvailable = true
    static var unavailableReason: String?
    static var requests = 0
    static var completion: ((Result<Response, Error>) -> Void)?
    static func send(_ request: Request, started: (() -> Void)? = nil,
                     completion: @escaping (Result<Response, Error>) -> Void) {
        requests += 1; self.completion = completion; started?()
    }
    static func reset() { isAvailable = true; unavailableReason = nil; requests = 0; completion = nil }
}

enum HuskLog { static func log(_ category: String, _ message: String) {} }
final class OnDevicePairing {
    static let shared = OnDevicePairing()
    func cancel() {}
}
final class UIApplication {
    static let shared = UIApplication()
    func canOpenURL(_ url: URL) -> Bool { false }
    func open(_ url: URL) { preconditionFailure("A fixture must not open a real application") }
}
