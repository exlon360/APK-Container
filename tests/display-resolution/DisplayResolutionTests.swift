// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

@main
struct DisplayResolutionTests {
    static func main() throws {
        func surface(_ width: Double, _ height: Double, _ scale: Double,
                     _ preset: APKDisplayResolution.Preset = .native, edge: Int = 1920,
                     fallback: APKDisplayResolution.Preset = .native) -> APKDisplayResolution.Surface {
            APKDisplayResolution.surface(width: width, height: height, nativeScale: scale,
                                         preset: preset, maximumEdge: edge, defaultPreset: fallback)!
        }
        let phone = surface(390, 844, 3)
        precondition(phone.width == 1170 && phone.height == 2532 && phone.scale == 3)
        let tablet = surface(1032, 1376, 2)
        precondition(tablet.width == 2064 && tablet.height == 2752 && tablet.scale == 2)
        let landscape = surface(1376, 1032, 2)
        precondition(landscape.width == tablet.height && landscape.height == tablet.width)
        let downsampledPhone = surface(414, 736, 1080.0 / 414.0)
        precondition(downsampledPhone.width == 1080 && downsampledPhone.height == 1920)

        precondition(surface(390, 844, 3, .low).scale == 1)
        precondition(surface(390, 844, 3, .medium).scale == 1.5)
        precondition(surface(390, 844, 3, .high).scale == 2)
        precondition(surface(390, 844, 3, .automatic) == phone)
        precondition(surface(390, 844, 3, .automatic, fallback: .low).scale == 1)
        precondition(surface(390, 844, 3, .automatic, fallback: .automatic) == phone)
        precondition(surface(390, 844, 1, .high).scale == 1, "Never supersample beyond the device")

        let custom = surface(390, 844, 3, .custom)
        precondition(custom.width == 887 && custom.height == 1920)
        precondition(surface(390, 844, 3, .custom, edge: Int.max) == phone)
        precondition(surface(390, 844, 3, .custom, edge: Int.min).height == 320)
        precondition(surface(5000, 4000, 3).width == 4096)
        precondition(surface(300, 500, 3).width == 900, "Window uses its own bounds")

        for invalid in [0.0, -1, Double.nan, Double.infinity] {
            precondition(APKDisplayResolution.surface(width: invalid, height: 844, nativeScale: 3, preset: .native) == nil)
            precondition(APKDisplayResolution.surface(width: 390, height: invalid, nativeScale: 3, preset: .native) == nil)
            precondition(APKDisplayResolution.surface(width: 390, height: 844, nativeScale: invalid, preset: .native) == nil)
        }
        // Width, height, touch coordinates and safe areas all use the same density, with only pixel rounding error.
        for width in [320.0, 390, 414, 744, 834, 1032, 1376] {
            for height in [500.0, 736, 844, 1133, 1194, 1376] {
                for preset in APKDisplayResolution.Preset.allCases {
                    let value = surface(width, height, 3, preset)
                    precondition(value.width > 0 && value.height > 0 && value.width <= 4096 && value.height <= 4096)
                    precondition(abs(Double(value.width) - width * value.scale) <= 0.5)
                    precondition(abs(Double(value.height) - height * value.scale) <= 0.5)
                    precondition(value.scale <= 3)
                    if preset == .custom { precondition(max(value.width, value.height) <= 1920) }
                }
            }
        }
        let legacy = try JSONDecoder().decode(APKDisplayResolution.Preset.self, from: Data("\"high\"".utf8))
        precondition(legacy == .high, "Existing per-app preferences remain readable")
        print("Display resolution checks passed (phone, iPad, orientation, presets, custom limits, input density, invalid values).")
    }
}
