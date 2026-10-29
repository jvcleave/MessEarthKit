import Foundation
@testable import MessEarthKit
import simd
import Testing

private enum SourceInterruption: CaseIterable, Sendable { case http, cancellation, disk }

private actor SourceFixture
{
    var metadata: [String: Data]
    let payload: Data
    var interruption: SourceInterruption?
    var received: [URL] = []
    let generatesLargeFiles: Bool
    var blockedDestination: URL?

    init(count: Int = 2, interruption: SourceInterruption? = nil, generatesLargeFiles: Bool = false) throws
    {
        let original = try precheckFixtureResources(flatNormals: false)
        metadata = original
        payload = original["/v1/3dtiles/block.glb"]!
        self.interruption = interruption
        self.generatesLargeFiles = generatesLargeFiles
        var catalog = try JSONSerialization.jsonObject(with: original["/v1/3dtiles/catalog.json"]!) as! [String: Any]
        var root = catalog["root"] as! [String: Any]
        var children = (0 ..< count).map
        { index in
            // Preserve the authored fixture's first-child placement.
            ["boundingVolume": ["sphere": [2, 2, 1, 6]], "geometricError": 0, "transform": [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, -5, 0, 0, 1], "content": ["uri": "/v1/3dtiles/tile-\(index).glb"]] as [String: Any]
        }
        if count == 2 { children.insert(children[0], at: 0) }
        root["children"] = children
        catalog["root"] = root
        metadata["/v1/3dtiles/catalog.json"] = try JSONSerialization.data(withJSONObject: catalog, options: [.withoutEscapingSlashes])
    }

    func load(_ url: URL, maximumBytes: Int) throws -> Data
    {
        received.append(url)
        guard let data = metadata[url.path], data.count <= maximumBytes else { throw EarthCaptureError.requestFailed(404) }
        return data
    }

    func download(_ url: URL, to output: URL) async throws -> Int
    {
        received.append(url)
        if url.lastPathComponent == "tile-1.glb", let interruption
        {
            try Data([1, 2, 3]).write(to: output)
            switch interruption
            {
                case .http: throw EarthCaptureError.requestFailed(429)
                case .cancellation:
                    try await Task.sleep(for: .seconds(10))
                    throw CancellationError()
                case .disk:
                    // Fail the real atomic publication, after successful transfer.
                    let id = EarthSourceAccess(apiKey: "").identity(url)
                    let destination = output.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("tiles/\(id).glb")
                    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
                    blockedDestination = destination
            }
        }
        if generatesLargeFiles
        {
            let index = Int(url.deletingPathExtension().lastPathComponent.dropFirst(5))!
            return try generatedGLB(to: output, bytes: index < 8 ? 17 * 1024 * 1024 : 24)
        }
        try payload.write(to: output)
        return payload.count
    }

    func refreshAccess(changedVersion: Bool = false) throws
    {
        interruption = nil
        if let blockedDestination
        {
            try FileManager.default.removeItem(at: blockedDestination)
            self.blockedDestination = nil
        }
        let root = metadata["/v1/3dtiles/root.json"]!
        metadata["/v1/3dtiles/root.json"] = Data(String(decoding: root, as: UTF8.self).replacingOccurrences(of: "fixture-session", with: "renewed-session").utf8)
        if changedVersion
        {
            var catalog = try JSONSerialization.jsonObject(with: metadata["/v1/3dtiles/catalog.json"]!) as! [String: Any]
            catalog["asset"] = ["version": "1.1", "tilesetVersion": "new-source-version"]
            metadata["/v1/3dtiles/catalog.json"] = try JSONSerialization.data(withJSONObject: catalog)
        }
    }

    func requests() -> [URL] { received }

    func redirectCatalog(to uri: String) throws
    {
        var catalog = try JSONSerialization.jsonObject(with: metadata["/v1/3dtiles/catalog.json"]!) as! [String: Any]
        var root = catalog["root"] as! [String: Any]
        root["children"] = nil
        root["content"] = ["uri": uri]
        catalog["root"] = root
        metadata["/v1/3dtiles/catalog.json"] = try JSONSerialization.data(withJSONObject: catalog)
    }
}

