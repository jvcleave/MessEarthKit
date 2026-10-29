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
