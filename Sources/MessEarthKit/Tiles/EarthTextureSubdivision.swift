import Foundation
import simd

/// UV clipping is affine on each repeat/mirror/clamp interval. One-pixel gutters
/// reproduce base-level bilinear samples across crop edges. Exact mode rejects
/// changed mip/normal interpolation; optimized copies permit those approximations.
struct EarthTextureSubdivision
{
    let profile: EarthPreparationProfile

    func write(mesh: EarthMesh, material: EarthMaterial, emit: (EarthMesh, EarthMaterial) throws -> Void) throws
    {
        guard let source = material.baseColorTexture else { try emit(mesh, material); return }
        let optimizes = profile.appearancePolicy == .optimizedCopy
        guard source.mipmapFilter == .none || optimizes else { throw EarthPreparationError.textureMipmapsUnsupported }
        let gutter = source.usesNearestMagnification && source.usesNearestMinification ? 0 : 1
        let side = min(profile.maximumTextureDimension, Int(sqrt(Double(profile.maximumDecodedTextureBytesPerModel / 4))))
        let interior = side - 2 * gutter
        guard interior > 0 else { throw EarthPreparationError.textureSubdivisionWorkingSet }
        let raster = try EarthTextureRaster(texture: source)
        var cache: [EarthTextureCropKey: EarthTexture] = [:]
        var order: [EarthTextureCropKey] = []
        var cachedBytes = 0
        let cacheBudget = 16 * 1024 * 1024
        for start in stride(from: 0, to: mesh.triangleIndices.count, by: 3)
        {
            try Task.checkCancellation()
            let triangle = mesh.triangleIndices[start ..< start + 3].map { mesh.vertices[Int($0)] }
            let u = triangle.map { Double($0.textureCoordinate.x) }
            let v = triangle.map { Double($0.textureCoordinate.y) }
            let horizontal = try intervals(minimum: u.min()!, maximum: u.max()!, pixels: source.width, interior: interior, wrap: source.wrapS)
            let vertical = try intervals(minimum: v.min()!, maximum: v.max()!, pixels: source.height, interior: interior, wrap: source.wrapT)
            guard horizontal.count <= 65536 / max(1, vertical.count) else { throw EarthPreparationError.textureSubdivisionWorkingSet }
            for sy in vertical
            {
                for sx in horizontal
                {
                    try Task.checkCancellation()
                    var polygon = [SIMD3<Double>(1, 0, 0), SIMD3<Double>(0, 1, 0), SIMD3<Double>(0, 0, 1)]
                    for (coordinates, boundary, greater) in [(u, sx.lower, true), (u, sx.upper, false), (v, sy.lower, true), (v, sy.upper, false)]
                    { polygon = clip(polygon, coordinates: coordinates, boundary: boundary, greater: greater) }
                    guard polygon.count >= 3 else { continue }
                    let key = EarthTextureCropKey(x: sx.pixel, y: sy.pixel, width: sx.count, height: sy.count)
                    let texture: EarthTexture
                    if let existing = cache[key] { texture = existing }
                    else
                    {
                        texture = try raster.crop(x: sx.pixel, y: sy.pixel, width: sx.count, height: sy.count, gutter: gutter, source: source)
                        if texture.encodedImage.count <= cacheBudget
                        {
                            while cachedBytes > cacheBudget - texture.encodedImage.count, let old = order.first
                            { cachedBytes -= cache.removeValue(forKey: old)?.encodedImage.count ?? 0; order.removeFirst() }
                            cache[key] = texture; order.append(key); cachedBytes += texture.encodedImage.count
                        }
                    }
                    var vertices: [EarthVertex] = []
                    for weights in polygon
                    {
                        let isOriginal = weights.x == 1 || weights.y == 1 || weights.z == 1
                        if !optimizes, !isOriginal, !material.isUnlit,
                           !(triangle[0].normal == triangle[1].normal && triangle[1].normal == triangle[2].normal)
                        { throw EarthPreparationError.textureInterpolationUnsupported }
                        func scalar(_ a: Float, _ b: Float, _ c: Float) -> Float { Float(Double(a) * weights.x + Double(b) * weights.y + Double(c) * weights.z) }
                        let position = SIMD3(scalar(triangle[0].position.x, triangle[1].position.x, triangle[2].position.x), scalar(triangle[0].position.y, triangle[1].position.y, triangle[2].position.y), scalar(triangle[0].position.z, triangle[1].position.z, triangle[2].position.z))
                        var normal = SIMD3(scalar(triangle[0].normal.x, triangle[1].normal.x, triangle[2].normal.x), scalar(triangle[0].normal.y, triangle[1].normal.y, triangle[2].normal.y), scalar(triangle[0].normal.z, triangle[1].normal.z, triangle[2].normal.z))
                        if optimizes, simd_length_squared(normal) <= 1e-20
                        {
                            let a = SIMD3<Double>(triangle[1].position) - SIMD3<Double>(triangle[0].position)
                            let b = SIMD3<Double>(triangle[2].position) - SIMD3<Double>(triangle[0].position)
                            let face = simd_cross(a, b)
                            if simd_length_squared(face) > 1e-20 { normal = SIMD3<Float>(simd_normalize(face)) }
                        }
                        guard simd_length_squared(normal) > 1e-20
                        else
                        {
                            if optimizes { throw EarthImportError.invalidContent("A texture-subdivision triangle has no usable surface normal.") }
                            throw EarthPreparationError.textureInterpolationUnsupported
                        }
                        let sourceU = u[0] * weights.x + u[1] * weights.y + u[2] * weights.z
                        let sourceV = v[0] * weights.x + v[1] * weights.y + v[2] * weights.z
                        let uv = SIMD2<Float>(Float(((sourceU * sx.scale + sx.offset) * Double(source.width) - Double(sx.pixel) + Double(gutter)) / Double(texture.width)), Float(((sourceV * sy.scale + sy.offset) * Double(source.height) - Double(sy.pixel) + Double(gutter)) / Double(texture.height)))
                        let color = SIMD4(
                            scalar(triangle[0].color.x, triangle[1].color.x, triangle[2].color.x),
                            scalar(triangle[0].color.y, triangle[1].color.y, triangle[2].color.y),
                            scalar(triangle[0].color.z, triangle[1].color.z, triangle[2].color.z),
                            scalar(triangle[0].color.w, triangle[1].color.w, triangle[2].color.w)
                        )
                        vertices.append(EarthVertex(position: position, normal: simd_normalize(normal), textureCoordinate: uv, color: color))
                    }
                    var indices: [UInt32] = []
                    for index in 1 ..< vertices.count - 1
                    {
                        let area = simd_cross(vertices[index].position - vertices[0].position, vertices[index + 1].position - vertices[0].position)
                        if simd_length_squared(area) > 1e-20 { indices += [0, UInt32(index), UInt32(index + 1)] }
                    }
                    guard !indices.isEmpty else { continue }
                    let outputMaterial = EarthMaterial(
                        name: material.name,
                        baseColor: material.baseColor,
                        baseColorTexture: texture,
                        metallic: material.metallic,
                        roughness: material.roughness,
                        isUnlit: material.isUnlit,
                        isDoubleSided: material.isDoubleSided,
                        alphaMode: material.alphaMode,
                        alphaCutoff: material.alphaCutoff
                    )
                    try emit(EarthMesh(id: mesh.id, name: mesh.name, vertices: vertices, triangleIndices: indices, materialIndex: 0), outputMaterial)
                }
            }
        }
    }

