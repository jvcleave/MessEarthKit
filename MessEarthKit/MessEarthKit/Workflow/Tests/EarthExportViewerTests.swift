import Foundation
@testable import MessEarthKit
import Metal
import simd
import Testing

private func exportViewerFixture(root: URL) async throws -> (EarthAppFiles, UUID, UUID, [EarthProjectExportRecord])
{
    let files = try EarthAppFiles(storageRootURL: root)
    try await files.initialize()
    let store = EarthProjectStore(files: files)
    let project = try await store.create()
    let raw = try await projectSourceFixture(files: files, projectID: project.id, placements: 2, mipmapped: true, linearSampling: true)
    let registered = try await projectRegisterSource(files: files, store: store, projectID: project.id, source: raw)
    let variantID = try #require(registered.selectedCaptureID)
    let service = EarthProjectExportService(projectID: project.id, files: files, store: store, prepare: { archive, profile, progress in
        let destination = try await files.newArtifactDirectory(projectID: project.id, kind: .prepared)
        return try await EarthModelPreparer().prepare(archive: archive, directoryURL: destination, profile: profile, progress: progress)
    })
    var records: [EarthProjectExportRecord] = []
    for format in EarthExportFormat.allCases
    {
        let result = try await service.export(variantID: variantID, options: .init(includeNormals: false), format: format, progress: { _ in })
        records.append(result.output)
    }
    return (files, project.id, variantID, records)
}

private func viewerLibrary() async throws -> MTLLibrary
{
    let device = try #require(MTLCreateSystemDefaultDevice())
    let url = try #require(Bundle.module.url(forResource: "EarthPreviewShaders", withExtension: "metal"))
    return try await device.makeLibrary(source: String(contentsOf: url, encoding: .utf8), options: nil)
}

