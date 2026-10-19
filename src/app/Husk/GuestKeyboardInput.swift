// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// Filters Android's global keyboard navigation while retaining application input.
/// QEMU's `home` is Android MOVE_HOME (text navigation), not Android HOME.
struct GuestKeyboardInput {
    struct Event: Equatable {
        let key: String
        let down: Bool
    }

    private var pressed: Set<String> = []
    private var forwarded: Set<String> = []
    private var suppressed: Set<String> = []

    mutating func keyDown(_ key: String, meta: Bool = false, alt: Bool = false) -> Event? {
        pressed.insert(key)
        // Android reserves Meta combinations for system actions. Even Meta by
        // itself can open All Apps. Do not leak the other half of a blocked chord
        // as ordinary text when its modifier is released first.
        let metaHeld = meta || pressed.contains("meta_l") || pressed.contains("meta_r")
        let altHeld = alt || pressed.contains("alt") || pressed.contains("alt_r")
        if suppressed.contains(key) || metaHeld || (key == "tab" && altHeld) {
            // A repeat may arrive after this key was already sent without a
            // modifier. Keep its eventual release, but suppress this repeat.
            if !forwarded.contains(key) { suppressed.insert(key) }
            return nil
        }
        forwarded.insert(key)
        return Event(key: key, down: true)
    }

    mutating func keyUp(_ key: String) -> Event? {
        pressed.remove(key)
        suppressed.remove(key)
        guard forwarded.remove(key) != nil else { return nil }
        return Event(key: key, down: false)
    }

    mutating func releaseAll() -> [Event] {
        let releases = forwarded.sorted().map { Event(key: $0, down: false) }
        pressed.removeAll()
        forwarded.removeAll()
        suppressed.removeAll()
        return releases
    }
}
