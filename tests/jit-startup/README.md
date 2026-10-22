# Hosted JIT startup regression tests

The recovery test additionally compiles the actual `AutoStart` implementation with its Documents path redirected to a temporary directory and its delayed callbacks captured by a deterministic scheduler. It verifies that old timers cannot remove a new attempt's marker, and that a prior failed attempt is consumed once. No production callback waits 60 seconds in the fixture.

Run `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer sh tests/jit-startup/run.sh` on a Mac with Xcode.

The tests compile the real `JITStartupPolicy.swift` and a temporary snapshot of the real `JITSetup.swift`. The snapshot only removes the unavailable UIKit import, exposes the coordinator initializer, and redirects preferences and Documents to fixtures. Coordinator methods, intent transitions, automatic startup logic and timer callbacks are unchanged. A second binary compiles the actual `JITBootstrap.swift` with inert native-function spies and a renamed `csops` fixture symbol, verifying that `available` never calls JIT actions.

All preferences are in memory. Pairing bytes are synthetic and exist only in the runner's temporary directory. UIKit, debugger/bootstrap and helper dependencies are inert stubs. The suite neither executes JIT probes nor opens another app, changes VPN settings, or reads real pairing files.

Coverage includes LiveContainer/LiveProcess passive launch and foreground gating, explicit app/JIT/autostart requests, process-only intent, external handoff cancellation, an already debugged manual Enable, a busy attachment returning to foreground, built-in failures/success, and standalone automatic setup. Timer success paths run the real coordinator timer; long external timeout behavior and physical iOS debugger behavior are outside this Mac harness.
