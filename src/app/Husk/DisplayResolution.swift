// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// The same pixel budget is applied to both axes. A phone, iPad, or floating window keeps its own shape.
enum APKDisplayResolution {
    enum Preset: String, Codable, CaseIterable, Identifiable {
        case automatic, low, medium, high, native, custom
        var id: String { rawValue }
        var title: String {
            switch self {
            case .automatic: return "Use Default"
            case .low: return "Performance (1×)"
            case .medium: return "Balanced (1.5×)"
            case .high: return "High (2×)"
            case .native: return "Native Device Resolution"
            case .custom: return "Custom Pixel Limit"
            }
        }
        var detail: String {
            switch self {
            case .automatic: return "Uses the default in Settings › Display & Resolution."
            case .low: return "One render pixel per screen point. Reduces the GPU's pixel workload."
            case .medium: return "1.5 render pixels per screen point. Balances detail and pixel workload."
            case .high: return "Two render pixels per screen point, up to the screen's native resolution."
            case .native: return "Uses this screen's native pixel density and the app's available area."
            case .custom: return "Limits the longest edge in pixels while preserving the screen's aspect ratio."
            }
        }
    }

    static let customRange = 320...4096
    static let defaultMaximumEdge = 1920
    static let defaultsKey = "apkcontainer.defaultResolution"
    static let defaultChoices: [Preset] = [.native, .high, .medium, .low]

    static var defaultPreset: Preset {
        get {
            let stored = UserDefaults.standard.string(forKey: defaultsKey).flatMap(Preset.init(rawValue:))
            return stored.flatMap { defaultChoices.contains($0) ? $0 : nil } ?? .native
        }
        set { UserDefaults.standard.set(defaultChoices.contains(newValue) ? newValue.rawValue : Preset.native.rawValue, forKey: defaultsKey) }
    }

    static func clampedMaximumEdge(_ value: Int) -> Int {
        min(max(value, customRange.lowerBound), customRange.upperBound)
    }

    struct Surface: Equatable {
        let width: Int
        let height: Int
        /// Used for render density, input coordinates, safe areas, and Android's density together.
        let scale: Double
    }

    /// Pure sizing calculation: callers supply the actual window bounds and screen density.
    /// Pixel rounding is the only aspect-ratio error (at most half a pixel on either axis).
    static func surface(width: Double, height: Double, nativeScale: Double, preset: Preset,
                        maximumEdge: Int = defaultMaximumEdge, defaultPreset: Preset = .native) -> Surface? {
        guard width.isFinite, height.isFinite, nativeScale.isFinite,
              width > 0, height > 0, nativeScale > 0 else { return nil }
        let resolved = preset == .automatic ? defaultPreset : preset
        let requestedScale: Double
        switch resolved {
        case .low: requestedScale = 1
        case .medium: requestedScale = 1.5
        case .high: requestedScale = 2
        case .custom: requestedScale = Double(clampedMaximumEdge(maximumEdge)) / max(width, height)
        case .native, .automatic: requestedScale = nativeScale
        }
        // Avoid supersampling beyond the physical screen and bound allocations even for corrupt preferences.
        let scale = min(requestedScale, nativeScale, Double(customRange.upperBound) / max(width, height))
        guard scale.isFinite, scale > 0 else { return nil }
        return Surface(width: max(1, Int((width * scale).rounded())),
                       height: max(1, Int((height * scale).rounded())), scale: scale)
    }
}