/// Valid GLB containers generated through a 64 KiB buffer. The deliberately
/// empty JSON is not a renderable model, proving acquisition is codec independent.
private func generatedGLB(to url: URL, bytes: Int) throws -> Int
{
    guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw EarthAcquisitionError.storage }
    let output = try FileHandle(forWritingTo: url)
    defer { try? output.close() }
    var header = Data()
    let hasBinary = bytes > 24
    for word: UInt32 in [0x46546C67, 2, UInt32(bytes), 4, 0x4E4F534A]
    {
        var value = word.littleEndian
        withUnsafeBytes(of: &value) { header.append(contentsOf: $0) }
    }
    header.append(Data("{}  ".utf8))
    if hasBinary
    {
        for word: UInt32 in [UInt32(bytes - 32), 0x004E4942]
        {
            var value = word.littleEndian
            withUnsafeBytes(of: &value) { header.append(contentsOf: $0) }
        }
    }
    try output.write(contentsOf: header)
    let chunk = Data(repeating: 0, count: 65536)
    var remaining = bytes - header.count
    while remaining > 0
    {
        try Task.checkCancellation()
        let size = min(remaining, chunk.count)
        try output.write(contentsOf: chunk.prefix(size))
        remaining -= size
    }
    return bytes
}

private func sourceRequest(width: Double = 20) throws -> EarthDownloadRequest
{
    try EarthDownloadRequest(center: EarthGeographicOrigin(latitude: 0, longitude: 0), widthMeters: width, depthMeters: 20)
}

private func fixtureAcquisition(_ fixture: SourceFixture, key: String = "fixture-key", observer: EarthRequestObserver? = nil) -> EarthSourceAcquisition
{
    EarthSourceAcquisition(apiKey: key, requestObserver: observer, metadataLoader: { try await fixture.load($0, maximumBytes: $1) }, downloader: { try await fixture.download($0, to: $1) })
}

@Test func sourceAcquisitionStreamsBeyondLegacyCeilings() async throws
{
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let fixture = try SourceFixture(count: 4100, generatesLargeFiles: true)
    let archive = try await fixtureAcquisition(fixture).download(request: sourceRequest(width: 6000), directoryURL: directory)
    #expect(archive.state == .downloaded)
    #expect(archive.selectedTileCount == 4100)
    #expect(archive.completedPayloadCount == 4100)
    #expect(archive.downloadedBytes > 128 * 1024 * 1024)
    #expect(archive.sourceRequests == 4102)
    let root = try #require(archive.rootSourceURL)
    let json = try JSONSerialization.jsonObject(with: Data(contentsOf: root)) as! [String: Any]
    let tile = json["root"] as! [String: Any]
    #expect((tile["children"] as? [Any])?.count == 4100)
    #expect(try await EarthSourceArchive.open(directoryURL: directory).state == .downloaded)
    let attempts = await fixture.requests().count
    _ = try await fixtureAcquisition(fixture).download(request: sourceRequest(width: 6000), directoryURL: directory, resuming: true)
    #expect(await fixture.requests().count == attempts)
}

