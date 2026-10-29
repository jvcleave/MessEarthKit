import Foundation
@testable import MessEarthKit
import simd
import Testing

private let fixtureDirectory = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Tools/IntegrationProbe/Fixtures/Orientation")

@Test(arguments: [false, true])
func automaticSectionsPreserveAlignmentAndSaveIndependentSources(textureBudget: Bool) async throws
{
    let limits = textureBudget ? EarthImportLimits(maximumDecodedTextureBytes: 16) : EarthImportLimits(maximumVertices: 28)
    let importer = EarthCaptureImporter(limits: limits)
    let collection = try await importer.prepareCollection(fileURL: fixtureDirectory.appendingPathComponent("tileset.json"))
    #expect(collection.sections.count == 2)
    var minimum = SIMD3<Float>(repeating: .infinity)
    var maximum = SIMD3<Float>(repeating: -.infinity)
    let original = try Data(contentsOf: fixtureDirectory.appendingPathComponent("block.glb"))
    for section in collection.sections
    {
        let capture = try await importer.importSection(section)
        #expect(capture.vertexCount == 28 && capture.triangleCount == 14)
        #expect(capture.geographicOrigin?.latitude == collection.geographicOrigin.latitude)
        #expect(section.sourceFiles.first { $0.relativePath.hasSuffix(".glb") }?.data == original)
        minimum = simd_min(minimum, capture.bounds.minimum)
        maximum = simd_max(maximum, capture.bounds.maximum)
    }
    // Independent fixture contract: splitting must preserve placement, all
    // leaf geometry, and the original 56-vertex/28-triangle result.
    #expect(simd_distance(minimum, SIMD3(-4, 0.5, -7)) < 0.001)
    #expect(simd_distance(maximum, SIMD3(10, 2.3, -1)) < 0.001)
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let last = try #require(collection.sections.last)
    let selected = try collection.selecting([last.id])
    let expected = try await importer.importSection(last)
    let root = try await EarthCaptureStore().save(collection: selected, directoryURL: directory)
    let reopened = try await importer.prepareCollection(fileURL: root)
    let restored = try await importer.importSection(#require(reopened.sections.first))
    #expect(restored.bounds.minimum == expected.bounds.minimum && restored.bounds.maximum == expected.bounds.maximum)
    let standaloneRoot = directory.appendingPathComponent("models/model-\(last.id)/tileset.json")
    let standalone = try await importer.importFile(fileURL: standaloneRoot)
    #expect(standalone.bounds.minimum == expected.bounds.minimum)
}

@Test func tiledReferencePreservesPlacementRefinementAndSourceBytes() async throws
{
    let capture = try await EarthCaptureImporter().importFile(fileURL: fixtureDirectory.appendingPathComponent("tileset.json"))
    // These dimensions/counts are specified independently in the fixture README.
    #expect(capture.meshes.count == 4)
    #expect(capture.vertexCount == 56)
    #expect(capture.triangleCount == 28)
    #expect(simd_length(capture.bounds.minimum - SIMD3(-4, 0.5, -7)) < 0.0001)
    #expect(simd_length(capture.bounds.maximum - SIMD3(10, 2.3, -1)) < 0.0001)
    #expect(abs(try #require(capture.geographicOrigin).latitude) < 1e-9)
    let original = try Data(contentsOf: fixtureDirectory.appendingPathComponent("block.glb"))
    #expect(capture.sourceFiles.first { $0.relativePath == "block.glb" }?.data == original)
    #expect(Set(capture.sourceFiles.map(\.relativePath)) == ["tileset.json", "nested.json", "block.glb"])
}

@Test func declaredSharedOriginMetadataCannotSilentlyFallBackToBounds() async throws
{
    let importer = EarthCaptureImporter()
    let collection = try await importer.prepareCollection(fileURL: fixtureDirectory.appendingPathComponent("tileset.json"))
    let files = try collection.sourceFiles()
    let root = try #require(files.first { $0.relativePath == "tileset.json" })
    var json = try #require(JSONSerialization.jsonObject(with: root.data) as? [String: Any])
    var extras = try #require(json["extras"] as? [String: Any])
    extras["messEarthKitSharedOrigin"] = ["latitude": "invalid", "longitude": 0, "ellipsoidHeight": 0]
    json["extras"] = extras
    let invalidRoot = EarthSourceFile(relativePath: root.relativePath, data: try JSONSerialization.data(withJSONObject: json))
    let changed = files.map { $0.relativePath == root.relativePath ? invalidRoot : $0 }
    await #expect(throws: EarthImportError.self)
    { try await importer.importSourceFiles(sourceFiles: changed, rootSourcePath: root.relativePath) }
}

@Test func standaloneGLBRetainsNodeTransformsUVsAndUnlitImage() async throws
{
    let capture = try await EarthCaptureImporter().importFile(fileURL: fixtureDirectory.appendingPathComponent("block.glb"))
    #expect(simd_length(capture.bounds.minimum - SIMD3(1, 0.5, -5)) < 0.0001)
    #expect(simd_length(capture.bounds.maximum - SIMD3(5, 1.3, -1)) < 0.0001)
    let ground = try #require(capture.meshes.first)
    #expect(ground.vertices.first?.textureCoordinate == SIMD2(0, 1))
    #expect(ground.vertices.first?.normal == SIMD3(0, 1, 0))
    let material = capture.materials[ground.materialIndex]
    #expect(material.isUnlit)
    let texture = try #require(material.baseColorTexture)
    #expect(texture.width == 2 && texture.height == 2)
    #expect(texture.usesNearestMagnification && texture.usesNearestMinification && texture.mipmapFilter == .none)
    #expect(texture.wrapS == .clampToEdge && texture.wrapT == .clampToEdge)
    #expect(capture.geographicOrigin == nil)
}

@Test func omittedTextureFiltersUseDefaultsButExplicitZeroIsRejected() async throws
{
    let original = try Data(contentsOf: fixtureDirectory.appendingPathComponent("block.glb"))
    let jsonLength = Int(original.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: 12, as: UInt32.self)) })
    let originalJSON = try #require(JSONSerialization.jsonObject(with: original.subdata(in: 20 ..< 20 + jsonLength)) as? [String: Any])
    let binaryChunk = original.suffix(from: 20 + jsonLength)
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    for minFilter in [nil, 0] as [Int?]
    {
        var json = originalJSON
        var sampler = ["wrapS": 33071, "wrapT": 33071]
        if let minFilter { sampler["minFilter"] = minFilter }
        json["samplers"] = [sampler]
        var jsonData = try JSONSerialization.data(withJSONObject: json, options: [.withoutEscapingSlashes])
        while !jsonData.count.isMultiple(of: 4) { jsonData.append(0x20) }
        var source = Data()
        for word: UInt32 in [0x46546C67, 2, UInt32(20 + jsonData.count + binaryChunk.count), UInt32(jsonData.count), 0x4E4F534A]
        {
            var encoded = word.littleEndian
            withUnsafeBytes(of: &encoded) { source.append(contentsOf: $0) }
        }
        source.append(jsonData)
        source.append(binaryChunk)
        let file = directory.appendingPathComponent("sampler.glb")
        try source.write(to: file)
        if minFilter == nil
        {
            let capture = try await EarthCaptureImporter().importFile(fileURL: file)
            let texture = try #require(capture.materials.first?.baseColorTexture)
            // The client selects linear filtering/mips when glTF omits filters.
            #expect(!texture.usesNearestMagnification && !texture.usesNearestMinification && texture.mipmapFilter == .linear)
        }
        else
        {
            do
            {
                _ = try await EarthCaptureImporter().importFile(fileURL: file)
                Issue.record("An explicit invalid filter was treated as an omitted default.")
            }
            catch EarthImportError.unsupportedContent {}
        }
    }
}

