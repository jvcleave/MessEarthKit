import Foundation
import MessEarthKit
import Testing

private func queueTestService(files: EarthAppFiles, store: EarthProjectStore, projectID: UUID) -> EarthProjectExportService
{
    EarthProjectExportService(projectID: projectID, files: files, store: store, prepare: { archive, profile, progress in
        let directory = try await files.newArtifactDirectory(projectID: projectID, kind: .prepared)
        return try await EarthModelPreparer().prepare(archive: archive, directoryURL: directory, profile: profile, progress: progress)
    })
}

private func queueTestRequest(files: EarthAppFiles, store: EarthProjectStore) async throws -> (EarthQueuedExportRequest, EarthProjectExportService)
{
    let project = try await store.create()
    let archive = try await projectSourceFixture(files: files, projectID: project.id)
    let registered = try await projectRegisterSource(files: files, store: store, projectID: project.id, source: archive)
    let service = queueTestService(files: files, store: store, projectID: project.id)
    let request = try await service.queuedRequest(variantID: #require(registered.selectedCaptureID), options: .minimal, format: .glb, optimization: .init())
    return (request, service)
}

@MainActor private func waitForExportQueue(_ condition: @MainActor () async -> Bool) async throws
{
    let deadline = ContinuousClock.now.advanced(by: .seconds(15))
    while !(await condition()), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
    try #require(await condition())
}

// Real local exports cover global identity, frozen names/settings, selected
// execution, failure isolation, collision-safe collection and history renames.
@Test @MainActor func exportQueueRunsSnapshotsAcrossProjectsAndCollectsExactResults() async throws
{
    let root = try projectStoreTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let files = try EarthAppFiles(storageRootURL: root.appendingPathComponent("managed"))
    try await files.initialize()
    let store = EarthProjectStore(files: files)
    let (first, firstService) = try await queueTestRequest(files: files, store: store)
    let (second, secondService) = try await queueTestRequest(files: files, store: store)
    let failure = try await firstService.queuedRequest(variantID: first.variantID, options: .minimal, format: .usdz, optimization: .init())
    let excluded = try await secondService.queuedRequest(variantID: second.variantID, options: .full, format: .optimizedUSDZ, optimization: .init(triangleFraction: 0.25, maximumErrorMeters: 0.2, maximumTextureDimension: 256))
    let original = EarthExportQueue(files: files)
    try await waitForExportQueue { !original.isBusy }
    let controls = EarthProjectExportViewModel(service: firstService)
    for field in EarthProjectExportField.allCases { controls.setOption(field, included: false, variantID: first.variantID) }
    controls.addToQueue(variantID: first.variantID, queue: original, saveEdits: {})
    try await waitForExportQueue { !original.isBusy && !controls.isBusy }
    #expect(original.entries.first?.request == first)
    controls.setFormat(.optimizedGLB, variantID: first.variantID)
    controls.setOption(.textures, included: true, variantID: first.variantID)
    #expect(!original.enqueue(first))
    #expect(original.enqueue(failure) && original.enqueue(second) && original.enqueue(excluded))
    let excludedID = try #require(original.entries.last?.id)
    original.setIncluded(false, id: excludedID)
    try await waitForExportQueue { !original.isBusy }
    let queue = EarthExportQueue(files: files)
    try await waitForExportQueue { !queue.isBusy }
    #expect(!queue.isRunning && queue.entries == original.entries)
    // Renaming and choosing other controls after enqueue must not change output.
    let current = try await store.record(id: first.projectID)
    var edit = try #require(current.locations.first).edit
    edit.title = "Later name"
    _ = try await store.updateEditor(id: first.projectID, locations: [first.locationID: edit])
    queue.start
    { entry, progress in
        if entry.request.format == .usdz { throw EarthAppFilesError.storage }
        let service = entry.request.projectID == first.projectID ? firstService : secondService
        let request = entry.request
        return try await service.export(variantID: request.variantID, options: request.options, format: request.format, optimization: request.optimization, queuedRequest: request, exportID: #require(entry.exportID), progress: progress)
    }
    try await waitForExportQueue { !queue.isBusy }
    #expect(queue.entries.map(\.phase) == [.complete, .failed, .complete, .pending])
    #expect(queue.entries.last?.request.optimization == excluded.optimization)
    let completed = queue.entries.filter { $0.phase == .complete }
    let a = try #require(completed.first?.result), b = try #require(completed.last?.result)
    #expect(a.locationName == first.locationTitle && a.source == first.source)
    #expect(a.fileName == b.fileName && !a.fileName.contains("Later"))
    #expect(try await EarthGLBExporter().exportedOptions(fileURL: files.exportFileURL(projectID: first.projectID, record: a)) == .minimal)
    let destination = root.appendingPathComponent("delivery")
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
    let sentinel = destination.appendingPathComponent(a.fileName)
    try Data([9, 8, 7]).write(to: sentinel)
    queue.collect(to: destination)
    try await waitForExportQueue { !queue.isBusy }
    try #require(queue.operationError == nil)
    let batch = try #require(queue.lastCollectionURL)
    let names = try FileManager.default.contentsOfDirectory(atPath: batch.path)
    let renamedCollision = String(a.fileName.dropLast(4)) + "_2.glb"
    #expect(Set(names) == [a.fileName, a.fileName + ".info.json", renamedCollision, renamedCollision + ".info.json"])
    let source = try await files.exportFileURL(projectID: first.projectID, record: a)
    #expect(try Data(contentsOf: batch.appendingPathComponent(a.fileName)) == Data(contentsOf: source))
    #expect(try Data(contentsOf: batch.appendingPathComponent(a.fileName + ".info.json")) == Data(contentsOf: EarthGLBInfo.companionURL(source)))
    #expect(try Data(contentsOf: sentinel) == Data([9, 8, 7]))
    // Resolve the same export UUID after Rename instead of using a stale path.
    _ = try await firstService.rename(a, to: "Renamed result")
    let recollected = try await files.collectExports([completed[0]], to: destination, progress: { _, _ in })
    #expect(FileManager.default.fileExists(atPath: recollected.appendingPathComponent("Renamed result.glb").path))
    queue.removeIncluded()
    try await waitForExportQueue { !queue.isBusy }
    #expect(queue.entries.map(\.id) == [excludedID])
    let firstHistory = try await firstService.exports(), secondHistory = try await secondService.exports()
    #expect(firstHistory.count == 1 && secondHistory.count == 1)
}

private actor ExportQueueGate
{
    private(set) var started = 0

    func wait() async throws
    {
        started += 1
        while true { try await Task.sleep(for: .milliseconds(5)) }
    }
}

// A project's completion refresh can still be loading export history when the
// next queued variant starts. That read must settle before admission, without
// turning a transient UI refresh into a failed export.
@Test @MainActor func exportQueueWaitsForHistoryRefreshBetweenEntries() async throws
{
    let root = try projectStoreTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let files = try EarthAppFiles(storageRootURL: root)
    try await files.initialize()
    let (first, service) = try await queueTestRequest(files: files, store: EarthProjectStore(files: files))
    let second = try await service.queuedRequest(variantID: first.variantID, options: .minimal, format: .usdz, optimization: .init())
    let queue = EarthExportQueue(files: files)
    let export = EarthProjectExportViewModel(service: service)
    try await waitForExportQueue { !queue.isBusy }
    queue.enqueue(first)
    queue.enqueue(second)
    try await waitForExportQueue { !queue.isBusy }
    queue.start
    { entry, progress in
        // Match the project refresh at a queue handoff, keeping the race
        // deterministic even when the local history fixture is very small.
        export.reloadHistory()
        return try await export.exportQueued(entry, cancel: { queue.cancel() }, progress: progress)
    }
    try await waitForExportQueue { !queue.isBusy && !export.isLoadingHistory }
    #expect(queue.entries.map(\.phase) == [.complete, .complete])
    #expect(export.history.count == 2 && export.historyError == nil)
}

// Cancellation locks the active row until native work settles, admits no later
// job and keeps a publication that completes simultaneously with Cancel.
@Test @MainActor func exportQueueCancellationKeepsPendingWorkAndPublishedResults() async throws
{
    let root = try projectStoreTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let files = try EarthAppFiles(storageRootURL: root)
    try await files.initialize()
    let store = EarthProjectStore(files: files)
    let (first, service) = try await queueTestRequest(files: files, store: store)
    let second = try await service.queuedRequest(variantID: first.variantID, options: .minimal, format: .usdz, optimization: .init())
    let third = try await service.queuedRequest(variantID: first.variantID, options: .full, format: .glb, optimization: .init())
    let queue = EarthExportQueue(files: files)
    try await waitForExportQueue { !queue.isBusy }
    queue.enqueue(first)
    queue.enqueue(second)
    queue.enqueue(third)
    try await waitForExportQueue { !queue.isBusy }
    let ids = queue.entries.map(\.id)
    let gate = ExportQueueGate()
    let gatedService = EarthProjectExportService(projectID: first.projectID, files: files, store: store, prepare: { archive, profile, progress in
        try await gate.wait()
        let directory = try await files.newArtifactDirectory(projectID: first.projectID, kind: .prepared)
        return try await EarthModelPreparer().prepare(archive: archive, directoryURL: directory, profile: profile, progress: progress)
    })
    let activeExport = EarthProjectExportViewModel(service: gatedService)
    queue.start
    { entry, progress in try await activeExport.exportQueued(entry, cancel: { queue.cancel() }, progress: progress) }
    try await waitForExportQueue { await gate.started == 1 }
    let cancelledAttempt = queue.entries[0].exportID
    queue.setIncluded(false, id: ids[0])
    queue.remove(ids[0])
    #expect(queue.entries[0].isIncluded && queue.entries.count == 3)
    queue.setIncluded(false, id: ids[1])
    queue.remove(ids[2])
    activeExport.cancel()
    try await waitForExportQueue { !queue.isBusy }
    #expect(queue.entries.map(\.phase) == [.cancelled, .pending])
    #expect(await gate.started == 1)
    queue.retry(ids[0])
    queue.setIncluded(true, id: ids[1])
    queue.move(ids[1], by: -1)
    #expect(queue.entries[0].id == ids[1])
    queue.move(ids[1], by: 1)
    try await waitForExportQueue { !queue.isBusy }
    queue.start
    { entry, progress in
        let request = entry.request
        let result = try await service.export(variantID: request.variantID, options: request.options, format: request.format, optimization: request.optimization, queuedRequest: request, exportID: #require(entry.exportID), progress: progress)
        queue.cancel()
        return result
    }
    try await waitForExportQueue { !queue.isBusy }
    #expect(queue.entries.map(\.phase) == [.complete, .pending])
    #expect(queue.entries[0].exportID != cancelledAttempt)
    let reopened = EarthExportQueue(files: files)
    try await waitForExportQueue { !reopened.isBusy }
    #expect(reopened.entries == queue.entries && reopened.selectedCompleteCount == 1)
}

// Persisted attempt IDs reconcile an output committed just before interruption.
// An unpublished attempt stays stopped; launch never invokes the exporter.
@Test @MainActor func exportQueueRecoversExactPublishedAttemptAndRejectsCorruption() async throws
{
    let root = try projectStoreTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let files = try EarthAppFiles(storageRootURL: root)
    try await files.initialize()
    let (request, service) = try await queueTestRequest(files: files, store: EarthProjectStore(files: files))
    var published = EarthExportQueueEntry(request: request)
    published.phase = .running
    published.exportID = UUID()
    var interrupted = EarthExportQueueEntry(request: request)
    interrupted.phase = .running
    interrupted.exportID = UUID()
    let store = EarthExportQueueStore(files: files)
    try await store.save([published, interrupted])
    let mismatched = EarthQueuedExportRequest(
        projectID: request.projectID,
        projectTitle: request.projectTitle,
        locationID: request.locationID,
        locationName: request.locationName,
        locationTitle: request.locationTitle,
        variantID: request.variantID,
        detail: request.detail,
        source: .init(id: UUID(), request: request.source.request),
        preparationProfile: request.preparationProfile,
        options: request.options,
        format: request.format,
        optimization: request.optimization
    )
    await #expect(throws: EarthGLBExportError.sourceChanged)
    { try await service.export(variantID: request.variantID, options: request.options, queuedRequest: mismatched, progress: { _ in }) }
    #expect(try await files.artifactDirectories(projectID: request.projectID, kind: .output).isEmpty)
    let output = try await service.export(variantID: request.variantID, options: request.options, format: request.format, optimization: request.optimization, queuedRequest: request, exportID: #require(published.exportID), progress: { _ in })
    let queue = EarthExportQueue(files: files)
    try await waitForExportQueue { !queue.isBusy }
    #expect(queue.entries.map(\.phase) == [.complete, .cancelled])
    #expect(queue.entries[0].result == output.output && !queue.isRunning)
    #expect(try await store.load() == queue.entries)
    let corrupt = Data("{\"version\":2,\"entries\":[]}".utf8)
    try await files.writeMetadata(corrupt, location: .exportQueue)
    let invalid = EarthExportQueue(files: files)
    try await waitForExportQueue { !invalid.isBusy }
    #expect(invalid.loadError != nil && !invalid.enqueue(request))
    #expect(try await files.readMetadata(.exportQueue) == corrupt)
}

// Publication remains collectible when its independent history write fails.
// The queue keeps the known output reference without repairing corrupt history.
@Test @MainActor func exportQueueCollectsPublishedResultAfterHistoryFailure() async throws
{
    let root = try projectStoreTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let files = try EarthAppFiles(storageRootURL: root.appendingPathComponent("managed"))
    try await files.initialize()
    let (request, service) = try await queueTestRequest(files: files, store: EarthProjectStore(files: files))
    let historyURL = try await files.projectLocations(id: request.projectID).directoryURL.appendingPathComponent("exports.json")
    let damaged = Data("{".utf8)
    let queue = EarthExportQueue(files: files)
    try await waitForExportQueue { !queue.isBusy }
    queue.enqueue(request)
    try await waitForExportQueue { !queue.isBusy }
    queue.start
    { entry, progress in
        try await service.export(variantID: request.variantID, options: request.options, queuedRequest: request, exportID: #require(entry.exportID))
        { value in
            progress(value)
            if case let .exporting(written) = value, written.phase == .writing, written.completedModels == 1
            {
                do { try damaged.write(to: historyURL) }
                catch { Issue.record("Could not install the local history-failure fixture.") }
            }
        }
    }
    try await waitForExportQueue { !queue.isBusy }
    let entry = try #require(queue.entries.first)
    #expect(entry.phase == .complete && entry.isUnrecorded && entry.message != nil)
    let destination = root.appendingPathComponent("delivery")
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
    queue.collect(to: destination)
    try await waitForExportQueue { !queue.isBusy }
    try #require(queue.operationError == nil)
    let batch = try #require(queue.lastCollectionURL), record = try #require(entry.result)
    let original = try await files.exportFileURL(projectID: request.projectID, record: record)
    #expect(try Data(contentsOf: batch.appendingPathComponent(record.fileName)) == Data(contentsOf: original))
    #expect(try await files.readMetadata(.exports(request.projectID)) == damaged)
}

// Collection rejects managed destinations and linked companions, and removes
// only its own incomplete copies after cancellation. Original exports survive.
@Test func exportQueueCollectionCancellationAndConfinement() async throws
{
    let root = try projectStoreTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let files = try EarthAppFiles(storageRootURL: root.appendingPathComponent("managed"))
    try await files.initialize()
    let (request, service) = try await queueTestRequest(files: files, store: EarthProjectStore(files: files))
    let output = try await service.export(variantID: request.variantID, options: request.options, progress: { _ in })
    var entry = EarthExportQueueEntry(request: request)
    entry.phase = .complete
    entry.exportID = output.output.id
    entry.result = output.output
    let snapshot = entry
    let bytes = try Data(contentsOf: output.fileURL)
    let destination = root.appendingPathComponent("delivery")
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
    let sentinel = destination.appendingPathComponent("keep.txt")
    try Data([5]).write(to: sentinel)
    await #expect(throws: EarthAppFilesError.invalidLocation)
    { try await files.collectExports([snapshot], to: files.storageRootURL, progress: { _, _ in }) }
    let copy = Task
    {
        try await files.collectExports([snapshot], to: destination)
        { completed, _ in if completed == 0 { withUnsafeCurrentTask { $0?.cancel() } } }
    }
    await #expect(throws: CancellationError.self) { try await copy.value }
    #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path) == ["keep.txt"])
    #expect(try Data(contentsOf: output.fileURL) == bytes)
    let companion = EarthGLBInfo.companionURL(output.fileURL)
    try FileManager.default.removeItem(at: companion)
    try FileManager.default.createSymbolicLink(at: companion, withDestinationURL: sentinel)
    await #expect(throws: EarthAppFilesError.invalidLocation)
    { try await files.collectExports([snapshot], to: destination, progress: { _, _ in }) }
    #expect(try Data(contentsOf: sentinel) == Data([5]))
}
