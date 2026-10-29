import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// File-preparation boundary only. Reads encoded 8-bit samples without drawing
/// through a premultiplied/color-converting context, then writes lossless PNGs.
/// One admitted source raster and bounded output crops belong to this worker.
struct EarthTextureRaster
{
    static let maximumBytes = 256 * 1024 * 1024
    static let maximumDimension = 16384
    let width: Int
    let height: Int
    private let rgba: Data

    init(texture: EarthTexture) throws
    {
        guard texture.width > 0, texture.height > 0,
              texture.width <= Self.maximumDimension, texture.height <= Self.maximumDimension,
              texture.width <= Self.maximumBytes / 4 / texture.height
        else { throw EarthPreparationError.textureSubdivisionWorkingSet }
        guard let source = CGImageSourceCreateWithData(texture.encodedImage as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary),
              image.width == texture.width, image.height == texture.height,
              image.bitsPerComponent == 8, let provider = image.dataProvider?.data
        else { throw EarthPreparationError.texturePixelFormatUnsupported }
        let gray = image.colorSpace?.model == .monochrome
        guard gray || image.colorSpace?.model == .rgb,
              [8, 16, 24, 32].contains(image.bitsPerPixel),
              image.bitsPerPixel.isMultiple(of: 8)
        else { throw EarthPreparationError.texturePixelFormatUnsupported }
        let bytes = provider as Data
        guard image.bytesPerRow <= Int.max / image.height,
              bytes.count >= image.bytesPerRow * image.height
        else { throw EarthPreparationError.texturePixelFormatUnsupported }
        let components = image.bitsPerPixel / 8
        let byteOrder = image.bitmapInfo.intersection(.byteOrderMask)
        let little = byteOrder == .byteOrder32Little
        guard !gray || (byteOrder != .byteOrder16Little && !little),
              gray ? (components == 1 || components == 2) : (components == 3 || components == 4)
        else { throw EarthPreparationError.texturePixelFormatUnsupported }
        var result = Data(count: texture.width * texture.height * 4)
        try result.withUnsafeMutableBytes
        { destination in
            try bytes.withUnsafeBytes
            { input in
                let src = input.bindMemory(to: UInt8.self)
                let dst = destination.bindMemory(to: UInt8.self)
                for y in 0 ..< image.height
                {
                    try Task.checkCancellation()
                    for x in 0 ..< image.width
                    {
                        let offset = y * image.bytesPerRow + x * components
                        func sample(_ index: Int) throws -> UInt8
                        {
                            guard index < components else { throw EarthPreparationError.texturePixelFormatUnsupported }
                            return src[offset + (little ? components - 1 - index : index)]
                        }
                        let color: Int
                        let alpha: UInt8
                        switch image.alphaInfo
                        {
                            case .none, .noneSkipLast: color = 0; alpha = 255
                            case .noneSkipFirst: color = 1; alpha = 255
                            case .last, .premultipliedLast: color = 0; alpha = try sample(components - 1)
                            case .first, .premultipliedFirst: color = 1; alpha = try sample(0)
                            default: throw EarthPreparationError.texturePixelFormatUnsupported
                        }
                        // Unpremultiplying quantized pixels would change their
                        // authored RGB values. Refuse that representation explicitly.
                        if image.alphaInfo == .premultipliedFirst || image.alphaInfo == .premultipliedLast
                        { guard alpha == 255 else { throw EarthPreparationError.texturePixelFormatUnsupported } }
                        let target = (y * image.width + x) * 4
                        dst[target] = try sample(color)
                        dst[target + 1] = try sample(gray ? color : color + 1)
                        dst[target + 2] = try sample(gray ? color : color + 2)
                        dst[target + 3] = alpha
                    }
                }
            }
        }
        width = image.width
        height = image.height
        rgba = result
    }

    func crop(x: Int, y: Int, width: Int, height: Int, gutter: Int, source: EarthTexture) throws -> EarthTexture
    {
        let outputWidth = width + 2 * gutter
        let outputHeight = height + 2 * gutter
        guard outputWidth > 0, outputHeight > 0, outputWidth <= Self.maximumBytes / 4 / outputHeight else { throw EarthPreparationError.textureSubdivisionWorkingSet }
        var pixels = Data(count: outputWidth * outputHeight * 4)
        func wrapped(_ index: Int, length: Int, mode: EarthTextureWrap) -> Int
        {
            switch mode
            {
                case .clampToEdge: return min(max(0, index), length - 1)
                case .repeatTexture: return (index % length + length) % length
                case .mirroredRepeat:
                    let value = (index % (2 * length) + 2 * length) % (2 * length)
                    return value < length ? value : 2 * length - 1 - value
            }
        }
        try pixels.withUnsafeMutableBytes
        { output in
            try rgba.withUnsafeBytes
            { input in
                let src = input.bindMemory(to: UInt8.self)
                let dst = output.bindMemory(to: UInt8.self)
                for row in 0 ..< outputHeight
                {
                    try Task.checkCancellation()
                    let sy = wrapped(y + row - gutter, length: self.height, mode: source.wrapT)
                    for column in 0 ..< outputWidth
                    {
                        let sx = wrapped(x + column - gutter, length: self.width, mode: source.wrapS)
                        for channel in 0 ..< 4 { dst[(row * outputWidth + column) * 4 + channel] = src[(sy * self.width + sx) * 4 + channel] }
                    }
                }
            }
        }
        guard let provider = CGDataProvider(data: pixels as CFData),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let image = CGImage(
                  width: outputWidth,
                  height: outputHeight,
                  bitsPerComponent: 8,
                  bitsPerPixel: 32,
                  bytesPerRow: outputWidth * 4,
                  space: colorSpace,
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue).union(.byteOrder32Big),
                  provider: provider,
                  decode: nil,
                  shouldInterpolate: false,
                  intent: .defaultIntent
              )
        else { throw EarthPreparationError.texturePixelFormatUnsupported }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { throw EarthPreparationError.storage }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw EarthPreparationError.storage }
        // Exact callers admit non-mipmapped input only. Optimized copies retain
        // the requested filter and let the renderer regenerate each crop's mips.
        return EarthTexture(
            encodedImage: data as Data,
            mimeType: "image/png",
            width: outputWidth,
            height: outputHeight,
            wrapS: .clampToEdge,
            wrapT: .clampToEdge,
            usesNearestMagnification: source.usesNearestMagnification,
            usesNearestMinification: source.usesNearestMinification,
            mipmapFilter: source.mipmapFilter
        )
    }
}
