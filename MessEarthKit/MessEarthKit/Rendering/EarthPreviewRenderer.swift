import Foundation
import MessEarthKit
import MetalKit
import simd

/// Metal construction/preparation is worker-owned. Only the small scene/camera
/// mailbox is mutable and every access to it is protected by `lock`.
final class EarthPreviewRenderer: NSObject, MTKViewDelegate, @unchecked Sendable
{
    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let geometryPipeline: MTLRenderPipelineState
    private let opaqueDepth: MTLDepthStencilState
    private let blendedDepth: MTLDepthStencilState
    private let lock = NSLock()
    private var scene: EarthPreparedPreview?
    private var yaw: Float = .pi / 5
    private var pitch: Float = .pi / 4
    private var zoomScale: Float = 1

    init(device: MTLDevice, library suppliedLibrary: MTLLibrary? = nil) throws
    {
        guard let queue = device.makeCommandQueue(),
              let library = suppliedLibrary ?? device.makeDefaultLibrary(),
              let vertex = library.makeFunction(name: "earthPreviewVertex"),
              let fragment = library.makeFunction(name: "earthPreviewFragment"),
              let geometryFragment = library.makeFunction(name: "earthPreviewGeometryFragment")
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
        descriptor.fragmentFunction = geometryFragment
        descriptor.colorAttachments[0].isBlendingEnabled = false
        geometryPipeline = try device.makeRenderPipelineState(descriptor: descriptor)
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
        super.init()
    }

    func prepare(capture: EarthCapture) throws -> EarthPreparedPreview
    {
        try EarthPreviewSceneBuilder(device: device).prepare(capture: capture)
    }

    func publish(scene: EarthPreparedPreview)
    {
        lock.lock()
        self.scene = scene
        zoomScale = 1
        yaw = .pi / 5
        pitch = .pi / 4
        lock.unlock()
    }

    func resetCamera()
    {
        lock.lock()
        zoomScale = 1
        yaw = .pi / 5
        pitch = .pi / 4
        lock.unlock()
    }

    func clearScene()
    {
        lock.lock()
        scene = nil
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
        zoomScale = min(50, max(0.05, zoomScale * exp(delta * 0.04)))
        lock.unlock()
    }

    func draw(in view: MTKView)
    {
        lock.lock()
        let snapshot = (scene, yaw, pitch, zoomScale)
        lock.unlock()
        guard let scene = snapshot.0, view.drawableSize.width > 0, view.drawableSize.height > 0,
              let descriptor = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let command = queue.makeCommandBuffer(), let encoder = command.makeRenderCommandEncoder(descriptor: descriptor)
        else { return }
        let aspect = Float(view.drawableSize.width / view.drawableSize.height)
        let camera = Self.cameraFrame(bounds: scene.bounds, aspect: aspect, yaw: snapshot.1, pitch: snapshot.2, zoomScale: snapshot.3)
        encode(scene: scene, viewProjection: camera.viewProjection, eye: camera.eye, encoder: encoder)
        encoder.endEncoding()
        command.present(drawable)
        command.commit()
    }

    static func cameraFrame(bounds: EarthPreviewBounds, aspect: Float, yaw: Float = .pi / 5, pitch: Float = .pi / 4, zoomScale: Float = 1) -> (viewProjection: simd_float4x4, eye: SIMD3<Float>)
    {
        let center = bounds.center
        let distance = Self.fittingDistance(bounds: bounds, aspect: aspect) * zoomScale
        let eye = center + SIMD3(cos(pitch) * sin(yaw), sin(pitch), cos(pitch) * cos(yaw)) * distance
        let back = simd_normalize(eye - center)
        let right = simd_normalize(simd_cross(SIMD3<Float>(0, 1, 0), back))
        let up = simd_cross(back, right)
        let camera = simd_float4x4(columns: (
            SIMD4(right.x, up.x, back.x, 0),
            SIMD4(right.y, up.y, back.y, 0),
            SIMD4(right.z, up.z, back.z, 0),
            SIMD4(-simd_dot(right, eye), -simd_dot(up, eye), -simd_dot(back, eye), 1)
        ))
        let near = max(0.001, distance / 1000)
        let far = max(near + 1, distance + simd_length(bounds.dimensions) * 10)
        let verticalScale = 1 / tan(Float.pi / 8)
        let horizontalScale = verticalScale / aspect
        let projection = simd_float4x4(columns: (SIMD4(horizontalScale, 0, 0, 0), SIMD4(0, verticalScale, 0, 0), SIMD4(0, 0, far / (near - far), -1), SIMD4(0, 0, near * far / (near - far), 0)))
        return (projection * camera, eye)
    }

    /// Encodes immutable resources into the caller's render pass.
    func encode(scene: EarthPreparedPreview, viewProjection: simd_float4x4, eye: SIMD3<Float>, encoder: MTLRenderCommandEncoder, includesVertexColors: Bool = true)
    {
        var viewProjection = viewProjection
        let textured = scene.displayMode.usesTextures
        let wireframe = scene.displayMode == .wireframe
        encoder.setRenderPipelineState(textured ? pipeline : geometryPipeline)
        encoder.setTriangleFillMode(wireframe ? .lines : .fill)
        encoder.setFrontFacing(.counterClockwise)
        encoder.setVertexBytes(&viewProjection, length: MemoryLayout<simd_float4x4>.stride, index: 1)
        let orderedMeshes = textured ? scene.meshes.sorted
        { first, second in
            if first.material.alphaMode != .blend, second.material.alphaMode == .blend { return true }
            if first.material.alphaMode == .blend, second.material.alphaMode != .blend { return false }
            return simd_distance_squared(first.center, eye) > simd_distance_squared(second.center, eye)
        } : scene.meshes
        for mesh in orderedMeshes
        {
            let material = mesh.material
            encoder.setCullMode(textured && !material.isDoubleSided ? .back : .none)
            encoder.setDepthStencilState(textured && material.alphaMode == .blend ? blendedDepth : opaqueDepth)
            var surface = textured
                ? SurfaceUniforms(baseColor: material.baseColor, options: SIMD4(material.isUnlit ? 1 : 0, material.alphaMode == .mask ? material.alphaCutoff : -1, material.alphaMode != .blend ? 1 : 0, includesVertexColors ? 0 : 1))
                : SurfaceUniforms(baseColor: SIMD4(0.72, 0.78, 0.84, 1), options: SIMD4(0, -1, 1, wireframe ? 1 : 0))
            encoder.setVertexBuffer(mesh.vertices, offset: 0, index: 0)
            encoder.setFragmentBytes(&surface, length: MemoryLayout<SurfaceUniforms>.stride, index: 0)
            if textured
            {
                encoder.setFragmentTexture(mesh.texture, index: 0)
                encoder.setFragmentSamplerState(mesh.sampler, index: 0)
            }
            encoder.drawIndexedPrimitives(type: .triangle, indexCount: mesh.indexCount, indexType: .uint32, indexBuffer: mesh.indices, indexBufferOffset: 0)
        }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    /// Fit the enclosing sphere against both axes, including narrow viewports.
    static func fittingDistance(bounds: EarthPreviewBounds, aspect: Float) -> Float
    {
        let halfVertical: Float = .pi / 8
        let halfHorizontal = atan(tan(halfVertical) * max(0.001, aspect))
        let radius = max(0.1, simd_length(bounds.dimensions) / 2)
        return radius / sin(min(halfVertical, halfHorizontal)) * 1.1
    }
}

private struct SurfaceUniforms
{
    var baseColor: SIMD4<Float>
    var options: SIMD4<Float>
}