@Test func truncatedPayloadAndResourceBudgetFailExplicitly() async throws
{
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("truncated.glb")
    let original = try Data(contentsOf: fixtureDirectory.appendingPathComponent("block.glb"))
    try original.prefix(30).write(to: file)
    do
    {
        _ = try await EarthCaptureImporter().importFile(fileURL: file)
        Issue.record("Truncated GLB unexpectedly imported.")
    }
    catch EarthImportError.invalidContent {}
    do
    {
        _ = try await EarthCaptureImporter(limits: EarthImportLimits(maximumSourceBytes: 32)).importFile(fileURL: fixtureDirectory.appendingPathComponent("block.glb"))
        Issue.record("An oversized source unexpectedly imported.")
    }
    catch EarthImportError.limitExceeded {}
}

@Test func tilesetCannotReadOutsideAuthorizedDirectoryOrFormCycles() async throws
{
    let container = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let directory = container.appendingPathComponent("capture")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: container) }
    try Data(contentsOf: fixtureDirectory.appendingPathComponent("block.glb")).write(to: container.appendingPathComponent("private.glb"))
    try FileManager.default.createSymbolicLink(atPath: directory.appendingPathComponent("link.glb").path, withDestinationPath: "../private.glb")
    let file = directory.appendingPathComponent("tileset.json")
    for uri in ["../private.glb", "link.glb", "tileset.json"]
    {
        let json: [String: Any] = [
            "asset": ["version": "1.1"],
            "root": ["boundingVolume": ["sphere": [6378137, 0, 0, 10]], "geometricError": 0, "content": ["uri": uri]],
        ]
        try JSONSerialization.data(withJSONObject: json).write(to: file)
        do
        {
            _ = try await EarthCaptureImporter().importFile(fileURL: file)
            Issue.record("Invalid tileset reference unexpectedly imported.")
        }
        catch EarthImportError.inaccessibleSource
        {
            #expect(uri != "tileset.json")
        }
        catch EarthImportError.invalidContent
        {
            #expect(uri == "tileset.json")
        }
    }
    let outsideManifest = container.appendingPathComponent("outside.json")
    try Data(contentsOf: file).write(to: outsideManifest)
    let linkedManifest = directory.appendingPathComponent("linked.json")
    try FileManager.default.createSymbolicLink(atPath: linkedManifest.path, withDestinationPath: outsideManifest.path)
    do
    {
        _ = try await EarthCaptureImporter().importFile(fileURL: linkedManifest)
        Issue.record("A linked root manifest escaped the selected directory.")
    }
    catch EarthImportError.inaccessibleSource {}
}