@Test(arguments: SourceInterruption.allCases)
private func sourceAcquisitionResumesCompletedFiles(interruption: SourceInterruption) async throws
{
    let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: parent) }
    let directory = parent.appendingPathComponent("source")
    let usage = EarthRequestUsageStore(fileURL: parent.appendingPathComponent("usage.sqlite"))
    let observer: EarthRequestObserver = { await usage.record($0) }
    let fixture = try SourceFixture(interruption: interruption)
    let initializedOffline = interruption == .http
    if initializedOffline
    {
        let created = try await EarthSourceArchive.create(request: sourceRequest(), directoryURL: directory)
        #expect(created.state == .paused && created.sourceRequests == 0 && created.rootSourceURL == nil)
        #expect(await fixture.requests().isEmpty)
    }
    let interrupted = Task { try await fixtureAcquisition(fixture, observer: observer).download(request: sourceRequest(), directoryURL: directory, resuming: initializedOffline) }
    defer { interrupted.cancel() }
    if interruption == .cancellation
    {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while await fixture.requests().count < 4, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        interrupted.cancel()
    }
    await #expect(throws: (any Error).self) { try await interrupted.value }
    let paused = try await EarthSourceArchive.open(directoryURL: directory)
    #expect(paused.state == .paused)
    #expect(paused.completedPayloadCount == 1)
    #expect(paused.rootSourceURL == nil)
    #expect(await usage.snapshot().totalRequests == 4)
    try await fixture.refreshAccess()
    let completed = try await fixtureAcquisition(fixture, key: "new-key", observer: observer).download(request: sourceRequest(), directoryURL: directory, resuming: true)
    #expect(completed.state == .downloaded)
    #expect(completed.selectedTileCount == 3)
    let requests = await fixture.requests()
    #expect(requests.filter { $0.lastPathComponent == "tile-0.glb" }.count == 1)
    #expect(requests.filter { $0.lastPathComponent == "tile-1.glb" }.count == 2)
    let last = try #require(requests.last)
    let query = URLComponents(url: last, resolvingAgainstBaseURL: true)?.queryItems
    #expect(query?.contains(.init(name: "key", value: "new-key")) == true)
    #expect(query?.contains(.init(name: "session", value: "renewed-session")) == true)
    #expect(await usage.snapshot().totalRequests == 7)
    #expect(await usage.snapshot().sessionRequests == 2)
    // One representative fixture checks the whole journal, sidecars and metadata.
    if interruption == .http
    {
        let models = try await EarthCaptureImporter().prepareCollection(fileURL: #require(completed.rootSourceURL))
        let decoded = try await EarthCaptureImporter().importSection(#require(models.sections.first))
        // Independently authored orientation fixture: each placement has two
        // meshes with this local minimum. Flattening must preserve all three.
        #expect(decoded.meshes.count == 6)
        #expect(simd_distance(decoded.bounds.minimum, SIMD3(-4, 0.5, -5)) < 0.001)
        let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey])!
        while let file = files.nextObject() as? URL
        {
            if try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true
            {
                let data = try Data(contentsOf: file)
                for secret in ["fixture-key", "new-key", "fixture-session", "renewed-session", "tile.googleapis.com"]
                { #expect(data.range(of: Data(secret.utf8)) == nil) }
            }
        }
        let limit = EarthImportLimits(maximumVertices: 1)
        await #expect(throws: (any Error).self) { try await EarthCaptureImporter(limits: limit).prepareCollection(fileURL: #require(completed.rootSourceURL)) }
        try await verifyResumedSourceOfflineWorkflow(completed, parent: parent)
        #expect(await usage.snapshot().totalRequests == 7)
        #expect(await fixture.requests().count == requests.count)
    }
}