    private func clip(_ polygon: [SIMD3<Double>], coordinates: [Double], boundary: Double, greater: Bool) -> [SIMD3<Double>]
    {
        guard var previous = polygon.last else { return [] }
        func value(_ weights: SIMD3<Double>) -> Double { coordinates[0] * weights.x + coordinates[1] * weights.y + coordinates[2] * weights.z - boundary }
        var distance = value(previous)
        var output: [SIMD3<Double>] = []
        for current in polygon
        {
            let nextDistance = value(current)
            let inside = greater ? nextDistance >= 0 : nextDistance <= 0
            let wasInside = greater ? distance >= 0 : distance <= 0
            if inside != wasInside
            {
                let t = distance / (distance - nextDistance)
                output.append(previous + (current - previous) * t)
            }
            if inside { output.append(current) }
            previous = current; distance = nextDistance
        }
        return output
    }

    private func intervals(minimum: Double, maximum: Double, pixels: Int, interior: Int, wrap: EarthTextureWrap) throws -> [EarthTextureInterval]
    {
        guard minimum.isFinite, maximum.isFinite, abs(minimum) < Double(Int.max / 4), abs(maximum) < Double(Int.max / 4) else { throw EarthPreparationError.textureSubdivisionWorkingSet }
        let count = (pixels + interior - 1) / interior
        let firstPeriod = wrap == .clampToEdge ? 0 : Int(floor(minimum))
        let lastPeriod = wrap == .clampToEdge ? 0 : max(firstPeriod, Int(ceil(maximum)) - 1)
        guard lastPeriod - firstPeriod < 4096 else { throw EarthPreparationError.textureSubdivisionWorkingSet }
        var result: [EarthTextureInterval] = []
        func append(_ value: EarthTextureInterval) throws
        {
            guard value.lower <= maximum, value.upper >= minimum else { return }
            guard result.count < 65536 else { throw EarthPreparationError.textureSubdivisionWorkingSet }
            result.append(value)
        }
        if wrap == .clampToEdge, minimum < 0
        { try append(.init(lower: minimum, upper: min(0, maximum), scale: 0, offset: 0, pixel: 0, count: min(interior, pixels))) }
        for period in firstPeriod ... lastPeriod
        {
            try Task.checkCancellation()
            for cell in 0 ..< count
            {
                let pixel = cell * interior
                let length = min(interior, pixels - pixel)
                let lower = Double(pixel) / Double(pixels)
                let upper = Double(pixel + length) / Double(pixels)
                let mirror = wrap == .mirroredRepeat && period % 2 != 0
                try append(.init(lower: Double(period) + (mirror ? 1 - upper : lower), upper: Double(period) + (mirror ? 1 - lower : upper), scale: mirror ? -1 : 1, offset: mirror ? Double(period) + 1 : -Double(period), pixel: pixel, count: length))
            }
        }
        if wrap == .clampToEdge, maximum > 1
        {
            let pixel = (count - 1) * interior
            try append(.init(lower: max(1, minimum), upper: maximum, scale: 0, offset: 1, pixel: pixel, count: pixels - pixel))
        }
        if minimum == maximum
        {
            let period = floor(minimum)
            let canonical: Double
            switch wrap
            {
                case .clampToEdge: canonical = min(1, max(0, minimum))
                case .repeatTexture: canonical = minimum - period
                case .mirroredRepeat: canonical = Int(period) % 2 == 0 ? minimum - period : 1 - (minimum - period)
            }
            let pixel = min(pixels - 1, max(0, Int(floor(canonical * Double(pixels))))) / interior * interior
            return result.first(where: { $0.pixel == pixel }).map { [$0] } ?? []
        }
        return result
    }
}

private struct EarthTextureCropKey: Hashable { let x: Int; let y: Int; let width: Int; let height: Int }
private struct EarthTextureInterval
{
    let lower: Double
    let upper: Double
    let scale: Double
    let offset: Double
    let pixel: Int
    let count: Int
}