@Test func anAlreadyCancelledImportDoesNotPublishACapture() async throws
{
    let importer = EarthCaptureImporter()
    let task = Task
    {
        withUnsafeCurrentTask { $0?.cancel() }
        return try await importer.importFile(fileURL: fixtureDirectory.appendingPathComponent("tileset.json"))
    }
    await #expect(throws: CancellationError.self) { try await task.value }
}

// Analytic source geometry exercises exact degeneracy, small valid surfaces,
// translation cancellation and reflected/nonuniform transforms independently.
func flatNormalFixture(positions: [SIMD3<Float>], indices: [UInt32], transform: simd_double4x4 = matrix_identity_double4x4) throws -> Data
{
    let vertices = positions.map { EarthVertex(position: $0, normal: SIMD3(0, 0, 1), textureCoordinate: SIMD2($0.x, $0.y), color: SIMD4(0.2, 0.4, 0.6, 1)) }
    let material = EarthMaterial(name: "Analytic", baseColor: SIMD4(repeating: 1), baseColorTexture: nil, metallic: 0, roughness: 1, isUnlit: false, isDoubleSided: false, alphaMode: .opaque, alphaCutoff: 0.5)
    let source = try EarthDerivativeGLB.encode(vertices: vertices, indices: indices, material: material, name: "Analytic", attributions: [], sourceID: "analytic")
    let length = Int(source.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: 12, as: UInt32.self)) })
    var json = try #require(JSONSerialization.jsonObject(with: source.subdata(in: 20 ..< 20 + length)) as? [String: Any])
    var meshes = try #require(json["meshes"] as? [[String: Any]])
    var primitives = try #require(meshes[0]["primitives"] as? [[String: Any]])
    var attributes = try #require(primitives[0]["attributes"] as? [String: Any])
    attributes["NORMAL"] = nil
    primitives[0]["attributes"] = attributes
    meshes[0]["primitives"] = primitives
    json["meshes"] = meshes
    json["nodes"] = [["mesh": 0, "matrix": [transform.columns.0, transform.columns.1, transform.columns.2, transform.columns.3].flatMap { [$0.x, $0.y, $0.z, $0.w] }]]
    var encoded = try JSONSerialization.data(withJSONObject: json)
    while !encoded.count.isMultiple(of: 4) { encoded.append(32) }
    let binary = source.suffix(from: 20 + length)
    var result = Data()
    for var word in [UInt32(0x46546C67), 2, UInt32(20 + encoded.count + binary.count), UInt32(encoded.count), 0x4E4F534A].map(\.littleEndian)
    { withUnsafeBytes(of: &word) { result.append(contentsOf: $0) } }
    result.append(encoded)
    result.append(binary)
    return result
}

