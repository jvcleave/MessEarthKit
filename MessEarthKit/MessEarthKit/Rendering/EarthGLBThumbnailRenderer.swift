import CoreGraphics
import Foundation
import ImageIO
import MessEarthKit
import Metal
import simd

/// Retains one part's GPU resources until its command completes. Color/depth
/// survive between parts so the thumbnail covers the entire exported region.
actor EarthGLBThumbnailRenderer
{
    private static let size = 256
    private static let maximumPartBytes = 256 * 1024 * 1024
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let renderer: EarthPreviewRenderer
    private let builder: EarthPreviewSceneBuilder
    private let color: MTLTexture
    private let depth: MTLTexture
    private let camera: (viewProjection: simd_float4x4, eye: SIMD3<Float>)
    private let options: EarthGLBExportOptions
    private var partCount = 0

    init(geometry: EarthGLBInfo.Geometry, options: EarthGLBExportOptions, library: MTLLibrary? = nil) throws
    {
        guard geometry.minimum.count == 3, geometry.maximum.count == 3,
              let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue()
        else { throw EarthRegionPreviewError.allocation }
        self.device = device
        self.queue = queue
        self.options = options
        renderer = try EarthPreviewRenderer(device: device, library: library)
        builder = try EarthPreviewSceneBuilder(device: device, exportOptions: options)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm_srgb, width: Self.size, height: Self.size, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = .renderTarget
        guard let color = device.makeTexture(descriptor: descriptor) else { throw EarthRegionPreviewError.allocation }
        self.color = color
        descriptor.pixelFormat = .depth32Float
        descriptor.storageMode = .private
        guard let depth = device.makeTexture(descriptor: descriptor) else { throw EarthRegionPreviewError.allocation }
        self.depth = depth
        let low = geometry.minimum, high = geometry.maximum
        camera = EarthPreviewRenderer.cameraFrame(bounds: EarthPreviewBounds(minimum: SIMD3(low[0], low[1], low[2]), maximum: SIMD3(high[0], high[1], high[2])), aspect: 1)
    }

    func consume(_ capture: EarthCapture) async throws
    {
        try Task.checkCancellation()
        let cost = try builder.memoryCost(capture: capture).totalBytes
        guard cost <= Self.maximumPartBytes,
              UInt64(cost) < device.recommendedMaxWorkingSetSize,
              UInt64(device.currentAllocatedSize) < device.recommendedMaxWorkingSetSize - UInt64(cost)
        else { throw EarthRegionPreviewError.workingSet }
        let scene = try autoreleasepool { try builder.prepare(capture: capture) }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = color
        pass.colorAttachments[0].loadAction = partCount == 0 ? .clear : .load
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0.025, 0.03, 0.04, 1)
        pass.depthAttachment.texture = depth
        pass.depthAttachment.loadAction = partCount == 0 ? .clear : .load
        pass.depthAttachment.storeAction = .store
        pass.depthAttachment.clearDepth = 1
        guard let command = queue.makeCommandBuffer(), let encoder = command.makeRenderCommandEncoder(descriptor: pass)
        else { throw EarthRegionPreviewError.allocation }
        renderer.encode(scene: scene, viewProjection: camera.viewProjection, eye: camera.eye, encoder: encoder, includesVertexColors: options.includeVertexColors)
        encoder.endEncoding()
        await withCheckedContinuation
        { continuation in
            command.addCompletedHandler { _ in continuation.resume() }
            command.commit()
        }
        withExtendedLifetime(scene) {}
        guard command.status == .completed else { throw EarthRegionPreviewError.allocation }
        partCount += 1
        try Task.checkCancellation()
    }

    func finish() throws -> EarthGLBInfo.Thumbnail
    {
        guard partCount > 0, let space = CGColorSpace(name: CGColorSpace.sRGB) else { throw EarthRegionPreviewError.allocation }
        var pixels = Data(count: Self.size * Self.size * 4)
        pixels.withUnsafeMutableBytes
        { bytes in
            color.getBytes(bytes.baseAddress!, bytesPerRow: Self.size * 4, from: MTLRegionMake2D(0, 0, Self.size, Self.size), mipmapLevel: 0)
        }
        guard let provider = CGDataProvider(data: pixels as CFData),
              let image = CGImage(
                  width: Self.size,
                  height: Self.size,
                  bitsPerComponent: 8,
                  bitsPerPixel: 32,
                  bytesPerRow: Self.size * 4,
                  space: space,
                  bitmapInfo: CGBitmapInfo.byteOrder32Little.union(CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)),
                  provider: provider,
                  decode: nil,
                  shouldInterpolate: true,
                  intent: .defaultIntent
              )
        else { throw EarthRegionPreviewError.allocation }
        let bytes = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(bytes, "public.png" as CFString, 1, nil)
        else { throw EarthRegionPreviewError.allocation }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw EarthRegionPreviewError.allocation }
        return try EarthGLBInfo.Thumbnail(width: Self.size, height: Self.size, pngData: bytes as Data)
    }
}
