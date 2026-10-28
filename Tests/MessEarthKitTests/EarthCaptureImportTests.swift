import Foundation
import MessEarthKit
import simd
import Testing

private let fixtureDirectory = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Tools/IntegrationProbe/Fixtures/Orientation")

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
