// SPDX-License-Identifier: GPL-2.0-or-later
// Rebuild the original, vector-drawn APK Container icon and its appearance variants.
import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
let variants: [(String, String, Bool, Bool)] = [
    ("AppIcon.appiconset/Icon-Default.png", "icon-default.png", false, false),
    ("AppIcon.appiconset/Icon-Dark.png", "icon-dark.png", true, false),
    ("AppIcon.appiconset/Icon-Tinted.png", "icon-tinted.png", true, true),
    ("AppIconClearLight.appiconset/Icon-1024.png", "icon-clearlight.png", false, true),
    ("AppIconClearDark.appiconset/Icon-1024.png", "icon-cleardark.png", true, false),
    ("AppIconTintedLight.appiconset/Icon-1024.png", "icon-tintedlight.png", false, true),
    ("AppIconTintedDark.appiconset/Icon-1024.png", "icon-tinteddark.png", true, true),
]
for (asset, preview, dark, monochrome) in variants {
    let context = CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8,
                            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    let bg = dark ? NSColor(calibratedRed: 0.055, green: 0.09, blue: 0.16, alpha: 1)
                  : NSColor(calibratedRed: 0.16, green: 0.37, blue: 0.91, alpha: 1)
    (monochrome ? NSColor(white: dark ? 0.09 : 0.78, alpha: 1) : bg).setFill()
    NSBezierPath(rect: NSRect(x: 0, y: 0, width: 1024, height: 1024)).fill()
    for (x, y, width, height, alpha) in [(228.0, 280.0, 568.0, 568.0, 0.18), (190, 240, 644, 568, 0.32)] {
        NSColor.white.withAlphaComponent(alpha).setFill()
        NSBezierPath(roundedRect: NSRect(x: x, y: y, width: width, height: height), xRadius: 100, yRadius: 100).fill()
    }
    NSColor.white.setFill()
    NSBezierPath(roundedRect: NSRect(x: 152, y: 180, width: 720, height: 568), xRadius: 116, yRadius: 116).fill()
    let ink = monochrome ? NSColor(white: 0.2, alpha: 1) : NSColor(calibratedRed: 0.10, green: 0.48, blue: 0.40, alpha: 1)
    ink.setFill()
    NSBezierPath(roundedRect: NSRect(x: 418, y: 622, width: 188, height: 24), xRadius: 12, yRadius: 12).fill()
    let text = "APK" as NSString
    let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 176, weight: .bold), .foregroundColor: ink]
    let size = text.size(withAttributes: attributes)
    text.draw(at: NSPoint(x: (1024-size.width)/2, y: 352), withAttributes: attributes)
    NSGraphicsContext.restoreGraphicsState()
    let bitmap = NSBitmapImageRep(cgImage: context.makeImage()!)
    let data = bitmap.representation(using: .png, properties: [:])!
    try data.write(to: root.appendingPathComponent("src/app/Husk/Assets.xcassets/\(asset)"))
    try data.write(to: root.appendingPathComponent("src/app/Husk/Resources/\(preview)"))
}
