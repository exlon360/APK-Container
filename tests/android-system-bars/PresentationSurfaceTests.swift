// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import QuartzCore
import Metal

@main
enum PresentationSurfaceTests {
    static func main() {
        let backing = CAMetalLayer()
        backing.device = MTLCreateSystemDefaultDevice()
        backing.pixelFormat = .bgra8Unorm
        backing.framebufferOnly = false
        backing.bounds = CGRect(x: 0, y: 0, width: 640, height: 480)
        let surface = RuntimePresentationSurface(backing: backing)
        precondition(surface.backing === backing)
        precondition(surface.layer !== backing && surface.layer.superlayer === backing)
        precondition(surface.layer.isOpaque && surface.layer.backgroundColor?.alpha == 1)
        precondition(surface.layer.backgroundColor?.components?.first == 0)
        precondition(surface.layer.frame == backing.bounds, "Black coverage exists at construction")
        precondition(surface.layer.framebufferOnly && !backing.framebufferOnly)
        precondition(surface.layer.pixelFormat == backing.pixelFormat)
        for (bounds, scale) in [(CGRect(x: 0, y: 0, width: 1376, height: 1032), CGFloat(2)),
                                (CGRect(x: 0, y: 0, width: 390, height: 844), CGFloat(3))] {
            surface.resize(bounds: bounds, scale: scale)
            precondition(surface.layer.frame == bounds)
            precondition(surface.layer.contentsScale == scale && backing.contentsScale == scale)
            precondition(surface.layer.drawableSize == CGSize(width: bounds.width * scale, height: bounds.height * scale))
            precondition(surface.layer.drawableSize == backing.drawableSize)
            precondition(backing.sublayers?.count == 1, "Resizing must not replace ANGLE's stable backing or stack covers")
        }
        print("Presentation surface tests passed: opaque independent layer, fixed backing, synchronized resize")
    }
}
