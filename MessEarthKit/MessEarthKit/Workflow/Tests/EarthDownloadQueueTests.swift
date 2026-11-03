import Foundation
@testable import MessEarthKit
import Testing

private enum DownloadQueueFixtureError: Error { case timeout, preparation }

private actor DownloadQueueFixture
{
    let archive: EarthSourceArchive
    let collection: EarthPreparedCollection
    private(set) var downloads: [Int] = []
    private(set) var preparations: [Int] = []
    private(set) var peakDownloads = 0
    private(set) var peakPreparations = 0
    private var downloading = 0
    private var preparing = 0
    private var releasedDownloads: Set<Int> = []
    private var releasedPreparations: Set<Int> = []
    private var failedDownloads: Set<Int> = []
    private(set) var progressCallbacks: [Int: @Sendable (EarthCaptureProgress) -> Void] = [:]

    init(archive: EarthSourceArchive, collection: EarthPreparedCollection)
    { self.archive = archive; self.collection = collection }

    func download(_ index: Int, progress: @escaping @Sendable (EarthCaptureProgress) -> Void) async throws -> EarthSourceArchive
    {
        downloads.append(index)
        progressCallbacks[index] = progress
        downloading += 1
        peakDownloads = max(peakDownloads, downloading)
        defer { downloading -= 1 }
        while !releasedDownloads.contains(index) { try await Task.sleep(for: .milliseconds(5)) }
        if failedDownloads.remove(index) != nil { throw EarthCaptureError.serviceRejected(reason: .ipRestricted, statusCode: 403) }
        return archive
    }

    func prepare(_ index: Int) async throws -> EarthPreparedCollection
    {
        preparations.append(index)
        preparing += 1
        peakPreparations = max(peakPreparations, preparing)
        defer { preparing -= 1 }
        while !releasedPreparations.contains(index) { try await Task.sleep(for: .milliseconds(5)) }
        return collection
    }

    func releaseDownload(_ index: Int) { releasedDownloads.insert(index) }
    func releasePreparation(_ index: Int) { releasedPreparations.insert(index) }
    func failDownload(_ index: Int) { failedDownloads.insert(index); releasedDownloads.insert(index) }
}

@MainActor private func awaitDownloadQueue(_ condition: @MainActor () async -> Bool) async throws
{
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while !(await condition())
    {
        guard ContinuousClock.now < deadline else { throw DownloadQueueFixtureError.timeout }
        try await Task.sleep(for: .milliseconds(5))
    }
}

