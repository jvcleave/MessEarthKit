import Foundation
@testable import MessEarthKit
import simd
import Testing

// Reuse the independent authored/Draco fixtures and triangle/material comparer.
// Distinct risks: local placement, baked reflections/UVs/colors, generated
// normals, compressed-to-ordinary geometry, selection and embedded image bytes.
@Test(arguments: GeometrySplitCase.allCases)
func combinedGLBPreservesSelectedModels(scenario: GeometrySplitCase) async throws
{
    let parent = try preparationParent()
    defer { try? FileManager.default.removeItem(at: parent) }
    let raw = try preparationArchive(parent: parent, count: 3, sourceOverride: subdivisionFixture(scenario: scenario))
    let profile = try EarthPreparationProfile(maximumPlacementsPerModel: 1)
    let catalog = try await EarthModelPreparer().prepare(archive: raw, directoryURL: parent.appendingPathComponent("prepared"), profile: profile)
    let exporter = EarthGLBExporter()
    // Sparse selected IDs remain the same after saving/reopening a subset.
    let subsetRoot = try await EarthCaptureStore().save(collection: catalog, selection: .only([1, 3]), directoryURL: parent.appendingPathComponent("subset"))
    let subset = try await EarthPreparedCollection.open(directoryURL: subsetRoot.deletingLastPathComponent())
    let plan = try await exporter.preflight(collection: subset, destination: profile)
    #expect(plan.canExport && plan.selectedModelCount == 2 && !plan.coversEntireSource)
    let target = parent.appendingPathComponent("combined.glb")
    try await exporter.export(plan: plan, fileURL: target)
    let capture = try await EarthCaptureImporter(limits: profile.importLimits).importFile(fileURL: target)
    let first = try await catalog.importModel(id: 1)
    let last = try await catalog.importModel(id: 3)
    #expect(subdivisionTriangleSignatures(capture) == (subdivisionTriangleSignatures(first) + subdivisionTriangleSignatures(last)).sorted())
    #expect(capture.geographicOrigin == raw.request.center && capture.incompleteReason == nil)
    #expect(capture.attributions == first.attributions)
    #expect(try target.resourceValues(forKeys: [.fileSizeKey]).fileSize == plan.outputByteCount)
    // Independent fixture dimensions anchor placement rather than only comparing
    // two paths through the exporter. The omitted middle model adds no triangles.
    if scenario == .authored
    {
        #expect(capture.triangleCount == 28 && simd_distance(capture.bounds.minimum, SIMD3(-4, 0.5, -5)) < 0.001)
        // The fixture ground is 4 m wide, translated 1 m by its parent node.
        #expect(abs(capture.bounds.maximum.x - 20) < 0.001)
    }
    let json = try EarthGLBDecoder(limits: profile.importLimits).preflight(data: Data(contentsOf: target))
    let metadata = try #require(try EarthCombinedGLBMetadata.read(json: json))
    #expect(metadata.selectedModels == [1, 3] && metadata.sourceIdentifier == catalog.sourceIdentifier)
    #expect(metadata.sourceProfile == profile && metadata.destinationProfile == profile)
}

private enum CombinedBudget: CaseIterable, Sendable { case vertices, indices, textures, nodes, fileBytes }

@Test func captureIdentityRejectsAnUnsupportedDeclaredVersion() throws
{
    let identity = try EarthCaptureIdentity(locationName: "Named capture", request: EarthDownloadRequest(center: EarthGeographicOrigin(latitude: 41, longitude: -87)), detailName: "high")
    var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(identity)) as? [String: Any])
    json["formatVersion"] = 999
    let invalid = try JSONSerialization.data(withJSONObject: json)
    #expect(throws: EarthImportError.self) { try JSONDecoder().decode(EarthCaptureIdentity.self, from: invalid) }
    #expect(throws: EarthImportError.self) { try EarthCaptureIdentity.readMetadata(json: ["extras": ["messEarthKitCaptureIdentity": json]]) }
}