// Exercise the actual acquired artifact through the new file-backed route.
// Component fixtures alone cannot prove the acquisition/preparation boundary or
// that a failed profile can be retried and delivered without more transport.
private func verifyResumedSourceOfflineWorkflow(_ archive: EarthSourceArchive, parent: URL) async throws
{
    let root = try #require(archive.rootSourceURL)
    let manifest = try Data(contentsOf: root)
    let originals = try FileManager.default.contentsOfDirectory(at: archive.directoryURL.appendingPathComponent("tiles"), includingPropertiesForKeys: nil)
    let payloads = try originals.map { try Data(contentsOf: $0) }
    let preparer = EarthModelPreparer()
    let tooSmall = try EarthPreparationProfile(maximumVerticesPerModel: 1)
    await #expect(throws: EarthPreparationError.invalidProfile)
    { try await preparer.prepare(archive: archive, directoryURL: parent.appendingPathComponent("unfit"), profile: tooSmall) }
    let retained = try await EarthSourceArchive.open(directoryURL: archive.directoryURL)
    #expect(retained.state == .downloaded && retained.interruptionReason == nil)

    let profile = try EarthPreparationProfile(maximumPlacementsPerModel: 1)
    let prepared = try await preparer.prepare(archive: retained, directoryURL: parent.appendingPathComponent("prepared"), profile: profile)
    #expect(prepared.state == .ready && prepared.modelCount == 3 && prepared.coversEntireSource)
    let subsetRoot = try await EarthCaptureStore().save(collection: prepared, selection: .only([1, 3]), directoryURL: parent.appendingPathComponent("subset"))
    let subset = try await EarthPreparedCollection.open(directoryURL: subsetRoot.deletingLastPathComponent())
    #expect(try await subset.models().map(\.id) == [1, 3])
    let preview = try await subset.importModel(id: 3)
    #expect(preview.triangleCount == 14 && preview.incompleteReason == nil)
    // Both selected placements reuse the independently authored orientation tile.
    #expect(simd_distance(preview.bounds.minimum, SIMD3(-4, 0.5, -5)) < 0.001)
    let exporter = EarthGLBExporter()
    let plan = try await exporter.preflight(collection: subset, destination: profile)
    #expect(plan.canExport && !plan.coversEntireSource)
    let combined = try await exporter.export(plan: plan, fileURL: parent.appendingPathComponent("combined.glb"))
    let reopened = try await EarthCaptureImporter(limits: profile.importLimits).importFile(fileURL: combined)
    #expect(reopened.triangleCount == 28 && reopened.geographicOrigin == archive.request.center)
    #expect(reopened.attributions == preview.attributions && reopened.preparationProfile == profile)
    #expect(try Data(contentsOf: root) == manifest)
    #expect(try originals.map { try Data(contentsOf: $0) } == payloads)
}

@Test func sourceAcquisitionRejectsChangedVersionsAndConcurrentWriters() async throws
{
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let fixture = try SourceFixture(interruption: .http)
    await #expect(throws: (any Error).self) { try await fixtureAcquisition(fixture).download(request: sourceRequest(), directoryURL: directory) }
    do
    {
        let lock = try EarthAcquisitionLock(files: EarthAcquisitionFiles(directoryURL: directory))
        await #expect(throws: EarthAcquisitionError.archiveInUse)
        { try await fixtureAcquisition(fixture).download(request: sourceRequest(), directoryURL: directory, resuming: true) }
        withExtendedLifetime(lock) {}
    }
    try await fixture.refreshAccess(changedVersion: true)
    await #expect(throws: EarthAcquisitionError.sourceChanged)
    { try await fixtureAcquisition(fixture).download(request: sourceRequest(), directoryURL: directory, resuming: true) }
    #expect(try await EarthSourceArchive.open(directoryURL: directory).completedPayloadCount == 1)
    #expect(await fixture.requests().filter { $0.pathExtension == "glb" }.count == 2)
}

private enum SourceFileRecovery: CaseIterable, Sendable { case atomicPublication, corruptedPayload }

@Test(arguments: SourceFileRecovery.allCases)
private func sourceAcquisitionRevalidatesFilesAndRecoversAtomicPublication(scenario: SourceFileRecovery) async throws
{
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let fixture = try SourceFixture(interruption: .http)
    await #expect(throws: (any Error).self) { try await fixtureAcquisition(fixture).download(request: sourceRequest(), directoryURL: directory) }
    let files = EarthAcquisitionFiles(directoryURL: directory)
    let first = await fixture.requests().first { $0.lastPathComponent == "tile-0.glb" }!
    let id = EarthSourceAccess(apiKey: "").identity(first)
    let path = "tiles/\(id).glb"
    let url = try files.checked(path)
    if scenario == .atomicPublication
    {
        // Simulate a crash after atomic rename but before the completed-row update.
        let index = try EarthAcquisitionIndex(directoryURL: directory, creating: nil)
        try index.pending(id)
    }
    else
    {
        var corrupt = try Data(contentsOf: url)
        corrupt[corrupt.count - 1] ^= 1
        try corrupt.write(to: url)
    }
    try await fixture.refreshAccess()
    _ = try await fixtureAcquisition(fixture).download(request: sourceRequest(), directoryURL: directory, resuming: true)
    #expect(await fixture.requests().filter { $0.lastPathComponent == "tile-0.glb" }.count == (scenario == .atomicPublication ? 1 : 2))
    #expect(try files.integrity(url).bytes > 0)
}

