import Foundation
@testable import MessEarthKit
import simd
import Testing

/// Builds a valid raw artifact from the independent authored orientation GLB.
/// Payloads are streamed; many placements reuse a small source asset.
func preparationArchive(parent: URL, count: Int, largePayloads: Int = 0, uniqueSmallPayloads: Bool = false, compressed: Bool = false, sourceOverride: Data? = nil) throws -> EarthSourceArchive
{
    let resources = try precheckFixtureResources(flatNormals: false)
    let original: Data
    if let sourceOverride { original = sourceOverride }
    else if compressed
    {
        original = try Data(contentsOf: #require(Bundle.module.url(forResource: "Fixtures", withExtension: nil)).appendingPathComponent("DracoBox/BoxDraco.glb"))
    }
    else { original = resources["/v1/3dtiles/block.glb"]! }
    let directory = parent.appendingPathComponent("raw")
    let request = try EarthDownloadRequest(center: EarthGeographicOrigin(latitude: 0, longitude: 0), widthMeters: max(20, Double(count) * 20), depthMeters: 20)
    let index = try EarthAcquisitionIndex(directoryURL: directory, creating: request)
    let run = try index.begin(request: request)
    let assetCount = uniqueSmallPayloads ? count : min(count, largePayloads + 1)
    var ids: [String] = []
    for asset in 0 ..< assetCount
    {
        let id = EarthSourceAccess.digest(Data("fixture-\(asset)".utf8))
        ids.append(id)
        let file = try index.files.checked("tiles/\(id).glb")
        if asset < largePayloads { try writePaddedPreparationGLB(original, to: file) }
        else { try original.write(to: file) }
        let integrity = try index.files.integrity(file)
        try index.pending(id)
        try index.stage(id, bytes: integrity.bytes, hash: integrity.hash)
        try index.complete(id, run: run)
    }
    let earth = try JSONDecoder().decode(EarthTileset.self, from: resources["/v1/3dtiles/root.json"]!).root.localTransform()
    for ordinal in 0 ..< count
    {
        var placement = matrix_identity_double4x4
        placement.columns.3.x = -5 + Double(ordinal) * 10
        let transform = earth * placement
        let columns = [transform.columns.0, transform.columns.1, transform.columns.2, transform.columns.3]
        let id = ids[min(ordinal, ids.count - 1)]
        let tile = EarthTileset.Tile(boundingVolume: .init(box: nil, sphere: [2, 2, 1, 6], region: nil), geometricError: 0, transform: columns.flatMap { [$0.x, $0.y, $0.z, $0.w] }, refine: "REPLACE", content: .init(uri: "tiles/\(id).glb"), contents: nil, children: nil, implicitTiling: nil)
        try index.place(tile: tile, run: run, ordinal: ordinal)
    }
    try EarthSourceMetadata.publishManifest(index: index, request: request)
    try index.finish(state: .downloaded)
    return try index.snapshot()
}

private func writePaddedPreparationGLB(_ original: Data, to file: URL) throws
{
    let jsonLength = Int(original.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: 12, as: UInt32.self)) })
    var json = try JSONSerialization.jsonObject(with: original.subdata(in: 20 ..< 20 + jsonLength)) as! [String: Any]
    var buffers = json["buffers"] as! [[String: Any]]
    let binaryLength = 17 * 1024 * 1024
    buffers[0]["byteLength"] = binaryLength
    json["buffers"] = buffers
    var encoded = try JSONSerialization.data(withJSONObject: json, options: [.withoutEscapingSlashes])
    while !encoded.count.isMultiple(of: 4) { encoded.append(32) }
    guard FileManager.default.createFile(atPath: file.path, contents: nil) else { throw EarthPreparationError.storage }
    let output = try FileHandle(forWritingTo: file)
    defer { try? output.close() }
    func words(_ values: [UInt32]) throws
    {
        var bytes = Data()
        for var value in values.map(\.littleEndian) { withUnsafeBytes(of: &value) { bytes.append(contentsOf: $0) } }
        try output.write(contentsOf: bytes)
    }
    try words([0x46546C67, 2, UInt32(28 + encoded.count + binaryLength), UInt32(encoded.count), 0x4E4F534A])
    try output.write(contentsOf: encoded)
    try words([UInt32(binaryLength), 0x004E4942])
    let binary = original.suffix(from: 28 + jsonLength)
    try output.write(contentsOf: binary)
    var remaining = binaryLength - binary.count
    let chunk = Data(repeating: 0, count: 65536)
    while remaining > 0
    {
        let count = min(remaining, chunk.count)
        try output.write(contentsOf: chunk.prefix(count))
        remaining -= count
    }
}

