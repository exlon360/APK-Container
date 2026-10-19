// SPDX-License-Identifier: GPL-2.0-or-later
import Metal
import QuartzCore
import simd

/// Draws the guest's scanout straight from its Metal texture.
///
/// The GL path this replaces was correct code against the wrong object.
/// virglrenderer runs on ANGLE over Metal, and the GL texture id it reports for
/// each scanout belongs to its own context: attaching it to a framebuffer of
/// ours looks fine, and every `glBlitFramebuffer` from it then raises
/// GL_INVALID_FRAMEBUFFER_OPERATION and writes nothing. The log said so plainly
/// once it was asked -- Android drawing at 42 fps, both framebuffers uniformly
/// black, the same error on every frame, and `native=METAL` on all 545
/// scanouts. The pixels were never in the GL texture.
///
/// They are in the `MTLTexture` that this fork of QEMU carries beside the GL id.
/// UTM's own display reaches for that handle first and treats GL as the
/// fallback, which in hindsight was the whole answer written down in advance.
///
/// So this takes the texture and draws it into the same CAMetalLayer, with no
/// GL involved. ANGLE keeps its window surface on that layer for virgl's sake,
/// but nothing ever swaps it, so the two do not fight over drawables.
final class HuskMetalPresenter {
    nonisolated(unsafe) static let shared = HuskMetalPresenter()

    /// The layer to present into. Set once the view has one; read on QEMU's
    /// thread, hence the lock around it and everything built from it.
    private var layer: CAMetalLayer?
    private var device: MTLDevice?
    private var queue: MTLCommandQueue?
    private var pipeline: MTLRenderPipelineState?
    private var sampler: MTLSamplerState?
    private let lock = NSLock()
    private var complained = false
    private var presented: UInt64 = 0
    private let geometryLock = NSLock()
    private var lastGeometry: RuntimeDisplayGeometry?

    var displayGeometry: RuntimeDisplayGeometry? {
        geometryLock.lock()
        defer { geometryLock.unlock() }
        return lastGeometry
    }

    /// Whether the guest's picture needs a quarter turn to match the screen.
    /// Set by HuskGLView when the device orientation changes, and read on
    /// QEMU's thread, so it goes through the same lock as everything else.
    private var rotated = false

    func setRotated(_ on: Bool) {
        lock.lock()
        rotated = on
        lock.unlock()
    }

    func attach(layer: CAMetalLayer) {
        lock.lock()
        self.layer = layer
        lock.unlock()
    }

    /// Build the pipeline against the texture's own device.
    ///
    /// Not against `MTLCreateSystemDefaultDevice()`: a texture can only be
    /// sampled by the device that owns it, and ANGLE picked the device here,
    /// not us. On a single-GPU phone these are the same object, but relying on
    /// that would be relying on a coincidence.
    private func prepare(for texture: MTLTexture, _ layer: CAMetalLayer) -> Bool {
        if pipeline != nil, device === texture.device { return true }

        let dev = texture.device
        device = dev
        layer.device = dev
        queue = dev.makeCommandQueue()

        let source = """
        #include <metal_stdlib>
        using namespace metal;

        struct VOut { float4 pos [[position]]; float2 uv; };

        struct Params { float flip; float rotate; float2 scale; float4 crop; };

        vertex VOut husk_vertex(uint vid [[vertex_id]],
                                constant Params &p [[buffer(0)]]) {
            float flip = p.flip;
            // A full-screen triangle strip, in clip space, scaled to keep the
            // guest's aspect. Drawing edge to edge is what made a 360x800 panel
            // look stretched the moment the screen was not that shape.
            const float2 corners[4] = { float2(-1, -1), float2(1, -1),
                                        float2(-1,  1), float2(1,  1) };
            VOut o;
            o.pos = float4(corners[vid] * p.scale, 0, 1);
            float2 uv = corners[vid] * 0.5 + 0.5;
            uv.y = 1.0 - uv.y; // View coordinates start at the top left.
            if (p.rotate > 0.5) uv = float2(1.0 - uv.y, uv.x);
            // Crop in physical display coordinates, exactly as touch mapping
            // does. A texture storage flip comes last, after the physical crop.
            uv = p.crop.xy + uv * p.crop.zw;
            if (flip > 0.5) uv.y = 1.0 - uv.y;
            o.uv = uv;
            return o;
        }

        fragment float4 husk_fragment(VOut in [[stage_in]],
                                      texture2d<float> tex [[texture(0)]],
                                      sampler smp [[sampler(0)]]) {
            // Alpha forced opaque. Android's scanout is commonly B8G8R8X8,
            // where the fourth byte is ignored by definition and zero in
            // practice, and Core Animation would blend the frame away.
            return float4(tex.sample(smp, in.uv).rgb, 1.0);
        }
        """

        do {
            let library = try dev.makeLibrary(source: source, options: nil)
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = library.makeFunction(name: "husk_vertex")
            desc.fragmentFunction = library.makeFunction(name: "husk_fragment")
            desc.colorAttachments[0].pixelFormat = layer.pixelFormat
            pipeline = try dev.makeRenderPipelineState(descriptor: desc)
        } catch {
            HuskLog.log("gl", "metal: could not build the present pipeline: \(error)")
            pipeline = nil
            return false
        }

        let sd = MTLSamplerDescriptor()
        sd.minFilter = .linear
        sd.magFilter = .linear
        sd.sAddressMode = .clampToEdge
        sd.tAddressMode = .clampToEdge
        sampler = dev.makeSamplerState(descriptor: sd)

        HuskLog.log("gl", "metal: presenting on \(dev.name), "
                        + "guest \(texture.width)x\(texture.height) -> layer "
                        + "\(Int(layer.drawableSize.width))x\(Int(layer.drawableSize.height))")
        return sampler != nil
    }

