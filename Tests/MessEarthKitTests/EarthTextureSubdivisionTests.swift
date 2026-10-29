import CoreGraphics
import Foundation
import ImageIO
@testable import MessEarthKit
import simd
import Testing
import UniformTypeIdentifiers

private enum TextureSamplingCase: CaseIterable, Sendable
{
    case nearestClamp, linearClamp, nearestRepeat, linearRepeat, nearestMirror, linearMirror, mixedAxes
    var linear: Bool { [.linearClamp, .linearRepeat, .linearMirror, .mixedAxes].contains(self) }
    var wrapS: EarthTextureWrap
    {
        switch self
        {
            case .nearestClamp, .linearClamp: .clampToEdge
            case .nearestRepeat, .linearRepeat, .mixedAxes: .repeatTexture
            case .nearestMirror, .linearMirror: .mirroredRepeat
        }
    }

    var wrapT: EarthTextureWrap { self == .mixedAxes ? .mirroredRepeat : wrapS }
}

/// Independently specified source pixels: x controls red, y controls green,
/// checker parity controls blue, and alpha varies without premultiplication.
private func textureFixtureImage(sixteenBits: Bool = false) throws -> Data
{
    var pixels = Data()
    for y in 0 ..< 4
    {
        for x in 0 ..< 6
        {
            let values = [UInt8(20 + 35 * x), UInt8(30 + 55 * y), UInt8((x + y) % 2 == 0 ? 40 : 220), UInt8(120 + 20 * (x % 3))]
            for value in values
            {
                pixels.append(value)
                if sixteenBits { pixels.append(value) }
            }
        }
    }
    let bits = sixteenBits ? 16 : 8
    let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
    let provider = try #require(CGDataProvider(data: pixels as CFData))
    let order: CGBitmapInfo = sixteenBits ? .byteOrder16Big : .byteOrder32Big
    let image = try #require(
        CGImage(width: 6, height: 4, bitsPerComponent: bits, bitsPerPixel: bits * 4, bytesPerRow: 6 * bits / 8 * 4, space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue).union(order), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    )
    let data = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
    return data as Data
}

private func textureFixture(sampling: TextureSamplingCase = .nearestClamp, mipmap: EarthMipmapFilter = .none, sixteenBits: Bool = false) throws -> (EarthMesh, EarthMaterial)
{
    let texture = EarthTexture(encodedImage: try textureFixtureImage(sixteenBits: sixteenBits), mimeType: "image/png", width: 6, height: 4, wrapS: sampling.wrapS, wrapT: sampling.wrapT, usesNearestMagnification: !sampling.linear, usesNearestMinification: !sampling.linear, mipmapFilter: mipmap)
    let points: [SIMD2<Float>] = [SIMD2(0, 0), SIMD2(1, 0), SIMD2(1, 1), SIMD2(0, 1)]
    let vertices = points.map
    { point in
        EarthVertex(position: SIMD3(point.x, point.y, 0), normal: SIMD3(0, 0, 1), textureCoordinate: SIMD2(-0.4 + point.x * 1.8, -0.25 + point.y * 1.5), color: SIMD4(point.x, point.y, 0.5, 0.75))
    }
    let mesh = EarthMesh(id: 0, name: "UV spanning quad", vertices: vertices, triangleIndices: [0, 1, 2, 0, 2, 3], materialIndex: 0)
    let material = EarthMaterial(name: "Independent pixels", baseColor: SIMD4(0.8, 0.6, 0.4, 0.7), baseColorTexture: texture, metallic: 0.2, roughness: 0.8, isUnlit: false, isDoubleSided: true, alphaMode: .mask, alphaCutoff: 0.3)
    return (mesh, material)
}