func preparationParent() throws -> URL
{
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    return directory
}

@Test func fileBackedPreparationPagesLargeCaptureAndExportsAlignedSubset() async throws
{
    let parent = try preparationParent()
    defer { try? FileManager.default.removeItem(at: parent) }
    let raw = try preparationArchive(parent: parent, count: 4100, largePayloads: 8)
    #expect(raw.downloadedBytes > 128 * 1024 * 1024)
    let before = try EarthAcquisitionFiles(directoryURL: raw.directoryURL).integrity(#require(raw.rootSourceURL)).hash
    let profile = try EarthPreparationProfile(maximumSourceBytesPerModel: 20 * 1024 * 1024, maximumPlacementsPerModel: 1)
    let catalog = try await EarthModelPreparer().prepare(archive: raw, directoryURL: parent.appendingPathComponent("prepared"), profile: profile)
    #expect(catalog.state == .ready && catalog.modelCount == 4100 && catalog.coversEntireSource)
    #expect(try await raw.sourceIdentifier() == catalog.sourceIdentifier)
    let page = try await catalog.models(offset: 4090, limit: 50)
    #expect(page.map(\.id) == Array(4091 ... 4100))
    let selectedIDs: Set<Int> = [1, 65, 4100]
    let saved = try await EarthCaptureStore().save(collection: catalog, selection: .only(selectedIDs), directoryURL: parent.appendingPathComponent("subset"))
    let reopened = try await EarthPreparedCollection.open(directoryURL: saved.deletingLastPathComponent())
    #expect(reopened.modelCount == 3 && !reopened.coversEntireSource && reopened.profile == profile)
    #expect(try await reopened.models().map(\.id) == [1, 65, 4100])
    for id in [1, 4100]
    {
        let decoded = try await reopened.importModel(id: id)
        let expected = SIMD3<Float>(-4 + Float(id - 1) * 10, 0.5, -5)
        #expect(decoded.meshes.count == 2 && simd_distance(decoded.bounds.minimum, expected) < 0.001)
    }
    let rootJSON = try JSONSerialization.jsonObject(with: Data(contentsOf: saved)) as! [String: Any]
    #expect(((rootJSON["root"] as? [String: Any])?["children"] as? [Any])?.count == 3)
    #expect(try EarthAcquisitionFiles(directoryURL: raw.directoryURL).integrity(#require(raw.rootSourceURL)).hash == before)
    // Derivative files must not alias either prepared or raw originals.
    let exported = try #require(try FileManager.default.contentsOfDirectory(at: parent.appendingPathComponent("subset/models/model-1/tiles"), includingPropertiesForKeys: nil).first)
    let original = parent.appendingPathComponent("prepared/models/model-1/tiles/\(exported.lastPathComponent)")
    let originalHash = try EarthAcquisitionFiles(directoryURL: catalog.directoryURL).integrity(original).hash
    try Data([1, 2, 3]).write(to: exported)
    #expect(try EarthAcquisitionFiles(directoryURL: catalog.directoryURL).integrity(original).hash == originalHash)
    let rejected = parent.appendingPathComponent("rejected-export")
    await #expect(throws: EarthPreparationError.sourceChanged) { try await EarthCaptureStore().save(collection: reopened, selection: .only([1]), directoryURL: rejected) }
    #expect(!FileManager.default.fileExists(atPath: rejected.path))
}

private enum PreparationBudget: CaseIterable, Sendable { case vertices, indices, textures, sourceBytes, placements }

@Test func preparedSourceMatchChecksPayloadHashesBeyondManifestIdentity() async throws
{
    let parent = try preparationParent()
    defer { try? FileManager.default.removeItem(at: parent) }
    let raw = try preparationArchive(parent: parent, count: 2)
    let catalog = try await EarthModelPreparer().prepare(archive: raw, directoryURL: parent.appendingPathComponent("prepared"), profile: EarthPreparationProfile())
    let other = parent.appendingPathComponent("other")
    try FileManager.default.createDirectory(at: other, withIntermediateDirectories: false)
    let changed = try preparationArchive(parent: other, count: 2, sourceOverride: subdivisionFixture(scenario: .reflectedUVs))
    // Publish the exact same hierarchy bytes; JSON key order from independent
    // fixture encoders is otherwise unspecified. Only the payload bytes differ.
    try Data(contentsOf: #require(raw.rootSourceURL)).write(to: #require(changed.rootSourceURL))
    let originalIdentity = try await raw.sourceIdentifier()
    let changedIdentity = try await changed.sourceIdentifier()
    #expect(originalIdentity == changedIdentity)
    #expect(try await catalog.matchesSource(raw))
    #expect(try await !catalog.matchesSource(changed))
}

@Test(arguments: PreparationBudget.allCases)
private func fileBackedPreparationPacksByDestinationRequirements(budget: PreparationBudget) async throws
{
    let parent = try preparationParent()
    defer { try? FileManager.default.removeItem(at: parent) }
    let raw = try preparationArchive(parent: parent, count: 3, uniqueSmallPayloads: true)
    let profile = try EarthPreparationProfile(
        maximumVerticesPerModel: budget == .vertices ? 28 : 2000000,
        maximumIndicesPerModel: budget == .indices ? 42 : 6000000,
        maximumDecodedTextureBytesPerModel: budget == .textures ? 16 : 256 * 1024 * 1024,
        maximumSourceBytesPerModel: budget == .sourceBytes ? 6312 : 128 * 1024 * 1024,
        maximumPlacementsPerModel: budget == .placements ? 1 : 64
    )
    let catalog = try await EarthModelPreparer().prepare(archive: raw, directoryURL: parent.appendingPathComponent("prepared"), profile: profile)
    #expect(catalog.modelCount == 3)
    let first = try #require(try await catalog.models(limit: 1).first)
    #expect(first.tileCount == 1)
    #expect(try await catalog.importModel(id: first.id).triangleCount == 14)
    if budget == .sourceBytes
    {
        // A looser profile is a new offline preparation of the same raw source.
        let larger = try EarthPreparationProfile()
        let regrouped = try await EarthModelPreparer().prepare(archive: raw, directoryURL: parent.appendingPathComponent("regrouped"), profile: larger)
        #expect(regrouped.modelCount == 1)
        await #expect(throws: EarthPreparationError.invalidCollection) { try await EarthCaptureStore().save(collection: catalog, selection: .only([999]), directoryURL: parent.appendingPathComponent("unknown")) }
        #expect(!FileManager.default.fileExists(atPath: parent.appendingPathComponent("unknown").path))
        await #expect(throws: EarthPreparationError.invalidCollection) { try await EarthCaptureStore().save(collection: catalog, directoryURL: raw.directoryURL) }
        await #expect(throws: EarthPreparationError.invalidDestination) { try await EarthModelPreparer().prepare(archive: raw, directoryURL: raw.directoryURL.appendingPathComponent("derived"), profile: larger) }
        await #expect(throws: EarthPreparationError.invalidDestination) { try await EarthCaptureStore().save(collection: catalog, directoryURL: catalog.directoryURL.appendingPathComponent("derived")) }
    }
}

private enum PreparationInterruption: CaseIterable, Sendable { case cancellation, publication }

@Test(arguments: PreparationInterruption.allCases)
private func fileBackedPreparationRetainsCommittedModelsOnInterruption(scenario: PreparationInterruption) async throws
{
    let parent = try preparationParent()
    defer { try? FileManager.default.removeItem(at: parent) }
    let raw = try preparationArchive(parent: parent, count: 4)
    let directory = parent.appendingPathComponent("prepared")
    let profile = try EarthPreparationProfile(maximumPlacementsPerModel: 1)
    let job = Task
    {
        try await EarthModelPreparer().prepare(archive: raw, directoryURL: directory, profile: profile)
        { progress in
            if progress.completedModels == 1
            {
                if scenario == .cancellation { withUnsafeCurrentTask { $0?.cancel() } }
                else { _ = FileManager.default.createFile(atPath: directory.appendingPathComponent("models/model-2").path, contents: Data()) }
            }
        }
    }
    if scenario == .cancellation { await #expect(throws: CancellationError.self) { try await job.value } }
    else { await #expect(throws: EarthPreparationError.storage) { try await job.value } }
    let partial = try await EarthPreparedCollection.open(directoryURL: directory)
    #expect(partial.state == .partial && partial.modelCount == 1 && partial.interruptionReason != nil)
    #expect(try await partial.importModel(id: 1).meshes.count == 2)
    #expect(try await EarthSourceArchive.open(directoryURL: raw.directoryURL).state == .downloaded)
    if scenario == .publication
    {
        let saved = try await EarthCaptureStore().save(collection: partial, directoryURL: parent.appendingPathComponent("partial-export"))
        #expect(try EarthCaptureManifest.incompleteReason(data: Data(contentsOf: saved)) != nil)
    }
}

@Test private func fileBackedPreparationRejectsAnUnfitSourceWorkingSet() async throws
{
    let parent = try preparationParent()
    defer { try? FileManager.default.removeItem(at: parent) }
    let raw = try preparationArchive(parent: parent, count: 1)
    let profile = try EarthPreparationProfile(maximumSourceBytesPerModel: 1024)
    let output = parent.appendingPathComponent("prepared")
    await #expect(throws: EarthPreparationError.subdivisionWorkingSet) { try await EarthModelPreparer().prepare(archive: raw, directoryURL: output, profile: profile) }
    #expect(try await EarthPreparedCollection.open(directoryURL: output).modelCount == 0)
    #expect(try await EarthSourceArchive.open(directoryURL: raw.directoryURL).state == .downloaded)
}

enum GeometrySplitCase: CaseIterable, Sendable { case authored, reflectedUVs, flatNormals, draco }

func subdivisionFixture(scenario: GeometrySplitCase) throws -> Data
{
    if scenario == .draco
    { return try Data(contentsOf: #require(Bundle.module.url(forResource: "Fixtures", withExtension: nil)).appendingPathComponent("DracoBox/BoxDraco.glb")) }
    let source = try #require(precheckFixtureResources(flatNormals: scenario == .flatNormals)["/v1/3dtiles/block.glb"])
    guard scenario == .reflectedUVs else { return source }
    let jsonLength = Int(source.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: 12, as: UInt32.self)) })
    var json = try JSONSerialization.jsonObject(with: source.subdata(in: 20 ..< 20 + jsonLength)) as! [String: Any]
    var nodes = json["nodes"] as! [[String: Any]]
    nodes[0]["scale"] = [-1, 2, 1]
    json["nodes"] = nodes
    var materials = json["materials"] as! [[String: Any]]
    var pbr = materials[0]["pbrMetallicRoughness"] as! [String: Any]
    var base = pbr["baseColorTexture"] as! [String: Any]
    base["extensions"] = ["KHR_texture_transform": ["offset": [0.1, 0.2], "scale": [0.5, 0.75], "rotation": 0.25]]
    pbr["baseColorTexture"] = base
    pbr["baseColorFactor"] = [0.8, 0.6, 0.4, 0.7]
    materials[0]["pbrMetallicRoughness"] = pbr
    materials[0]["alphaMode"] = "MASK"
    materials[0]["alphaCutoff"] = 0.3
    materials[0]["doubleSided"] = true
    json["materials"] = materials
    json["extensionsUsed"] = ["KHR_materials_unlit", "KHR_texture_transform"]
    json["samplers"] = [["magFilter": 9729, "minFilter": 9985, "wrapS": 10497, "wrapT": 33648]]
    var binaryPayload = Data(source.suffix(from: 28 + jsonLength))
    var views = json["bufferViews"] as! [[String: Any]]
    var accessors = json["accessors"] as! [[String: Any]]
    var meshes = json["meshes"] as! [[String: Any]]
    var primitives = meshes[0]["primitives"] as! [[String: Any]]
    for primitive in primitives.indices
    {
        var attributes = primitives[primitive]["attributes"] as! [String: Any]
        let positions = attributes["POSITION"] as! Int
        let count = accessors[positions]["count"] as! Int
        let offset = binaryPayload.count
        for index in 0 ..< count
        {
            for value in [Float(index % 2), Float(0.25), Float(0.75), Float(0.8)]
            { var word = value.bitPattern.littleEndian; withUnsafeBytes(of: &word) { binaryPayload.append(contentsOf: $0) } }
        }
        let view = views.count
        views.append(["buffer": 0, "byteOffset": offset, "byteLength": count * 16])
        attributes["COLOR_0"] = accessors.count
        accessors.append(["bufferView": view, "componentType": 5126, "count": count, "type": "VEC4"])
        primitives[primitive]["attributes"] = attributes
    }
    meshes[0]["primitives"] = primitives
    json["meshes"] = meshes
    json["accessors"] = accessors
    json["bufferViews"] = views
    json["buffers"] = [["byteLength": binaryPayload.count]]
    var encoded = try JSONSerialization.data(withJSONObject: json, options: [.withoutEscapingSlashes])
    while !encoded.count.isMultiple(of: 4) { encoded.append(32) }
    var binary = Data()
    for value in [UInt32(binaryPayload.count), 0x004E4942]
    { var word = value.littleEndian; withUnsafeBytes(of: &word) { binary.append(contentsOf: $0) } }
    binary.append(binaryPayload)
    var result = Data()
    for value in [UInt32(0x46546C67), 2, UInt32(20 + encoded.count + binary.count), UInt32(encoded.count), 0x4E4F534A]
    { var little = value.littleEndian; withUnsafeBytes(of: &little) { result.append(contentsOf: $0) } }
    result.append(encoded); result.append(binary)
    return result
}

/// A triangle retains ordered vertices, so swapped winding, duplicate/missing
/// triangles, normals, UV transforms, colors or material changes alter the bag.
func subdivisionTriangleSignatures(_ capture: EarthCapture) -> [String]
{
    func values(_ floats: [Float]) -> String { floats.map { String(Int64((Double($0) * 10000).rounded())) }.joined(separator: ",") }
    var result: [String] = []
    for mesh in capture.meshes
    {
        let material = capture.materials[mesh.materialIndex]
        let texture = material.baseColorTexture
        let materialKey = values([material.baseColor.x, material.baseColor.y, material.baseColor.z, material.baseColor.w, material.metallic, material.roughness, material.alphaCutoff]) + "\(material.alphaMode)\(material.isUnlit)\(material.isDoubleSided)\(texture.map { EarthSourceAccess.digest($0.encodedImage) } ?? "")\(texture?.wrapS as Any)\(texture?.wrapT as Any)\(texture?.mipmapFilter as Any)\(texture?.usesNearestMagnification as Any)\(texture?.usesNearestMinification as Any)"
        for index in stride(from: 0, to: mesh.triangleIndices.count, by: 3)
        {
            let vertices = mesh.triangleIndices[index ..< index + 3].map { mesh.vertices[Int($0)] }
            result.append(
                materialKey + vertices.map { vertex in values([vertex.position.x, vertex.position.y, vertex.position.z, vertex.normal.x, vertex.normal.y, vertex.normal.z, vertex.textureCoordinate.x, vertex.textureCoordinate.y, vertex.color.x, vertex.color.y, vertex.color.z, vertex.color.w]) }.joined(
                    separator: "|"
                )
            )
        }
    }
    return result.sorted()
}

@Test(arguments: GeometrySplitCase.allCases)
private func geometrySubdivisionPreservesPlacedTrianglesAndMaterials(scenario: GeometrySplitCase) async throws
{
    let parent = try preparationParent()
    defer { try? FileManager.default.removeItem(at: parent) }
    let raw = try preparationArchive(parent: parent, count: 2, sourceOverride: subdivisionFixture(scenario: scenario))
    let root = try #require(raw.rootSourceURL)
    let inputHash = try EarthAcquisitionFiles(directoryURL: raw.directoryURL).integrity(root).hash
    let reference = try await EarthCaptureImporter().importFile(fileURL: root)
    // Three-vertex/index triangles force a split within each original primitive.
    let profile = try EarthPreparationProfile(maximumVerticesPerModel: scenario == .reflectedUVs ? 2000000 : 3, maximumIndicesPerModel: scenario == .authored ? 6000000 : 3)
    let catalog = try await EarthModelPreparer().prepare(archive: raw, directoryURL: parent.appendingPathComponent("prepared"), profile: profile)
    #expect(catalog.modelCount == reference.triangleCount && catalog.coversEntireSource)
    var signatures: [String] = []
    for model in try await catalog.models(limit: 100)
    {
        let capture = try await catalog.importModel(id: model.id)
        #expect(capture.vertexCount == 3 && capture.triangleCount == 1)
        signatures += subdivisionTriangleSignatures(capture)
        #expect(capture.attributions == reference.attributions)
    }
    #expect(signatures.sorted() == subdivisionTriangleSignatures(reference))
    #expect(try EarthAcquisitionFiles(directoryURL: raw.directoryURL).integrity(root).hash == inputHash)
    if scenario == .authored
    {
        // Independent fixture specifies ground + box, 14 triangles per placement.
        #expect(reference.triangleCount == 28 && simd_distance(reference.bounds.minimum, SIMD3(-4, 0.5, -5)) < 0.001)
        let saved = try await EarthCaptureStore().save(collection: catalog, selection: .only([1, 28]), directoryURL: parent.appendingPathComponent("subset"))
        let subset = try await EarthPreparedCollection.open(directoryURL: saved.deletingLastPathComponent())
        #expect(!subset.coversEntireSource && subset.modelCount == 2)
        #expect(try await subset.importModel(id: 28).triangleCount == 1)
    }
}

@Test func geometrySubdivisionFitsAnOversizedSourceFileWithoutReducingGeometry() async throws
{
    let parent = try preparationParent()
    defer { try? FileManager.default.removeItem(at: parent) }
    let raw = try preparationArchive(parent: parent, count: 1, largePayloads: 1)
    let profile = try EarthPreparationProfile(maximumSourceBytesPerModel: 6312)
    let catalog = try await EarthModelPreparer().prepare(archive: raw, directoryURL: parent.appendingPathComponent("prepared"), profile: profile)
    var triangles = 0
    for model in try await catalog.models()
    {
        #expect(model.sourceByteCount <= profile.maximumSourceBytesPerModel)
        triangles += try await catalog.importModel(id: model.id).triangleCount
    }
    #expect(triangles == 14 && raw.downloadedBytes > 16 * 1024 * 1024)
    #expect(try await EarthSourceArchive.open(directoryURL: raw.directoryURL).downloadedBytes == raw.downloadedBytes)
}

@Test func geometrySubdivisionChecksCancellationBetweenParts() async throws
{
    let data = try subdivisionFixture(scenario: .authored)
    let job = Task
    {
        var emitted = 0
        let profile = try EarthPreparationProfile(maximumVerticesPerModel: 3, maximumIndicesPerModel: 3)
        try EarthGeometrySubdivision(profile: profile).writeParts(data: data, sourceID: "source", maximumPayloadBytes: 100000)
        { _, _ in emitted += 1; withUnsafeCurrentTask { $0?.cancel() } }
        return emitted
    }
    await #expect(throws: CancellationError.self) { try await job.value }
}