    /// Called from QEMU's thread, once per guest frame.
    func present(texture: MTLTexture, flip: Bool) {
        lock.lock()
        defer { lock.unlock() }

        guard let layer else { return }
        guard prepare(for: texture, layer),
              let queue, let pipeline, let sampler else { return }

        // nextDrawable returns nil when the pool is exhausted -- a dropped
        // frame, not an error, and the guest will send another.
        guard let drawable = layer.nextDrawable() else { return }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        pass.colorAttachments[0].storeAction = .store

        guard let buffer = queue.makeCommandBuffer(),
              let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }

        let frameRotated = rotated
        let geometry = AndroidSystemBars.shared.crop(width: texture.width, height: texture.height).map {
            RuntimeDisplayGeometry(width: Double(texture.width), height: Double(texture.height),
                                   rotated: frameRotated, crop: $0)
        }
        if let geometry {
            // Letterbox rather than stretch. The guest occupies effW x effH on
            // screen once any turn is applied; whichever axis runs out first sets
            // the scale, and the other is inset.
            let effW = Float(geometry.effectiveWidth)
            let effH = Float(geometry.effectiveHeight)
            let layerW = Float(layer.drawableSize.width)
            let layerH = Float(layer.drawableSize.height)
            var sx: Float = 1, sy: Float = 1
            if effW > 0, effH > 0, layerW > 0, layerH > 0 {
                let guestAspect = effW / effH
                let layerAspect = layerW / layerH
                if guestAspect > layerAspect { sy = layerAspect / guestAspect }
                else                         { sx = guestAspect / layerAspect }
            }

            var params = (flip: Float(flip ? 1 : 0), rotate: Float(frameRotated ? 1 : 0),
                          sx: sx, sy: sy, left: Float(geometry.crop.left), top: Float(geometry.crop.top),
                          width: Float(geometry.crop.width), height: Float(geometry.crop.height))
            encoder.setRenderPipelineState(pipeline)
            encoder.setVertexBytes(&params, length: MemoryLayout<Float>.size * 8, index: 0)
            encoder.setFragmentTexture(texture, index: 0)
            encoder.setFragmentSamplerState(sampler, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
        // Unknown or mismatched insets draw only the black clear, never a raw
        // Android frame while the bridge obtains trustworthy geometry.
        encoder.endEncoding()

        // No manual retain of `texture`: a command buffer keeps every resource
        // it references alive until it completes, which is exactly the window
        // in which the GPU reads it.
        buffer.present(drawable)
        buffer.commit()
        geometryLock.lock()
        lastGeometry = geometry
        geometryLock.unlock()

        presented &+= 1
        if presented == 1 || presented % 1800 == 0 {
            HuskLog.log("gl", "metal: presented \(presented) frames "
                            + "(\(texture.width)x\(texture.height), flip=\(flip))")
        }
    }

    /// Say nothing more than once when something is structurally wrong.
    func complainOnce(_ message: String) {
        lock.lock()
        let first = !complained
        complained = true
        lock.unlock()
        if first { HuskLog.log("gl", "metal: \(message)") }
    }
}

/// The C entry point QEMU calls. No captures, so it can be a plain function
/// pointer; everything it needs hangs off the shared presenter.
private let huskMetalPresent: husk_metal_present_fn = { texture, flip, _, _ in
    guard let texture else { return }
    let mtl = Unmanaged<AnyObject>.fromOpaque(texture).takeUnretainedValue()
    guard let tex = mtl as? MTLTexture else {
        HuskMetalPresenter.shared.complainOnce(
            "the scanout handle is not an MTLTexture; staying on the GL path")
        return
    }
    HuskMetalPresenter.shared.present(texture: tex, flip: flip != 0)
}

func huskInstallMetalPresenter() {
    husk_display_gl_set_metal_presenter(huskMetalPresent)
}
