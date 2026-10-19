// SPDX-License-Identifier: GPL-2.0-or-later
import QuartzCore
import Metal

/// Keep ANGLE's stable backing surface underneath an opaque presentation layer.
/// Only the verified, cropped Metal presenter receives the upper layer; QEMU's
/// raw EGL fallback can continue rendering without ever becoming visible.
final class RuntimePresentationSurface {
    let backing: CAMetalLayer
    let layer: CAMetalLayer

    init(backing: CAMetalLayer) {
        self.backing = backing
        let layer = CAMetalLayer()
        layer.device = backing.device
        layer.pixelFormat = backing.pixelFormat
        layer.framebufferOnly = true
        layer.isOpaque = true
        layer.backgroundColor = CGColor(gray: 0, alpha: 1)
        layer.frame = backing.bounds
        layer.zPosition = 1
        backing.addSublayer(layer)
        self.layer = layer
    }

    /// Size both surfaces in one transaction, with no animated gap that could
    /// reveal the underlying guest during rotation or iPad window resizing.
    func resize(bounds: CGRect, scale: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let pixels = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        backing.contentsScale = scale
        backing.drawableSize = pixels
        layer.frame = bounds
        layer.contentsScale = scale
        layer.drawableSize = pixels
        CATransaction.commit()
    }
}
