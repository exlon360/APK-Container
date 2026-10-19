// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import os

/// Runs QEMU inside this process on a dedicated thread.
///
/// iOS does not let an app spawn processes, so QEMU cannot be a child the way it
/// is on macOS. Instead `libqemu-aarch64-softmmu.dylib` is built with
/// `-Dshared_lib=true`, exposing `qemu_init` / `qemu_main_loop` / `qemu_cleanup`,
/// and we drive them from a pthread. QEMU never returns from `qemu_main_loop`
/// until the guest shuts down, so this thread belongs to QEMU for the session.
final class QemuRunner: ObservableObject {
    static let shared = QemuRunner()
    private var thread: Thread?
    private(set) var isRunning = false

    /// Last line the guest printed about its own setup. The first-boot service in
    /// the guest writes HUSK-SETUP markers to the serial console, which is already
    /// being tailed -- so Android's one-time download reports progress to the UI
    /// without needing any channel of its own.
    @Published var setupMessage: String?

    /// How much QEMU tells us. `in_asm`/`exec` produce gigabytes in seconds, so
    /// they are never on by default — but they are here because when a guest dies
    /// three instructions into its first translated block, nothing else will do.
    enum Verbosity: String, CaseIterable {
        case normal    = "guest_errors,unimp"
        case detailed  = "guest_errors,unimp,cpu_reset,page,mmu"
        case firehose  = "guest_errors,unimp,cpu_reset,page,mmu,int,exec,in_asm"
    }

    var verbosity: Verbosity = .detailed

    /// Which guest to boot.
    ///
    /// Phase 0's Alpine guest is kept because it is the fastest way to tell a
    /// broken substrate from a broken Android setup: it boots in seconds from the
    /// app bundle with no download, no UEFI and no disk, so if it draws and Phase 1
    /// does not, the problem is above the JIT/display layer.
    enum Profile: String, CaseIterable {
        case phase0Alpine   = "Alpine (substrate check)"
        case phase1Android = "Android (LineageOS guest)"
    }

    var profile: Profile = .phase1Android

    /// True once the GL display is live. The UI needs this: HuskGLView must
    /// exist before QEMU starts, because it is what publishes the layer, but if
    /// GL then fails to initialise nothing ever draws into that layer. Without
    /// this flag the fallback to the software display is invisible -- the log
    /// says it fell back and the screen stays black.
    /// Which display is drawing -- with a state for "not yet decided".
    ///
    /// This was a Bool, and false therefore meant both "GL failed" and "GL has
    /// not been tried yet". The UI reads it to decide whether to put the
    /// software display on screen, so during startup it put an opaque software
    /// view directly over the GL layer. On a cold boot that lasted a second and
    /// nobody noticed; on a restore the snapshot takes eleven seconds to load
    /// before the listener can bind, and the placement dump caught it red
    /// handed: "HuskGLView COVERED by HuskDisplay".
    enum DisplayKind { case undecided, gl, software }
    @Published var displayKind: DisplayKind = .undecided
    var glDisplayActive: Bool { displayKind == .gl }

    /// True when this session started from a saved machine rather than booting.
    @Published var restoredFromSnapshot = false

    /// True while the machine is being written to disk.
    @Published var isSavingState = false
    /// Completion for an explicit save. A static because the C callback is a
    /// bare function pointer and cannot carry context.
    nonisolated(unsafe) static var saveCompletion: ((Bool) -> Void)?
    /// Set once a save has been requested, so it is only ever done once.
    nonisolated(unsafe) static var snapshotRequested = false
    /// When the guest was started, for the progress readout.
    nonisolated(unsafe) static var bootStarted = Date()

    /// Recognisable points in an Android boot, in the order they occur.
    ///
    /// Matched against serial console lines. These are milestones a person can
    /// read, not every service -- the point is to show movement, not detail.
    /// The third field is how far through a boot that milestone is.
    ///
    /// Measured from real cold boots rather than spaced evenly: the kernel and
    /// init are over in seconds, and the long tail is app compilation after
    /// bootanim exits. Evenly spaced numbers would race to 90% and then sit
    /// there, which is the specific thing progress bars are distrusted for.
    nonisolated(unsafe) static let bootMilestones: [(String, String, Int)] = [
        ("Linux version",                 "Starting the Linux kernel",           5),
        ("init: init first stage started","Android init, first stage",           10),
        ("init: init second stage started","Android init, second stage",         15),
        ("SELinux: policy loaded",        "Loading the security policy",         20),
        ("apexd: activating",             "Activating system packages",          28),
        ("servicemanager: Waiting",       "Starting system services",            35),
        ("starting service 'vold'",       "Preparing storage",                   42),
        ("starting service 'surfaceflinger'", "Starting the display server",     50),
        ("starting service 'zygote'",     "Starting the Android runtime",        58),
        // The LineageOS image sets ro.boot.nobootanim=1, so the bootanim milestones
        // below never fire. Without these, the bar sat at 58% for the whole second half
        // of a cold boot, which looked like a hang. Both appear on console once system_server is up.
        ("sid=u:r:system_server:s0",      "Starting Android system services",    66),
        ("ctl.stop for 'idmap2d'",        "Loading system overlays",             72),
        ("starting service 'bootanim'",   "Boot animation running",              65),
        ("Service 'bootanim' (pid",       "Compiling apps (this is the slow part)", 80),
        ("sys.boot_completed=1",          "Android is up",                       100),
    ]

    /// How far through the boot the guest is, 0 to 100.
    ///
    /// Only ever moves forward. Android restarts parts of itself during a boot
    /// -- system_server more than once on a slow device -- so the same milestone
    /// can arrive twice, and a bar that jumped backwards would read as a failure
    /// when it is normal.
    @Published var bootProgress: Int = 0

    /// What the guest is actually producing, and since when.
    ///
    /// Both were already being measured for the log -- the frame counter every
    /// five seconds, the start time implicitly. Publishing them is what lets the
    /// library say "48 fps, up 12 minutes" instead of "running", which is the
    /// difference between a status light and something worth looking at.
    @Published var fps: Double = 0
    @Published var startedAt: Date?

    /// When Android announced `sys.boot_completed=1` on the serial console.
    ///
    /// Android says this itself, on a line init prints; it does not have to be
    /// inferred, and inferring it was the bug. Nil until the guest says so.
    /// True when this session restored rather than booted.
    ///
    /// Checked before advancing the progress bar: restoring does not replay a
    /// boot, but it does restart surfaceflinger and zygote, and those match
    /// milestones worth 50% and 58%. A bar that appears on a fifteen-second
    /// restore and stops at 58% is worse than no bar.
    nonisolated(unsafe) static var didRestore = false

    nonisolated(unsafe) static var bootCompletedAt: Date?
    nonisolated(unsafe) static var pendingSnapshotMiB = 0
    /// Current balloon target, once the guest has been shrunk. Nil while it
    /// still has everything it was given.
    nonisolated(unsafe) static var balloonTargetMiB: Int?
    /// Guest size actually handed to QEMU, recorded alongside any snapshot.
    nonisolated(unsafe) var lastGuestMiB = 0
    /// Resolution actually handed to virtio-gpu.
    ///
    /// The touch mapping needs this and had been carrying its own copy, which
    /// said 360x640 while QEMU was being told 360x800. Every touch was then
    /// mapped into a box a fifth too short: squashed vertically, with the
    /// bottom of the guest screen unreachable. One number, in one place, taken
    /// from what was actually asked for.
    nonisolated(unsafe) static var lastGuestRes = (w: 360, h: 800)
    /// The resolution the machine was actually created with, so a resize that
    /// changes nothing can be skipped.
    nonisolated(unsafe) static var bootGuestRes = (w: 360, h: 800)
    /// Whether the machine has a sound device.
    ///
    /// Off by default, and deliberately: adding a device changes the machine
    /// definition, and QEMU refuses to restore a snapshot into hardware that
    /// does not match. Turning this on costs one cold boot, and turning it off
    /// costs another -- which is why the saved machine is stamped with it
    /// rather than left to fail the restore.
    nonisolated static var soundEnabled: Bool {
        UserDefaults.standard.bool(forKey: "husk.sound")
    }

    /// Whether to attach the sound DEVICE, separately from the backend.
    ///
    /// Split in two to bisect an abort. QEMU dies inside qemu_init() with the
    /// audio arguments present and prints nothing at all -- no assertion, no
    /// error_report -- so the only way left to find out which half is at fault
    /// is to run them apart. Off by default: a backend with no device is silent
    /// but harmless, and it is the half that exonerates or convicts our own code.
    nonisolated static var soundDeviceEnabled: Bool {
        UserDefaults.standard.object(forKey: "husk.soundDevice") as? Bool ?? true
    }

    /// Captured from the argv used for this session. Changing preferences must
    /// never relabel an already running machine or enable GPU snapshots.
    nonisolated(unsafe) private static var runningSnapshotPolicy: RuntimeSnapshotPolicy?
    nonisolated(unsafe) private static var runningMemoryStrategy = ""
    nonisolated static var machineStamp: String {
        runningSnapshotPolicy?.stamp ?? "not-started"
    }