@Test private func exportedModelViewerLoadsActualGLBAndUSDZFilesWithSharedGPUResources() async throws
{
    let root = try projectStoreTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let (files, projectID, variantID, records) = try await exportViewerFixture(root: root)
    let library = try await viewerLibrary()
    let viewer = EarthExportViewerService(files: files, build: { try await EarthExportViewerService.buildScene($0, record: $1, byteCount: $2, progress: $3, library: library) })
    // An export viewer must work independently of the original capture/preparation.
    let locations = try await files.projectLocations(id: projectID)
    try FileManager.default.moveItem(at: locations.sourcesURL, to: root.appendingPathComponent("retained-sources"))
    try FileManager.default.moveItem(at: locations.preparedURL, to: root.appendingPathComponent("retained-preparations"))
    var referencePixels: Data?
    for (index, record) in records.enumerated()
    {
        let result = try await viewer.load(.init(projectID: projectID, variantID: variantID, exportID: record.id), progress: { _ in })
        #expect(result.choices.count == EarthExportFormat.allCases.count && result.choices.allSatisfy(\.isAvailable))
        #expect(result.model.format == EarthExportFormat.allCases[index])
        #expect(result.model.triangleCount == 28)
        #expect(result.model.scene.meshes.count == 4)
        #expect(result.model.scene.meshes.allSatisfy { $0.material.isUnlit && $0.material.alphaMode == .opaque })
        #expect(result.model.scene.meshes.contains { $0.texture?.width == 2 && $0.texture?.mipmapLevelCount == 2 })
        let url = try await files.exportFileURL(projectID: projectID, record: record)
        #expect(result.model.byteCount == (try Data(contentsOf: url)).count)
        let expectedMinimum = SIMD3<Float>(1, 1, 0.5), expectedMaximum = SIMD3<Float>(15, 5, 1.3)
        #expect(simd_distance(result.model.scene.bounds.minimum, expectedMinimum) < 0.001)
        #expect(simd_distance(result.model.scene.bounds.maximum, expectedMaximum) < 0.001)
        let pixels = try await exportViewerPixels(result.model)
        #expect(stride(from: 4, to: pixels.count, by: 4).contains { pixels[$0 ..< $0 + 4] != pixels.prefix(4) })
        if let referencePixels { #expect(pixels == referencePixels) }
        else { referencePixels = pixels }
        result.model.renderer.publish(scene: result.model.scene)
        let initial = try #require(result.model.renderer.frame(aspect: 1))
        let center = SIMD4<Float>(result.model.scene.bounds.center, 1)
        let centered = initial.viewProjection * center
        #expect(abs(centered.x / centered.w) < 0.0001 && abs(centered.y / centered.w) < 0.0001)
        result.model.renderer.pan(horizontal: 120, vertical: 60, viewportHeight: 512, aspect: 1)
        let moved = try #require(result.model.renderer.frame(aspect: 1)).viewProjection * center
        #expect(abs(moved.x / moved.w) > 0.1 && abs(moved.y / moved.w) > 0.1)
        result.model.renderer.orbit(horizontal: 50, vertical: 30)
        result.model.renderer.zoom(delta: 5)
        result.model.renderer.resetCamera()
        #expect(try #require(result.model.renderer.frame(aspect: 1)).viewProjection == initial.viewProjection)
        result.model.renderer.clearScene()
    }
}

private func exportViewerPixels(_ model: EarthExportViewerModel) async throws -> Data
{
    let device = model.renderer.device
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm_srgb, width: 128, height: 128, mipmapped: false)
    descriptor.storageMode = .shared
    descriptor.usage = .renderTarget
    let color = try #require(device.makeTexture(descriptor: descriptor))
    let depthDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float, width: 128, height: 128, mipmapped: false)
    depthDescriptor.storageMode = .private
    depthDescriptor.usage = .renderTarget
    let depth = try #require(device.makeTexture(descriptor: depthDescriptor))
    let pass = MTLRenderPassDescriptor()
    pass.colorAttachments[0].texture = color
    pass.colorAttachments[0].loadAction = .clear
    pass.colorAttachments[0].storeAction = .store
    pass.colorAttachments[0].clearColor = MTLClearColor(red: 0.025, green: 0.03, blue: 0.04, alpha: 1)
    pass.depthAttachment.texture = depth
    pass.depthAttachment.loadAction = .clear
    pass.depthAttachment.storeAction = .dontCare
    pass.depthAttachment.clearDepth = 1
    let command = try #require(device.makeCommandQueue()?.makeCommandBuffer())
    let encoder = try #require(command.makeRenderCommandEncoder(descriptor: pass))
    let camera = EarthPreviewRenderer.cameraFrame(bounds: model.scene.bounds, aspect: 1)
    model.renderer.encode(scene: model.scene, viewProjection: camera.viewProjection, eye: camera.eye, encoder: encoder)
    encoder.endEncoding()
    command.commit()
    await command.completed()
    #expect(command.status == .completed)
    var pixels = Data(count: 128 * 128 * 4)
    pixels.withUnsafeMutableBytes { color.getBytes($0.baseAddress!, bytesPerRow: 128 * 4, from: MTLRegionMake2D(0, 0, 128, 128), mipmapLevel: 0) }
    return pixels
}

private actor ExportViewerGate
{
    private(set) var entered = false
    private var released = false
    private var entry: CheckedContinuation<Void, Never>?
    private var completion: CheckedContinuation<Void, Never>?
    private(set) weak var scene: EarthPreparedPreview?
    func pause(_ scene: EarthPreparedPreview) async
    {
        self.scene = scene; entered = true; entry?.resume(); entry = nil
        if !released { await withCheckedContinuation { completion = $0 } }
    }

    func waitForEntry() async { if !entered { await withCheckedContinuation { entry = $0 } } }
    func release() { released = true; completion?.resume(); completion = nil }
}