// Omission accounting must not multiply with subdivision, and must survive
// repeated placements and standalone delivery without changing raw payloads.
@Test func combinedGLBRetainsDegenerateTriangleOmissionsThroughPreparation() async throws
{
    let source = try flatNormalFixture(positions: [.zero, SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(2, 0, 0)], indices: [0, 0, 1, 0, 1, 3, 0, 1, 2, 1, 3, 2])
    let parent = try preparationParent()
    defer { try? FileManager.default.removeItem(at: parent) }
    let raw = try preparationArchive(parent: parent, count: 2, sourceOverride: source)
    let rawPayload = try #require(FileManager.default.contentsOfDirectory(at: raw.directoryURL.appendingPathComponent("tiles"), includingPropertiesForKeys: nil).first)
    let profile = try EarthPreparationProfile(maximumVerticesPerModel: 3, maximumIndicesPerModel: 3, maximumPlacementsPerModel: 1)
    let catalog = try await EarthModelPreparer().prepare(archive: raw, directoryURL: parent.appendingPathComponent("prepared"), profile: profile)
    #expect(catalog.modelCount == 4)
    var omissions = 0
    for model in try await catalog.models()
    {
        let capture = try await catalog.importModel(id: model.id)
        omissions += capture.omittedDegenerateTriangleCount
    }
    #expect(omissions == 4)
    let exporter = EarthGLBExporter()
    let destination = try EarthPreparationProfile()
    let plan = try await exporter.preflight(collection: catalog, destination: destination)
    let target = parent.appendingPathComponent("recovered.glb")
    try await exporter.export(plan: plan, fileURL: target)
    let restored = try await EarthCaptureImporter().importFile(fileURL: target)
    #expect(restored.triangleCount == 4 && restored.omittedDegenerateTriangleCount == 4)
    #expect(try Data(contentsOf: rawPayload) == source)
}

