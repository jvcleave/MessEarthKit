import Foundation
import MessEarthKit
import MetalKit
import simd

/// Worker-confined construction. A decoded part is consumed and released before
/// importing the next; the result contains GPU resources and scalar values only.
struct EarthPreviewSceneBuilder
{
    let device: MTLDevice
    private let whiteTexture: MTLTexture
    var constantTextureBytes: Int { whiteTexture.allocatedSize }

    init(device: MTLDevice) throws
    {
        self.device = device
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm_srgb, width: 1, height: 1, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = .shaderRead
        guard let white = device.makeTexture(descriptor: descriptor) else { throw EarthRegionPreviewError.allocation }
        var pixel: [UInt8] = [255, 255, 255, 255]
        pixel.withUnsafeMutableBytes { white.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: 4) }
        whiteTexture = white
    }

    /// Include allocator alignment and the entire requested mip chain. This pass
    /// uses no texture rasterization/GPU uploads and never retains the capture.
    func memoryCost(capture: EarthCapture) throws -> EarthPreviewMemoryCost
    {
        var cost = EarthPreviewMemoryCost()
        for mesh in capture.meshes
        {
            try Task.checkCancellation()
            for length in [try EarthPreviewMemoryCost.product(mesh.vertices.count, MemoryLayout<EarthVertex>.stride),
                           try EarthPreviewMemoryCost.product(mesh.triangleIndices.count, MemoryLayout<UInt32>.stride)]
            {
                let size = device.heapBufferSizeAndAlign(length: length, options: .storageModeShared)
                cost.geometryBytes = try EarthPreviewMemoryCost.sum(cost.geometryBytes, EarthPreviewMemoryCost.sum(max(length, size.size), size.align))
            }
        }
        for material in capture.materials
        {
            try Task.checkCancellation()
            guard let texture = material.baseColorTexture else { continue }
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm_srgb, width: texture.width, height: texture.height, mipmapped: texture.mipmapFilter != .none)
            descriptor.storageMode = .private
            descriptor.usage = .shaderRead
            let size = device.heapTextureSizeAndAlign(descriptor: descriptor)
            guard size.size > 0 else { throw EarthRegionPreviewError.allocation }
            cost.textureBytes = try EarthPreviewMemoryCost.sum(cost.textureBytes, EarthPreviewMemoryCost.sum(size.size, size.align))
        }
        return cost
    }

    func prepare(capture: EarthCapture) throws -> EarthPreparedPreview
    {
        let loader = MTKTextureLoader(device: device)
        var textures: [Int: (MTLTexture, MTLSamplerState)] = [:]
        var allocatedBytes = 0
        for (index, material) in capture.materials.enumerated()
        {
            try Task.checkCancellation()
            let sampler = MTLSamplerDescriptor()
            let texture: MTLTexture
            if let source = material.baseColorTexture
            {
                texture = try loader.newTexture(data: source.encodedImage, options: [
                    .SRGB: true, .origin: MTKTextureLoader.Origin.topLeft.rawValue,
                    .generateMipmaps: source.mipmapFilter != .none,
                    .textureStorageMode: MTLStorageMode.private.rawValue,
                    .textureUsage: MTLTextureUsage.shaderRead.rawValue,
                ])
                allocatedBytes = try EarthPreviewMemoryCost.sum(allocatedBytes, texture.allocatedSize)
                sampler.sAddressMode = addressMode(source.wrapS)
                sampler.tAddressMode = addressMode(source.wrapT)
                sampler.magFilter = source.usesNearestMagnification ? .nearest : .linear
                sampler.minFilter = source.usesNearestMinification ? .nearest : .linear
                switch source.mipmapFilter
                {
                    case .none: sampler.mipFilter = .notMipmapped
                    case .nearest: sampler.mipFilter = .nearest
                    case .linear: sampler.mipFilter = .linear
                }
            }
            else { texture = whiteTexture }
            guard let state = device.makeSamplerState(descriptor: sampler) else { throw EarthRegionPreviewError.allocation }
            textures[index] = (texture, state)
        }
        var meshes: [EarthPreparedPreview.Mesh] = []
        for mesh in capture.meshes
        {
            try Task.checkCancellation()
            let vertices = mesh.vertices.withUnsafeBytes
            { bytes in bytes.baseAddress.flatMap { device.makeBuffer(bytes: $0, length: bytes.count, options: .storageModeShared) } }
            let indices = mesh.triangleIndices.withUnsafeBytes
            { bytes in bytes.baseAddress.flatMap { device.makeBuffer(bytes: $0, length: bytes.count, options: .storageModeShared) } }
            guard let vertices, let indices, let texture = textures[mesh.materialIndex], let first = mesh.vertices.first
            else { throw EarthRegionPreviewError.allocation }
            allocatedBytes = try EarthPreviewMemoryCost.sum(allocatedBytes, EarthPreviewMemoryCost.sum(vertices.allocatedSize, indices.allocatedSize))
            var minimum = first.position
            var maximum = minimum
            for vertex in mesh.vertices
            {
                minimum = simd_min(minimum, vertex.position)
                maximum = simd_max(maximum, vertex.position)
            }
            meshes.append(.init(
                vertices: vertices,
                indices: indices,
                indexCount: mesh.triangleIndices.count,
                material: EarthPreviewMaterial(capture.materials[mesh.materialIndex]),
                texture: texture.0,
                sampler: texture.1,
                center: minimum + (maximum - minimum) / 2
            ))
        }
        return EarthPreparedPreview(meshes: meshes, bounds: EarthPreviewBounds(capture.bounds), modelCount: 1, attributions: capture.attributions, allocatedBytes: allocatedBytes)
    }

    private func addressMode(_ mode: EarthTextureWrap) -> MTLSamplerAddressMode
    {
        switch mode
        {
            case .repeatTexture: .repeat
            case .mirroredRepeat: .mirrorRepeat
            case .clampToEdge: .clampToEdge
        }
    }
}
