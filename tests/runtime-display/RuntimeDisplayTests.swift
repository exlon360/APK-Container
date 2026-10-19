// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

@main
enum RuntimeDisplayTests {
    static func main() {
        typealias Display = RuntimeDisplayConfiguration
        typealias Geometry = RuntimeDisplayGeometry
        let iPad = Display.Viewport(width: 1376, height: 1032, nativeScale: 2)
        let portraitPad = Display.Viewport(width: 1032, height: 1376, nativeScale: 2)
        let phone = Display.Viewport(width: 390, height: 844, nativeScale: 3)
        let defaults = Display.Preferences(preset: .balanced, orientation: .device)
        let balanced = Display.make(viewport: iPad, preferences: defaults)
        precondition(balanced.width == 1280 && balanced.height == 960 && balanced.density == 149)
        let portrait = Display.make(viewport: portraitPad, preferences: defaults)
        precondition(portrait.width == 960 && portrait.height == 1280 && portrait.density == 149)
        let phonePanel = Display.make(viewport: phone, preferences: defaults)
        precondition(phonePanel.width == 592 && phonePanel.height == 1280 && phonePanel.density == 243)
        let low = Display.make(viewport: iPad, preferences: .init(preset: .performance, orientation: .device))
        precondition(low.width == 960 && low.height == 720 && low.density == 120)
        precondition(low.width * low.height < balanced.width * balanced.height)
        let max = Display.make(viewport: iPad, preferences: .init(preset: .maximum, orientation: .device))
        precondition(max.width == 2560 && max.height == 1920 && max.density == 298)

        func legacy(_ width: Int, _ height: Int, newPreset: String? = nil,
                    newOrientation: String? = nil, landscape: Bool = false) -> Display.Preferences {
            .init(presetRaw: newPreset, orientationRaw: newOrientation,
                  legacyCustom: true, legacyLandscape: landscape, customWidth: width, customHeight: height)
        }
        // Device log regression: old portrait Device Maximum on a landscape iPad.
        let old = legacy(1920, 2560)
        precondition(Display.make(viewport: iPad, preferences: old) == max)
        precondition(old.customWidth == 1920 && old.customHeight == 2560, "Reading must not overwrite legacy custom values")
        let half = Display.make(viewport: iPad, preferences: legacy(1032, 1376))
        precondition(half.width == 1376 && half.height == 1032 && half.density == 160)
        precondition(legacy(2560, 1920, landscape: true).resolved(for: portraitPad).orientation == .device)
        // Reproduce the old two-stage rounding: 595.7 -> 596 -> 600, not 592.
        let fractional = Display.Viewport(width: 397.1333333333, height: 844, nativeScale: 1.5)
        precondition(legacy(600, 1264).resolved(for: fractional).preset == .maximum)
        let explicit = Display.make(viewport: iPad, preferences: legacy(1920, 2560, newPreset: "custom"))
        precondition(explicit.width == 1920 && explicit.height == 2560 && explicit.density == 397)
        let arbitrary = Display.make(viewport: iPad, preferences: legacy(1024, 1536))
        precondition(arbitrary.width == 1024 && arbitrary.height == 1536, "Preserve arbitrary custom sizes")
        precondition(legacy(1920, 2560, newOrientation: "portrait").resolved(for: iPad).preset == .custom)
        // Recognize old presets using screen metrics, but fit the current window.
        let window = Display.Viewport(width: 700, height: 900, nativeScale: 2)
        let windowPanel = Display.make(viewport: window, preferences: old, legacyDevice: iPad)
        precondition(windowPanel.width == 1400 && windowPanel.height == 1800)
        precondition(Display.validCustom(width: 239, height: 800) == nil)
        precondition(Display.validCustom(width: 2561, height: 800) == nil)
        precondition(Display.make(viewport: .init(width: .nan, height: 0, nativeScale: -1), preferences: defaults).width > 0)
        for preset in Display.Preset.allCases where preset != .custom {
            for viewport in [iPad, portraitPad, phone, window] {
                let panel = Display.make(viewport: viewport, preferences: .init(preset: preset, orientation: .device))
                precondition(panel.width % 8 == 0 && panel.height % 8 == 0)
                precondition(panel.width <= 2560 && panel.height <= 2560)
                precondition((120...640).contains(panel.density))
                // Eight-pixel stride alignment is the only aspect deviation.
                let scale = Double(panel.height) / viewport.height
                precondition(abs(Double(panel.width) - viewport.width * scale) <= 12)
            }
        }

        let padGeometry = Geometry(width: 1280, height: 960, rotated: false)
        let center = padGeometry.normalizedPoint(x: 688, y: 516, viewWidth: 1376, viewHeight: 1032)!
        precondition(center == .init(x: 0.5, y: 0.5))
        let actualPixels = Geometry.pixels(center, width: 1920, height: 1440)!
        precondition(actualPixels.0 == 960 && actualPixels.1 == 720, "Input maps to current console, not boot size")
        let letterbox = Geometry(width: 360, height: 800, rotated: false)
        precondition(letterbox.normalizedPoint(x: 0, y: 516, viewWidth: 1376, viewHeight: 1032) == nil)
        let turned = Geometry(width: 360, height: 800, rotated: true)
        let corner = turned.normalizedPoint(x: 0, y: 0, viewWidth: 800, viewHeight: 360)!
        let edge = Geometry.pixels(corner, width: 360, height: 800)!
        precondition(edge.0 == 359 && edge.1 == 0, "Rotated top edge remains tappable")
        let turnedCenter = turned.normalizedPoint(x: 400, y: 180, viewWidth: 800, viewHeight: 360)!
        precondition(turnedCenter == center)
        precondition(padGeometry.normalizedPoint(x: .nan, y: 0, viewWidth: 0, viewHeight: 10) == nil)
        var pointer = Geometry.Pointer()
        precondition(pointer.update(point: nil, down: false) == nil)
        precondition(pointer.update(point: center, down: true) == center)
        precondition(pointer.update(point: nil, down: true) == nil)
        precondition(pointer.update(point: nil, down: false) == center, "Release outside letterbox must reach Android")
        precondition(pointer.lastDown == nil)
        precondition(pointer.update(point: nil, down: false) == nil, "Do not send duplicate releases")
        print("Runtime display tests passed: device-aspect budgets, density, legacy presets, preserved custom sizes, actual-console input, rotation and releases.")
    }
}