// Distinct risks: geometry-only admission must ignore source texture costs,
// omit image bytes/references, and retain placement, attributes and material factors.
@Test func combinedGLBWithoutTexturesRetainsGeometryAndSourceImages() async throws
{
    let parent = try preparationParent()
    defer { try? FileManager.default.removeItem(at: parent) }
    let raw = try preparationArchive(parent: parent, count: 2)
    let profile = try EarthPreparationProfile(maximumPlacementsPerModel: 1)
    let catalog = try await EarthModelPreparer().prepare(archive: raw, directoryURL: parent.appendingPathComponent("prepared"), profile: profile)
    let first = try await catalog.importModel(id: 1)
    let last = try await catalog.importModel(id: 2)
    let image = try #require(first.materials.compactMap(\.baseColorTexture).first)
    let originalManifest = try Data(contentsOf: #require(catalog.rootSourceURL))
    let destination = try EarthPreparationProfile(maximumDecodedTextureBytesPerModel: 1, maximumTextureDimension: 1)
    let exporter = EarthGLBExporter()
    let textured = try await exporter.preflight(collection: catalog, destination: destination)
    #expect(textured.includesTextures && !textured.canExport)
    await #expect(throws: EarthGLBExportError.invalidOptions)
    { try await exporter.preflight(collection: catalog, destination: destination, options: .init(includeTextureCoordinates: false)) }
    await #expect(throws: EarthGLBExportError.invalidOptions)
    { try await exporter.preflight(collection: catalog, destination: destination, options: .init(includeMaterials: false)) }
    let plan = try await exporter.preflight(collection: catalog, destination: destination, options: .untextured)
    #expect(plan.canExport && !plan.includesTextures && plan.coversEntireSource)
    #expect(plan.estimate.decodedTextureBytes == 0 && plan.estimate.largestTextureDimension == 0)
    let target = try await exporter.export(plan: plan, fileURL: parent.appendingPathComponent("geometry.glb"))
    let bytes = try Data(contentsOf: target)
    let json = try EarthGLBDecoder(limits: destination.importLimits).preflight(data: bytes)
    #expect(json["images"] == nil && json["textures"] == nil && json["samplers"] == nil)
    #expect(bytes.range(of: image.encodedImage) == nil)
    let capture = try await EarthCaptureImporter(limits: destination.importLimits).importFile(fileURL: target)
    let expected = subdivisionTriangleSignatures(first, includingTextures: false) + subdivisionTriangleSignatures(last, includingTextures: false)
    #expect(subdivisionTriangleSignatures(capture) == expected.sorted())
    #expect(capture.materials.allSatisfy { $0.baseColorTexture == nil })
    #expect(capture.geographicOrigin == raw.request.center && capture.attributions == first.attributions)
    #expect(try Data(contentsOf: #require(catalog.rootSourceURL)) == originalManifest)
    let reopened = try await catalog.importModel(id: 1)
    #expect(reopened.materials.compactMap(\.baseColorTexture).first?.encodedImage == image.encodedImage)
}

private enum OptionalGLBData: CaseIterable, Sendable
{
    case normals, colors, coordinates, materials, minimal

    var options: EarthGLBExportOptions
    {
        switch self
        {
            case .normals: .init(includeNormals: false)
            case .colors: .init(includeVertexColors: false)
            case .coordinates: .init(includeTextureCoordinates: false, includeTextures: false)
            case .materials: .init(includeMaterials: false, includeTextures: false)
            case .minimal: .minimal
        }
    }

    // Independent glTF float-layout expectations, including required positions.
    var stride: Int
    {
        switch self
        {
            case .normals: 36
            case .colors: 32
            case .coordinates: 40
            case .materials: 48
            case .minimal: 12
        }
    }
}

// Optional attributes must change the actual binary stride, not just the JSON.
// The native decoder independently checks values, indexing and placement against
// the established authored fixture, including when it regenerates absent normals.
@Test(arguments: OptionalGLBData.allCases)
private func combinedGLBOmitsSelectedDataWithoutChangingRetainedValues(scenario: OptionalGLBData) async throws
{
    let parent = try preparationParent()
    defer { try? FileManager.default.removeItem(at: parent) }
    let raw = try preparationArchive(parent: parent, count: 2)
    let profile = try EarthPreparationProfile(maximumPlacementsPerModel: 1)
    let catalog = try await EarthModelPreparer().prepare(archive: raw, directoryURL: parent.appendingPathComponent("prepared"), profile: profile)
    let first = try await catalog.importModel(id: 1)
    let last = try await catalog.importModel(id: 2)
    let expected = first.meshes + last.meshes
    let options = scenario.options
    let exporter = EarthGLBExporter()
    let plan = try await exporter.preflight(collection: catalog, destination: .init(), options: options)
    let target = try await exporter.export(plan: plan, fileURL: parent.appendingPathComponent("optional.glb"))
    let bytes = try Data(contentsOf: target)
    #expect(bytes.count == plan.outputByteCount)
    let json = try EarthGLBDecoder(limits: .init()).preflight(data: bytes)
    let views = try #require(json["bufferViews"] as? [[String: Any]])
    #expect(views.compactMap { $0["byteStride"] as? Int } == Array(repeating: scenario.stride, count: expected.count))
    let meshes = try #require(json["meshes"] as? [[String: Any]])
    for mesh in meshes
    {
        let primitive = try #require((mesh["primitives"] as? [[String: Any]])?.first)
        let attributes = try #require(primitive["attributes"] as? [String: Int])
        #expect((attributes["NORMAL"] != nil) == options.includeNormals)
        #expect((attributes["TEXCOORD_0"] != nil) == options.includeTextureCoordinates)
        #expect((attributes["COLOR_0"] != nil) == options.includeVertexColors)
        #expect((primitive["material"] != nil) == options.includeMaterials)
    }
    if !options.includeMaterials { #expect(json["materials"] == nil && json["extensionsUsed"] == nil) }
    let extras = try #require(json["extras"] as? [String: Any])
    let recorded = try JSONSerialization.data(withJSONObject: #require(extras["messEarthKitExportOptions"]))
    #expect(try JSONDecoder().decode(EarthGLBExportOptions.self, from: recorded) == options)
    let restored = try await EarthCaptureImporter().importFile(fileURL: target)
    try #require(restored.meshes.count == expected.count)
    for (actual, source) in zip(restored.meshes, expected)
    {
        let actualVertices = actual.triangleIndices.map { actual.vertices[Int($0)] }
        let sourceVertices = source.triangleIndices.map { source.vertices[Int($0)] }
        #expect(actualVertices.map(\.position) == sourceVertices.map(\.position))
        if options.includeNormals
        { #expect(zip(actualVertices, sourceVertices).allSatisfy { simd_distance($0.normal, $1.normal) < 0.00001 }) }
        if options.includeTextureCoordinates
        { #expect(actualVertices.map(\.textureCoordinate) == sourceVertices.map(\.textureCoordinate)) }
        if options.includeVertexColors
        { #expect(actualVertices.map(\.color) == sourceVertices.map(\.color)) }
    }
    #expect(restored.geographicOrigin == raw.request.center && restored.attributions == first.attributions)
}

@Test(arguments: CombinedBudget.allCases)
private func combinedGLBPreflightRejectsDestinationExcessBeforeOutput(budget: CombinedBudget) async throws
{
    let parent = try preparationParent()
    defer { try? FileManager.default.removeItem(at: parent) }
    let raw = try preparationArchive(parent: parent, count: 2)
    let profile = try EarthPreparationProfile(maximumPlacementsPerModel: 1)
    let catalog = try await EarthModelPreparer().prepare(archive: raw, directoryURL: parent.appendingPathComponent("prepared"), profile: profile)
    let destination = try EarthPreparationProfile(
        maximumVerticesPerModel: budget == .vertices ? 28 : 2000000,
        maximumIndicesPerModel: budget == .indices ? 42 : 6000000,
        maximumDecodedTextureBytesPerModel: budget == .textures ? 16 : 256 * 1024 * 1024,
        maximumSourceBytesPerModel: budget == .fileBytes ? 100 : 128 * 1024 * 1024,
        maximumNodesPerPayload: budget == .nodes ? 1 : 4096
    )
    let exporter = EarthGLBExporter()
    let plan = try await exporter.preflight(collection: catalog, destination: destination)
    #expect(!plan.canExport && !plan.issues.isEmpty)
    let output = parent.appendingPathComponent("blocked.glb")
    await #expect(throws: EarthGLBExportError.self) { try await exporter.export(plan: plan, fileURL: output) }
    #expect(!FileManager.default.fileExists(atPath: output.path))
}

@Test func combinedGLBRetainsInputsOnCancellationChangeAndExistingDestination() async throws
{
    let parent = try preparationParent()
    defer { try? FileManager.default.removeItem(at: parent) }
    let raw = try preparationArchive(parent: parent, count: 2)
    let profile = try EarthPreparationProfile(maximumPlacementsPerModel: 1)
    let catalog = try await EarthModelPreparer().prepare(archive: raw, directoryURL: parent.appendingPathComponent("prepared"), profile: profile)
    let exporter = EarthGLBExporter()
    let plan = try await exporter.preflight(collection: catalog, destination: profile)
    #expect(plan.coversEntireSource)
    let output = parent.appendingPathComponent("cancelled.glb")
    let task = Task
    {
        try await exporter.export(plan: plan, fileURL: output)
        { progress in if progress.completedModels == 1 { withUnsafeCurrentTask { $0?.cancel() } } }
    }
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(!FileManager.default.fileExists(atPath: output.path))
    #expect(try FileManager.default.contentsOfDirectory(atPath: parent.path).allSatisfy { !$0.hasSuffix(".partial") })
    let existing = parent.appendingPathComponent("existing.glb")
    try Data("keep".utf8).write(to: existing)
    await #expect(throws: EarthGLBExportError.invalidDestination) { try await exporter.export(plan: plan, fileURL: existing) }
    #expect(try Data(contentsOf: existing) == Data("keep".utf8))
    await #expect(throws: EarthGLBExportError.invalidDestination) { try await exporter.export(plan: plan, fileURL: raw.directoryURL.appendingPathComponent("combined.glb")) }
    let model = try #require(try await catalog.models(limit: 1).first)
    let manifest = try Data(contentsOf: model.rootSourceURL)
    try (manifest + Data([32])).write(to: model.rootSourceURL)
    await #expect(throws: EarthGLBExportError.sourceChanged) { try await exporter.export(plan: plan, fileURL: output) }
    #expect(!FileManager.default.fileExists(atPath: output.path))
    #expect(try await EarthSourceArchive.open(directoryURL: raw.directoryURL).state == .downloaded)
    #expect(try await catalog.importModel(id: 2).triangleCount == 14)
}

@Test func combinedGLBRetainsPartialPreparationWarning() async throws
{
    let parent = try preparationParent()
    defer { try? FileManager.default.removeItem(at: parent) }
    let raw = try preparationArchive(parent: parent, count: 2)
    let profile = try EarthPreparationProfile(maximumPlacementsPerModel: 1)
    let directory = parent.appendingPathComponent("prepared")
    let task = Task
    {
        try await EarthModelPreparer().prepare(archive: raw, directoryURL: directory, profile: profile)
        { progress in if progress.completedModels == 1 { withUnsafeCurrentTask { $0?.cancel() } } }
    }
    await #expect(throws: CancellationError.self) { try await task.value }
    let partial = try await EarthPreparedCollection.open(directoryURL: directory)
    let issue = try #require(partial.interruptionReason)
    let exporter = EarthGLBExporter()
    let plan = try await exporter.preflight(collection: partial, selection: .only([1]), destination: profile)
    #expect(plan.canExport && !plan.coversEntireSource)
    let target = try await exporter.export(plan: plan, fileURL: parent.appendingPathComponent("partial.glb"))
    let capture = try await EarthCaptureImporter().importFile(fileURL: target)
    #expect(capture.incompleteReason == issue && capture.triangleCount == 14)
}
