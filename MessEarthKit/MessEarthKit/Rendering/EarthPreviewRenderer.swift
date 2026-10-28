import Foundation
import MessEarthKit
import MetalKit
import simd

/// Immutable GPU resources after preparation; buffers/textures are never rewritten.
final class EarthPreparedPreview: @unchecked Sendable
{
    struct Mesh
    {
        let vertices: MTLBuffer
        let indices: MTLBuffer
        let indexCount: Int
        let material: EarthMaterial
        let texture: MTLTexture
        let sampler: MTLSamplerState
        let center: SIMD3<Float>
    }

    let meshes: [Mesh]
    let bounds: EarthBounds

    init(meshes: [Mesh], bounds: EarthBounds)
    {
        self.meshes = meshes
        self.bounds = bounds
    }
}

/// Metal construction/preparation is worker-owned. Only the small scene/camera
/// mailbox is mutable and every access to it is protected by `lock`.
final class EarthPreviewRenderer: NSObject, MTKViewDelegate, @unchecked Sendable
{
    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let opaqueDepth: MTLDepthStencilState
    private let blendedDepth: MTLDepthStencilState
    private let whiteTexture: MTLTexture
    private let lock = NSLock()
    private var scene: EarthPreparedPreview?
    private var yaw: Float = .pi / 5
    private var pitch: Float = .pi / 4
    private var distance: Float = 10

