import Foundation

// This binary compiles the actual JITBootstrap property bodies. Only native/UI
// dependencies are inert spies, so a display predicate reaching a JIT action
// fails the test without executing any trap or executable memory mapping.
enum BootstrapFixture {
    final class Defaults {
        func bool(forKey key: String) -> Bool { false }
        func string(forKey key: String) -> String? { nil }
        func set(_ value: Any?, forKey key: String) { preconditionFailure("No display read may write preferences") }
    }
    static let defaults = Defaults()
    static var debugged = false
    static var live = false
    static var trapInstalls = 0
    static var prewarmCalls = 0
    static var mapCalls = 0
    static var detachCalls = 0
    static var actionCount: Int { trapInstalls + prewarmCalls + mapCalls + detachCalls }
}

@_cdecl("fixture_csops")
func fixtureCSOps(_ pid: Int32, _ ops: Int32, _ output: UnsafeMutableRawPointer?, _ size: Int) -> Int32 {
    precondition(ops == 0 && size == MemoryLayout<UInt32>.size)
    output?.storeBytes(of: BootstrapFixture.debugged ? UInt32(0x10000000) : UInt32(0), as: UInt32.self)
    return 0
}
func husk_ios_jit_install_trap_handler() { BootstrapFixture.trapInstalls += 1 }
func husk_ios_jit_prewarm(_ bytes: Int) -> Bool { BootstrapFixture.prewarmCalls += 1; return true }
func husk_ios_jit_mapjit_works() -> Bool { BootstrapFixture.mapCalls += 1; return true }
func husk_ios_jit_detach() { BootstrapFixture.detachCalls += 1 }
func husk_ios_jit_is_available() -> Bool { BootstrapFixture.live }

enum JITMethod: String { case automatic, stikDebug }
enum HuskLog {
    static let deviceModel = "isolated-fixture"
    static func expectsTXM(model: String) -> Bool { false }
    static func log(_ category: String, _ message: String) {}
}
final class UIApplication {
    static let shared = UIApplication()
    func canOpenURL(_ url: URL) -> Bool { false }
    func open(_ url: URL) { preconditionFailure("Display predicates must not open an application") }
}

@main struct BootstrapTests {
    static func main() {
        for _ in 0..<1000 { precondition(!JITBootstrap.available) }
        precondition(BootstrapFixture.actionCount == 0, "An unprepared display read triggered JIT work")
        precondition(JITBootstrap.mapJITResult == nil)
        BootstrapFixture.debugged = true
        for _ in 0..<1000 { precondition(JITBootstrap.available) }
        precondition(BootstrapFixture.actionCount == 0, "An inherited debugger flag triggered JIT work")
        BootstrapFixture.debugged = false; JITBootstrap.prewarmed = true
        precondition(JITBootstrap.available && BootstrapFixture.actionCount == 0)
        JITBootstrap.prewarmed = false; BootstrapFixture.live = true
        precondition(JITBootstrap.available && BootstrapFixture.actionCount == 0)
        BootstrapFixture.live = false
        // Explicitly populate the cached result using the inert map spy, then
        // prove display reads only observe it and never repeat the action.
        precondition(JITBootstrap.mapJITWorks && BootstrapFixture.mapCalls == 1)
        for _ in 0..<1000 { precondition(JITBootstrap.available) }
        precondition(BootstrapFixture.actionCount == 1 && BootstrapFixture.mapCalls == 1)
        print("PASS real JITBootstrap.available observes debugger/live/cached state without JIT actions")
    }
}
