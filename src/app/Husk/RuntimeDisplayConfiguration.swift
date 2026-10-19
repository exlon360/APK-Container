// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// Hardware pixels and Android density are chosen together for the fallback runtime.
/// Unlike a native app surface, this panel keeps its shape until the next boot.
struct RuntimeDisplayConfiguration: Equatable {
    enum Preset: String, CaseIterable, Identifiable {
        case balanced, performance, sharp, maximum, half, custom
        var id: String { rawValue }
        var title: String {
            switch self {
            case .balanced: return "Balanced · 1280 px"
            case .performance: return "Performance · 960 px"
            case .sharp: return "Sharper · 1920 px"
            case .maximum: return "Device Maximum · 2560 px"
            case .half: return "Half Device Resolution"
            case .custom: return "Custom Size"
            }
        }
        var longestEdge: Double {
            switch self {
            case .performance: return 960
            case .balanced: return 1280
            case .sharp: return 1920
            case .maximum, .half, .custom: return 2560
            }
        }
    }

    enum Orientation: String, CaseIterable, Identifiable {
        case device, portrait, landscape
        var id: String { rawValue }
        var title: String {
            switch self {
            case .device: return "Match Window"
            case .portrait: return "Portrait"
            case .landscape: return "Landscape"
            }
        }
    }

    struct Viewport: Equatable {
        let width: Double
        let height: Double
        let nativeScale: Double
        static let fallback = Viewport(width: 390, height: 844, nativeScale: 1)
        var isValid: Bool {
            width.isFinite && height.isFinite && nativeScale.isFinite
                && width > 0 && height > 0 && nativeScale > 0
        }
    }

    struct Preferences {
        static let presetKey = "apkcontainer.runtimeResolutionPreset"
        static let orientationKey = "apkcontainer.runtimeOrientation"
        let preset: Preset
        let orientation: Orientation
        let customWidth: Int
        let customHeight: Int
        private let recognizeLegacyPreset: Bool

        init(preset: Preset, orientation: Orientation, customWidth: Int = 720, customHeight: Int = 1280) {
            self.preset = preset; self.orientation = orientation
            recognizeLegacyPreset = false
            self.customWidth = customWidth; self.customHeight = customHeight
        }

        /// Read legacy selections without rewriting them: a previous preset was
        /// stored as a custom width/height and cannot be distinguished from typing.
        init(presetRaw: String?, orientationRaw: String?, legacyCustom: Bool,
             legacyLandscape: Bool, customWidth: Int, customHeight: Int) {
            recognizeLegacyPreset = presetRaw == nil && orientationRaw == nil && legacyCustom
            preset = presetRaw.flatMap(Preset.init(rawValue:)) ?? (legacyCustom ? .custom : .balanced)
            orientation = orientationRaw.flatMap(Orientation.init(rawValue:))
                ?? (legacyLandscape ? .landscape : .device)
            self.customWidth = customWidth; self.customHeight = customHeight
        }

        /// Older Device presets were persisted as raw custom pixels. Recognize
        /// only their exact rounded values on this screen; keep the original
        /// keys untouched and preserve all other explicitly typed dimensions.
        func resolved(for device: Viewport) -> Preferences {
            guard recognizeLegacyPreset, device.isValid else { return self }
            let short = min(device.width, device.height), long = max(device.width, device.height)
            let w = orientation == .landscape ? long : short
            let h = orientation == .landscape ? short : long
            for (fraction, quality) in [(1.0, Preset.maximum), (0.5, Preset.half)] {
                let scale = min(device.nativeScale * fraction, 2560 / max(w, h))
                let oldWidth = Int(((w * scale).rounded() / 8).rounded()) * 8
                let oldHeight = Int(((h * scale).rounded() / 8).rounded()) * 8
                if customWidth == oldWidth, customHeight == oldHeight {
                    return Preferences(preset: quality, orientation: .device,
                        customWidth: customWidth, customHeight: customHeight)
                }
            }
            return self
        }

        static var current: Preferences {
            let defaults = UserDefaults.standard
            return Preferences(presetRaw: defaults.string(forKey: presetKey),
                orientationRaw: defaults.string(forKey: orientationKey),
                legacyCustom: defaults.bool(forKey: "husk.customRes"),
                legacyLandscape: defaults.bool(forKey: "husk.landscapeGuest"),
                customWidth: defaults.integer(forKey: "husk.resWidth"),
                customHeight: defaults.integer(forKey: "husk.resHeight"))
        }
    }

    let width: Int
    let height: Int
    let density: Int
    var summary: String { "\(width) × \(height) · \(density) dpi" }

    static func validCustom(width: Int, height: Int) -> (width: Int, height: Int)? {
        guard (240...2560).contains(width), (240...2560).contains(height) else { return nil }
        return (Int((Double(width) / 8).rounded()) * 8, Int((Double(height) / 8).rounded()) * 8)
    }