    nonisolated var snapshotSavingSupported: Bool {
        QemuRunner.qemuReady && QemuRunner.runningSnapshotPolicy?.savingSupported == true
    }

    nonisolated var automaticSnapshotSavingAllowed: Bool {
        snapshotSavingSupported && QemuRunner.autoSaveEnabled
    }

    /// Software snapshots may be automatic. GPU saves are disabled regardless
    /// of this preference because quiescing the compositor crashes system_server.
    nonisolated static var autoSaveEnabled: Bool {
        UserDefaults.standard.object(forKey: "husk.autoSave") as? Bool ?? true
    }

    nonisolated(unsafe) static var qemuReady = false
    /// A display size asked for before QEMU was up, applied once it is.
    nonisolated(unsafe) static var pendingUISize: (w: Int, h: Int)?

    private var documentsDir: String {
        NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true)[0]
    }
    var guestSerialLogPath: String { "\(documentsDir)/guest-serial.log" }

    /// Phase 0 guest: Alpine 3.24.1 aarch64, booted directly from kernel+initramfs.
    ///
    /// This exact command line was validated on the host under TCG before ever
    /// being run on device: the kernel reaches userspace, virtio-gpu registers
    /// fb0, and the virtio tablet and keyboard both enumerate.
    private func phase0Arguments() -> [String] {
        let bundle = Bundle.main.bundlePath

        return [
            "qemu-system-aarch64",
            "-M", "virt",
            "-cpu", "cortex-a72",
            "-smp", "4",
            "-m", "1024",

            // tb-size is the whole JIT budget for the session. StikDebug detaches
            // after startup and a second allocation is impossible, so this has to
            // be right up front. It also costs attach time: StikDebug touches every
            // 16 KiB page through the debugger, so 256 MiB is 16384 round trips.
            // split-wx=on is NOT optional here. It defaults to 0 (see
            // tcg_accel_instance_init), and with it off TCG never calls the
            // splitwx allocator at all -- it goes straight to an RWX mmap, which
            // iOS refuses with EPERM and which no amount of JIT setup can fix.
            // Forcing it on (rather than "auto") also disables the RWX fallback,
            // so a genuine failure surfaces as itself instead of as a confusing
            // "Operation not permitted".
            "-accel", "tcg,tb-size=256,thread=multi,split-wx=on",

            "-kernel", "\(bundle)/vmlinuz-virt",
            "-initrd", "\(bundle)/initramfs-virt",
            "-append", "console=tty0 console=ttyAMA0 loglevel=8",

            // -M virt adds a default virtio-net-pci unless told otherwise, and that
            // device wants its PXE option ROM at startup -- which is why the first
            // device run died on 'failed to find romfile "efi-virtio.rom"'. Phase 0
            // needs no network at all, so the device simply should not exist. The
            // ROMs are bundled anyway, because Android will need networking and the
            // next occurrence of this would be just as opaque.
            "-nic", "none",
            "-L", "\(bundle)/pc-bios",

            "-device", "virtio-gpu-pci",
            "-device", "virtio-tablet-pci",
            "-device", "virtio-keyboard-pci",

            // The guest's own kernel console. By far the most informative single
            // signal available: if the guest is executing translated code at all,
            // it says so here. A file chardev rather than stdio, because stdio
            // would have QEMU reach for a stdin that does not exist on iOS and
            // fail during init -- a bad way to lose a first device run. A tailer
            // folds this back into the unified log a moment later.
            "-chardev", "file,id=ser0,path=\(guestSerialLogPath)",
            "-serial", "chardev:ser0",

            // Our own DisplayChangeListener is the display; QEMU needs no backend.
            "-display", "none",
            "-monitor", "none",
            "-no-reboot",

            // No -D: let QEMU's own diagnostics go to stderr, which HuskLog has
            // already redirected. One file, one chronology, so "JIT region
            // allocated" and "first translated block" appear in the order they
            // actually happened.
            "-d", verbosity.rawValue,
        ]
    }

    /// How much RAM to give the guest, in MiB.
    ///
    /// Sized from what iOS says this process may still allocate rather than from a
    /// fixed number. A jetsam kill is a SIGKILL: no signal handler runs, the log
    /// just stops mid-line, and it looks exactly like a crash. Guessing 4096 here
    /// is what produced one.
    ///
    /// The budget has to cover the JIT region and QEMU's own allocations as well as
    /// guest RAM, and leave genuine headroom -- Android dirties most of what it is
    /// given, and dirty pages count against the footprint.
    /// Where the guest RAM size used when the snapshot was taken is recorded.
    /// A restored machine must be given exactly the memory it was saved with,
    /// and the budget is computed from a figure that can drift between runs.
    nonisolated var snapshotSizePath: String {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("husk-snapshot.mib").path
    }

    /// Whether to give the guest a real GPU.
    ///
    /// Opt-in, because turning it on invalidates any snapshot saved without one
    /// and therefore costs a single cold boot before it pays for itself.
    nonisolated static var gpuModeEnabled: Bool {
        // Absent means GPU: bool(forKey:) answers false for a key nobody
        // has set, which quietly made the slow renderer the default.
        UserDefaults.standard.object(forKey: "husk.gpuMode") as? Bool ?? true
    }

    /// Which display device the saved machine was built around.
    ///
    /// A snapshot is only valid against the device it was taken with, exactly
    /// as it is only valid against its RAM size, so this is recorded next to it
    /// and checked before any restore is attempted.
    nonisolated var snapshotDisplayPath: String {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("husk-snapshot.display").path
    }
    nonisolated var snapshotDisplay: String? {
        (try? String(contentsOfFile: snapshotDisplayPath, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated var hasSnapshot: Bool {
        FileManager.default.fileExists(atPath: snapshotSizePath)
    }

    /// Forget the saved machine, so the next launch boots Android from cold.
    ///
    /// Only the stamps are removed. The snapshot itself lives inside the qcow2
    /// and is overwritten by the next save; deleting it here would mean rewriting
    /// a multi-gigabyte image to reclaim space the next save reclaims anyway.
    /// What decides whether a restore is attempted is these files, so clearing
    /// them is exactly "forget it".
    ///
    /// `mode` is "gl" or "sw". A machine is only forgotten if it was saved in the
    /// mode asked for -- there is one saved machine, not two, and deleting the
    /// software one should not silently throw away a GPU one.
    @discardableResult
    nonisolated func forgetSnapshot(mode: String) -> Bool {
        guard hasSnapshot else { return false }
        let have = snapshotDisplay ?? "sw"
        guard RuntimeSnapshotPolicy.displayMode(of: have) == mode else { return false }
        for path in [snapshotSizePath, snapshotDisplayPath, memoryStrategyPath] {
            try? FileManager.default.removeItem(atPath: path)
        }
        HuskLog.log("snap", "forgot the \(mode) machine; the next launch boots from cold")
        return true
    }

    /// Whether a saved machine exists that this session could actually restore.
    ///
    /// Existence alone is the wrong question, and asking it is why turning GPU
    /// mode on never produced a GPU snapshot however many times it cold-booted:
    /// a software snapshot from an earlier run left its stamp on disk, the
    /// auto-save saw "a snapshot exists" and skipped, and the one machine worth
    /// saving -- the one running on the GPU -- was never written. A snapshot
    /// taken in the other display mode is not a snapshot this session can use.
    nonisolated var hasUsableSnapshot: Bool {
        guard hasSnapshot else { return false }
        return snapshotSavingSupported && snapshotDisplay == QemuRunner.machineStamp
    }

    /// Save software-rendered RAM and device state. Guest disk writes persist
    /// without this operation. Restoring a snapshot rewinds that disk to its
    /// saved state, so later changes are discarded on restore.
    /// GPU snapshots are unsupported: stopping their compositor can crash Android.
    func saveState(reason: String, automatic: Bool = false, completion: ((Bool) -> Void)? = nil) {
        guard isRunning, snapshotSavingSupported,
              QemuRunner.runningSnapshotPolicy?.allowsSave(
                automatic: automatic, automaticEnabled: QemuRunner.autoSaveEnabled) == true else {
            HuskLog.log("snap", "not saving (\(reason)): snapshots require a ready software runtime; "
                              + "GPU disk data persists without a RAM snapshot")
            completion?(false)
            return
        }
        guard !isSavingState else {
            HuskLog.log("snap", "save already in progress; ignoring \(reason)")
            completion?(false); return
        }
        isSavingState = true
        QemuRunner.pendingSnapshotMiB = lastGuestMiB
        QemuRunner.saveCompletion = completion
        HuskLog.log("snap", "saving the machine (\(reason), guest "
                          + "\(QemuRunner.pendingSnapshotMiB) MiB); the picture freezes "
                          + "while RAM is written to disk")

        DispatchQueue.global(qos: .userInitiated).async {
            self.performSave()
        }
    }

    private func performSave() {
        // Defense at the last Swift boundary before QEMU. Never stop Android
        // services to make GPU resources appear migratable.
        guard snapshotSavingSupported else {
            let done = QemuRunner.saveCompletion
            QemuRunner.saveCompletion = nil
            DispatchQueue.main.async {
                QemuRunner.shared.isSavingState = false
                done?(false)
            }
            return
        }

        husk_snapshot_save { ok, what in
            let label = what.map { String(cString: $0) } ?? "save"
            HuskLog.log("snap", "\(label) \(ok ? "succeeded" : "FAILED")")
            if ok {
                try? String(QemuRunner.pendingSnapshotMiB)
                    .write(toFile: QemuRunner.shared.snapshotSizePath,
                           atomically: true, encoding: .utf8)
                try? QemuRunner.runningMemoryStrategy
                    .write(toFile: QemuRunner.shared.memoryStrategyPath,
                           atomically: true, encoding: .utf8)
                // Stamp the display this machine belongs to, so a later launch
                // in the other mode cold-boots instead of restoring into a
                // device the guest does not expect.
                try? QemuRunner.machineStamp
                    .write(toFile: QemuRunner.shared.snapshotDisplayPath,
                           atomically: true, encoding: .utf8)
            }
            let done = QemuRunner.saveCompletion
            QemuRunner.saveCompletion = nil
            Task { @MainActor in
                QemuRunner.shared.isSavingState = false
                done?(ok)
            }
        }
    }

    /// Backing file for guest RAM.
    ///
    /// Guest RAM allocated the ordinary way is dirty anonymous memory, which is
    /// precisely what jetsam counts and what caps the guest at roughly 1.9 GiB
    /// on an 11.7 GiB phone. Backing it with a MAP_SHARED file instead makes
    /// those pages file-backed: the kernel can write them back and evict them,
    /// and clean external pages are not charged to phys_footprint the way
    /// anonymous ones are. That is the whole point -- it turns guest RAM into
    /// something the OS can page rather than something that must all stay
    /// resident.
    nonisolated var guestRamPath: String {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("guest-ram.bin").path
    }

    /// How RAM was provided on the run that took the snapshot.
    ///
    /// A snapshot records a machine shape, and changing the memory backend
    /// changes that shape. Restoring a file-backed machine into an anonymous
    /// one (or the reverse) is not something to find out about at load time.
    nonisolated var memoryStrategyPath: String {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("husk-memory-strategy").path
    }

    /// Bumped whenever the memory layout changes, to retire old snapshots.
    static var memoryStrategy: String {
        // The GPU device is part of the machine's shape, so a snapshot taken
        // with virtio-gpu-pci cannot be restored into a virtio-gpu-gl-pci
        // machine. Folding the display choice into the strategy means the first
        // launch after GL starts working boots cold once, then re-snapshots,
        // rather than failing to restore.
        GuestImage.shared.hasShippedSnapshot
            ? "shipped-snapshot-v10"
            : "file-backed-lineage-v2-" + (glProven ? "gl" : "sw")
                + (soundEnabled ? "+snd" : "")
                + (landscapeGuest ? "+land" : "")
                + (customResolution.map { "+\($0.w)x\($0.h)" } ?? "")
    }

    /// Whether guest RAM can be backed by a file on this device, this run.
    ///
    /// Checked rather than assumed: QEMU creates and ftruncates the backing file
    /// itself, and if that fails the machine does not start at all. Falling back
    /// to anonymous RAM costs the guest some size; failing to start costs the
    /// user the app. Evaluated once and cached, because the answer is used both
    /// to size the guest and to build the command line, and they must agree.
    private lazy var ramFileReady: Bool = {
        let needBytes = Int64(6144 + 768) * 1024 * 1024
        let dir = (guestRamPath as NSString).deletingLastPathComponent

        if let attrs = try? FileManager.default.attributesOfFileSystem(forPath: dir),
           let free = (attrs[.systemFreeSize] as? NSNumber)?.int64Value {
            let freeMiB = free / (1024 * 1024)
            guard free > needBytes else {
                HuskLog.log("qemu", "only \(freeMiB) MiB free; not backing guest RAM "
                                  + "with a file, falling back to anonymous memory")
                return false
            }
            HuskLog.log("qemu", "\(freeMiB) MiB free for the guest RAM file")
        }

        // Create it now so the no-backup flag can be set. iOS evicts nothing it
        // has been told to back up, and a multi-gigabyte scratch file has no
        // business in iCloud.
        if !FileManager.default.fileExists(atPath: guestRamPath) {
            guard FileManager.default.createFile(atPath: guestRamPath, contents: nil) else {
                HuskLog.log("qemu", "could not create \(guestRamPath); "
                                  + "falling back to anonymous memory")
                return false
            }
        }
        var url = URL(fileURLWithPath: guestRamPath)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
        return true
    }()

    /// Size we are about to attempt, and the largest size known to have survived.
    ///
    /// A PROT_NONE reservation is not proof: 6144 MiB reserved cleanly and QEMU
    /// still died initialising it. So the size is written down before the
    /// attempt and only confirmed once qemu_init() returns. If a launch finds an
    /// attempt that was never confirmed, that size killed us last time and this
    /// run picks a smaller one -- which means a bad size costs one launch rather
    /// than every launch.
    nonisolated var ramAttemptPath: String {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("husk-ram-attempt").path
    }
    nonisolated var ramProvenPath: String {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("husk-ram-proven").path
    }
    /// Smallest size ever seen to fail, remembered permanently.
    ///
    /// Comparing the last attempt against the last success was not enough. One
    /// failed launch at 6144 MiB followed by a good launch at 5120 left
    /// attempt == proven, the guard disengaged, and the next launch tried 6144
    /// again -- which failed again, in exactly the same place. A size that has
    /// once killed qemu_init has to stay excluded, not be forgotten as soon as
    /// something smaller works.
    nonisolated var ramFailedPath: String {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("husk-ram-failed").path
    }

    private func readInt(_ path: String) -> Int? {
        guard let t = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        return Int(t.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Largest of `candidates` that can actually be mapped the way QEMU maps it.
    ///
    /// Not a PROT_NONE reservation. QEMU creates the file, extends it to the
    /// full size, maps it MAP_SHARED read/write and then writes to it, so this
    /// does exactly that and touches both the first and last page. A reservation
    /// that succeeds where the real mapping fails is worse than no check at all,
    /// because it produces confidence and then a crash.
    private func largestMappableMiB(_ candidates: [Int]) -> Int? {
        for mib in candidates {
            let bytes = off_t(mib) * 1024 * 1024
            let fd = open(guestRamPath, O_RDWR | O_CREAT, 0o600)
            if fd < 0 {
                HuskLog.log("qemu", "RAM file check: cannot open (errno \(errno))")
                return nil
            }
            defer { close(fd) }

            guard ftruncate(fd, bytes) == 0 else {
                HuskLog.log("qemu", "RAM file check: \(mib) MiB cannot be allocated "
                                  + "on disk (errno \(errno)); trying smaller")
                continue
            }
            guard let p = mmap(nil, size_t(bytes), PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0),
                  p != MAP_FAILED else {
                HuskLog.log("qemu", "RAM file check: \(mib) MiB maps no better than "
                                  + "QEMU would (errno \(errno)); trying smaller")
                continue
            }

            // Touch both ends: a mapping can be handed back and still fail on
            // first write if the backing store cannot honour it.
            let bytesPtr = p.assumingMemoryBound(to: UInt8.self)
            bytesPtr[0] = 0
            bytesPtr[Int(bytes) - 1] = 0
            munmap(p, size_t(bytes))
            HuskLog.log("qemu", "RAM file check: \(mib) MiB maps and writes cleanly")
            return mib
        }
        return nil
    }

    /// Guest resolution, shaped like the screen it will be stretched onto.
    ///
    /// The blit scales the guest texture across the whole window with no regard
    /// for aspect ratio, so a 360x640 guest (0.5625) drawn onto a 1206x2622
    /// phone (0.460) comes out visibly squashed. Keeping the width at 360 --
    /// the emulated cost is per pixel, and this is already the cheapest useful
    /// size -- and deriving the height from the real screen makes the two
    /// shapes agree, so nothing has to be letterboxed or distorted.
    ///
    /// Rounded to a multiple of 8: graphics stacks are happier with aligned
    /// strides, and the error is under half a percent of the height.
    private var guestResolution: (w: Int, h: Int) {
        let r = computedGuestResolution
        QemuRunner.lastGuestRes = r
        return r
    }

    /// Whether the guest's panel is landscape-shaped.
    ///
    /// Android will not reshape a running panel -- every dpy_set_ui_info request
    /// came back with the console unchanged -- so when an app asks for landscape
    /// on a 360x800 panel, Android letterboxes it into a band across the middle.
    /// Turning that band in the shader gives an upright picture that is mostly
    /// black, which is exactly what "right orientation, just way too small"
    /// describes.
    ///
    /// The panel's shape is fixed when the machine is created, so the honest fix
    /// is to create it the other way round. That costs a cold boot, and it is
    /// part of the machine stamp so a snapshot taken in one shape never tries to
    /// restore into the other.
    nonisolated static var landscapeGuest: Bool {
        UserDefaults.standard.bool(forKey: "husk.landscapeGuest")
    }

    /// A panel size chosen by hand, when there is one.
    ///
    /// It overrides everything below -- including the size pinned by a shipped
    /// snapshot -- because someone who typed a resolution meant it. That does
    /// mean the shipped snapshot cannot be used: it was captured against its
    /// own panel, and a machine whose display differs is a different machine.
    /// Nothing special is needed to arrange that, only the stamp: a custom size
    /// changes it, the restore path already refuses a machine whose stamp does
    /// not match, and the first launch after a change boots cold and saves a
    /// new one.
    nonisolated static var customResolution: (w: Int, h: Int)? {
        let d = UserDefaults.standard
        guard d.bool(forKey: "husk.customRes") else { return nil }
        return validResolution(w: d.integer(forKey: "husk.resWidth"),
                               h: d.integer(forKey: "husk.resHeight"))
    }

    /// A size both QEMU and Android will accept, or nothing.
    ///
    /// Rounded to a multiple of eight because that is what the guest's
    /// compositor wants its stride to be, and bounded because the two ends of
    /// the range are both failures rather than preferences: below about 240 the
    /// launcher has nowhere to lay itself out, and above 2560 a software-drawn
    /// frame costs more than the emulator can deliver in a second.
    nonisolated static func validResolution(w: Int, h: Int) -> (w: Int, h: Int)? {
        guard w >= 240, w <= 2560, h >= 240, h <= 2560 else { return nil }
        return (Int((Double(w) / 8).rounded()) * 8, Int((Double(h) / 8).rounded()) * 8)
    }

    private var computedGuestResolution: (w: Int, h: Int) {
        if let custom = QemuRunner.customResolution { return custom }

        // A shipped snapshot fixes the resolution: it was saved against one,
        // and a machine whose display differs is a different machine.
        if GuestImage.shared.hasShippedSnapshot, !QemuRunner.landscapeGuest {
            // From the manifest the snapshot was published with, not a constant
            // compiled into this build -- an app older than a snapshot cannot
            // know the machine it was saved on.
            let pins = GuestImage.shared.snapshotPins
            return (pins.xres, pins.yres)
        }
        if QemuRunner.landscapeGuest {
            // The shipped snapshot's own panel, turned. Keeping the same pixel
            // count means the same memory footprint and the same load on TCG;
            // only the shape changes.
            let pins = GuestImage.shared.snapshotPins
            let short = min(pins.xres, pins.yres), long = max(pins.xres, pins.yres)
            return (long, short)
        }
        let size = HuskGLView.pixelSize
        guard size.width > 0, size.height > 0 else { return (360, 640) }
        let w = 360
        let exact = Double(w) * Double(size.height) / Double(size.width)
        let h = max(480, Int((exact / 8).rounded()) * 8)
        return (w, h)
    }

    private var machineCpu: String {
        GuestImage.shared.hasShippedSnapshot ? GuestImage.shared.snapshotPins.cpu
                                            : GuestImage.defaultCpu
    }
    private var machineSmp: Int {
        GuestImage.shared.hasShippedSnapshot ? GuestImage.shared.snapshotPins.smp
                                            : GuestImage.defaultSmp
    }

    private func guestMemoryMiB() -> Int {
        // Same reasoning as the resolution: the shipped snapshot was saved with
        // exactly this much RAM, and QEMU rejects a restore that differs by a
        // byte. No probing, no stepping down -- this number or nothing.
        if GuestImage.shared.hasShippedSnapshot {
            let mib = GuestImage.shared.snapshotPins.mib
            QemuRunner.shared.lastGuestMiB = mib
            HuskLog.log("qemu", "using the shipped snapshot: guest pinned to \(mib) MiB")
            return mib
        }

        // A snapshot pins the size. Restoring into a differently sized machine
        // does not work, and the adaptive budget below is derived from
        // os_proc_available_memory(), which moves with whatever else the phone
        // is doing.
        // A snapshot from a differently shaped machine is not restorable, and
        // the memory backend is part of that shape. Retire it rather than
        // discover the mismatch inside load_snapshot.
        let priorStrategy = try? String(contentsOfFile: memoryStrategyPath, encoding: .utf8)
        let strategyChanged = priorStrategy?.trimmingCharacters(in: .whitespacesAndNewlines)
            != QemuRunner.memoryStrategy
        if strategyChanged, FileManager.default.fileExists(atPath: snapshotSizePath) {
            HuskLog.log("qemu", "memory layout changed to \(QemuRunner.memoryStrategy); "
                              + "leaving old snapshot metadata intact and using a fresh memory budget")
        }

        if !strategyChanged,
           let recorded = try? String(contentsOfFile: snapshotSizePath, encoding: .utf8),
           let mib = Int(recorded.trimmingCharacters(in: .whitespacesAndNewlines)), mib > 0 {
            HuskLog.log("qemu", "snapshot exists; using its guest size of \(mib) MiB")
            return mib
        }

        let physMiB = Int(ProcessInfo.processInfo.physicalMemory / (1024 * 1024))
        let availableMiB = Int(husk_ios_available_memory() / (1024 * 1024))

        // os_proc_available_memory() is the real ceiling, not a floor. Budgeting
        // 40% of physical RAM instead -- a 3426 MiB guest -- got the app
        // jetsammed 85 seconds in, the footprint falling cleanly from 2082 MiB
        // of headroom to 178 MiB before the log simply stopped. Death came just
        // past 3400 MiB, against the 3376 MiB this call reported at launch.
        //
        // It is accurate because a guest's RAM is dirty anonymous memory, which
        // is exactly what it measures. QEMU's resident size is a high-water mark
        // of guest page touches: once the guest dirties a page it stays resident
        // even after the guest frees it, so the peak is what kills us and it
        // cannot be walked back. Another app reaching a larger number does not
        // transfer -- clean file-backed pages are evictable and charged
        // differently.
        let jitMiB = 256          // tb-size
        let qemuOverheadMiB = 750 // measured, not guessed
        // Real margin, in megabytes rather than a fraction. A fraction of what
        // was left quietly cost ~375 MiB the guest could have had; the run that
        // booted Android peaked with ~500 MiB spare, so this is the same shape
        // of safety without the waste.
        let safetyMarginMiB = 450

        guard availableMiB > 0 else {
            HuskLog.log("qemu", "available memory unknown; falling back to 1536 MiB guest")
            return 1536
        }

        // The JIT is only subtracted if it has not been taken yet. Prewarming
        // claims it before this runs, so os_proc_available_memory() has already
        // fallen by that much -- subtracting again charged for it twice and cut
        // the guest from 1906 MiB to 1650.
        let jitStillToCome = JITBootstrap.prewarmed ? 0 : jitMiB
        let anonymousTarget = max(1024, min(6144,
            availableMiB - safetyMarginMiB - jitStillToCome - qemuOverheadMiB))

        // With a file-backed RAM block the arithmetic above is the wrong shape:
        // it measures room for pages that must stay resident, and these do not
        // have to. Ask for more than that ceiling allows, because the excess
        // lives in the page cache rather than in our footprint.
        //
        // Deliberately not the largest number that fits. Whether iOS really
        // keeps these pages out of phys_footprint is the thing this build is
        // measuring, and the footprint line logged every five seconds is the
        // evidence: if resident stays flat while the guest grows, the next
        // build can raise this. Jumping straight to 4096 would instead risk
        // regressing a configuration that currently boots.
        // Ask for as much as this process can actually map, largest first.
        //
        // 6144 MiB was not merely optimistic, it was fatal: QEMU died inside
        // qemu_init() before printing anything, because the mapping could not
        // be made. 2560 MiB had been fine. The JIT already holds about a
        // gigabyte of address space -- 512 MiB mapped twice, RW and RX -- so a
        // 6 GiB RAM block puts the total past what the process is allowed.
        //
        // Rather than hard-code whatever happens to work on one phone, find out.
        // A PROT_NONE anonymous reservation costs no physical memory and fails
        // exactly when the real mapping would, so stepping down through these
        // sizes and keeping the first that succeeds turns a crash into a
        // slightly smaller guest.
        // 6144 is deliberately absent. It passed every check that could be
        // made for it -- the address space is there, the file maps and writes
        // -- and then killed qemu_init three times regardless. Whatever objects
        // to it is not something this code can see, so it is simply not offered.
        var candidates = [5120, 4096, 3584, 3072, 2560, 2048]

        // Fold a failed attempt into the permanent floor before using it.
        if let attempted = readInt(ramAttemptPath), readInt(ramProvenPath) != attempted {
            let worst = min(attempted, readInt(ramFailedPath) ?? Int.max)
            try? String(worst).write(toFile: ramFailedPath, atomically: true, encoding: .utf8)
            HuskLog.log("qemu", "last launch attempted \(attempted) MiB and never got "
                              + "past qemu_init; remembering that permanently")
        }
        if let failed = readInt(ramFailedPath) {
            candidates = candidates.filter { $0 < failed }
            HuskLog.log("qemu", "\(failed) MiB is known to fail on this device; "
                              + "staying below it")
        }
        let fileBackedTarget = ramFileReady ? largestMappableMiB(candidates) : nil
        let target = fileBackedTarget.map { max(anonymousTarget, $0) } ?? anonymousTarget

        QemuRunner.shared.lastGuestMiB = target
        try? String(target).write(toFile: ramAttemptPath, atomically: true, encoding: .utf8)
        HuskLog.log("qemu", "memory budget: \(physMiB) MiB physical but "
                          + "\(availableMiB) MiB before jetsam -- that is the real "
                          + "ceiling; reserving \(jitMiB) MiB JIT + \(qemuOverheadMiB) "
                          + "MiB overhead + \(safetyMarginMiB) MiB margin; "
                          + "GUEST GETS \(target) MiB "
                          + (fileBackedTarget != nil
                             ? "from a file-backed block (anonymous memory could only "
                             + "have given it \(anonymousTarget) MiB)"
                             : "as anonymous memory"))
        return target
    }

    /// Phase 1 guest: LineageOS booting directly under QEMU via UEFI.
    private func phase1Arguments() -> [String] {
        let guest = GuestImage.shared
        let memMiB = guestMemoryMiB()

        // Modelled on android-lineage-qemu's own documented qemu-system line for
        // the arm64only build, because that is the configuration the image is
        // actually tested in -- including on iOS under UTM, which like us has no
        // hypervisor and runs TCG. Deviating from it is how the last three days
        // went, so the deviations here are only the ones Husk structurally needs:
        // our own display bridge, our own serial capture, and a memory budget
        // that fits iOS's jetsam ceiling rather than their flat 2048.
        return [
            "qemu-system-aarch64",
            "-M", ramFileReady ? "virt,highmem=on,memory-backend=huskram"
                               : "virt,highmem=on",

            // Their emulation line, not cortex-a72. "max" is what the image is
            // tested against and avoids guessing which ARMv8 extensions this
            // Android build assumes; pauth-impdef picks a cheap implementation
            // -defined pointer-auth algorithm instead of QARMA, which TCG
            // emulates at ruinous cost.
            // pauth-impdef=on, and do NOT turn pauth off.
            //
            // Turning it off panicked the kernel at 9.3s inside
            // __pi_scs_handle_fde_frame <- module_finalize <- load_module, with
            // 0xd503233f and 0xd50323bf in the registers -- the encodings of
            // PACIASP and AUTIASP. That is the dynamic shadow call stack
            // patcher, which rewrites pointer-auth instructions into
            // shadow-call-stack ones and which the kernel runs ONLY when the CPU
            // lacks PAC. So "pauth degrades to no-ops" holds for userspace and
            // not for this kernel: removing the feature switches a whole code
            // path ON rather than switching one off. impdef keeps PAC present
            // while picking a cheap algorithm instead of QARMA.
            // sve=off and sme=off are performance changes, not correctness ones.
            //
            // "max" advertises FEAT_SVE (with PMULL128, BitPerm, SHA3, SM4) and
            // FEAT_SME. TCG has no host SVE to map those onto, so every SVE
            // instruction becomes a helper call -- while bionic selects its
            // SVE memcpy/memset/strlen/strcmp through ifunc the moment HWCAP_SVE
            // is set. The result is that every string and memory operation in
            // the whole of Android takes the slow path. With SVE absent bionic
            // falls back to its ASIMD routines, which TCG translates onto the
            // host's own NEON.
            //
            // MTE needs no such treatment: the virt machine provides no tag
            // memory, so QEMU already downgrades ID_AA64PFR1.MTE to 1 and no
            // tag checking happens.
            // From the snapshot when there is one, because the CPU model and
            // vCPU count are as much a part of the machine as its RAM size and
            // QEMU refuses a restore into a different shape.
            "-cpu", machineCpu,
            "-smp", "\(machineSmp)",
            "-m", "\(memMiB)",
            "-accel", "tcg,tb-size=256,thread=multi,split-wx=on",

            // The balloon was written earlier and never put on the machine, so
            // nothing could ever reclaim guest memory. With it present the guest
            // can be told to hand pages back when the host gets tight.
            "-device", "virtio-balloon-pci,id=huskballoon",

            // UEFI: our bundled code volume, and the variable store that shipped
            // with the image.
            "-drive", "if=pflash,unit=0,format=raw,readonly=on,file=\(guest.firmwarePath)",
            "-drive", "if=pflash,unit=1,format=qcow2,file=\(guest.varsPath)",

            // vda is the system disk, vdb is userdata. bootindex matters: the
            // firmware must try the system disk first.
            "-device", "virtio-blk-pci,drive=vda,bootindex=0",
            "-device", "virtio-blk-pci,drive=vdb,bootindex=1",
            // detect-zeroes made QEMU scan the contents of every guest write
            // looking for runs of zeroes to punch out. That is host CPU spent
            // to save disk space on a device with 53 GB free, and host CPU is
            // the one resource this whole system is short of.
            "-drive", "file=\(guest.diskPath),if=none,id=vda,format=qcow2,discard=unmap",
            // node-name matters: save_snapshot picks where to put the VM state
            // by node name, and with nothing named it takes the FIRST
            // snapshot-capable drive in graph order -- which is the pflash
            // variable store. That is how a 64 MiB UEFI vars image grew to
            // 2.6 GB of guest RAM blobs.
            "-drive", "file=\(guest.userdataPath),if=none,id=vdb,node-name=huskvmstate,"
                    + "format=qcow2,discard=unmap",

            // Two forwards, both on loopback so nothing outside this app can
            // reach the guest.
            //
            //   5555  adbd, when it is willing to talk. It usually is not: an
            //         unprovisioned LineageOS runs adbd in trade-in mode, where
            //         every shell is refused, and provisioning it from outside
            //         is the problem this bridge exists to solve.
            //   5599  Husk's own bridge -- a plain nc listener started by init
            //         as u:r:shell:s0, which hands whatever is written to it to
            //         /system/bin/sh. That is the same authority adb shell has,
            //         obtained without adbd's cooperation.
            "-device", "virtio-net-pci,netdev=net0",
            "-netdev", "user,id=net0,hostfwd=tcp:127.0.0.1:5555-:5555,"
                     + "hostfwd=tcp:127.0.0.1:5599-:5599",
            "-L", "\(Bundle.main.bundlePath)/pc-bios",

            // 360x640 rather than 1280x800: a quarter of the pixels.
            //
            // This is the dominant term. There is no GPU, so every pixel is
            // rasterised in software by a CPU that is itself emulated, and the
            // cost is paid twice -- ~1M pixels per frame at a ~10x emulation
            // penalty lands almost exactly on the 2 FPS observed. Cutting pixel
            // count 4.4x attacks the multiplication rather than one of its
            // factors. It is also a measurement: if the frame rate does not move
            // roughly in proportion then fill is not the bottleneck and this
            // model is wrong, which is worth knowing before tuning anything else.
            // GL only if it has been proven to work on this device, because the
            // choice is not reversible: a console created for virtio-gpu-gl
            // demands a GL listener, so when GL then fails to initialise the
            // software display cannot register and QEMU aborts with "The
            // console requires a GL context". Falling back has to mean not
            // asking for the GL device in the first place.
            "-device", QemuRunner.glProven
                ? "virtio-gpu-gl-pci,xres=\(guestResolution.w),yres=\(guestResolution.h)"
                : "virtio-gpu-pci,xres=\(guestResolution.w),yres=\(guestResolution.h)",

            // USB HID rather than virtio-input, which is what their config uses.
            // Every Android kernel has usbhid; virtio-input is not guaranteed,
            // and losing input would look exactly like a hung guest.
            "-device", "qemu-xhci,id=usb-bus",
            "-device", "usb-tablet,bus=usb-bus.0",
            "-device", "usb-kbd,bus=usb-bus.0",

            // Entropy. Without it the guest stalls waiting for crng init, which
            // on a previous guest cost several seconds of boot.
            "-device", "virtio-rng-pci",
        ] + (QemuRunner.soundEnabled ? [
            // virtio-snd rather than intel-hda: a paravirtual device with no
            // codec to emulate, so the cost is a queue rather than a chip.
            // Conditional, because adding it changes the machine definition and
            // no snapshot taken without it can be restored into it.
            "-audiodev", "husk,id=huskaudio",
        ] : []) + (QemuRunner.soundEnabled && QemuRunner.soundDeviceEnabled ? [
            "-device", "virtio-sound-pci,audiodev=huskaudio",
        ] : []) + [
            "-chardev", "file,id=ser0,path=\(guestSerialLogPath)",
            "-serial", "chardev:ser0",
            "-display", "none",
            "-monitor", "none",
            // NOT -no-reboot. Android reboots itself on purpose, and the most
            // important case is repair: when /data is inconsistent it reboots
            // into recovery, fixes it, and reboots again. With -no-reboot that
            // self-repair became a dead VM -- init announced
            // "Rebooting into recovery, reason: init_user0_failed" and QEMU
            // simply stopped. A guest that loops will show up in the log; a
            // guest that cannot reboot cannot recover.
            // -d dropped. Android generates a continuous stream of SELinux
            // denials and unimplemented-device accesses, and each one was
            // formatted by QEMU, written to a pipe, read back by HuskLog, split
            // into lines and logged. That is real work on the thread that also
            // runs the machine. It was worth it while the GPU path was being
            // debugged and costs frames now that it works.

        ] + (ramFileReady ? [
            // Guest RAM as a MAP_SHARED file rather than anonymous memory, so
            // the kernel can write it back and evict it instead of counting all
            // of it against our jetsam footprint. share=on is what makes the
            // mapping shared and therefore external; without it the file maps
            // private and every dirtied page becomes anonymous again, which is
            // the thing being avoided.
            //
            // prealloc is deliberately off. Touching the whole block up front
            // would make every page resident immediately and hand back exactly
            // the problem this is here to solve.
            "-object", "memory-backend-file,id=huskram,size=\(memMiB)M,"
                     + "mem-path=\(guestRamPath),share=on,prealloc=off",
        ] : [])
    }

    func start() {
        guard !isRunning else {
            HuskLog.log("qemu", "start() ignored -- already running")
            return
        }
        isRunning = true
        startedAt = Date()
        QemuRunner.bootStarted = Date()

        let t = Thread { [weak self] in self?.run() }
        t.name = "husk.qemu"
        // Darwin propagates QoS to threads a thread creates, and every vCPU is
        // created from this one. Left at the default they read as background
        // work -- CPU-saturated for the guest's whole life -- and get parked on
        // efficiency cores, which on a phone are several times slower than the
        // performance cores. The guest's speed is the app's speed, so this is
        // user-interactive by definition.
        t.qualityOfService = .userInteractive
        // QEMU's main loop is not shy with stack.
        t.stackSize = 16 * 1024 * 1024
        thread = t

        // 9p exports a directory that must already exist when QEMU starts.
        HuskBridgeFS.shared.prepare()
        HuskLog.log("qemu", "spawning QEMU thread (stack 16 MiB)")
        t.start()
        startSerialTailer()
    }

    /// Set once the GL stack has been shown to work on this device. Persisted,
    /// because the device choice happens before anything can be tested and a
    /// wrong guess costs the whole session.
    /// Software display unless the user asks otherwise.
    ///
    /// Not a retreat from the GL work -- that stack is finished and correct --
    /// but a reading of the evidence. Runs on the software display reached
    /// sys.boot_completed twice, at 281s and 321s. No run on the GPU has
    /// reached it at all, and the run that got closest spent longer after the
    /// boot animation than the software runs took in total. virtio-gpu-gl makes
    /// the guest drive Mesa's virgl driver and SurfaceFlinger's full render
    /// engine, and all of that is emulated code; what it buys back is
    /// rasterisation of a 360x640 screen, which was never the expensive part.
    /// Get a booted machine snapshotted first, then re-open the question.
    nonisolated(unsafe) static var glProven: Bool {
        // The display device is part of the machine's shape, exactly like its
        // RAM size -- and the shipped snapshot was saved against virtio-gpu-pci.
        //
        // Restoring it into virtio-gpu-gl-pci produces a machine whose guest
        // holds virgl resource IDs that the freshly created virgl context has
        // never heard of, and every scanout then fails:
        //
        //   virgl_cmd_set_scanout: illegal resource specified 57
        //   virtio_gpu_virgl_process_cmd: ctrl 0x103, error 0x1203
        //
        // Android is alive behind that -- services start, adbd runs -- but
        // nothing can ever be drawn. RAM and resolution were pinned for this
        // reason; the display was missed.
        // GPU mode replaces the blanket refusal that used to sit here.
        //
        // The refusal was right at the time: the shipped snapshot was saved
        // against virtio-gpu-pci, and restoring it into virtio-gpu-gl-pci hands
        // the guest virgl resource ids a fresh renderer has never created. What
        // was missing was not a reason to allow it but a way to tell the two
        // kinds of snapshot apart, which snapshotDisplay now does -- a machine
        // saved in the wrong display mode is cold-booted instead of restored.
        guard QemuRunner.gpuModeEnabled else { return false }
        return UserDefaults.standard.bool(forKey: "husk.glProven")
    }

    /// Try the GL stack without committing to it. Runs before the QEMU command
    /// line is built, so its answer can pick the virtio-gpu device.
    /// Create the GL context and surface, and on the first run decide whether
    /// GL is usable at all.
    ///
    /// The early-return that used to sit here -- `guard !glProven` -- meant the
    /// context and surface were only ever built on the run that proved GL
    /// worked. Every launch after that skipped straight past creation, and
    /// husk_display_gl_bind() was then asked to make current a context that had
    /// never been made, failed, and fell back to the software display. So GL
    /// worked exactly once, on the run that discovered it, and never again.
    ///
    /// Creation is unconditional now. Only the *probe* is skipped once the
    /// answer is known, because that is the part that is merely a question.
    private func probeGL() {
        HuskGLView.surfaceReady.lock()
        let deadline = Date().addingTimeInterval(5)
        while HuskGLView.layerForGL == nil, Date() < deadline {
            HuskGLView.surfaceReady.wait(until: deadline)
        }
        let layer = HuskGLView.layerForGL
        let size = HuskGLView.pixelSize
        HuskGLView.surfaceReady.unlock()

        guard let layer, size.width > 0 else {
            HuskLog.log("gl", "no layer to probe with; staying on the software display")
            return
        }

        // The surface is built once and never rebuilt, so this size is the one
        // the GPU draws at for the rest of the process. If it disagrees with
        // what is on screen later, that is the bug -- not the renderer.
        HuskLog.log("gl", "binding the EGL surface to the layer published at "
                        + "\(Int(size.width))x\(Int(size.height)) px")
        var created = false
        DispatchQueue.main.sync {
            created = husk_display_gl_create(Unmanaged.passUnretained(layer).toOpaque(),
                                             Int32(size.width), Int32(size.height))
        }
        if QemuRunner.glProven {
            HuskLog.log("gl", "GL already proven on this device; context created "
                            + "(create=\(created)), skipping the probe")
            return
        }

        let works = created && husk_display_gl_probe()
        HuskLog.log("gl", "probe: create=\(created) usable=\(works)")
        if works {
            // glProven is computed now, so only the stored fact is written here.
            UserDefaults.standard.set(true, forKey: "husk.glProven")
            HuskLog.log("gl", "GL works; this and future runs use the GPU")
        } else {
            HuskLog.log("gl", "GL not usable on this device; software display it is")
        }
    }

    private func run() {
        probeGL()
        let args = (profile == .phase0Alpine) ? phase0Arguments() : phase1Arguments()
        let runningPolicy = RuntimeSnapshotPolicy(arguments: args)
        QemuRunner.runningSnapshotPolicy = runningPolicy
        if let memoryMiB = runningPolicy.memoryMiB { lastGuestMiB = memoryMiB }
        if let width = runningPolicy.width, let height = runningPolicy.height {
            QemuRunner.lastGuestRes = (width, height)
        }
        QemuRunner.runningMemoryStrategy = QemuRunner.memoryStrategy
        HuskLog.log("qemu", "profile: \(profile.rawValue)")
        HuskLog.log("qemu", "DISPLAY MODE: "
                          + (QemuRunner.glProven ? "GPU (virtio-gpu-gl)"
                                                 : "software (CPU framebuffer)"))
        if QemuRunner.glProven {
            HuskLog.log("qemu", "GPU snapshots disabled; Android services stay running and disk writes persist")
        }

        QemuRunner.bootGuestRes = QemuRunner.lastGuestRes
        HuskLog.log("qemu", "---- QEMU command line (\(args.count) args) ----")
        for (i, a) in args.enumerated() {
            HuskLog.log("qemu", String(format: "  argv[%2d] = %@", i, a))
        }
        // Only phase 0 takes its -d from this setting; phase 1 hardcodes a quiet
        // one. Printing the setting regardless made it look as though Android
        // was running with page and mmu logging on, which would be ruinous.
        HuskLog.log("qemu", profile == .phase0Alpine
            ? "---- verbosity: \(verbosity) (-d \(verbosity.rawValue)) ----"
            : "---- verbosity: fixed for Android (-d guest_errors,unimp) ----")

        // Confirm the guest images are actually in the bundle before QEMU tries to
        // open them; "could not load kernel" is a far less obvious error message.
        let required: [String] = (profile == .phase0Alpine)
            ? ["\(Bundle.main.bundlePath)/vmlinuz-virt",
               "\(Bundle.main.bundlePath)/initramfs-virt"]
            : [GuestImage.shared.diskPath,
               GuestImage.shared.userdataPath,
               GuestImage.shared.firmwarePath,
               GuestImage.shared.varsPath]
        for path in required {
            let attrs = try? FileManager.default.attributesOfItem(atPath: path)
            let size = (attrs?[.size] as? NSNumber)?.intValue ?? -1
            HuskLog.log("qemu", "needs \((path as NSString).lastPathComponent): "
                              + (size >= 0 ? "\(size) bytes" : "MISSING"))
        }

        if QemuRunner.glProven {
            // Only claimed once GL has actually been shown to work, since the
            // flag is what lets virtio-gpu-gl realize.
            _ = husk_display_gl_early()
            HuskLog.log("qemu", "GL proven previously; asking for virtio-gpu-gl")
        }

        HuskLog.logFootprint("before-qemu-init")

        // qemu_init takes ownership of argv for the life of the process, so these
        // strdup'd copies are intentionally never freed.
        var argv: [UnsafeMutablePointer<CChar>?] = args.map { strdup($0) }
        argv.append(nil)

        // Keep QEMU's GPU migration blocker active as an additional safeguard.
        unsetenv("HUSK_VIRGL_SNAPSHOT")

        HuskLog.log("qemu", "calling qemu_init() -- JIT allocation happens inside this")
        argv.withUnsafeMutableBufferPointer { buf in
            qemu_init(Int32(args.count), buf.baseAddress)
        }
        HuskLog.log("qemu", "qemu_init() returned")
        // Nothing in QEMU may be called before this point -- its locks do not
        // exist yet, and bql_lock() on an uninitialised mutex aborts the
        // process. husk_display_gl_early() says so in its own comment and I
        // called the display-resize path from layoutSubviews anyway, which runs
        // during the first layout, long before this line.
        QemuRunner.qemuReady = true
        if let pending = QemuRunner.pendingUISize {
            QemuRunner.pendingUISize = nil
            // Only if it differs from what the machine was built with.
            //
            // The first layout always records a size, so every launch was
            // sending a modeset request the moment qemu_init() returned --
            // usually for the size the guest already had. On a RESTORED machine
            // that arrives while the guest's display stack is still coming back,
            // and asking virtio-gpu to remake a display it is mid-way through
            // restoring is a good way to get exactly what the last log showed:
            //
            //   [drm:virtio_gpu_dequeue_ctrl_func] *ERROR* response 0x1203
            //
            // A no-op modeset has nothing to gain and this to lose, so it is
            // now sent only when the shape genuinely changed.
            if pending.w != QemuRunner.bootGuestRes.w
                || pending.h != QemuRunner.bootGuestRes.h {
                HuskLog.log("qemu", "display shape differs from boot; asking for "
                                  + "\(pending.w)x\(pending.h)")
                husk_display_set_ui_size(Int32(pending.w), Int32(pending.h))
            } else {
                HuskLog.log("qemu", "display is already \(pending.w)x\(pending.h); "
                                  + "not disturbing the guest")
            }
        }
        // Survived initialisation, so this size is safe to try again next launch.
        try? String(QemuRunner.shared.lastGuestMiB)
            .write(toFile: ramProvenPath, atomically: true, encoding: .utf8)

        // Before the main loop: restore the machine if we saved one. This is
        // the difference between ten minutes of Android booting and a few
        // seconds of reading RAM back from disk.
        // Two kinds of snapshot can be present, and they are recorded
        // differently: the shipped one stamps the generation it belongs to,
        // while a locally saved one records the guest size it was taken at.
        let snapshotFits: Bool
        if GuestImage.shared.hasShippedSnapshot {
            snapshotFits = (QemuRunner.shared.lastGuestMiB == GuestImage.shared.snapshotPins.mib)
        } else {
            snapshotFits = (try? String(contentsOfFile: snapshotSizePath, encoding: .utf8))
                .flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
                .map { $0 == QemuRunner.shared.lastGuestMiB } ?? false
        }
        if !snapshotFits {
            HuskLog.log("qemu", "no snapshot matching a \(QemuRunner.shared.lastGuestMiB) MiB "
                              + "guest; booting cold rather than failing a restore")
        }

        let policy = QemuRunner.runningSnapshotPolicy!
        let savedStamp = snapshotDisplay
        let displayFits = policy.canRestore(savedStamp: savedStamp,
            hasLocalSnapshot: hasSnapshot)
        if !displayFits {
            HuskLog.log("qemu", "snapshot hardware identity is missing, legacy, different, or GPU; "
                              + "cold booting the current disk without restoring older userdata")
        }
        let restored = snapshotFits && displayFits && husk_snapshot_load_at_startup()
        HuskLog.log("qemu", restored
            ? "restored a compatible software snapshot; userdata matches that saved state"
            : "booting Android from its current disk state")
        QemuRunner.didRestore = restored
        DispatchQueue.main.async { QemuRunner.shared.restoredFromSnapshot = restored }
        HuskLog.logFootprint("after-qemu-init")

        // Must happen after qemu_init (the console does not exist before it) and
        // before qemu_main_loop (which does not return).
        // The surface was already created and proven during probeGL(); all that
        // is left is to register the listener, which needs console 0 and so has
        // to wait until qemu_init() has run.
        var glUp = false
        if QemuRunner.glProven {
            // Before bind, because registering the listener can deliver a
            // scanout immediately and a frame presented through the GL path is
            // a frame thrown away.
            huskInstallMetalPresenter()
            // The stored rotation is read before the presenter exists, so it
            // has to be handed over once it does.
            DispatchQueue.main.async { HuskGLView.applyStoredRotation() }
            glUp = husk_display_gl_bind()
            HuskLog.log("qemu", glUp ? "GL display is up -- the GPU is drawing now"
                                     : "GL bind failed after a successful probe")
        }
        if !glUp {
            HuskLog.log("qemu", "using the software display")
            husk_display_init()
        }
        DispatchQueue.main.async {
            QemuRunner.shared.displayKind = glUp ? .gl : .software
            HuskGLView.shared.describePlacement(why: "the display is decided")
        }

        startMemoryWatch()

        HuskLog.log("qemu", "entering qemu_main_loop() -- this does not return until shutdown")
        qemu_main_loop()

        HuskLog.log("qemu", "qemu_main_loop() RETURNED -- guest stopped")
        HuskLog.logFootprint("after-main-loop")
        qemu_cleanup()
        QemuRunner.qemuReady = false
        HuskLog.log("qemu", "qemu_cleanup() done")
        isRunning = false
    }

    /// Sample memory every few seconds for the whole session.
    ///
    /// Without this a jetsam kill leaves no evidence at all: the log's last entry
    /// is whatever happened to be printed, and the cause is indistinguishable from
    /// a crash. With it, available-before-jetsam visibly falls towards zero.
    private func startMemoryWatch() {
        let t = Thread {
            var tick = 0
            var lastFrames: UInt64 = 0
            var quietWindows = 0
            var lastAudioFrames: UInt64 = 0
            var lastAudioSilent: UInt64 = 0
            while true {
                Thread.sleep(forTimeInterval: 5)
                tick += 1
                HuskLog.logFootprint("t+\(tick * 5)s")

                // Frame rate, as a number rather than an impression. "Slow" is
                // not something two people can compare across builds; frames per
                // second is. The sequence counter increments once per surface
                // update the guest pushed, so this is what the guest actually
                // produced, not what we managed to draw.
                let glFrames = husk_display_gl_frames()
                let frames = glFrames > 0 ? glFrames : husk_display_sequence()
                let delta = frames >= lastFrames ? frames - lastFrames : 0
                lastFrames = frames
                // Audio alongside the frame rate, because "no sound" has two
                // causes that sound identical from the speaker: the guest never
                // produced any samples, or it produced them and we failed to
                // play them. These two counters separate those without anyone
                // having to guess.
                let aFrames = husk_audio_frames_in()
                let aSilent = husk_audio_underruns()
                let audio = aFrames == 0 && aSilent == 0
                    ? "" : "  ·  audio \(aFrames - lastAudioFrames) frames in, "
                          + "\(aSilent - lastAudioSilent) silent"
                lastAudioFrames = aFrames
                lastAudioSilent = aSilent
                let rate = Double(delta) / 5.0
                DispatchQueue.main.async { [weak self] in self?.fps = rate }
                HuskLog.log("perf", "guest produced \(delta) frames in 5s "
                                  + "(\(String(format: "%.1f", Double(delta) / 5.0)) fps)"
                                  + audio)

                // Save the machine once Android is genuinely up, and only once.
                //
                // The previous rule here -- six consecutive five-second windows
                // with frames in them -- fired at 31 seconds, while the boot
                // animation was still playing and the system had another five
                // minutes of work in front of it. The comment even said that
                // snapshotting mid-boot would be worse than useless, which was
                // right; the heuristic just did not implement it. Wait for the
                // guest's own boot_completed, then let it settle: the launcher
                // still has to start and draw, and a snapshot taken during that
                // saves a machine that resumes into a half-drawn screen.
                // Quiet windows, not busy ones.
                //
                // This waited for three consecutive five-second windows WITH
                // frames in them, which is the opposite of settled. Android
                // draws while the launcher comes up and then stops entirely: a
                // phone sitting on its home screen produces no frames at all.
                // So on a guest that had finished booting -- exactly the guest
                // worth saving -- the counter reset every five seconds and the
                // save never fired. One run sat booted and idle for nine
                // minutes without ever taking a snapshot.
                //
                // Under fifteen frames in five seconds means nothing is moving
                // but a caret; three such windows means Android has stopped
                // working, which is the moment to freeze it.
                if delta < 15 { quietWindows += 1 } else { quietWindows = 0 }
                let settled = QemuRunner.bootCompletedAt.map {
                    Date().timeIntervalSince($0) >= 30
                } ?? false
                // Waiting for quiet is right for a phone sitting on its home
                // screen and wrong for one being used: playing a game keeps the
                // frame rate up, quietWindows never reaches three, and the first
                // snapshot after a cold boot is never taken at all. After three
                // minutes booted, save regardless -- a snapshot of a machine
                // mid-use is worth incomparably more than no snapshot.
                // Sixty seconds, not a hundred and eighty.
                //
                // The quiet path never fires in practice: the log shows quiet=0
                // on every single window after boot, because Android is never
                // still while anyone is using it. So the timeout is not a
                // fallback, it IS the path -- and at three minutes past
                // boot_completed most sessions ended before reaching it. That is
                // the whole of "the automatic snapshot doesn't work".
                let overdue = QemuRunner.bootCompletedAt.map {
                    Date().timeIntervalSince($0) >= 60
                } ?? false
                // Say why, once a window, when the conditions are close but
                // not met. Four separate things gate this save and the log
                // recorded none of them, so "it just won't snapshot" had no
                // evidence attached -- by the rule it should have fired at 165s
                // in the last session and there is nothing to say what stopped
                // it.
                if settled, QemuRunner.shared.automaticSnapshotSavingAllowed, !QemuRunner.snapshotRequested,
                   QemuRunner.shared.hasUsableSnapshot || !(quietWindows >= 3 || overdue) {
                    HuskLog.log("snap", "not saving yet: quiet=\(quietWindows) "
                              + "overdue=\(overdue) "
                              + "alreadyHaveOne=\(QemuRunner.shared.hasUsableSnapshot) "
                              + "(display \(QemuRunner.shared.snapshotDisplay ?? "none"))")
                }
                if settled, quietWindows >= 3 || overdue,
                   QemuRunner.shared.automaticSnapshotSavingAllowed,
                   !QemuRunner.snapshotRequested,
                   !QemuRunner.shared.hasUsableSnapshot {
                    QemuRunner.snapshotRequested = true
                    // Central policy rechecks the running hardware before saving.
                    DispatchQueue.main.async {
                        QemuRunner.shared.saveState(reason: "Android is booted and settled", automatic: true)
                    }
                }

                // No [guest] lines appeared at all in one session, which is either
                // the guest writing nothing or the tailer failing to read it. The
                // file's size separates the two, and guessing wrong would send the
                // next fix in entirely the wrong direction.
                // Give memory back before jetsam takes the whole app.
                //
                // A SIGKILL from jetsam is unsurvivable and silent; an inflated
                // balloon merely makes the guest tighter. So when headroom gets
                // genuinely low, shrink the guest by whatever is missing plus a
                // margin, and leave it shrunk -- re-growing it on a dip would
                // just oscillate against the same ceiling.
                let availMiB = Int(husk_ios_available_memory() / (1024 * 1024))
                let floorMiB = 350
                if availMiB > 0, availMiB < floorMiB,
                   QemuRunner.shared.lastGuestMiB > 0 {
                    let shortfall = floorMiB - availMiB + 128
                    let newSize = max(768, QemuRunner.balloonTargetMiB
                                         ?? QemuRunner.shared.lastGuestMiB) - shortfall
                    if newSize >= 768, newSize != QemuRunner.balloonTargetMiB {
                        QemuRunner.balloonTargetMiB = newSize
                        HuskLog.log("mem", "only \(availMiB) MiB before jetsam; "
                                         + "ballooning the guest down to \(newSize) MiB")
                        husk_balloon_set_bytes(Int64(newSize) * 1024 * 1024)
                    }
                }

                if tick % 6 == 0 {
                    let attrs = try? FileManager.default
                        .attributesOfItem(atPath: QemuRunner.shared.guestSerialLogPath)
                    let size = (attrs?[.size] as? NSNumber)?.intValue ?? -1
                    HuskLog.log("qemu", "guest serial log is \(size) bytes "
                                      + "(if this grows but no [guest] lines appear, "
                                      + "the tailer is at fault, not the guest)")
                }
            }
        }
        t.name = "husk.memwatch"
        t.qualityOfService = .utility
        t.start()
    }

    /// Fold the guest's kernel console into the unified log as it appears.
    ///
    /// Uses open(2)/read(2) rather than FileHandle. The FileHandle version opened
    /// the right file -- it logged "serial log opened" and the size probe showed
    /// that file growing from 51 KB to 63 KB -- yet never produced a single line.
    /// A plain fd advances its own offset on every read and returns 0 at EOF, so
    /// there is no seek/offset bookkeeping to get wrong, and it reports what it
    /// actually did.
    private func startSerialTailer() {
        let path = guestSerialLogPath
        try? FileManager.default.removeItem(atPath: path)

        let t = Thread {
            var fd: Int32 = -1
            var pending = Data()
            var buf = [UInt8](repeating: 0, count: 64 * 1024)
            var totalRead = 0
            var reportedOpen = false

            while true {
                if fd < 0 {
                    fd = open(path, O_RDONLY)
                    if fd >= 0, !reportedOpen {
                        reportedOpen = true
                        HuskLog.log("guest", "serial log opened (fd \(fd))")
                    }
                    if fd < 0 { Thread.sleep(forTimeInterval: 0.5); continue }
                }

                let n = buf.withUnsafeMutableBytes { read(fd, $0.baseAddress, 64 * 1024) }
                if n < 0 {
                    if errno == EINTR { continue }
                    HuskLog.log("guest", "serial read failed: errno \(errno); reopening")
                    close(fd); fd = -1
                    Thread.sleep(forTimeInterval: 1)
                    continue
                }
                if n == 0 {
                    // EOF for now; the fd keeps its offset, so appended bytes are
                    // picked up on the next read.
                    Thread.sleep(forTimeInterval: 0.25)
                    continue
                }

                totalRead += n
                pending.append(contentsOf: buf[0..<n])

                while let nl = pending.firstIndex(of: 0x0A) {
                    let lineData = pending.subdata(in: pending.startIndex..<nl)
                    pending.removeSubrange(pending.startIndex...nl)
                    // Serial consoles emit CRLF; strip the CR or every line ends
                    // with a stray carriage return.
                    var line = String(decoding: lineData, as: UTF8.self)
                    line = line.replacingOccurrences(of: "\r", with: "")
                    line = line.trimmingCharacters(in: .whitespaces)
                    if line.isEmpty { continue }

                    HuskLog.log("guest", line)

                    // Say what the guest is doing, so a long first boot does
                    // not look like a hang.
                    //
                    // Android's first boot here runs five to seven minutes:
                    // dex2oat compiles the system, and the framework watchdog
                    // kills and restarts system_server at least once along the
                    // way. All of that is invisible -- the screen holds the last
                    // frame the boot animation drew -- so it reads as a freeze
                    // and gets force-quit a minute short of finishing. It only
                    // has to succeed once, because the snapshot is taken after
                    // it, but it does have to succeed once.
                    for (needle, milestone, percent) in
                            (QemuRunner.didRestore ? [] : QemuRunner.bootMilestones) {
                        if line.contains(needle) {
                            let secs = Int(Date().timeIntervalSince(QemuRunner.bootStarted))
                            let mins = secs / 60, rem = secs % 60
                            let stamp = String(format: "%d:%02d", mins, rem)
                            Task { @MainActor in
                                let r = QemuRunner.shared
                                if percent > r.bootProgress { r.bootProgress = percent }
                                r.setupMessage =
                                    "\(r.bootProgress)%  ·  \(milestone)  ·  \(stamp) elapsed"
                            }
                            break
                        }
                    }

                    // Android announces the end of its own boot. init prints
                    // "processing action (sys.boot_completed=1)" when the
                    // property is set, which is the one unambiguous statement
                    // in the whole log that the system is up -- everything else
                    // (frames appearing, bootanim running) is true long before.
                    if QemuRunner.bootCompletedAt == nil,
                       line.contains("sys.boot_completed=1") {
                        QemuRunner.bootCompletedAt = Date()
                        HuskLog.log("snap", "Android reports boot_completed; "
                                          + "will save the machine once it settles")
                    }

                    if let r = line.range(of: "HUSK-SETUP: ") ?? line.range(of: "HUSK-UI: ") {
                        let msg = String(line[r.upperBound...])
                        Task { @MainActor in QemuRunner.shared.setupMessage = msg }
                    }
                }

                // A runaway buffer means no newline is ever arriving; say so rather
                // than growing without bound.
                if pending.count > 1_000_000 {
                    HuskLog.log("guest", "serial buffer exceeded 1 MB with no newline; discarding")
                    pending.removeAll(keepingCapacity: true)
                }
            }
        }
        t.name = "husk.serial-tail"
        t.qualityOfService = .utility
        t.start()
    }
}
