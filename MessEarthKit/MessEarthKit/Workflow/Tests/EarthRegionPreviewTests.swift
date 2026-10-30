import Foundation
@testable import MessEarthKit
import Metal
import simd
import Testing

// A later part must add pixels to the retained depth/color image without
// requiring a whole-region GPU scene or changing its shared camera bounds.
@Test private func exportThumbnailComposesPartsIntoOneSmallPNG() async throws
{
    let root = try projectStoreTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let fixture = try await regionPreviewFixture(root: root)
    let options = EarthGLBExportOptions.minimal
    let plan = try await EarthGLBExporter().preflight(collection: fixture.collection, destination: EarthPreparationProfile(), options: options)
    let device = try #require(MTLCreateSystemDefaultDevice())
    let source = try String(contentsOf: #require(Bundle.module.url(forResource: "EarthPreviewShaders", withExtension: "metal")), encoding: .utf8)
    let library = try await device.makeLibrary(source: source, options: nil)
    let renderer = try EarthGLBThumbnailRenderer(geometry: plan.informationGeometry(), options: options, library: library)
    let models = try await fixture.collection.models()
    let first = try #require(models.first)
    try await renderer.consume(fixture.collection.importModel(id: first.id))
    let initial = try await renderer.finish()
    for model in models.dropFirst() { try await renderer.consume(fixture.collection.importModel(id: model.id)) }
    let complete = try await renderer.finish()
    #expect(complete.width == 256 && complete.height == 256 && complete.data != initial.data)
}

private func regionPreviewFixture(root: URL, origin: EarthGeographicOrigin? = nil) async throws -> (files: EarthAppFiles, store: EarthProjectStore, record: EarthProjectRecord, collection: EarthPreparedCollection)
{
    let files = try EarthAppFiles(storageRootURL: root)
    try await files.initialize()
    let store = EarthProjectStore(files: files)
    let record = try await store.create()
    let raw = try await projectSourceFixture(files: files, projectID: record.id, placements: 3, mipmapped: true, origin: origin)
    let capture = EarthProjectCapture(id: try #require(UUID(uuidString: raw.directoryURL.lastPathComponent)), request: raw.request)
    _ = try await projectRegisterSource(files: files, store: store, projectID: record.id, source: raw)
    let url = try await files.newArtifactDirectory(projectID: record.id, kind: .prepared)
    let profile = try EarthPreparationProfile(maximumPlacementsPerModel: 1)
    let collection = try await EarthModelPreparer().prepare(archive: raw, directoryURL: url, profile: profile)
    _ = try await store.recordPreparation(id: record.id, variantID: capture.id, preparation: .init(id: #require(UUID(uuidString: url.lastPathComponent)), captureID: capture.id, profile: profile))
    return (files, store, try await store.record(id: record.id), collection)
}

private func previewTestResult(collection: EarthPreparedCollection, memoryLimit: EarthPreviewMemoryLimit = .automatic, displayMode: EarthPreviewDisplayMode = .textured, progress: @escaping @Sendable (EarthRegionPreviewProgress) -> Void, validate: @escaping @Sendable () async throws -> Void) async throws -> EarthRegionPreviewResult
{
    let device = try #require(MTLCreateSystemDefaultDevice())
    let scene = try await EarthRegionPreviewLoader(device: device).load(collection: collection, memoryLimit: memoryLimit, displayMode: displayMode, progress: progress, validateSource: validate)
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
    let image = try #require(scene.meshes.first(where: { $0.texture?.width == 2 })?.texture)
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

// Distinct risks: texture-free admission/upload must contain no images or
// samplers, and the real renderer must draw lines rather than filled triangles.
@Test private func regionPreviewGeometryModesSkipImagesAndRenderSolidOrWireframe() async throws
{
    let root = try projectStoreTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let fixture = try await regionPreviewFixture(root: root)
    let device = try #require(MTLCreateSystemDefaultDevice())
    let capture = try await fixture.collection.importModel(id: 1)
    let texturedCost = try EarthPreviewSceneBuilder(device: device).memoryCost(capture: capture)
    let source = try String(contentsOf: #require(Bundle.module.url(forResource: "EarthPreviewShaders", withExtension: "metal")), encoding: .utf8)
    let library = try await device.makeLibrary(source: source, options: nil)
    let renderer = try EarthPreviewRenderer(device: device, library: library)
    var coverage: [Int] = []
    for mode in [EarthPreviewDisplayMode.solid, .wireframe]
    {
        let builder = try EarthPreviewSceneBuilder(device: device, displayMode: mode)
        let cost = try builder.memoryCost(capture: capture)
        #expect(cost.textureBytes == 0 && builder.constantTextureBytes == 0)
        #expect(cost.geometryBytes == texturedCost.geometryBytes && texturedCost.textureBytes > 0)
        let scene = try await EarthRegionPreviewLoader(device: device).load(
            collection: fixture.collection,
            displayMode: mode,
            progress: { _ in },
            validateSource: {}
        )
        #expect(scene.displayMode == mode && scene.modelCount == 3)
        #expect(scene.meshes.allSatisfy { $0.texture == nil && $0.sampler == nil })
        #expect(scene.meshes.reduce(0) { $0 + $1.indexCount } == 126)
        #expect(simd_distance(scene.bounds.minimum, SIMD3(1, 1, 0.5)) < 0.001 && simd_distance(scene.bounds.maximum, SIMD3(25, 5, 1.3)) < 0.001)
        coverage.append(try await geometryPreviewCoverage(scene: scene, renderer: renderer))
    }
    // Compare coverage, not a golden color derived from the shader itself.
    #expect(coverage[1] > 0 && coverage[0] > coverage[1])
    #expect(try await fixture.store.record(id: fixture.record.id) == fixture.record)
}

private func geometryPreviewCoverage(scene: EarthPreparedPreview, renderer: EarthPreviewRenderer) async throws -> Int
{
    let device = renderer.device
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm_srgb, width: 64, height: 64, mipmapped: false)
    descriptor.storageMode = .private
    descriptor.usage = .renderTarget
    let color = try #require(device.makeTexture(descriptor: descriptor))
    descriptor.pixelFormat = .depth32Float
    let depth = try #require(device.makeTexture(descriptor: descriptor))
    let pass = MTLRenderPassDescriptor()
    pass.colorAttachments[0].texture = color
    pass.colorAttachments[0].loadAction = .clear
    pass.colorAttachments[0].storeAction = .store
    pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
    pass.depthAttachment.texture = depth
    pass.depthAttachment.loadAction = .clear
    pass.depthAttachment.storeAction = .dontCare
    pass.depthAttachment.clearDepth = 1
    let command = try #require(device.makeCommandQueue()?.makeCommandBuffer())
    let encoder = try #require(command.makeRenderCommandEncoder(descriptor: pass))
    let scale = SIMD3<Float>(1.6, 1.6, 0.6) / simd_max(scene.bounds.dimensions, SIMD3(repeating: 0.001))
    let projection = simd_float4x4(columns: (
        SIMD4(scale.x, 0, 0, 0),
        SIMD4(0, scale.y, 0, 0),
        SIMD4(0, 0, scale.z, 0),
        SIMD4(-scene.bounds.center.x * scale.x, -scene.bounds.center.y * scale.y, 0.2 - scene.bounds.minimum.z * scale.z, 1)
    ))
    renderer.encode(scene: scene, viewProjection: projection, eye: .zero, encoder: encoder)
    encoder.endEncoding()
    let readback = try #require(device.makeBuffer(length: 64 * 256, options: .storageModeShared))
    let blit = try #require(command.makeBlitCommandEncoder())
    blit.copy(from: color, sourceSlice: 0, sourceLevel: 0, sourceOrigin: .init(x: 0, y: 0, z: 0), sourceSize: .init(width: 64, height: 64, depth: 1), to: readback, destinationOffset: 0, destinationBytesPerRow: 256, destinationBytesPerImage: 64 * 256)
    blit.endEncoding()
    command.commit()
    await command.completed()
    try #require(command.status == .completed)
    let pixels = readback.contents().assumingMemoryBound(to: UInt8.self)
    return (0 ..< 64 * 64).reduce(0) { $0 + (pixels[$1 * 4 + 3] == 0 ? 0 : 1) }
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
            displayMode: .textured,
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
        try budget.admit(sceneBytes: builder.constantTextureBytes + partBytes, largestPartBytes: partBytes)
        let part = try await EarthRegionPreviewLoader(device: device).load(
            collection: fixture.collection,
            modelID: 2,
            progress: { _ in },
            validateSource: {}
        )
        #expect(part.modelCount == 1 && part.meshes.count == 2 && part.displayMode == .wireframe)
        // The second authored placement retains its 10 m shared-frame offset.
        #expect(abs(part.bounds.minimum.x - 11) < 0.001 && abs(part.bounds.maximum.x - 15) < 0.001)
    }
    else
    {
        await #expect(throws: CancellationError.self) { try await worker.value }
        #expect(events.uploadCount == 1)
    }
    let reopened = try await fixture.store.open(id: fixture.record.id)
    #expect(reopened.record == fixture.record && reopened.archive?.state == .downloaded && reopened.prepared?.coversEntireSource == true)
}

@Test func regionPreviewCustomMemoryLimitValidatesUnitsAndOverflow() throws
{
    let custom = try EarthPreviewMemoryLimit(gibibytes: "8.5")
    #expect(try custom.resolvedBytes(recommendedWorkingSetSize: 2 * 1024 * 1024 * 1024) == 9126805504)
    #expect(try EarthPreviewMemoryLimit.automatic.resolvedBytes(recommendedWorkingSetSize: 64 * 1024 * 1024 * 1024) == 32 * 1024 * 1024 * 1024)
    #expect(try EarthPreviewMemoryLimit.automatic.resolvedBytes(recommendedWorkingSetSize: 1024 * 1024 * 1024) == 512 * 1024 * 1024)
    // Invalid number, non-positive amount, non-finite input, integer overflow
    // and a positive amount that converts to zero must each reject explicitly.
    for input in ["", "0", "nan", "1e100", "1e-100"]
    { #expect(throws: EarthRegionPreviewError.invalidMemoryBudget) { try EarthPreviewMemoryLimit(gibibytes: input) } }
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
    private(set) var memoryLimits: [EarthPreviewMemoryLimit] = []
    private(set) var displayModes: [EarthPreviewDisplayMode] = []
    private(set) weak var scene: EarthPreparedPreview?
    private var entered = false
    private var released = false
    private var entry: CheckedContinuation<Void, Never>?
    private var completion: CheckedContinuation<Void, Never>?
    func pause(memoryLimit: EarthPreviewMemoryLimit, scene: EarthPreparedPreview) async
    {
        memoryLimits.append(memoryLimit)
        displayModes.append(scene.displayMode)
        self.scene = scene
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
        build: { collection, _, memoryLimit, displayMode, progress, validate in
            let result = try await previewTestResult(collection: collection, memoryLimit: memoryLimit, displayMode: displayMode, progress: progress, validate: validate)
            // Simulate completion already produced by a worker that has not yet
            // observed cancellation or replacement of the recorded source.
            await gate.pause(memoryLimit: memoryLimit, scene: result.scene)
            if outcome == .failed { throw EarthRegionPreviewError.allocation }
            return result
        }
    )
    let preview = EarthRegionPreviewViewModel(service: service)
    if outcome == .visible
    {
        preview.setUsesAutomaticMemoryBudget(false)
        preview.setCustomMemoryBudgetGiB("8")
    }
    preview.setVisible(true)
    preview.show(fixture.collection)
    await gate.waitForEntry()
    if outcome == .visible
    {
        preview.setDisplayMode(.textured, collection: fixture.collection)
        #expect(preview.displayMode == .wireframe)
    }
    var replacement: EarthSourceArchive?
    if outcome == .hidden { preview.setVisible(false) }
    if outcome == .cancelled { preview.cancel() }
    #expect(preview.isLoading)
    if outcome == .replacedSource
    {
        let raw = try await projectSourceFixture(files: fixture.files, projectID: fixture.record.id)
        replacement = raw
        _ = try await projectRegisterSource(files: fixture.files, store: fixture.store, projectID: fixture.record.id, source: raw)
    }
    await gate.release()
    try await settlePreview(preview)
    #expect(preview.hasPreview == (outcome == .visible))
    #expect((preview.renderer != nil) == (outcome == .visible))
    #expect((preview.errorMessage != nil) == (outcome == .replacedSource || outcome == .failed))
    if outcome == .visible
    {
        let firstLimits = await gate.memoryLimits
        #expect(firstLimits == [.customBytes(8589934592)])
        preview.setCustomMemoryBudgetGiB("0")
        preview.reload(fixture.collection)
        #expect(preview.hasPreview && !preview.isLoading && preview.memoryBudgetError != nil)
        preview.setCustomMemoryBudgetGiB("6")
        // Reusing the same collection must not reuse a preview with an old limit.
        preview.show(fixture.collection)
        try await settlePreview(preview)
        let reloadedLimits = await gate.memoryLimits
        #expect(reloadedLimits == [.customBytes(8589934592), .customBytes(6442450944)])
        let retainedRenderer = try #require(preview.renderer)
        weak let previousScene = await gate.scene
        #expect(previousScene != nil)
        preview.setDisplayMode(.textured, collection: fixture.collection)
        // A view can still retain the old renderer while SwiftUI updates it.
        // Clear its scene immediately so switching modes frees its textures.
        withExtendedLifetime(retainedRenderer) { #expect(previousScene == nil) }
        try await settlePreview(preview)
        let modes = await gate.displayModes
        #expect(modes == [.wireframe, .wireframe, .textured] && preview.hasPreview)
        preview.show(fixture.collection)
        #expect(!preview.isLoading)
        preview.setUsesAutomaticMemoryBudget(true)
        #expect(preview.memoryBudgetError == nil)
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
            variantID: #require(try await fixture.store.record(id: fixture.record.id).selectedCaptureID),
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
