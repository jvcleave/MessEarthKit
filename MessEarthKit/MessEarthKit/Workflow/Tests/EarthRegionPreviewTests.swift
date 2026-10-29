import Foundation
@testable import MessEarthKit
import Metal
import simd
import Testing

private func regionPreviewFixture(root: URL, origin: EarthGeographicOrigin? = nil) async throws -> (files: EarthAppFiles, store: EarthProjectStore, record: EarthProjectRecord, collection: EarthPreparedCollection)
{
    let files = try EarthAppFiles(storageRootURL: root)
    try await files.initialize()
    let store = EarthProjectStore(files: files)
    let record = try await store.create()
    let raw = try await projectSourceFixture(files: files, projectID: record.id, placements: 3, mipmapped: true, origin: origin)
    let capture = EarthProjectCapture(id: try #require(UUID(uuidString: raw.directoryURL.lastPathComponent)), request: raw.request)
    _ = try await store.recordCapture(id: record.id, capture: capture)
    let url = try await files.newArtifactDirectory(projectID: record.id, kind: .prepared)
    let profile = try EarthPreparationProfile(maximumPlacementsPerModel: 1)
    let collection = try await EarthModelPreparer().prepare(archive: raw, directoryURL: url, profile: profile)
    _ = try await store.recordPreparation(id: record.id, preparation: .init(id: #require(UUID(uuidString: url.lastPathComponent)), captureID: capture.id, profile: profile))
    return (files, store, try await store.record(id: record.id), collection)
}

private func previewTestResult(collection: EarthPreparedCollection, progress: @escaping @Sendable (EarthRegionPreviewProgress) -> Void, validate: @escaping @Sendable () async throws -> Void) async throws -> EarthRegionPreviewResult
{
    let device = try #require(MTLCreateSystemDefaultDevice())
    let scene = try await EarthRegionPreviewLoader(device: device).load(collection: collection, progress: progress, validateSource: validate)
    let source = try String(contentsOf: #require(Bundle.module.url(forResource: "EarthPreviewShaders", withExtension: "metal")), encoding: .utf8)
    let library = try await device.makeLibrary(source: source, options: nil)
    return try .init(renderer: EarthPreviewRenderer(device: device, library: library), scene: scene, appearancePolicy: collection.profile.appearancePolicy)
}

// Distinct GPU risk: all parts must survive upload in their shared coordinates,
// with full bounds, material values, top-left source pixels and requested mips.
// Reuse the authored orientation GLB; only its standard sampler enum is changed.
@Test(arguments: [false, true])
private func regionPreviewComposesAllPartsWithFullBoundsAndMaterialResources(nonzeroOrigin: Bool) async throws
{
    let root = try projectStoreTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let origin = try EarthGeographicOrigin(latitude: nonzeroOrigin ? 39.1031 : 0, longitude: nonzeroOrigin ? -84.5120 : 0)
    let fixture = try await regionPreviewFixture(root: root, origin: origin)
    let result = try await previewTestResult(collection: fixture.collection, progress: { _ in }, validate: {})
    let scene = result.scene
    #expect(scene.modelCount == 3 && scene.meshes.count == 6 && scene.meshes.reduce(0) { $0 + $1.indexCount } == 126)
    // The authored block after glTF→tile conversion occupies x=1…5, y=1…5,
    // z=0.5…1.3. Three explicit placements are 10 m apart along local East.
    let expectedMinimum = SIMD3<Float>(1, 1, 0.5)
    let expectedMaximum = SIMD3<Float>(25, 5, 1.3)
    #expect(simd_distance(scene.bounds.minimum, expectedMinimum) < 0.001 && simd_distance(scene.bounds.maximum, expectedMaximum) < 0.001)
    for aspect: Float in [0.4, 1.6]
    {
        let distance = EarthPreviewRenderer.fittingDistance(bounds: scene.bounds, aspect: aspect)
        let angle = asin(simd_length(scene.bounds.dimensions) / (2 * distance))
        #expect(angle < .pi / 8 && angle < atan(tan(Float.pi / 8) * aspect))
    }
    var minimum = SIMD3<Float>(repeating: .infinity)
    var maximum = SIMD3<Float>(repeating: -.infinity)
    for mesh in scene.meshes
    {
        let vertices = UnsafeBufferPointer(start: mesh.vertices.contents().assumingMemoryBound(to: EarthVertex.self), count: mesh.vertices.length / MemoryLayout<EarthVertex>.stride)
        for vertex in vertices { minimum = simd_min(minimum, vertex.position); maximum = simd_max(maximum, vertex.position) }
        #expect(mesh.material.isUnlit && mesh.material.alphaMode == .opaque)
    }
    #expect(simd_distance(minimum, expectedMinimum) < 0.001 && simd_distance(maximum, expectedMaximum) < 0.001)
    #expect(scene.attributions == ["MessEarthKit reference fixture"])
    let image = try #require(scene.meshes.first(where: { $0.texture.width == 2 })?.texture)
    #expect(image.mipmapLevelCount == 2)
    #expect(image.pixelFormat == .rgba8Unorm_srgb || image.pixelFormat == .bgra8Unorm_srgb)
    let device = image.device
    let output = try #require(device.makeBuffer(length: 512, options: .storageModeShared))
    let command = try #require(device.makeCommandQueue()?.makeCommandBuffer())
    let blit = try #require(command.makeBlitCommandEncoder())
    blit.copy(from: image, sourceSlice: 0, sourceLevel: 0, sourceOrigin: .init(x: 0, y: 0, z: 0), sourceSize: .init(width: 2, height: 2, depth: 1), to: output, destinationOffset: 0, destinationBytesPerRow: 256, destinationBytesPerImage: 512)
    blit.endEncoding()
    command.commit()
    await command.completed()
    #expect(command.status == .completed)
    let bytes = output.contents().assumingMemoryBound(to: UInt8.self)
    let corners = [0, 4, 256, 260].map
    { offset in
        let color = Array(UnsafeBufferPointer(start: bytes + offset, count: 4))
        return image.pixelFormat == .bgra8Unorm_srgb ? [color[2], color[1], color[0], color[3]] : color
    }
    #expect(corners == [[255, 0, 0, 255], [0, 255, 0, 255], [0, 0, 255, 255], [255, 255, 0, 255]])
}

private final class PreviewProgressRecord: @unchecked Sendable
{
    private let lock = NSLock()
    private var uploads = 0
    func record(_ progress: EarthRegionPreviewProgress)
    {
        lock.lock()
        if progress.phase == .uploading { uploads += 1 }
        lock.unlock()
    }

    var uploadCount: Int { lock.lock(); defer { lock.unlock() }; return uploads }
}

private enum PreviewInterruption: CaseIterable, Sendable { case aggregateBudget, cancelDuringUpload }

@Test(arguments: PreviewInterruption.allCases)
private func regionPreviewRejectsWholeSceneOrCancelsWithoutChangingSavedArtifacts(interruption: PreviewInterruption) async throws
{
    let root = try projectStoreTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let fixture = try await regionPreviewFixture(root: root)
    let device = try #require(MTLCreateSystemDefaultDevice())
    let builder = try EarthPreviewSceneBuilder(device: device)
    let capture = try await fixture.collection.importModel(id: 1)
    let partBytes = try builder.memoryCost(capture: capture).totalBytes
    // Admits one part plus upload headroom; rejects the whole three-part region.
    let budget = EarthPreviewMemoryBudget(limitBytes: builder.constantTextureBytes + partBytes * 2, existingBytes: 0, viewportReserveBytes: 0)
    let events = PreviewProgressRecord()
    let worker = Task.detached
    {
        try await EarthRegionPreviewLoader(device: device).load(
            collection: fixture.collection,
            budget: interruption == .aggregateBudget ? budget : nil,
            progress: { progress in
                events.record(progress)
                if interruption == .cancelDuringUpload, progress.phase == .uploading, progress.completed == 1
                { withUnsafeCurrentTask { $0?.cancel() } }
            },
            validateSource: {}
        )
    }
    if interruption == .aggregateBudget
    {
        await #expect(throws: EarthRegionPreviewError.workingSet) { try await worker.value }
        #expect(events.uploadCount == 0)
    }
    else
    {
        await #expect(throws: CancellationError.self) { try await worker.value }
        #expect(events.uploadCount == 1)
    }
    let reopened = try await fixture.store.open(id: fixture.record.id)
    #expect(reopened.record == fixture.record && reopened.archive?.state == .downloaded && reopened.prepared?.coversEntireSource == true)
}

@Test func regionPreviewAdmissionIncludesExistingSceneTransientUploadAndOverflow() throws
{
    let budget = EarthPreviewMemoryBudget(limitBytes: 1000, existingBytes: 300, viewportReserveBytes: 100)
    try budget.admit(sceneBytes: 400, largestPartBytes: 200)
    #expect(throws: EarthRegionPreviewError.workingSet) { try EarthPreviewMemoryBudget(limitBytes: 1000, existingBytes: 301, viewportReserveBytes: 100).admit(sceneBytes: 400, largestPartBytes: 200) }
    #expect(throws: EarthRegionPreviewError.workingSet) { try budget.admit(sceneBytes: 400, largestPartBytes: 201) }
    #expect(throws: EarthRegionPreviewError.workingSet) { try budget.admit(sceneBytes: Int.max, largestPartBytes: 0) }
}

@Test func regionPreviewAdmitsMeasuredAllocationAboveEstimateWithinItsBudget() throws
{
    // The initial forecast includes three parts and existing/viewport costs.
    // Driver overhead on the first part fits; the full budget remains the limit.
    let budget = EarthPreviewMemoryBudget(limitBytes: 1000, existingBytes: 100, viewportReserveBytes: 100)
    var plan = EarthPreviewMemoryPlan(sceneBytes: 300, largestPartBytes: 100)
    try plan.includeUpload(estimatedBytes: 100, allocatedBytes: 150, budget: budget)
    // Still account for remaining parts and the largest upload; checking only
    // allocated-so-far would incorrectly admit this second oversized part.
    #expect(throws: EarthRegionPreviewError.workingSet)
    { try plan.includeUpload(estimatedBytes: 100, allocatedBytes: 400, budget: budget) }
    #expect(throws: EarthRegionPreviewError.deviceWorkingSet(allocatedBytes: 901, allowedBytes: 900))
    { try budget.checkDeviceAllocation(901) }
}

private actor PreviewCompletionGate
{
    private var entered = false
    private var released = false
    private var entry: CheckedContinuation<Void, Never>?
    private var completion: CheckedContinuation<Void, Never>?
    func pause() async
    {
        entered = true
        entry?.resume()
        entry = nil
        if !released { await withCheckedContinuation { completion = $0 } }
    }

    func waitForEntry() async { if !entered { await withCheckedContinuation { entry = $0 } } }
    func release() { released = true; completion?.resume(); completion = nil }
}

private enum PreviewCompletion: CaseIterable, Sendable { case visible, hidden, cancelled, replacedSource, failed }

@MainActor private func settlePreview(_ preview: EarthRegionPreviewViewModel) async throws
{
    for _ in 0 ..< 400
    {
        if !preview.isLoading { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("The preview worker did not settle within two seconds.")
}

@Test(arguments: PreviewCompletion.allCases)
@MainActor private func regionPreviewPublicationRespectsVisibilityCancellationAndCurrentSource(outcome: PreviewCompletion) async throws
{
    let root = try projectStoreTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let fixture = try await regionPreviewFixture(root: root)
    let gate = PreviewCompletionGate()
    let service = EarthRegionPreviewService(
        projectID: fixture.record.id,
        files: fixture.files,
        store: fixture.store,
        build: { collection, progress, validate in
            let result = try await previewTestResult(collection: collection, progress: progress, validate: validate)
            // Simulate completion already produced by a worker that has not yet
            // observed cancellation or replacement of the recorded source.
            await gate.pause()
            if outcome == .failed { throw EarthRegionPreviewError.allocation }
            return result
        }
    )
    let preview = EarthRegionPreviewViewModel(service: service)
    preview.setVisible(true)
    preview.show(fixture.collection)
    await gate.waitForEntry()
    var replacement: EarthSourceArchive?
    if outcome == .hidden { preview.setVisible(false) }
    if outcome == .cancelled { preview.cancel() }
    #expect(preview.isLoading)
    if outcome == .replacedSource
    {
        let raw = try await projectSourceFixture(files: fixture.files, projectID: fixture.record.id)
        replacement = raw
        _ = try await fixture.store.recordCapture(id: fixture.record.id, capture: .init(id: #require(UUID(uuidString: raw.directoryURL.lastPathComponent)), request: raw.request))
    }
    await gate.release()
    try await settlePreview(preview)
    #expect(preview.hasPreview == (outcome == .visible))
    #expect((preview.renderer != nil) == (outcome == .visible))
    #expect((preview.errorMessage != nil) == (outcome == .replacedSource || outcome == .failed))
    if outcome == .visible
    {
        preview.setVisible(false)
        #expect(preview.renderer == nil && !preview.hasPreview)
    }
    if outcome == .hidden
    {
        preview.setVisible(true)
        preview.show(fixture.collection)
        try await settlePreview(preview)
        #expect(preview.hasPreview)
    }
    if let replacement
    {
        // A refresh must adopt the newly recorded artifacts, not retry the
        // stale catalog retained by the failed preview owner.
        let url = try await fixture.files.newArtifactDirectory(projectID: fixture.record.id, kind: .prepared)
        let profile = fixture.collection.profile
        _ = try await EarthModelPreparer().prepare(archive: replacement, directoryURL: url, profile: profile)
        _ = try await fixture.store.recordPreparation(
            id: fixture.record.id,
            preparation: .init(id: #require(UUID(uuidString: url.lastPathComponent)), captureID: #require(UUID(uuidString: replacement.directoryURL.lastPathComponent)), profile: profile)
        )
        let refreshed = try await fixture.store.open(id: fixture.record.id)
        let current = try #require(refreshed.prepared)
        #expect(current.directoryURL != fixture.collection.directoryURL)
        preview.show(current)
        try await settlePreview(preview)
        #expect(preview.hasPreview && preview.errorMessage == nil)
    }
    #expect(try await fixture.store.open(id: fixture.record.id).archive?.state == .downloaded)
}