    static func make(viewport supplied: Viewport, preferences requested: Preferences,
                     legacyDevice: Viewport? = nil) -> RuntimeDisplayConfiguration {
        let viewport = supplied.isValid ? supplied : .fallback
        let preferences = requested.resolved(for: legacyDevice ?? viewport)
        let pixels: (width: Int, height: Int)
        if preferences.preset == .custom,
           let custom = validCustom(width: preferences.customWidth, height: preferences.customHeight) {
            pixels = custom
        } else {
            let short = min(viewport.width, viewport.height), long = max(viewport.width, viewport.height)
            let w: Double, h: Double
            switch preferences.orientation {
            case .device: w = viewport.width; h = viewport.height
            case .portrait: w = short; h = long
            case .landscape: w = long; h = short
            }
            let budget = preferences.preset == .custom ? Preset.balanced.longestEdge : preferences.preset.longestEdge
            let nativeScale = viewport.nativeScale * (preferences.preset == .half ? 0.5 : 1)
            let scale = min(nativeScale, budget / max(w, h))
            pixels = (max(240, min(2560, Int((w * scale / 8).rounded()) * 8)),
                      max(240, min(2560, Int((h * scale / 8).rounded()) * 8)))
        }
        // One Android dp roughly matches one visible iOS point, including an
        // explicitly letterboxed custom panel. Native pixels alone are not dp:
        // 1920x2560 at the image's 160 dpi made every control tiny on an iPad.
        let fit = min(viewport.width / Double(pixels.width), viewport.height / Double(pixels.height))
        let density = min(640, max(120, Int((160 / fit).rounded())))
        return RuntimeDisplayConfiguration(width: pixels.width, height: pixels.height, density: density)
    }
}

/// Shared aspect-fit geometry for the rendered scanout and input. Coordinates
/// are normalized first, then mapped to QEMU's actual console size at the event.
struct RuntimeDisplayGeometry {
    struct Point: Equatable { let x: Double; let y: Double }
    /// Normalized coordinates in the complete physical scanout, before the
    /// optional host quarter turn. Only reported system bar areas are removed.
    struct Crop: Equatable {
        let left: Double
        let top: Double
        let right: Double
        let bottom: Double
        static let full = Crop(left: 0, top: 0, right: 1, bottom: 1)
        var width: Double { right - left }
        var height: Double { bottom - top }
        var isValid: Bool {
            [left, top, right, bottom].allSatisfy(\.isFinite)
                && left >= 0 && top >= 0 && right <= 1 && bottom <= 1
                && width > 0 && height > 0
        }
    }
    let width: Double
    let height: Double
    let rotated: Bool
    var crop: Crop = .full
    var contentWidth: Double { width * crop.width }
    var contentHeight: Double { height * crop.height }
    var effectiveWidth: Double { rotated ? contentHeight : contentWidth }
    var effectiveHeight: Double { rotated ? contentWidth : contentHeight }

    func normalizedPoint(x: Double, y: Double, viewWidth: Double, viewHeight: Double) -> Point? {
        guard crop.isValid,
              [width, height, viewWidth, viewHeight].allSatisfy({ $0.isFinite && $0 > 0 }),
              x.isFinite, y.isFinite else { return nil }
        let scale = min(viewWidth / effectiveWidth, viewHeight / effectiveHeight)
        let px = (x - (viewWidth - effectiveWidth * scale) / 2) / (effectiveWidth * scale)
        let py = (y - (viewHeight - effectiveHeight * scale) / 2) / (effectiveHeight * scale)
        // Normalized integer crops can leave a sub-ulp inset after multiplying
        // back to pixels. Accept that rounding at the leading edges only.
        guard px >= -1e-12, px < 1, py >= -1e-12, py < 1 else { return nil }
        let local = rotated ? Point(x: 1 - max(0, py), y: max(0, px)) : Point(x: max(0, px), y: max(0, py))
        // A quarter-turned leading edge maps to local 1. Keep its pixel inside
        // the crop, rather than sending a tap to the first hidden navigation row.
        return Point(x: min(crop.right - 0.5 / width, max(crop.left + 0.5 / width, crop.left + local.x * crop.width)),
                     y: min(crop.bottom - 0.5 / height, max(crop.top + 0.5 / height, crop.top + local.y * crop.height)))
    }

    static func pixels(_ point: Point, width: Int32, height: Int32) -> (Int32, Int32)? {
        guard width > 0, height > 0, point.x.isFinite, point.y.isFinite else { return nil }
        return (Int32(min(Double(width - 1), max(0, floor(point.x * Double(width))))),
                Int32(min(Double(height - 1), max(0, floor(point.y * Double(height))))))
    }

    /// A release outside the image must still reach Android; otherwise its
    /// mouse button stays held down after dragging into a letterbox or cancelling.
    struct Pointer {
        private(set) var lastDown: Point?
        mutating func update(point: Point?, down: Bool) -> Point? {
            if down {
                guard let point else { return nil }
                lastDown = point
                return point
            }
            guard let last = lastDown else { return nil }
            lastDown = nil
            return point ?? last
        }
    }
}