@Test func flatNormalsOmitOnlyZeroAreaTrianglesAndRetainSourceBytes() async throws
{
    let source = try flatNormalFixture(positions: [.zero, SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(2, 0, 0)], indices: [0, 0, 1, 0, 1, 3, 0, 1, 2])
    let capture = try await EarthCaptureImporter(limits: EarthImportLimits(maximumVertices: 4)).importSourceFiles(sourceFiles: [.init(relativePath: "analytic.glb", data: source)], rootSourcePath: "analytic.glb")
    #expect(capture.triangleCount == 1 && capture.vertexCount == 3)
    #expect(capture.omittedDegenerateTriangleCount == 2)
    let mesh = try #require(capture.meshes.first)
    #expect(mesh.vertices.map(\.position) == [.zero, SIMD3(1, 0, 0), SIMD3(0, 1, 0)])
    #expect(mesh.vertices.allSatisfy { $0.normal == SIMD3(0, 0, 1) && $0.textureCoordinate == SIMD2($0.position.x, $0.position.y) && $0.color == SIMD4(0.2, 0.4, 0.6, 1) })
    #expect(capture.sourceFiles.first?.data == source)
}

private enum FlatNormalPrecision: CaseIterable, Sendable { case tiny, translated, reflected }

@Test(arguments: FlatNormalPrecision.allCases)
private func flatNormalsPreserveNonzeroSurfacesAndTransformedDirection(scenario: FlatNormalPrecision) async throws
{
    var transform = matrix_identity_double4x4
    let positions: [SIMD3<Float>]
    let expected: SIMD3<Float>
    switch scenario
    {
        case .tiny:
            positions = [.zero, SIMD3(0.000001, 0, 0), SIMD3(0, 0.000001, 0)]
            expected = SIMD3(0, 0, 1)
        case .translated:
            transform.columns.3 = SIMD4(1e12, 1e12, 1e12, 1)
            positions = [.zero, SIMD3(1, 0, 0), SIMD3(0, 1, 0)]
            expected = SIMD3(0, 0, 1)
        case .reflected:
            transform.columns.0.x = -2
            transform.columns.1.y = 3
            transform.columns.2.z = 4
            positions = [.zero, SIMD3(1, 0, 1), SIMD3(0, 1, 1)]
            expected = simd_normalize(SIMD3(6, -4, 3))
    }
    let source = try flatNormalFixture(positions: positions, indices: [0, 1, 2], transform: transform)
    let capture = try await EarthCaptureImporter().importSourceFiles(sourceFiles: [.init(relativePath: "analytic.glb", data: source)], rootSourcePath: "analytic.glb")
    #expect(capture.triangleCount == 1 && capture.omittedDegenerateTriangleCount == 0)
    let mesh = try #require(capture.meshes.first)
    #expect(mesh.vertices.allSatisfy { simd_distance($0.normal, expected) < 0.000001 })
    if scenario == .reflected
    {
        let direction = simd_cross(mesh.vertices[1].position - mesh.vertices[0].position, mesh.vertices[2].position - mesh.vertices[0].position)
        #expect(simd_dot(direction, expected) > 0)
    }
}

@Test func flatNormalsRejectEntirelyDegenerateContent() async throws
{
    let source = try flatNormalFixture(positions: [.zero, SIMD3(1, 0, 0), SIMD3(2, 0, 0)], indices: [0, 0, 1, 0, 1, 2])
    do
    {
        _ = try await EarthCaptureImporter().importSourceFiles(sourceFiles: [.init(relativePath: "analytic.glb", data: source)], rootSourcePath: "analytic.glb")
        Issue.record("A scene with only zero-area surfaces was accepted.")
    }
    catch let EarthImportError.invalidContent(reason) { #expect(reason.contains("no usable triangle geometry")) }
}

@Test func flatNormalsStillRejectNonFiniteSourceGeometry() async throws
{
    var source = try flatNormalFixture(positions: [.zero, SIMD3(1, 0, 0), SIMD3(0, 1, 0)], indices: [0, 0, 1, 0, 1, 2])
    let length = Int(source.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: 12, as: UInt32.self)) })
    var invalid = Float.infinity.bitPattern.littleEndian
    withUnsafeBytes(of: &invalid) { source.replaceSubrange(28 + length ..< 32 + length, with: $0) }
    await #expect(throws: EarthImportError.self)
    { try await EarthCaptureImporter().importSourceFiles(sourceFiles: [.init(relativePath: "analytic.glb", data: source)], rootSourcePath: "analytic.glb") }
}