private func decodedTexturePixels(_ texture: EarthTexture) throws -> (Data, Int)
{
    let source = try #require(CGImageSourceCreateWithData(texture.encodedImage as CFData, nil))
    let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    #expect(image.bitsPerPixel == 32 && image.bitsPerComponent == 8 && image.alphaInfo == .last)
    return (try #require(image.dataProvider?.data) as Data, image.bytesPerRow)
}

/// Independent reference sampler: integer pixel wrapping plus nearest/bilinear
/// evaluation in linear light, including alpha. It does not call production
/// interval/crop/clip helpers or the production raster decoder.
private func textureSample(_ texture: EarthTexture, pixels: Data, stride: Int, uv: SIMD2<Double>, linear: Bool) -> SIMD4<Double>
{
    func coordinate(_ value: Int, size: Int, wrap: EarthTextureWrap) -> Int
    {
        switch wrap
        {
            case .clampToEdge: return max(0, min(size - 1, value))
            case .repeatTexture: return ((value % size) + size) % size
            case .mirroredRepeat:
                var value = value % (size * 2)
                if value < 0 { value += size * 2 }
                return value >= size ? size * 2 - value - 1 : value
        }
    }
    func pixel(_ x: Int, _ y: Int) -> SIMD4<Double>
    {
        let column = coordinate(x, size: texture.width, wrap: texture.wrapS)
        let row = coordinate(y, size: texture.height, wrap: texture.wrapT)
        let offset = row * stride + column * 4
        func channel(_ index: Int) -> Double
        {
            let value = Double(pixels[offset + index]) / 255
            return index == 3 ? value : (value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4))
        }
        return SIMD4(channel(0), channel(1), channel(2), channel(3))
    }
    if !linear { return pixel(Int(floor(uv.x * Double(texture.width))), Int(floor(uv.y * Double(texture.height)))) }
    let x = uv.x * Double(texture.width) - 0.5
    let y = uv.y * Double(texture.height) - 0.5
    let ix = Int(floor(x)), iy = Int(floor(y))
    let dx = x - floor(x), dy = y - floor(y)
    return (pixel(ix, iy) * (1 - dx) + pixel(ix + 1, iy) * dx) * (1 - dy) + (pixel(ix, iy + 1) * (1 - dx) + pixel(ix + 1, iy + 1) * dx) * dy
}