    init(device: MTLDevice) throws
    {
        guard let queue = device.makeCommandQueue(),
              let library = device.makeDefaultLibrary(),
              let vertex = library.makeFunction(name: "earthPreviewVertex"),
              let fragment = library.makeFunction(name: "earthPreviewFragment")
        else { throw EarthImportError.unsupportedContent("The Metal preview is unavailable.") }
        self.device = device
        self.queue = queue
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm_srgb
        descriptor.colorAttachments[0].isBlendingEnabled = true
        descriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
        descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        descriptor.depthAttachmentPixelFormat = .depth32Float
        pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        let depth = MTLDepthStencilDescriptor()
        depth.depthCompareFunction = .lessEqual
        depth.isDepthWriteEnabled = true
        guard let opaque = device.makeDepthStencilState(descriptor: depth)
        else { throw EarthImportError.unsupportedContent("Depth testing is unavailable.") }
        opaqueDepth = opaque
        depth.isDepthWriteEnabled = false
        guard let blended = device.makeDepthStencilState(descriptor: depth)
        else { throw EarthImportError.unsupportedContent("Depth testing is unavailable.") }
        blendedDepth = blended
        let whiteDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm_srgb, width: 1, height: 1, mipmapped: false)
        whiteDescriptor.storageMode = .shared
        whiteDescriptor.usage = .shaderRead
        guard let white = device.makeTexture(descriptor: whiteDescriptor)
        else { throw EarthImportError.limitExceeded("Cannot allocate the constant material texture.") }
        var pixel: [UInt8] = [255, 255, 255, 255]
        pixel.withUnsafeMutableBytes { white.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: 4) }
        whiteTexture = white
        super.init()
    }

    func prepare(capture: EarthCapture) throws -> EarthPreparedPreview
    {
        let loader = MTKTextureLoader(device: device)
        var textures: [Int: (MTLTexture, MTLSamplerState)] = [:]
        for (index, material) in capture.materials.enumerated()
        {
            try Task.checkCancellation()
            let sampler = MTLSamplerDescriptor()
            let texture: MTLTexture
            if let source = material.baseColorTexture
            {
                texture = try loader.newTexture(data: source.encodedImage, options: [.SRGB: true, .origin: MTKTextureLoader.Origin.topLeft.rawValue, .generateMipmaps: source.mipmapFilter != .none])
                sampler.sAddressMode = addressMode(mode: source.wrapS)
                sampler.tAddressMode = addressMode(mode: source.wrapT)
                sampler.magFilter = source.usesNearestMagnification ? .nearest : .linear
                sampler.minFilter = source.usesNearestMinification ? .nearest : .linear
                switch source.mipmapFilter
                {
                    case .none: sampler.mipFilter = .notMipmapped
                    case .nearest: sampler.mipFilter = .nearest
                    case .linear: sampler.mipFilter = .linear
                }
            }
            else
            {
                texture = whiteTexture
            }
            guard let state = device.makeSamplerState(descriptor: sampler)
            else { throw EarthImportError.limitExceeded("Cannot allocate texture sampling state.") }
            textures[index] = (texture, state)
        }
        var meshes: [EarthPreparedPreview.Mesh] = []
        for mesh in capture.meshes
        {
            try Task.checkCancellation()
            let vertices = mesh.vertices.withUnsafeBytes
            { bytes in
                bytes.baseAddress.flatMap { device.makeBuffer(bytes: $0, length: bytes.count, options: .storageModeShared) }
            }
            let indices = mesh.triangleIndices.withUnsafeBytes
            { bytes in
                bytes.baseAddress.flatMap { device.makeBuffer(bytes: $0, length: bytes.count, options: .storageModeShared) }
            }
            guard let vertices, let indices, let texture = textures[mesh.materialIndex]
            else { throw EarthImportError.limitExceeded("Cannot allocate preview geometry.") }
            var minimum = mesh.vertices[0].position
            var maximum = minimum
            for vertex in mesh.vertices
            {
                minimum = simd_min(minimum, vertex.position)
                maximum = simd_max(maximum, vertex.position)
            }
            meshes.append(.init(vertices: vertices, indices: indices, indexCount: mesh.triangleIndices.count, material: capture.materials[mesh.materialIndex], texture: texture.0, sampler: texture.1, center: (minimum + maximum) / 2))
        }
        return EarthPreparedPreview(meshes: meshes, bounds: capture.bounds)
    }

    func publish(scene: EarthPreparedPreview)
    {
        lock.lock()
        self.scene = scene
        distance = max(1, simd_length(scene.bounds.dimensions) * 1.4)
        yaw = .pi / 5
        pitch = .pi / 4
        lock.unlock()
    }

    func resetCamera()
    {
        lock.lock()
        if let scene { distance = max(1, simd_length(scene.bounds.dimensions) * 1.4) }
        yaw = .pi / 5
        pitch = .pi / 4
        lock.unlock()
    }

    func orbit(horizontal: Float, vertical: Float)
    {
        lock.lock()
        yaw += horizontal * 0.008
        pitch = min(1.45, max(-1.45, pitch + vertical * 0.008))
        lock.unlock()
    }

    func zoom(delta: Float)
    {
        lock.lock()
        if let scene
        {
            let radius = max(0.1, simd_length(scene.bounds.dimensions))
            distance = min(radius * 50, max(radius * 0.05, distance * exp(delta * 0.04)))
        }
        lock.unlock()
    }

    func draw(in view: MTKView)
    {
        lock.lock()
        let snapshot = (scene, yaw, pitch, distance)
        lock.unlock()
        guard let scene = snapshot.0, view.drawableSize.width > 0, view.drawableSize.height > 0,
              let descriptor = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let command = queue.makeCommandBuffer(), let encoder = command.makeRenderCommandEncoder(descriptor: descriptor)
        else { return }
        let center = scene.bounds.center
        let eye = center + SIMD3(cos(snapshot.2) * sin(snapshot.1), sin(snapshot.2), cos(snapshot.2) * cos(snapshot.1)) * snapshot.3
        let back = simd_normalize(eye - center)
        let right = simd_normalize(simd_cross(SIMD3<Float>(0, 1, 0), back))
        let up = simd_cross(back, right)
        let camera = simd_float4x4(columns: (
            SIMD4(right.x, up.x, back.x, 0),
            SIMD4(right.y, up.y, back.y, 0),
            SIMD4(right.z, up.z, back.z, 0),
            SIMD4(-simd_dot(right, eye), -simd_dot(up, eye), -simd_dot(back, eye), 1)
        ))
        let near = max(0.001, snapshot.3 / 1000)
        let far = max(near + 1, snapshot.3 + simd_length(scene.bounds.dimensions) * 10)
        let verticalScale = 1 / tan(Float.pi / 8)
        let horizontalScale = verticalScale / Float(view.drawableSize.width / view.drawableSize.height)
        let projection = simd_float4x4(columns: (SIMD4(horizontalScale, 0, 0, 0), SIMD4(0, verticalScale, 0, 0), SIMD4(0, 0, far / (near - far), -1), SIMD4(0, 0, near * far / (near - far), 0)))
        var viewProjection = projection * camera
        encoder.setRenderPipelineState(pipeline)
        encoder.setFrontFacing(.counterClockwise)
        encoder.setVertexBytes(&viewProjection, length: MemoryLayout<simd_float4x4>.stride, index: 1)
        let orderedMeshes = scene.meshes.sorted
        { first, second in
            if first.material.alphaMode != .blend, second.material.alphaMode == .blend { return true }
            if first.material.alphaMode == .blend, second.material.alphaMode != .blend { return false }
            return simd_distance_squared(first.center, eye) > simd_distance_squared(second.center, eye)
        }
        for mesh in orderedMeshes
        {
            let material = mesh.material
            encoder.setCullMode(material.isDoubleSided ? .none : .back)
            encoder.setDepthStencilState(material.alphaMode == .blend ? blendedDepth : opaqueDepth)
            var surface = SurfaceUniforms(baseColor: material.baseColor, options: SIMD4(material.isUnlit ? 1 : 0, material.alphaMode == .mask ? material.alphaCutoff : -1, material.alphaMode != .blend ? 1 : 0, 0))
            encoder.setVertexBuffer(mesh.vertices, offset: 0, index: 0)
            encoder.setFragmentBytes(&surface, length: MemoryLayout<SurfaceUniforms>.stride, index: 0)
            encoder.setFragmentTexture(mesh.texture, index: 0)
            encoder.setFragmentSamplerState(mesh.sampler, index: 0)
            encoder.drawIndexedPrimitives(type: .triangle, indexCount: mesh.indexCount, indexType: .uint32, indexBuffer: mesh.indices, indexBufferOffset: 0)
        }
        encoder.endEncoding()
        command.present(drawable)
        command.commit()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    private func addressMode(mode: EarthTextureWrap) -> MTLSamplerAddressMode
    {
        switch mode
        {
            case .repeatTexture: .repeat
            case .mirroredRepeat: .mirrorRepeat
            case .clampToEdge: .clampToEdge
        }
    }
}

private struct SurfaceUniforms
{
    var baseColor: SIMD4<Float>
    var options: SIMD4<Float>
}
