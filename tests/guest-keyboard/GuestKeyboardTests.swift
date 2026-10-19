// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

@main
enum GuestKeyboardTests {
    static func main() {
        typealias Event = GuestKeyboardInput.Event
        var input = GuestKeyboardInput()
        // Meta alone, HOME chords, and Recents must never reach Android.
        for modifier in ["meta_l", "meta_r"] {
            precondition(input.keyDown(modifier) == nil)
            for key in ["h", "ret", "tab", "a", "i"] {
                precondition(input.keyDown(key) == nil)
                precondition(input.keyUp(key) == nil)
            }
            precondition(input.keyUp(modifier) == nil)
            precondition(input.releaseAll().isEmpty)
        }
        // UIKit modifier flags work even if the key and modifier arrive in an
        // unordered event set, or the modifier began before capture became active.
        precondition(input.keyDown("h", meta: true) == nil)
        precondition(input.keyDown("meta_l") == nil)
        precondition(input.keyUp("meta_l") == nil)
        precondition(input.keyDown("h") == nil, "A blocked chord's repeat must not type h")
        precondition(input.keyUp("h") == nil)
        precondition(input.keyDown("tab", alt: true) == nil)
        precondition(input.keyUp("tab") == nil)
        for modifier in ["alt", "alt_r"] {
            precondition(input.keyDown(modifier) == Event(key: modifier, down: true))
            precondition(input.keyDown("shift") == Event(key: "shift", down: true))
            precondition(input.keyDown("tab") == nil)
            precondition(input.keyUp(modifier) == Event(key: modifier, down: false))
            precondition(input.keyDown("tab") == nil)
            precondition(input.keyUp("tab") == nil)
            precondition(input.keyUp("shift") == Event(key: "shift", down: false))
        }
        // Preserve app Back/Escape and text navigation, including physical Home.
        for key in ["home", "end", "left", "right", "up", "down", "esc", "tab", "ret", "backspace", "a"] {
            precondition(input.keyDown(key) == Event(key: key, down: true))
            precondition(input.keyDown(key) == Event(key: key, down: true), "Keep ordinary repeat")
            precondition(input.keyUp(key) == Event(key: key, down: false))
        }
        precondition(input.keyDown("ctrl") == Event(key: "ctrl", down: true))
        precondition(input.keyDown("c") == Event(key: "c", down: true))
        precondition(input.keyUp("c") == Event(key: "c", down: false))
        precondition(input.keyUp("ctrl") == Event(key: "ctrl", down: false))
        // If Meta arrives during an already-held key, don't strand that key.
        precondition(input.keyDown("h") == Event(key: "h", down: true))
        precondition(input.keyDown("meta_l") == nil)
        precondition(input.keyDown("h", meta: true) == nil)
        precondition(input.keyUp("h") == Event(key: "h", down: false))
        precondition(input.keyUp("meta_l") == nil)
        // Dismissal/cancellation releases only keys actually forwarded, once.
        _ = input.keyDown("ctrl")
        _ = input.keyDown("a")
        _ = input.keyDown("tab", alt: true)
        precondition(input.releaseAll() == [Event(key: "a", down: false), Event(key: "ctrl", down: false)])
        precondition(input.releaseAll().isEmpty)
        precondition(input.keyUp("ctrl") == nil)
        precondition(input.keyDown("tab") == Event(key: "tab", down: true))
        precondition(input.keyUp("tab") == Event(key: "tab", down: false))
        print("Guest keyboard tests passed")
    }
}