@Test(arguments: TextureSamplingCase.allCases)
private func textureSubdivisionPreservesPixelsWrappingCoverageAndAttributes(sampling: TextureSamplingCase) throws
{
    let (mesh, material) = try textureFixture(sampling: sampling)
    let profile = try EarthPreparationProfile(maximumDecodedTextureBytesPerModel: sampling.linear ? 64 : 16, maximumTextureDimension: sampling.linear ? 4 : 2)
    try verifyTextureSubdivision(mesh: mesh, material: material, profile: profile, sampling: sampling)
    { clipped in #expect(clipped.vertices.allSatisfy { $0.normal == SIMD3(0, 0, 1) }) }
}

/// Share independent base-pixel, material, area/winding and color checks across
/// exact and optimized cases. Mip equivalence is deliberately not asserted.
private func verifyTextureSubdivision(mesh: EarthMesh, material: EarthMaterial, profile: EarthPreparationProfile, sampling: TextureSamplingCase, inspectNormals: (EarthMesh) throws -> Void) throws
{
    let original = try #require(material.baseColorTexture)
    let sourcePixels = try decodedTexturePixels(original)
    #expect(Array(sourcePixels.0.prefix(4)) == [20, 30, 40, 120])
    var area: Double = 0
    var emitted = 0
    var checkedSamples = 0
    try EarthTextureSubdivision(profile: profile).write(mesh: mesh, material: material)
    { clipped, derived in
        emitted += 1
        let crop = try #require(derived.baseColorTexture)
        let withinProfile = crop.width <= profile.maximumTextureDimension && crop.height <= profile.maximumTextureDimension && crop.width * crop.height * 4 <= profile.maximumDecodedTextureBytesPerModel
        let samplingPreserved = crop.usesNearestMinification == original.usesNearestMinification && crop.usesNearestMagnification == original.usesNearestMagnification && crop.mipmapFilter == original.mipmapFilter
        let materialPreserved = derived.baseColor == material.baseColor && derived.metallic == material.metallic && derived.roughness == material.roughness && derived.alphaMode == .mask && derived.alphaCutoff == 0.3 && derived.isDoubleSided
        #expect(withinProfile)
        #expect(samplingPreserved)
        #expect(materialPreserved)
        let cropPixels = try decodedTexturePixels(crop)
        for index in stride(from: 0, to: clipped.triangleIndices.count, by: 3)
        {
            let vertices = clipped.triangleIndices[index ..< index + 3].map { clipped.vertices[Int($0)] }
            let cross = simd_cross(vertices[1].position - vertices[0].position, vertices[2].position - vertices[0].position)
            #expect(cross.z > 0)
            area += Double(cross.z) / 2
            // Interior samples plus points near edges independently check the
            // UV remap/gutter and interpolated position/color contract.
            for weights in [SIMD3<Double>(0.2, 0.3, 0.5), SIMD3(0.0001, 0.4999, 0.5), SIMD3(0.9998, 0.0001, 0.0001)]
            {
                let point = SIMD3<Double>(vertices[0].position) * weights.x + SIMD3<Double>(vertices[1].position) * weights.y + SIMD3<Double>(vertices[2].position) * weights.z
                let firstUV = SIMD2<Double>(mesh.vertices[0].textureCoordinate)
                let expectedUV = firstUV + SIMD2((Double(mesh.vertices[1].textureCoordinate.x) - firstUV.x) * point.x, (Double(mesh.vertices[3].textureCoordinate.y) - firstUV.y) * point.y)
                let derivedUV = SIMD2<Double>(vertices[0].textureCoordinate) * weights.x + SIMD2<Double>(vertices[1].textureCoordinate) * weights.y + SIMD2<Double>(vertices[2].textureCoordinate) * weights.z
                let expected = textureSample(original, pixels: sourcePixels.0, stride: sourcePixels.1, uv: expectedUV, linear: sampling.linear)
                let actual = textureSample(crop, pixels: cropPixels.0, stride: cropPixels.1, uv: derivedUV, linear: sampling.linear)
                // Nearest sampling is discontinuous at exact texel edges.
                // Float UV storage can choose either neighbor at a tie; exercise
                // near-edge interiors, not an invented double-precision tie rule.
                let texels = expectedUV * SIMD2(Double(original.width), Double(original.height))
                let tie = abs(texels.x - texels.x.rounded()) < 0.000001 || abs(texels.y - texels.y.rounded()) < 0.000001
                if sampling.linear || !tie
                {
                    checkedSamples += 1
                    #expect(simd_length(expected - actual) < 0.00001)
                }
            }
        }
        for vertex in clipped.vertices
        {
            #expect(simd_length(vertex.color - SIMD4(vertex.position.x, vertex.position.y, 0.5, 0.75)) < 0.00001)
        }
        try inspectNormals(clipped)
    }
    let completeCoverage = emitted > 1 && checkedSamples > 20 && abs(area - 1) < 0.00001
    #expect(completeCoverage)
}

private enum OptimizedTextureNormals: CaseIterable, Sendable { case smooth, opposed }

@Test(arguments: OptimizedTextureNormals.allCases)
private func optimizedTextureCopiesRetainBaseSamplesAndProduceUsableNormals(normals: OptimizedTextureNormals) throws
{
    let (source, material) = try textureFixture(sampling: .linearClamp, mipmap: .linear)
    let vertices = source.vertices.enumerated().map
    { index, vertex in
        let normal: SIMD3<Float>
        if normals == .opposed { normal = index == 1 ? SIMD3(0, 0, -1) : SIMD3(0, 0, 1) }
        else { normal = index == 0 ? simd_normalize(SIMD3(0.5, 0, 1)) : SIMD3(0, 0, 1) }
        let uv = normals == .opposed ? SIMD2(vertex.position.x, vertex.position.y) : vertex.textureCoordinate
        return EarthVertex(position: vertex.position, normal: normal, textureCoordinate: uv, color: vertex.color)
    }
    let mesh = EarthMesh(id: source.id, name: source.name, vertices: vertices, triangleIndices: source.triangleIndices, materialIndex: 0)
    let side = normals == .opposed ? 5 : 4
    let profile = try EarthPreparationProfile(maximumDecodedTextureBytesPerModel: side * side * 4, maximumTextureDimension: side, appearancePolicy: .optimizedCopy)
    var sawFallbackNormal = false
    try verifyTextureSubdivision(mesh: mesh, material: material, profile: profile, sampling: .linearClamp)
    { clipped in
        for vertex in clipped.vertices
        {
            if normals == .opposed
            {
                #expect(abs(simd_length(vertex.normal) - 1) < 0.00001)
                // At the midpoint of opposing source normals, the original
                // interpolant is zero. The explicit optimized path uses +Z,
                // the independently authored quad's geometric face normal.
                if simd_distance(vertex.position, SIMD3(0.5, 0, 0)) < 0.00001
                { #expect(vertex.normal == SIMD3(0, 0, 1)); sawFallbackNormal = true }
            }
            else
            {
                // Independently authored affine field on this quad: vertex 0
                // has weight 1 - max(x,y) in either of its two source triangles.
                let weight = 1 - max(vertex.position.x, vertex.position.y)
                let expected = simd_normalize(vertices[0].normal * weight + SIMD3<Float>(0, 0, 1) * (1 - weight))
                #expect(simd_distance(vertex.normal, expected) < 0.00001)
            }
        }
    }
    if normals == .opposed { #expect(sawFallbackNormal) }
}

@Test func textureSubdivisionHandlesConstantUVsWithoutDuplicateGeometry() throws
{
    let (source, material) = try textureFixture()
    let original = try #require(material.baseColorTexture)
    let originalPixels = try decodedTexturePixels(original)
    for uv in [SIMD2<Float>(0.5, 0.5), SIMD2(-2, -2), SIMD2(2, 2)]
    {
        let vertices = source.vertices.map { EarthVertex(position: $0.position, normal: $0.normal, textureCoordinate: uv, color: $0.color) }
        let mesh = EarthMesh(id: 0, name: source.name, vertices: vertices, triangleIndices: source.triangleIndices, materialIndex: 0)
        var triangles = 0
        try EarthTextureSubdivision(profile: EarthPreparationProfile(maximumTextureDimension: 2)).write(mesh: mesh, material: material)
        { clipped, material in
            triangles += clipped.triangleIndices.count / 3
            let texture = try #require(material.baseColorTexture)
            let pixels = try decodedTexturePixels(texture)
            let sourceSample = textureSample(original, pixels: originalPixels.0, stride: originalPixels.1, uv: SIMD2<Double>(uv), linear: false)
            let result = textureSample(texture, pixels: pixels.0, stride: pixels.1, uv: SIMD2<Double>(clipped.vertices[0].textureCoordinate), linear: false)
            #expect(sourceSample == result)
        }
        #expect(triangles == 2)
    }
}

@Test(arguments: [EarthPreparationAppearancePolicy.preserveAppearance, .optimizedCopy])
func textureSubdivisionPreparesExportsAndReopensOffline(appearance: EarthPreparationAppearancePolicy) async throws
{
    let parent = try preparationParent()
    defer { try? FileManager.default.removeItem(at: parent) }
    let (sourceMesh, material) = try textureFixture(sampling: .mixedAxes, mipmap: appearance == .optimizedCopy ? .linear : .none)
    var vertices = sourceMesh.vertices
    if appearance == .optimizedCopy
    { vertices[0] = .init(position: vertices[0].position, normal: simd_normalize(SIMD3(0.5, 0, 1)), textureCoordinate: vertices[0].textureCoordinate, color: vertices[0].color) }
    let mesh = EarthMesh(id: sourceMesh.id, name: sourceMesh.name, vertices: vertices, triangleIndices: sourceMesh.triangleIndices, materialIndex: sourceMesh.materialIndex)
    let data = try EarthDerivativeGLB.encode(vertices: mesh.vertices, indices: mesh.triangleIndices, material: material, name: mesh.name, attributions: ["Authored texture test"], sourceID: "fixture")
    let raw = try preparationArchive(parent: parent, count: 2, sourceOverride: data)
    let originalFile = try #require(try FileManager.default.contentsOfDirectory(at: raw.directoryURL.appendingPathComponent("tiles"), includingPropertiesForKeys: nil).first)
    let originalBytes = try Data(contentsOf: originalFile)
    let profile = try EarthPreparationProfile(maximumVerticesPerModel: 12, maximumIndicesPerModel: 12, maximumDecodedTextureBytesPerModel: 64, maximumTextureDimension: 4, appearancePolicy: appearance)
    let catalog = try await EarthModelPreparer().prepare(archive: raw, directoryURL: parent.appendingPathComponent("prepared"), profile: profile)
    #expect(catalog.state == .ready && catalog.coversEntireSource && catalog.modelCount > 2)
    let page = try await catalog.models(limit: 1)
    let first = try #require(page.first)
    let source = try await catalog.importModel(id: first.id)
    #expect(source.preparationProfile == profile)
    #expect(source.materials.allSatisfy { ($0.baseColorTexture?.width ?? 0) <= 4 && ($0.baseColorTexture?.height ?? 0) <= 4 })
    let saved = try await EarthCaptureStore().save(collection: catalog, selection: .only([first.id]), directoryURL: parent.appendingPathComponent("subset"))
    let subset = try await EarthPreparedCollection.open(directoryURL: saved.deletingLastPathComponent())
    let restored = try await subset.importModel(id: first.id)
    #expect(restored.bounds.minimum == source.bounds.minimum && restored.bounds.maximum == source.bounds.maximum && restored.attributions == ["Authored texture test"])
    #expect(restored.preparationProfile == profile && subset.profile == profile)
    if appearance == .optimizedCopy
    {
        #expect(restored.materials.allSatisfy { $0.baseColorTexture?.mipmapFilter == .linear })
        let exporter = EarthGLBExporter()
        let plan = try await exporter.preflight(collection: subset, destination: EarthPreparationProfile())
        let glb = try await exporter.export(plan: plan, fileURL: parent.appendingPathComponent("optimized.glb"))
        let combined = try await EarthCaptureImporter().importFile(fileURL: glb)
        #expect(combined.preparationProfile == profile && combined.incompleteReason == nil)
        // A plain tileset import/save path must retain the same permission,
        // including when the catalog SQLite file is not the entry point.
        let legacy = try await EarthCaptureImporter().prepareCollection(fileURL: saved)
        let root = try await EarthCaptureStore().save(collection: legacy, directoryURL: parent.appendingPathComponent("plain-folder"))
        #expect(try await EarthCaptureImporter().importFile(fileURL: root).preparationProfile == profile)
    }
    #expect(try Data(contentsOf: originalFile) == originalBytes)
    #expect(try await EarthSourceArchive.open(directoryURL: raw.directoryURL).state == .downloaded)
}

@Test func preparationAppearanceProfilesKeepLegacyDefaultsAndExplicitConsent() throws
{
    // Established v1 artifact shape: the appearance field did not exist.
    let legacy = Data(
        #"{"name":"Native preview","version":1,"maximumVerticesPerModel":2000000,"maximumIndicesPerModel":6000000,"maximumDecodedTextureBytesPerModel":268435456,"maximumTextureDimension":8192,"maximumSourceBytesPerModel":134217728,"maximumPlacementsPerModel":64,"maximumNodesPerPayload":4096}"#.utf8
    )
    let old = try JSONDecoder().decode(EarthPreparationProfile.self, from: legacy)
    #expect(old.version == 1 && old.appearancePolicy == .preserveAppearance)
    let optimized = try EarthPreparationProfile(appearancePolicy: .optimizedCopy)
    #expect(try JSONDecoder().decode(EarthPreparationProfile.self, from: JSONEncoder().encode(optimized)) == optimized)
    #expect(throws: EarthPreparationError.invalidProfile)
    { try EarthPreparationProfile(version: 1, appearancePolicy: .optimizedCopy) }
}

private enum TextureRejection: CaseIterable, Sendable { case mipmaps, litNormals, gutter, pixels, traversal }

@Test(arguments: TextureRejection.allCases)
private func textureSubdivisionRejectsUnpreservableCasesAndRetainsRaw(scenario: TextureRejection) async throws
{
    let parent = try preparationParent()
    defer { try? FileManager.default.removeItem(at: parent) }
    let (source, material) = try textureFixture(sampling: scenario == .traversal ? .linearRepeat : .linearClamp, mipmap: scenario == .mipmaps ? .linear : .none, sixteenBits: scenario == .pixels)
    var vertices = source.vertices
    if scenario == .litNormals { vertices[0] = .init(position: vertices[0].position, normal: simd_normalize(SIMD3(0.5, 0, 1)), textureCoordinate: vertices[0].textureCoordinate, color: vertices[0].color) }
    if scenario == .traversal { vertices[0] = .init(position: vertices[0].position, normal: vertices[0].normal, textureCoordinate: SIMD2(100000, 100000), color: vertices[0].color) }
    let encoded = try EarthDerivativeGLB.encode(vertices: vertices, indices: source.triangleIndices, material: material, name: source.name, attributions: [], sourceID: "fixture")
    let raw = try preparationArchive(parent: parent, count: 1, sourceOverride: encoded)
    let profile = try EarthPreparationProfile(maximumTextureDimension: scenario == .gutter ? 2 : 4)
    let expected: EarthPreparationError
    switch scenario
    {
        case .mipmaps: expected = .textureMipmapsUnsupported
        case .litNormals: expected = .textureInterpolationUnsupported
        case .gutter, .traversal: expected = .textureSubdivisionWorkingSet
        case .pixels: expected = .texturePixelFormatUnsupported
    }
    await #expect(throws: expected) { try await EarthModelPreparer().prepare(archive: raw, directoryURL: parent.appendingPathComponent("prepared"), profile: profile) }
    #expect(try await EarthSourceArchive.open(directoryURL: raw.directoryURL).state == .downloaded)
}

@Test func textureSubdivisionCancellationStopsBetweenCrops() async throws
{
    let (mesh, material) = try textureFixture(sampling: .linearRepeat)
    let job = Task
    {
        try EarthTextureSubdivision(profile: EarthPreparationProfile(maximumTextureDimension: 4)).write(mesh: mesh, material: material)
        { _, _ in withUnsafeCurrentTask { $0?.cancel() } }
    }
    await #expect(throws: CancellationError.self) { try await job.value }
}
