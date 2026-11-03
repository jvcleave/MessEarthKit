import CoreGraphics
import Foundation
@testable import MessEarthKit
import Testing

private enum TextureRasterLayout: CaseIterable, Sendable
{
    case rgb, rgba, packedRGBA, argb, bgra, abgr, rgbx, xrgb, bgrx, xbgr, gray, grayAlpha

    var expected: [UInt8]
    {
        switch self
        {
            case .gray:
                [10, 10, 10, 255, 40, 40, 40, 255, 70, 70, 70, 255, 100, 100, 100, 255]
            case .grayAlpha:
                [10, 10, 10, 0, 40, 40, 40, 17, 70, 70, 70, 129, 100, 100, 100, 255]
            case .rgba, .packedRGBA, .argb, .bgra, .abgr:
                [10, 20, 30, 0, 40, 50, 60, 17, 70, 80, 90, 129, 100, 110, 120, 255]
            default:
                [10, 20, 30, 255, 40, 50, 60, 255, 70, 80, 90, 255, 100, 110, 120, 255]
        }
    }

    func image() throws -> CGImage
    {
        // Authored byte layouts include distinct padding and unused-channel
        // values. Expected RGBA samples above are independent of the decoder.
        let format: (bits: Int, stride: Int, alpha: CGImageAlphaInfo, order: CGBitmapInfo, bytes: [UInt8])
        switch self
        {
            case .rgb:
                format = (24, 8, .none, [], [10, 20, 30, 40, 50, 60, 201, 202, 70, 80, 90, 100, 110, 120, 203, 204])
            case .rgba:
                format = (32, 12, .last, .byteOrder32Big, [10, 20, 30, 0, 40, 50, 60, 17, 201, 202, 203, 204, 70, 80, 90, 129, 100, 110, 120, 255, 205, 206, 207, 208])
            case .packedRGBA:
                format = (32, 8, .last, .byteOrder32Big, [10, 20, 30, 0, 40, 50, 60, 17, 70, 80, 90, 129, 100, 110, 120, 255])
            case .argb:
                format = (32, 12, .first, .byteOrder32Big, [0, 10, 20, 30, 17, 40, 50, 60, 201, 202, 203, 204, 129, 70, 80, 90, 255, 100, 110, 120, 205, 206, 207, 208])
            case .bgra:
                format = (32, 12, .first, .byteOrder32Little, [30, 20, 10, 0, 60, 50, 40, 17, 201, 202, 203, 204, 90, 80, 70, 129, 120, 110, 100, 255, 205, 206, 207, 208])
            case .abgr:
                format = (32, 12, .last, .byteOrder32Little, [0, 30, 20, 10, 17, 60, 50, 40, 201, 202, 203, 204, 129, 90, 80, 70, 255, 120, 110, 100, 205, 206, 207, 208])
            case .rgbx:
                format = (32, 12, .noneSkipLast, .byteOrder32Big, [10, 20, 30, 0, 40, 50, 60, 17, 201, 202, 203, 204, 70, 80, 90, 129, 100, 110, 120, 254, 205, 206, 207, 208])
            case .xrgb:
                format = (32, 12, .noneSkipFirst, .byteOrder32Big, [0, 10, 20, 30, 17, 40, 50, 60, 201, 202, 203, 204, 129, 70, 80, 90, 254, 100, 110, 120, 205, 206, 207, 208])
            case .bgrx:
                format = (32, 12, .noneSkipFirst, .byteOrder32Little, [30, 20, 10, 0, 60, 50, 40, 17, 201, 202, 203, 204, 90, 80, 70, 129, 120, 110, 100, 254, 205, 206, 207, 208])
            case .xbgr:
                format = (32, 12, .noneSkipLast, .byteOrder32Little, [0, 30, 20, 10, 17, 60, 50, 40, 201, 202, 203, 204, 129, 90, 80, 70, 254, 120, 110, 100, 205, 206, 207, 208])
            case .gray:
                format = (8, 4, .none, [], [10, 40, 201, 202, 70, 100, 203, 204])
            case .grayAlpha:
                format = (16, 6, .last, [], [10, 0, 40, 17, 201, 202, 70, 129, 100, 255, 203, 204])
        }
        let space = self == .gray || self == .grayAlpha ? CGColorSpaceCreateDeviceGray() : CGColorSpaceCreateDeviceRGB()
        return try rasterFixtureImage(bytes: format.bytes, width: 2, height: 2, bits: format.bits, stride: format.stride, space: space, alpha: format.alpha, order: format.order)
    }
}

private func rasterFixtureImage(bytes: [UInt8], width: Int, height: Int, bits: Int, stride: Int, space: CGColorSpace, alpha: CGImageAlphaInfo, order: CGBitmapInfo) throws -> CGImage
{
    let provider = try #require(CGDataProvider(data: Data(bytes) as CFData))
    return try #require(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: bits, bytesPerRow: stride, space: space, bitmapInfo: CGBitmapInfo(rawValue: alpha.rawValue).union(order), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
}

@Test(arguments: TextureRasterLayout.allCases)
private func textureRasterPreservesLayoutAndPadding(layout: TextureRasterLayout) throws
{
    let raster = try EarthTextureRaster(image: layout.image())
    #expect(Array(raster.rgba8Data) == layout.expected)
}

@Test(arguments: [false, true])
private func textureRasterPreservesPremultipliedRejection(firstAlpha: Bool) throws
{
    let alpha: CGImageAlphaInfo = firstAlpha ? .premultipliedFirst : .premultipliedLast
    let order: CGBitmapInfo = firstAlpha ? .byteOrder32Little : .byteOrder32Big
    var bytes: [UInt8] = firstAlpha ? [30, 20, 10, 255, 60, 50, 40, 255] : [10, 20, 30, 255, 40, 50, 60, 255]
    let space = CGColorSpaceCreateDeviceRGB()
    let opaque = try rasterFixtureImage(bytes: bytes, width: 2, height: 1, bits: 32, stride: 8, space: space, alpha: alpha, order: order)
    #expect(Array(try EarthTextureRaster(image: opaque).rgba8Data) == [10, 20, 30, 255, 40, 50, 60, 255])
    bytes[7] = 128
    let translucent = try rasterFixtureImage(bytes: bytes, width: 2, height: 1, bits: 32, stride: 8, space: space, alpha: alpha, order: order)
    #expect(throws: EarthPreparationError.texturePixelFormatUnsupported)
    { _ = try EarthTextureRaster(image: translucent) }
}

@Test func textureDecodingStopsWhenCancelled() async throws
{
    let (_, material) = try textureFixture(zeroAlphaPixel: true)
    let texture = try #require(material.baseColorTexture)
    let job = Task
    {
        withUnsafeCurrentTask { $0?.cancel() }
        return try texture.decodedRGBA8()
    }
    await #expect(throws: CancellationError.self) { try await job.value }
}
