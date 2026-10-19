// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import Metal

@main
enum MetalCropTests {
    static func main() throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            fatalError("Metal device required for renderer crop verification")
        }
        let root = CommandLine.arguments[1]
        let presenter = try String(contentsOfFile: root + "/src/app/Husk/HuskMetalPresenter.swift", encoding: .utf8)
        let shaderStart = presenter.range(of: "let source = \"\"\"")!.upperBound
        let shaderEnd = presenter.range(of: "\"\"\"", range: shaderStart..<presenter.endIndex)!.lowerBound
        let gpuLibrary = try device.makeLibrary(source: String(presenter[shaderStart..<shaderEnd]), options: nil)
        let softwareSource = try String(contentsOfFile: root + "/src/app/Husk/Shaders.metal", encoding: .utf8)
        let softwareLibrary = try device.makeLibrary(source: softwareSource, options: nil)
        func pipeline(_ library: MTLLibrary) throws -> MTLRenderPipelineState {
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = library.makeFunction(name: "husk_vertex")
            desc.fragmentFunction = library.makeFunction(name: "husk_fragment")
            desc.colorAttachments[0].pixelFormat = .rgba8Unorm
            return try device.makeRenderPipelineState(descriptor: desc)
        }
        let gpu = try pipeline(gpuLibrary), software = try pipeline(softwareLibrary)
        func texture(_ w: Int, _ h: Int) -> MTLTexture {
            let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: w, height: h, mipmapped: false)
            desc.storageMode = .shared
            desc.usage = [.shaderRead, .renderTarget]
            return device.makeTexture(descriptor: desc)!
        }
        let samplerDesc = MTLSamplerDescriptor()
        samplerDesc.minFilter = .linear; samplerDesc.magFilter = .linear
        samplerDesc.sAddressMode = .clampToEdge; samplerDesc.tAddressMode = .clampToEdge
        let sampler = device.makeSamplerState(descriptor: samplerDesc)!
        let crop = RuntimeDisplayGeometry.Crop(left: 4.0 / 64, top: 6.0 / 48, right: 60.0 / 64, bottom: 42.0 / 48)

        for useSoftware in [false, true] {
            for rotated in (useSoftware ? [false] : [false, true]) {
                for flip in (useSoftware ? [false] : [false, true]) {
                    let geometry = RuntimeDisplayGeometry(width: 64, height: 48, rotated: rotated, crop: crop)
                    let w = Int(geometry.effectiveWidth), h = Int(geometry.effectiveHeight)
                    let source = texture(64, 48), output = texture(w, h)
                    var pixels = [UInt8](repeating: 0, count: 64 * 48 * 4)
                    for y in 0..<48 { for x in 0..<64 {
                        let storageY = flip ? 47 - y : y
                        let index = (storageY * 64 + x) * 4
                        pixels[index] = UInt8(x * 4); pixels[index + 1] = UInt8(y * 5)
                        pixels[index + 2] = 200; pixels[index + 3] = 255
                    } }
                    pixels.withUnsafeBytes { source.replace(region: MTLRegionMake2D(0, 0, 64, 48), mipmapLevel: 0,
                                                             withBytes: $0.baseAddress!, bytesPerRow: 64 * 4) }
                    let pass = MTLRenderPassDescriptor()
                    pass.colorAttachments[0].texture = output
                    pass.colorAttachments[0].loadAction = .clear
                    pass.colorAttachments[0].storeAction = .store
                    let command = queue.makeCommandBuffer()!
                    let encoder = command.makeRenderCommandEncoder(descriptor: pass)!
                    encoder.setRenderPipelineState(useSoftware ? software : gpu)
                    encoder.setFragmentTexture(source, index: 0)
                    if useSoftware {
                        var fit = SIMD2<Float>(1, 1)
                        encoder.setViewport(MTLViewport(originX: -4, originY: -6, width: 64, height: 48, znear: 0, zfar: 1))
                        encoder.setScissorRect(MTLScissorRect(x: 0, y: 0, width: w, height: h))
                        encoder.setVertexBytes(&fit, length: MemoryLayout<SIMD2<Float>>.size, index: 0)
                        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
                    } else {
                        var params = (flip: Float(flip ? 1 : 0), rotate: Float(rotated ? 1 : 0),
                                      sx: Float(1), sy: Float(1), left: Float(crop.left), top: Float(crop.top),
                                      width: Float(crop.width), height: Float(crop.height))
                        encoder.setVertexBytes(&params, length: MemoryLayout<Float>.size * 8, index: 0)
                        encoder.setFragmentSamplerState(sampler, index: 0)
                        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
                    }
                    encoder.endEncoding(); command.commit(); command.waitUntilCompleted()
                    precondition(command.status == .completed, "Metal rendering failed: \(String(describing: command.error))")
                    var rendered = [UInt8](repeating: 0, count: w * h * 4)
                    rendered.withUnsafeMutableBytes { output.getBytes($0.baseAddress!, bytesPerRow: w * 4,
                                                                      from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0) }
                    for y in 0..<h { for x in 0..<w {
                        let point = geometry.normalizedPoint(x: Double(x) + 0.5, y: Double(y) + 0.5,
                                                             viewWidth: Double(w), viewHeight: Double(h))!
                        let expected = RuntimeDisplayGeometry.pixels(point, width: 64, height: 48)!
                        let offset = (y * w + x) * 4
                        precondition(abs(Int(rendered[offset]) - Int(expected.0) * 4) <= 1
                                     && abs(Int(rendered[offset + 1]) - Int(expected.1) * 5) <= 1,
                            "Render/input mismatch at \(x),\(y); software=\(useSoftware) rotate=\(rotated) flip=\(flip)")
                    } }
                }
            }
        }
        print("Metal crop pixels match touch geometry: GPU flip/rotation and software viewport")
    }
}