@Test(arguments: ["https://example.com/v1/3dtiles/foreign.glb", "/v1/3dtiles/catalog.json?session=rotated"])
func sourceAcquisitionConfinesAccessAndRejectsCycles(uri: String) async throws
{
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let fixture = try SourceFixture()
    try await fixture.redirectCatalog(to: uri)
    await #expect(throws: EarthImportError.self)
    { try await fixtureAcquisition(fixture).download(request: sourceRequest(), directoryURL: directory) }
    #expect(await fixture.requests().count == 2)
}

@Test func sourceSelectionSupportsLargeWrappedAndPolarFootprints() throws
{
    let center = try EarthGeographicOrigin(latitude: 0, longitude: 179.9)
    let request = try EarthDownloadRequest(center: center, widthMeters: 300000, depthMeters: 20000)
    let selection = EarthRegionSelection(request: request)
    let crossing = EarthTileset.BoundingVolume(box: nil, sphere: nil, region: [-.pi, -0.001, -179.8 * .pi / 180, 0.001, 0, 10])
    #expect(try selection.intersects(bounds: crossing, transform: matrix_identity_double4x4))
    let opposite = EarthTileset.BoundingVolume(box: nil, sphere: [6378137, 0, 0, 10], region: nil)
    #expect(try !selection.intersects(bounds: opposite, transform: matrix_identity_double4x4))
    let nearby = EarthRegionSelection(request: try sourceRequest(width: 6000))
    let outside = EarthTileset.BoundingVolume(box: nil, sphere: [6378137, 20000, 0, 10], region: nil)
    #expect(try !nearby.intersects(bounds: outside, transform: matrix_identity_double4x4))
    for latitude in [-89.99, 89.99]
    {
        let request = try EarthDownloadRequest(center: EarthGeographicOrigin(latitude: latitude, longitude: 0), widthMeters: 20000, depthMeters: 20000)
        let region = EarthTileset.BoundingVolume(box: nil, sphere: nil, region: [1.0, min(latitude * .pi / 180, latitude.sign == .minus ? -.pi / 2 : .pi / 2), 1.1, max(latitude * .pi / 180, latitude.sign == .minus ? -.pi / 2 : .pi / 2), 0, 10])
        #expect(try EarthRegionSelection(request: request).intersects(bounds: region, transform: matrix_identity_double4x4))
    }
}

private enum InvalidSource: CaseIterable, Sendable { case metadataBytes, metadataNesting, container }

@Test(arguments: InvalidSource.allCases)
private func sourceAcquisitionRejectsUnsupportedWorkingSetsAndContainers(scenario: InvalidSource) async throws
{
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let fixture = try SourceFixture()
    let acquisition = EarthSourceAcquisition(
        apiKey: "fixture",
        metadataLoader:
        { url, maximum in
            switch scenario
            {
                case .metadataBytes: return Data(repeating: 32, count: EarthSourceMetadata.maximumBytes + 1)
                case .metadataNesting: return Data((String(repeating: "[", count: 257) + "0" + String(repeating: "]", count: 257)).utf8)
                case .container: return try await fixture.load(url, maximumBytes: maximum)
            }
        },
        downloader:
        { _, output in
            try Data([1, 2, 3]).write(to: output)
            return 3
        }
    )
    if scenario == .container
    {
        await #expect(throws: EarthImportError.self) { try await acquisition.download(request: sourceRequest(), directoryURL: directory) }
    }
    else
    {
        await #expect(throws: EarthAcquisitionError.metadataTooLarge) { try await acquisition.download(request: sourceRequest(), directoryURL: directory) }
    }
    let archive = try await EarthSourceArchive.open(directoryURL: directory)
    #expect(archive.state == .paused && archive.completedPayloadCount == 0)
}
