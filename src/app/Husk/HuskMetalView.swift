// SPDX-License-Identifier: GPL-2.0-or-later
import MetalKit
import SwiftUI
import os

/// Blits the guest framebuffer to the screen and forwards touches back into it.
///
/// The guest surface is pixman x8r8g8b8, which is byte-for-byte Metal's
/// .bgra8Unorm, so there is no pixel conversion anywhere in this path — the
/// bytes QEMU's virtio-gpu wrote go straight into a texture.
final class HuskMetalView: MTKView {
    private let log = Logger(subsystem: "com.husk.app", category: "display")
    private var commandQueue: MTLCommandQueue?
    private var pipelineState: MTLRenderPipelineState?
    private var texture: MTLTexture?
    private var textureGeneration: UInt64 = .max
    private var lastSequence: UInt64 = .max

    /// Guest surface size, for mapping touches back into guest coordinates.
    private var guestWidth: Int32 = 0
    private var guestHeight: Int32 = 0
    private var pointer = RuntimeDisplayGeometry.Pointer()
    private var lastGeometry: RuntimeDisplayGeometry?

    init() {
        let dev = MTLCreateSystemDefaultDevice()
        super.init(frame: .zero, device: dev)
        self.commandQueue = dev?.makeCommandQueue()
        self.colorPixelFormat = .bgra8Unorm
        self.framebufferOnly = false
        self.isPaused = false
        self.enableSetNeedsDisplay = false
        self.preferredFramesPerSecond = 60
        self.isMultipleTouchEnabled = false
        self.delegate = self
        self.clearColor = MTLClearColorMake(0, 0, 0, 1)
        buildPipeline()
    }

    private func buildPipeline() {
        guard let device, let library = device.makeDefaultLibrary() else {
            log.error("no Metal default library; is Shaders.metal in the target?")
            return
        }
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = library.makeFunction(name: "husk_vertex")
        desc.fragmentFunction = library.makeFunction(name: "husk_fragment")
        desc.colorAttachments[0].pixelFormat = .bgra8Unorm
        do {
            pipelineState = try device.makeRenderPipelineState(descriptor: desc)
        } catch {
            log.error("pipeline creation failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    required init(coder: NSCoder) { fatalError("not supported") }

    // MARK: - Touch -> guest

    /// Map a view-space point into guest pixels, honouring the aspect-fit letterbox
    /// that `draw(in:)` produces.
    private func guestPoint(from p: CGPoint) -> RuntimeDisplayGeometry.Point? {
        guard let geometry = lastGeometry,
              AndroidSystemBars.shared.crop(width: Int(geometry.width), height: Int(geometry.height)) == geometry.crop else { return nil }
        return geometry.normalizedPoint(x: Double(p.x), y: Double(p.y),
                             viewWidth: Double(bounds.width), viewHeight: Double(bounds.height))
    }

    private func send(_ touch: UITouch, down: Bool) {
        guard QemuRunner.qemuReady,
              let point = pointer.update(point: guestPoint(from: touch.location(in: self)), down: down) else { return }
        var width: Int32 = 0, height: Int32 = 0
        husk_display_guest_size(&width, &height)
        guard let (x, y) = RuntimeDisplayGeometry.pixels(point, width: width, height: height) else { return }
        husk_display_send_pointer(x, y, down)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        if let t = touches.first { send(t, down: true) }
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        if let t = touches.first { send(t, down: true) }
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        if let t = touches.first { send(t, down: false) }
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        if let t = touches.first { send(t, down: false) }
    }
}

extension HuskMetalView: MTKViewDelegate {
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let device,
              let commandQueue,
              let drawable = currentDrawable,
              let pass = currentRenderPassDescriptor else { return }

        let seq = husk_display_sequence()

        // No need to poke QEMU for a redraw here: register_displaychangelistener()
        // calls gui_setup_refresh(), which drives dpy_refresh on QEMU's own timer
        // for any listener that provides one. Calling husk_display_request_update()
        // per frame would take the BQL 60 times a second from the UI thread and
        // contend with the emulator for nothing.
        var info = HuskFrameInfo()
        guard husk_display_lock_frame(&info) else { return }

        if info.generation != textureGeneration || texture == nil {
            let desc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm,
                width: Int(info.width),
                height: Int(info.height),
                mipmapped: false)
            desc.usage = [.shaderRead]
            texture = device.makeTexture(descriptor: desc)
            textureGeneration = info.generation
            guestWidth = info.width
            guestHeight = info.height
            lastSequence = .max
            log.info("guest surface \(info.width)x\(info.height) stride=\(info.stride) bpp=\(info.bpp)")
        }

        if seq != lastSequence, let texture, let pixels = info.pixels {
            texture.replace(
                region: MTLRegionMake2D(0, 0, Int(info.width), Int(info.height)),
                mipmapLevel: 0,
                withBytes: pixels,
                bytesPerRow: Int(info.stride))
            lastSequence = seq
        }
        husk_display_unlock_frame()

        guard let texture,
              let pipeline = pipelineState,
              let buffer = commandQueue.makeCommandBuffer(),
              let enc = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }

        let geometry = AndroidSystemBars.shared.crop(width: texture.width, height: texture.height).map {
            RuntimeDisplayGeometry(width: Double(texture.width), height: Double(texture.height),
                                   rotated: false, crop: $0)
        }
        if let geometry {
            // The bundled shader samples the full texture. Place that quad in an
            // oversized viewport, then scissor to the reported app area; this crops
            // with no CPU pixel copy or replacement precompiled Metal library.
            let dw = Double(drawable.texture.width), dh = Double(drawable.texture.height)
            let gw = Double(texture.width), gh = Double(texture.height)
            let scale = min(dw / geometry.contentWidth, dh / geometry.contentHeight)
            let imageX = (dw - geometry.contentWidth * scale) / 2
            let imageY = (dh - geometry.contentHeight * scale) / 2
            let x = max(0, Int(ceil(imageX))), y = max(0, Int(ceil(imageY)))
            let right = min(Int(dw), Int(floor(imageX + geometry.contentWidth * scale)))
            let bottom = min(Int(dh), Int(floor(imageY + geometry.contentHeight * scale)))
            var fit = SIMD2<Float>(1, 1)

            enc.setRenderPipelineState(pipeline)
            enc.setViewport(MTLViewport(originX: imageX - geometry.crop.left * gw * scale,
                                        originY: imageY - geometry.crop.top * gh * scale,
                                        width: gw * scale, height: gh * scale, znear: 0, zfar: 1))
            enc.setScissorRect(MTLScissorRect(x: x, y: y, width: max(0, right - x), height: max(0, bottom - y)))
            enc.setVertexBytes(&fit, length: MemoryLayout<SIMD2<Float>>.size, index: 0)
            enc.setFragmentTexture(texture, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        }
        enc.endEncoding()
        buffer.present(drawable)
        buffer.commit()
        lastGeometry = geometry
    }
}

/// SwiftUI wrapper.
struct HuskDisplay: UIViewRepresentable {
    func makeUIView(context: Context) -> HuskMetalView { HuskMetalView() }
    func updateUIView(_ uiView: HuskMetalView, context: Context) {}
}
