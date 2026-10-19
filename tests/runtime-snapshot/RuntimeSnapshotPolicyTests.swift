// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

@main
enum RuntimeSnapshotPolicyTests {
    static func main() {
        func arguments(gpu: Bool = false, width: Int = 360, height: Int = 800,
                       machine: String = "virt,highmem=on,memory-backend=huskram",
                       memory: Int = 4096, sound: Bool = false,
                       path: String = "/container-A/guest-ram.bin") -> [String] {
            ["qemu-system-aarch64", "-M", machine,
             "-cpu", "max,pauth-impdef=on,sve=off,sme=off", "-smp", "4", "-m", "\(memory)",
             "-device", "virtio-balloon-pci,id=huskballoon",
             "-device", "virtio-gpu\(gpu ? "-gl" : "")-pci,xres=\(width),yres=\(height)",
             "-object", "memory-backend-file,id=huskram,size=\(memory)M,mem-path=\(path),share=on,prealloc=off"]
                + (sound ? ["-audiodev", "husk,id=huskaudio", "-device", "virtio-sound-pci,audiodev=huskaudio"] : [])
        }
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            precondition(condition(), message)
        }

        let software = RuntimeSnapshotPolicy(arguments: arguments())
        let gpu = RuntimeSnapshotPolicy(arguments: arguments(gpu: true))
        check(!gpu.savingSupported, "GPU snapshot must be unavailable in UI")
        for automatic in [false, true] {
            for preference in [false, true] {
                check(!gpu.allowsSave(automatic: automatic, automaticEnabled: preference),
                      "Neither manual nor automatic GPU saves may stop Android services")
            }
        }
        check(software.allowsSave(automatic: false, automaticEnabled: false), "Manual software saves remain available")
        check(!software.allowsSave(automatic: true, automaticEnabled: false), "Automatic software saves honor preference")
        check(software.allowsSave(automatic: true, automaticEnabled: true), "Automatic software save opt-in")
        check(software.canRestore(savedStamp: software.stamp, hasLocalSnapshot: true), "Matching new software save restores")
        check(!gpu.canRestore(savedStamp: gpu.stamp, hasLocalSnapshot: true), "GPU restore always blocked")
        for stamp in [nil, "sw", "gl+1920x2560", "sw+1920x2560", "apkcontainer-v1:sw"] as [String?] {
            check(!software.canRestore(savedStamp: stamp, hasLocalSnapshot: true), "Legacy identity must never rewind current disk")
            check(!software.canRestore(savedStamp: stamp, hasLocalSnapshot: false), "Unstamped shipped state must not rewind current disk")
        }
        check(!software.canRestore(savedStamp: software.stamp, hasLocalSnapshot: false), "Partial metadata cannot restore")

        // Reproduces device logs: running 360x800, then preferences change to
        // 1920x2560 before a save. The original identity must stay 360x800.
        var preferredArguments = arguments()
        let running = RuntimeSnapshotPolicy(arguments: preferredArguments)
        preferredArguments = arguments(width: 1920, height: 2560)
        let nextBoot = RuntimeSnapshotPolicy(arguments: preferredArguments)
        check(running.stamp == software.stamp, "Running hardware identity must remain frozen")
        check(running.width == 360 && running.height == 800 && running.memoryMiB == 4096, "Capture actual hardware arguments")
        check(!nextBoot.canRestore(savedStamp: running.stamp, hasLocalSnapshot: true), "Changed resolution rejects old save")
        check(RuntimeSnapshotPolicy(arguments: arguments(memory: 2048)).stamp != running.stamp, "Memory size is hardware")
        check(RuntimeSnapshotPolicy(arguments: arguments(sound: true)).stamp != running.stamp, "Audio device is hardware")
        check(RuntimeSnapshotPolicy(arguments: arguments(machine: "virt,highmem=off,memory-backend=huskram")).stamp != running.stamp,
              "Actual -M machine backend belongs in identity")
        let alias = arguments().map { $0 == "-M" ? "-machine" : $0 }
        check(RuntimeSnapshotPolicy(arguments: alias).stamp == running.stamp, "Equivalent machine aliases normalize")
        check(RuntimeSnapshotPolicy(arguments: arguments(path: "/container-B/guest-ram.bin")).stamp == running.stamp,
              "Container relocation is not a hardware change")
        check(!RuntimeSnapshotPolicy(arguments: []).savingSupported, "Incomplete hardware cannot save")
        check(RuntimeSnapshotPolicy.displayMode(of: software.stamp) == "sw", "New software stamp recognized by forget control")
        check(RuntimeSnapshotPolicy.displayMode(of: "gl+1920x2560") == "gl", "Legacy GPU stamp recognized by forget control")
        print("Runtime snapshot policy tests passed")
    }
}