// Admission and cancellation risks: FIFO overflow, independent pause, a retained
// worker slot until cancellation settles, serial preparation, stale retry progress.
@Test(arguments: [false, true])
@MainActor private func downloadQueueBoundsWorkAndIsolatesCancellationAndRetry(rejectDownload: Bool) async throws
{
    let root = try projectStoreTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let files = try EarthAppFiles(storageRootURL: root)
    try await files.initialize()
    let store = EarthProjectStore(files: files)
    let project = try await store.create()
    let archive = try await projectSourceFixture(files: files, projectID: project.id)
    let collection = try await EarthModelPreparer().prepare(archive: archive, directoryURL: root.appendingPathComponent("Prepared"), profile: EarthPreparationProfile(name: "Queue fixture"))
    let fixture = DownloadQueueFixture(archive: archive, collection: collection)
    let queue = EarthDownloadQueue()
    let jobs = (0 ..< 4).map { _ in EarthDownloadJob(id: .init(projectID: UUID(), variantID: UUID()), generation: UUID(), locationID: UUID(), sourceID: UUID()) }
    var completed: Set<EarthDownloadJobID> = []
    var downloaded: [EarthDownloadJobID: EarthSourceArchive] = [:]
    func enqueue(_ index: Int, job: EarthDownloadJob) -> Bool
    {
        queue.enqueue(job: job, download: { try await fixture.download(index, progress: $0) }, prepare: { _, _ in try await fixture.prepare(index) }, onDownloaded: { downloaded[job.id] = $0 }, onFinished: {
            #expect(!Task.isCancelled)
            completed.insert(job.id)
        })
    }
    defer { for job in jobs { queue.pause(job.id) } }
    for index in jobs.indices { #expect(enqueue(index, job: jobs[index])) }
    #expect(!enqueue(0, job: jobs[0]))
    try await awaitDownloadQueue { await fixture.downloads.count == 2 }
    #expect(await fixture.downloads == [0, 1])
    let staleProgress = try #require(await fixture.progressCallbacks[0])
    queue.pause(jobs[3].id)
    if rejectDownload { await fixture.failDownload(0) }
    else { queue.pause(jobs[0].id) }
    try await awaitDownloadQueue { await fixture.downloads.count == 3 && completed.contains(jobs[0].id) && completed.contains(jobs[3].id) }
    #expect(await fixture.downloads == [0, 1, 2])
    #expect(queue.jobs[jobs[1].id]?.phase == .downloading)
    #expect((queue.jobs[jobs[0].id]?.errorMessage != nil) == rejectDownload)
    await fixture.releaseDownload(1)
    try await awaitDownloadQueue { await fixture.preparations == [1] }
    await fixture.releaseDownload(2)
    try await awaitDownloadQueue { queue.jobs[jobs[2].id]?.phase == .waitingForPreparation }
    await fixture.releasePreparation(1)
    try await awaitDownloadQueue { await fixture.preparations == [1, 2] }
    if rejectDownload { await fixture.releasePreparation(2) }
    else { queue.pause(jobs[2].id) }
    try await awaitDownloadQueue { completed.count == 4 }
    #expect(downloaded[jobs[2].id]?.state == .downloaded)
    #expect(queue.jobs[jobs[2].id]?.phase == (rejectDownload ? .complete : .paused))
    let peakDownloads = await fixture.peakDownloads
    let peakPreparations = await fixture.peakPreparations
    #expect(peakDownloads == 2 && peakPreparations == 1)

    let retry = EarthDownloadJob(id: jobs[0].id, generation: UUID(), locationID: jobs[0].locationID, sourceID: jobs[0].sourceID)
    #expect(enqueue(0, job: retry))
    #expect(queue.jobs[retry.id]?.errorMessage == nil)
    staleProgress(.init(sourceRequests: 777, visitedTiles: 777, downloadedTiles: 777, downloadedBytes: 777))
    try await awaitDownloadQueue { await fixture.downloads.count == 4 }
    #expect(queue.jobs[retry.id]?.progressText.contains("777") == false)
    await fixture.releaseDownload(0)
    await fixture.releasePreparation(0)
    try await awaitDownloadQueue { queue.jobs[retry.id]?.phase == .complete }
    #expect(queue.jobs[jobs[3].id]?.phase == .paused)
    queue.forgetFinishedJob(retry.id)
    #expect(queue.jobs[retry.id] == nil)
}

private actor PreparationGateFixture
{
    private(set) var started: [Int] = []
    private(set) var active = 0
    private(set) var peak = 0
    private var released: Set<Int> = []

    func run(_ id: Int) async throws -> Int
    {
        started.append(id)
        active += 1
        peak = max(peak, active)
        defer { active -= 1 }
        while !released.contains(id) { try await Task.sleep(for: .milliseconds(5)) }
        if id == 1 { throw DownloadQueueFixtureError.preparation }
        return id
    }

    func release(_ id: Int) { released.insert(id) }
}

@Test @MainActor func downloadQueueIncludesCompletionRefreshInActiveWork() async throws
{
    let root = try projectStoreTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let files = try EarthAppFiles(storageRootURL: root)
    try await files.initialize()
    let project = try await EarthProjectStore(files: files).create()
    let archive = try await projectSourceFixture(files: files, projectID: project.id)
    let collection = try await EarthModelPreparer().prepare(archive: archive, directoryURL: root.appendingPathComponent("Prepared"), profile: EarthPreparationProfile())
    let gate = PreparationGateFixture(), queue = EarthDownloadQueue()
    let job = EarthDownloadJob(id: .init(projectID: project.id, variantID: UUID()), generation: UUID(), locationID: UUID(), sourceID: UUID())
    let accepted = queue.enqueue(job: job, download: { _ in archive }, prepare: { _, _ in collection }, onDownloaded: { _ in }, onFinished: { _ = try? await gate.run(0) })
    #expect(accepted)
    try await awaitDownloadQueue { await gate.started == [0] }
    // Physical work is complete, but its awaited metadata refresh still owns I/O.
    #expect(queue.jobs[job.id]?.phase == .complete && queue.hasActiveWork)
    await gate.release(0)
    try await awaitDownloadQueue { !queue.hasActiveWork }
}

// A queued cancellation must finish before the running preparation does, and a
// failed native operation must release admission for another caller.
@Test @MainActor func preparationGateReleasesFailureAndCancelsWaitingCaller() async throws
{
    let gate = EarthPreparationGate()
    let fixture = PreparationGateFixture()
    let first = Task { try await gate.run { try await fixture.run(1) } }
    defer { first.cancel() }
    try await awaitDownloadQueue { await fixture.started == [1] }
    var cancelled = false
    let second = Task
    {
        do { _ = try await gate.run { try await fixture.run(2) } }
        catch is CancellationError { cancelled = true }
        catch { Issue.record(error) }
    }
    try await Task.sleep(for: .milliseconds(10))
    second.cancel()
    try await awaitDownloadQueue { cancelled }
    #expect(await fixture.active == 1)
    let third = Task { try await gate.run { try await fixture.run(3) } }
    defer { third.cancel() }
    await fixture.release(1)
    await #expect(throws: DownloadQueueFixtureError.self) { try await first.value }
    try await awaitDownloadQueue { await fixture.started == [1, 3] }
    await fixture.release(3)
    let result = try await third.value
    let peak = await fixture.peak
    #expect(result == 3 && peak == 1)
}

// Selection changes are valid during acquisition/preparation. Only replacing
// the pinned variant's source invalidates the result.
@Test func concurrentCaptureCompletionKeepsVariantOwnershipAcrossSelection() async throws
{
    let root = try projectStoreTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let files = try EarthAppFiles(storageRootURL: root)
    try await files.initialize()
    let store = EarthProjectStore(files: files)
    let project = try await store.create()
    let first = try await projectSourceFixture(files: files, projectID: project.id)
    let firstRecord = try await projectRegisterSource(files: files, store: store, projectID: project.id, source: first)
    let firstID = try #require(firstRecord.selectedCaptureID)
    let second = try await projectSourceFixture(files: files, projectID: project.id)
    let secondRecord = try await projectRegisterSource(files: files, store: store, projectID: project.id, source: second)
    let secondID = try #require(secondRecord.selectedCaptureID)
    let service = EarthProjectCaptureService(
        id: project.id,
        files: files,
        store: store,
        lookup: { _ in throw DownloadQueueFixtureError.preparation },
        acquire: { source, _, _ in
            _ = try await store.selectCapture(id: project.id, captureID: secondID)
            return source
        },
        prepare: { source, profile, progress in
            _ = try await store.selectCapture(id: project.id, captureID: secondID)
            let directory = try await files.newArtifactDirectory(projectID: project.id, kind: .prepared)
            return try await EarthModelPreparer().prepare(archive: source, directoryURL: directory, profile: profile, progress: progress)
        }
    )
    _ = try await service.download(variantID: firstID, archive: first, apiKey: "fixture", progress: { _ in })
    let prepared = try await service.prepareModels(variantID: firstID, archive: first, progress: { _ in })
    let record = try await store.record(id: project.id)
    #expect(record.selectedCaptureID == secondID && record.editingLocationID == secondRecord.editingLocationID)
    #expect(record.captures.first { $0.id == firstID }?.preparation?.id.uuidString == prepared.directoryURL.lastPathComponent)
    #expect(record.captures.first { $0.id == secondID }?.preparation == nil)
    await #expect(throws: EarthProjectStoreError.sourceMismatch)
    { try await service.download(variantID: firstID, archive: second, apiKey: "fixture", progress: { _ in }) }
}
