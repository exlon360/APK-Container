import Foundation

enum RecoveryFixture {
    static let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    static var callbacks: [() -> Void] = []
    static func enqueue(deadline: DispatchTime, execute: @escaping () -> Void) {
        callbacks.append(execute)
    }
    static var markerExists: Bool {
        FileManager.default.fileExists(atPath: directory.appendingPathComponent("husk-autostart-pending").path)
    }
}

@main enum AutoStartTests {
    static func main() throws {
        try FileManager.default.createDirectory(at: RecoveryFixture.directory, withIntermediateDirectories: true)
        AutoStart.begin()
        precondition(RecoveryFixture.markerExists)
        AutoStart.end() // First attempt returns without JIT.
        precondition(!RecoveryFixture.markerExists)
        AutoStart.begin() // Later attachment starts a new attempt.
        RecoveryFixture.callbacks[0]()
        precondition(RecoveryFixture.markerExists, "An expired no-JIT attempt cleared the current recovery marker")
        RecoveryFixture.callbacks[1]()
        precondition(!RecoveryFixture.markerExists, "The current successful attempt did not clear its own marker")

        AutoStart.begin()
        AutoStart.begin()
        RecoveryFixture.callbacks[2]()
        precondition(RecoveryFixture.markerExists, "A superseded attempt cleared the newer marker")
        precondition(AutoStart.lastOneDied(), "An unfinished start must be recoverable")
        precondition(!AutoStart.lastOneDied(), "The previous failure must be consumed exactly once")
        AutoStart.begin()
        RecoveryFixture.callbacks[3]()
        precondition(RecoveryFixture.markerExists, "A timer from before recovery cleared the new marker")
        RecoveryFixture.callbacks[4]()
        precondition(!RecoveryFixture.markerExists)
        print("PASS actual AutoStart recovery marker lifetime, stale timers and one-time failure consumption")
    }
}
