// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// Snapshot identity comes from the actual QEMU argv, never live preferences.
/// GPU snapshots are disabled: stopping SurfaceFlinger to save leaves Android's
/// system_server holding released surfaces and can crash the framework.
struct RuntimeSnapshotPolicy {
    let usesGPU: Bool
    let stamp: String
    let memoryMiB: Int?
    let width: Int?
    let height: Int?

    init(arguments: [String]) {
        var hardware: [String] = []
        var values: [String: String] = [:]
        var gpu: String?
        let options: Set<String> = ["-M", "-machine", "-cpu", "-smp", "-m", "-accel",
                                    "-device", "-audiodev", "-object"]
        for index in arguments.indices.dropLast() where options.contains(arguments[index]) {
            let option = arguments[index] == "-M" ? "-machine" : arguments[index]
            let value = arguments[index + 1]
            values[option] = value
            // The app container path changes on reinstall; it is not hardware.
            let normalized = option == "-object"
                ? value.split(separator: ",").filter { !$0.hasPrefix("mem-path=") }.joined(separator: ",")
                : value
            hardware.append(contentsOf: [option, normalized])
            if option == "-device", value.hasPrefix("virtio-gpu") { gpu = value }

        }
        usesGPU = gpu?.hasPrefix("virtio-gpu-gl-") == true
        memoryMiB = values["-m"].flatMap(Int.init)
        let fields = (gpu ?? "").split(separator: ",")
        width = fields.first(where: { $0.hasPrefix("xres=") }).flatMap { Int($0.dropFirst(5)) }
        height = fields.first(where: { $0.hasPrefix("yres=") }).flatMap { Int($0.dropFirst(5)) }
        // JSON preserves argument boundaries, including commas in device values.
        let encoded = try! JSONEncoder().encode(hardware)
        stamp = "apkcontainer-v2:" + (usesGPU ? "gl:" : "sw:") + encoded.base64EncodedString()
    }

    var savingSupported: Bool { !usesGPU && width != nil && height != nil }

    func allowsSave(automatic: Bool, automaticEnabled: Bool) -> Bool {
        savingSupported && (!automatic || automaticEnabled)
    }

    func canRestore(savedStamp: String?, hasLocalSnapshot: Bool) -> Bool {
        // Unstamped shipped and legacy snapshots cannot establish that their
        // disk state still matches the user's current disk. Preserve it by
        // cold booting; never restore guessed hardware or old userdata.
        savingSupported && hasLocalSnapshot && savedStamp == stamp
    }

    static func displayMode(of stamp: String) -> String? {
        if stamp.hasPrefix("apkcontainer-v2:gl:") || stamp == "gl" || stamp.hasPrefix("gl+") { return "gl" }
        if stamp.hasPrefix("apkcontainer-v2:sw:") || stamp == "sw" || stamp.hasPrefix("sw+") { return "sw" }
        return nil
    }
}
