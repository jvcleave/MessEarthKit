import Accelerate
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
    let rgba8Data: Data

    init(texture: EarthTexture, maximumBytes: Int = Self.maximumBytes) throws
    {
        guard texture.width > 0, texture.height > 0,
              texture.width <= Self.maximumDimension, texture.height <= Self.maximumDimension,
              maximumBytes > 0, texture.width <= maximumBytes / 4 / texture.height
        else { throw EarthPreparationError.textureSubdivisionWorkingSet }
        try Task.checkCancellation()
        guard let source = CGImageSourceCreateWithData(texture.encodedImage as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary),
              image.width == texture.width, image.height == texture.height
        else { throw EarthPreparationError.texturePixelFormatUnsupported }
        try self.init(image: image, maximumBytes: maximumBytes)
    }

    init(image: CGImage, maximumBytes: Int = Self.maximumBytes) throws
    {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0,
              width <= Self.maximumDimension, height <= Self.maximumDimension,
              maximumBytes > 0, width <= maximumBytes / 4 / height
        else { throw EarthPreparationError.textureSubdivisionWorkingSet }
        let gray = image.colorSpace?.model == .monochrome
        guard image.bitsPerComponent == 8,
              gray || image.colorSpace?.model == .rgb,
              [8, 16, 24, 32].contains(image.bitsPerPixel),
              let provider = image.dataProvider?.data
        else { throw EarthPreparationError.texturePixelFormatUnsupported }
        let bytes = provider as Data
        let components = image.bitsPerPixel / 8
        let byteOrder = image.bitmapInfo.intersection(.byteOrderMask)
        let little = byteOrder == .byteOrder32Little
        guard image.bytesPerRow >= width * components,
              image.bytesPerRow <= Int.max / height,
              bytes.count >= image.bytesPerRow * height,
              !gray || (byteOrder != .byteOrder16Little && !little),
              gray ? (components == 1 || components == 2) : (components == 3 || components == 4)
        else { throw EarthPreparationError.texturePixelFormatUnsupported }

        let color: Int
        let hasAlpha: Bool
        let alpha: Int
        switch image.alphaInfo
        {
            case .none, .noneSkipLast: color = 0; hasAlpha = false; alpha = components - 1
            case .noneSkipFirst: color = 1; hasAlpha = false; alpha = 0
            case .last, .premultipliedLast: color = 0; hasAlpha = true; alpha = components - 1
            case .first, .premultipliedFirst: color = 1; hasAlpha = true; alpha = 0
            default: throw EarthPreparationError.texturePixelFormatUnsupported
        }
        let colors = gray ? [color, color, color] : [color, color + 1, color + 2]
        guard colors.allSatisfy({ $0 < components }) else { throw EarthPreparationError.texturePixelFormatUnsupported }
        let offsets = (colors + [alpha]).map { little ? components - 1 - $0 : $0 }
        let red = offsets[0], green = offsets[1], blue = offsets[2], opacity = offsets[3]

        try Task.checkCancellation()
        if image.alphaInfo == .premultipliedFirst || image.alphaInfo == .premultipliedLast
        {
            // Unpremultiplying quantized pixels would change their authored RGB.
            // Only fully opaque premultiplied input is representable unchanged.
            try bytes.withUnsafeBytes
            { (input: UnsafeRawBufferPointer) in
                let src = input.bindMemory(to: UInt8.self)
                for row in 0 ..< height
                {
                    try Task.checkCancellation()
                    for column in 0 ..< width
                    {
                        guard src[row * image.bytesPerRow + column * components + opacity] == 255
                        else { throw EarthPreparationError.texturePixelFormatUnsupported }
                    }
                }
            }
        }

        let outputRowBytes = width * 4
        if !gray, components == 4, hasAlpha, offsets == [0, 1, 2, 3],
           image.bytesPerRow == outputRowBytes, bytes.count == outputRowBytes * height
        {
            try Task.checkCancellation()
            self.width = width
            self.height = height
            rgba8Data = bytes
            return
        }

        let rgb24 = !gray && components == 3 && !hasAlpha && offsets[0 ..< 3] == [0, 1, 2]
        let rgb32 = !gray && components == 4
        var result = Data(count: outputRowBytes * height)
        try result.withUnsafeMutableBytes
        { destination in
            try bytes.withUnsafeBytes
            { (input: UnsafeRawBufferPointer) in
                if rgb24 || rgb32
                {
                    let channels = offsets.map { UInt8($0) }
                    let background: [UInt8] = [0, 0, 0, 255]
                    // Small row batches keep cancellation bounded while vImage
                    // expands/reorders bytes without color or alpha conversion.
                    for row in stride(from: 0, to: height, by: 64)
                    {
                        try Task.checkCancellation()
                        let rows = vImagePixelCount(min(64, height - row))
                        var source = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: input.baseAddress!.advanced(by: row * image.bytesPerRow)), height: rows, width: vImagePixelCount(width), rowBytes: image.bytesPerRow)
                        var output = vImage_Buffer(data: destination.baseAddress!.advanced(by: row * outputRowBytes), height: rows, width: vImagePixelCount(width), rowBytes: outputRowBytes)
                        let status = rgb24
                            ? vImageConvert_RGB888toRGBA8888(&source, nil, 255, &output, false, vImage_Flags(kvImageNoFlags))
                            : vImagePermuteChannelsWithMaskedInsert_ARGB8888(&source, &output, channels, hasAlpha ? 0 : 1, background, vImage_Flags(kvImageNoFlags))
                        guard status == kvImageNoError else { throw EarthPreparationError.texturePixelFormatUnsupported }
                    }
                    return
                }

                let src = input.bindMemory(to: UInt8.self)
                let dst = destination.bindMemory(to: UInt8.self)
                for y in 0 ..< height
                {
                    try Task.checkCancellation()
                    for x in 0 ..< width
                    {
                        let offset = y * image.bytesPerRow + x * components
                        let target = y * outputRowBytes + x * 4
                        dst[target] = src[offset + red]
                        dst[target + 1] = src[offset + green]
                        dst[target + 2] = src[offset + blue]
                        dst[target + 3] = hasAlpha ? src[offset + opacity] : 255
                    }
                }
            }
        }
        try Task.checkCancellation()
        self.width = width
        self.height = height
        rgba8Data = result
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
            try rgba8Data.withUnsafeBytes
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
