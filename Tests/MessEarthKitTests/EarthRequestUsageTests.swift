import Foundation
@testable import MessEarthKit
import Testing

@Test func usageWindowPersistsAndClearDoesNotRestoreInflightRequests() async throws
{
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("usage.sqlite")
    let now = Date(timeIntervalSince1970: 1800000000)
    let store = EarthRequestUsageStore(fileURL: file, now: { now })
    let root = UUID(), tile = UUID(), pending = UUID()
    let cutoff = now.addingTimeInterval(-EarthRequestUsageStore.window)
    await store.record(.started(id: UUID(), kind: .session, at: cutoff))
    await store.record(.started(id: root, kind: .session, at: cutoff.addingTimeInterval(0.01)))
    await store.record(.finished(id: root, outcome: .failed, at: now, statusCode: 429, receivedBytes: nil))
    await store.record(.started(id: tile, kind: .tile, at: now))
    await store.record(.started(id: tile, kind: .tile, at: now)) // Re-delivery is idempotent.
    await store.record(.finished(id: tile, outcome: .succeeded, at: now, statusCode: 200, receivedBytes: 8))
    await store.record(.finished(id: tile, outcome: .failed, at: now, statusCode: nil, receivedBytes: nil))
    await store.record(.started(id: pending, kind: .metadata, at: now))
    let current = await store.snapshot()
    #expect(current.totalRequests == 3 && current.sessionRequests == 1)
    #expect(current.metadataRequests == 1 && current.tileRequests == 1)
    #expect(current.succeededRequests == 1 && current.failedRequests == 1 && current.pendingRequests == 1)
    #expect(current.trackingStartedAt == now && current.lastClearedAt == nil)

    let later = now.addingTimeInterval(0.02)
    let reopened = EarthRequestUsageStore(fileURL: file, now: { later })
    let aged = await reopened.snapshot()
    #expect(aged.totalRequests == 2 && aged.sessionRequests == 0 && aged.failedRequests == 0)
    #expect(aged.pendingRequests == 1) // A restart does not pretend the outcome is known.
    let cleared = await reopened.clear()
    #expect(cleared.totalRequests == 0 && cleared.lastClearedAt == later && cleared.trackingStartedAt == later)
    await store.record(.finished(id: pending, outcome: .succeeded, at: later, statusCode: 200, receivedBytes: 1))
    await reopened.record(.started(id: UUID(), kind: .session, at: later))
    let afterClear = await reopened.snapshot()
    #expect(afterClear.totalRequests == 1 && afterClear.pendingRequests == 1)
    #expect(afterClear.succeededRequests == 0)
}

@Test func usageObserverCountsSourceRequestsButNotCacheOrOfflinePreparation() async throws
{
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = EarthRequestUsageStore(fileURL: directory.appendingPathComponent("usage.sqlite"))
    let resources = try precheckFixtureResources(flatNormals: false)
    let session = EarthCaptureSession(apiKey: "fixture-key", requestObserver: { await store.record($0) }, resourceLoader: { url, _ in
        guard let data = resources[url.path] else { throw EarthCaptureError.requestFailed(404) }
        return data
    })
    let request = try EarthCaptureRequest(center: EarthGeographicOrigin(latitude: 0, longitude: 0), widthMeters: 20, depthMeters: 20)
    let checked = try await session.precheck(request: request)
    _ = try await EarthCaptureImporter().importPrechecked(precheck: checked)
    let stats = await store.snapshot()
    // Two placements share one GLB; root + child JSON + one GLB is three requests.
    #expect(stats.totalRequests == 3 && stats.succeededRequests == 3)
    #expect(stats.sessionRequests == 1 && stats.metadataRequests == 1 && stats.tileRequests == 1)
}

private enum UsageTransportCase: CaseIterable, Sendable
{
    case retry, cancellation, nestedRoot
}

@Test(arguments: UsageTransportCase.allCases)
private func transportUsageTracksAttemptsAndOutcomes(scenario: UsageTransportCase) async throws
{
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = EarthRequestUsageStore(fileURL: directory.appendingPathComponent("usage.sqlite"))
    let path = scenario == .nestedRoot ? "/v1/3dtiles/child/root.json" : "/v1/3dtiles/root.json"
    let url = try #require(URL(string: "https://tile.googleapis.com" + path + "?key=fixture-key&session=fixture-session"))
    let transport = EarthRequestTransport(observer: { await store.record($0) }, loader: { _, _ in
        switch scenario
        {
            case .retry: throw EarthCaptureError.requestFailed(429)
            case .cancellation: throw CancellationError()
            case .nestedRoot: return Data([1])
        }
    })
    if scenario == .retry
    {
        for _ in 0 ..< 2
        { await #expect(throws: EarthCaptureError.self) { try await transport.load(url: url, maximumBytes: 100) } }
        let stats = await store.snapshot()
        #expect(stats.totalRequests == 2 && stats.failedRequests == 2 && stats.sessionRequests == 2)
    }
    else if scenario == .cancellation
    {
        await #expect(throws: CancellationError.self) { try await transport.load(url: url, maximumBytes: 100) }
        let alreadyCancelled = Task
        {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await transport.load(url: url, maximumBytes: 100)
        }
        await #expect(throws: CancellationError.self) { try await alreadyCancelled.value }
        let stats = await store.snapshot()
        #expect(stats.totalRequests == 1 && stats.cancelledRequests == 1)
    }
    else
    {
        _ = try await transport.load(url: url, maximumBytes: 100)
        let stats = await store.snapshot()
        #expect(stats.sessionRequests == 0 && stats.metadataRequests == 1)
    }
    if scenario == .nestedRoot
    {
        // One representative request checks the database and SQLite sidecars.
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        for file in files
        {
            let data = try Data(contentsOf: file)
            #expect(data.range(of: Data("fixture-key".utf8)) == nil && data.range(of: Data("fixture-session".utf8)) == nil)
        }
    }
}

@Test func usageStorageFailureIsExplicitAndDoesNotStopTheTransport() async throws
{
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("usage.sqlite")
    try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
    try Data("Keep capture".utf8).write(to: file.appendingPathComponent("capture.bin"))
    let store = EarthRequestUsageStore(fileURL: file) // A directory cannot be opened as SQLite.
    let transport = EarthRequestTransport(observer: { await store.record($0) }, loader: { _, _ in Data([7]) })
    let result = try await transport.load(url: #require(URL(string: "https://tile.googleapis.com/v1/3dtiles/tile.glb")), maximumBytes: 100)
    #expect(result == Data([7]))
    let unavailable = await store.snapshot()
    #expect(unavailable.totalRequests == nil && unavailable.trackingIssue != nil)
    let preserved = directory.appendingPathComponent("preserved")
    try FileManager.default.moveItem(at: file, to: preserved)
    let restored = await store.snapshot()
    #expect(restored.trackingIssue != nil) // Missing attempts cannot be silently called zero usage.
    let reopened = EarthRequestUsageStore(fileURL: file)
    #expect(await reopened.snapshot().trackingIssue != nil)
    let cleared = await reopened.clear()
    #expect(cleared.totalRequests == 0 && cleared.trackingIssue == nil)
    #expect(try Data(contentsOf: preserved.appendingPathComponent("capture.bin")) == Data("Keep capture".utf8))
}