@MainActor private func settleViewer(_ viewer: EarthExportViewerViewModel) async throws
{
    for _ in 0 ..< 1000
    {
        if !viewer.isLoading { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("The exported model viewer did not settle")
}

@Test(arguments: [false, true]) @MainActor private func exportedModelViewerRejectsStaleCompletionAndReleasesOnClose(closeDuringLoad: Bool) async throws
{
    let root = try projectStoreTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let (files, projectID, variantID, records) = try await exportViewerFixture(root: root)
    let replacementIndex = try #require(EarthExportFormat.allCases.firstIndex(of: .optimizedUSDZ))
    let replacement = records[replacementIndex]
    let library = try await viewerLibrary()
    let gate = ExportViewerGate()
    let service = EarthExportViewerService(files: files, build: { url, record, bytes, progress in
        let model = try await EarthExportViewerService.buildScene(url, record: record, byteCount: bytes, progress: progress, library: library)
        if record.id == records[0].id { await gate.pause(model.scene) }
        return model
    })
    let viewer = EarthExportViewerViewModel(service: service)
    viewer.open(.init(projectID: projectID, variantID: variantID, exportID: records[0].id))
    await gate.waitForEntry()
    // File moves are rejected while an already-produced result still holds its lease.
    await #expect(throws: EarthAppFilesError.exportInUse) { try await files.trashProject(id: projectID) }
    let history = EarthProjectExportHistoryStore(projectID: projectID, files: files)
    await #expect(throws: EarthAppFilesError.exportInUse) { try await history.rename(records[0], to: "Moving") }
    await #expect(throws: EarthAppFilesError.exportInUse) { try await history.delete(records[0]) }
    var closing: Task<Void, Never>?
    var closeStarted = false, closeFinished = false
    if closeDuringLoad
    {
        viewer.close()
        closing = Task
        { @MainActor in
            closeStarted = true
            await viewer.closeAndWait()
            closeFinished = true
        }
        for _ in 0 ..< 400
        {
            if closeStarted { break }
            await Task.yield()
        }
        #expect(closeStarted && !closeFinished)
    }
    else { viewer.open(.init(projectID: projectID, variantID: variantID, exportID: replacement.id)) }
    await gate.release()
    if let closing { await closing.value; #expect(closeFinished) }
    if closeDuringLoad
    {
        for _ in 0 ..< 400
        {
            if await gate.scene == nil { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await gate.scene == nil)
        #expect(viewer.renderer == nil && viewer.request == nil && !viewer.isOpen)
        viewer.open(.init(projectID: projectID, variantID: variantID, exportID: replacement.id))
    }
    try await settleViewer(viewer)
    #expect(viewer.errorMessage == nil && viewer.fileName == replacement.fileName)
    #expect(viewer.summary.contains("Optimized USDZ") && viewer.renderer != nil)
    #expect(await gate.scene == nil)
    viewer.renderer?.pan(horizontal: 40, vertical: 20, viewportHeight: 512, aspect: 1)
    viewer.renderer?.orbit(horizontal: 20, vertical: 10)
    let comparisonCamera = viewer.renderer?.cameraState
    viewer.selectExport(records[1].id)
    try await settleViewer(viewer)
    #expect(viewer.renderer?.cameraState == comparisonCamera)
    weak var renderer = viewer.renderer
    viewer.close()
    #expect(viewer.renderer == nil && viewer.request == nil && viewer.choices.isEmpty)
    #expect(renderer == nil)
    // Lease is gone after completion and a later open remains usable.
    _ = try await history.rename(records[0], to: "Moved After Loading")
    viewer.open(.init(projectID: projectID, variantID: variantID, exportID: records[1].id))
    try await settleViewer(viewer)
    #expect(viewer.errorMessage == nil && viewer.renderer != nil)
    viewer.close()
}

@Test private func exportedModelViewerAdmissionUsesWholeMapDeviceBudget() throws
{
    let admission = try EarthExportViewerAdmission(recommendedWorkingSetSize: 48 * 1024 * 1024 * 1024, allocatedBytes: 0, physicalMemory: 64 * 1024 * 1024 * 1024)
    // Regression: real combined deliveries have about 12m vertices and 626 MiB
    // source, while each prepared part remains bounded by the SDK's 2m default.
    #expect(admission.limits.maximumVertices > 12054879)
    #expect(admission.limits.maximumSourceBytes > 656322592)
    #expect(admission.limits.maximumDecodedTextureBytes > 256 * 1024 * 1024)
    #expect(EarthImportLimits().maximumVertices == 2000000)
    try admission.requireSource(656322592)
    try admission.requireGPU(sceneBytes: 2 * 1024 * 1024 * 1024)
    #expect(throws: EarthExportViewerError.self) { try admission.requireSource(admission.limits.maximumSourceBytes + 1) }
    #expect(throws: EarthExportViewerError.self) { try admission.requireGPU(sceneBytes: admission.gpuBudget.limitBytes) }
    #expect(throws: EarthExportViewerError.self) { try EarthExportViewerAdmission(recommendedWorkingSetSize: 128 * 1024 * 1024, allocatedBytes: 0, physicalMemory: 8 * 1024 * 1024 * 1024) }
    let constrained = try EarthExportViewerAdmission(recommendedWorkingSetSize: 2 * 1024 * 1024 * 1024, allocatedBytes: 512 * 1024 * 1024, physicalMemory: 8 * 1024 * 1024 * 1024)
    #expect(constrained.limits.maximumVertices < admission.limits.maximumVertices)
    #expect(constrained.limits.maximumDecodedTextureBytes < admission.limits.maximumDecodedTextureBytes)
    let message = try #require(EarthExportViewerError.decoding(format: .usdz, reason: "geometry", limits: constrained.limits).errorDescription)
    #expect(message.contains("USDZ") && message.contains("vertices") && message.contains("geometry"))
}

// Explicit local opt-in only: read tracked user exports without creating,
// renaming, rewriting, or deleting any project files. No assets are redistributed.
@Test private func exportedModelViewerReadOnlyProjectVerification() async throws
{
    guard let path = ProcessInfo.processInfo.environment["MESS_VIEWER_VERIFY_PROJECT"] else { return }
    let project = URL(fileURLWithPath: path, isDirectory: true)
    let projectID = try #require(UUID(uuidString: project.lastPathComponent))
    let files = try EarthAppFiles(storageRootURL: project.deletingLastPathComponent().deletingLastPathComponent())
    var records = try await EarthProjectExportHistoryStore(projectID: projectID, files: files).records()
    if ProcessInfo.processInfo.environment["MESS_VIEWER_VERIFY_INCLUDE_UNTRACKED"] == "1"
    {
        // A user-supplied directory may also contain older, untracked deliveries.
        // Build temporary test descriptors only; never add them to history.
        let template = try #require(records.first)
        let known = Set(records.map(\.id))
        let folders = try FileManager.default.contentsOfDirectory(at: project.appendingPathComponent("output"), includingPropertiesForKeys: nil)
        for folder in folders
        {
            guard let id = UUID(uuidString: folder.lastPathComponent), !known.contains(id) else { continue }
            for file in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) where ["glb", "usdz"].contains(file.pathExtension.lowercased())
            {
                records.append(EarthProjectExportRecord(
                    id: id,
                    variantID: template.variantID,
                    source: template.source,
                    preparation: template.preparation,
                    locationName: template.locationName,
                    detail: template.detail,
                    includeTextures: true,
                    fileName: file.lastPathComponent,
                    createdAt: template.createdAt
                ))
            }
        }
    }
    let library = try await viewerLibrary()
    let requested = ProcessInfo.processInfo.environment["MESS_VIEWER_VERIFY_EXPORT"]
    var checked = 0
    for record in records where requested == nil || record.id.uuidString == requested
    {
        guard try await files.exportFileIsAvailable(projectID: projectID, record: record) else { continue }
        do
        {
            let model = try await files.withExportRead(projectID: projectID, record: record)
            { url, bytes in try await EarthExportViewerService.buildScene(url, record: record, byteCount: bytes, progress: { _ in }, library: library) }
            print("Viewer verified \(record.id): \(model.vertexCount) vertices, \(model.triangleCount) triangles, \(model.scene.allocatedBytes) GPU bytes")
            checked += 1
        }
        catch { Issue.record("Viewer failed \(record.id): \(error.localizedDescription)") }
    }
    #expect(checked > 0)
}
