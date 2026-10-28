import Foundation
@testable import MessEarthKit
import simd
import Testing

private let referenceDirectory = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Tools/IntegrationProbe/Fixtures/Orientation")

private actor CaptureResources
{
    let files: [String: Data]
    var requests: [URL] = []

    init(files: [String: Data]) { self.files = files }

    func load(url: URL, maximumBytes: Int) throws -> Data
    {
        requests.append(url)
        guard let data = files[url.path] else { throw EarthCaptureError.requestFailed(404) }
        return data
    }

    func received() -> [URL] { requests }
}

@Test func regionCaptureSelectsMatchingDetailAndSavesWithoutCredentials() async throws
{
    var root = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: referenceDirectory.appendingPathComponent("tileset.json"))) as? [String: Any])
    var rootTile = try #require(root["root"] as? [String: Any])
    var children = try #require(rootTile["children"] as? [[String: Any]])
    children[0]["content"] = ["uri": "/v1/3dtiles/catalog.json?session=fixture-session"]
    children[1]["transform"] = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 500, 2, 0, 1]
    children[1]["content"] = ["uri": "/v1/3dtiles/outside.glb"]
    // Opposite-side tiles project onto the same East/South footprint. They must
    // be rejected before their coarse leaf errors can abort a nearby capture.
    let oppositeBounds: [[String: Any]] = [
        ["box": [0, 0, -12756274, 100, 0, 0, 0, 100, 0, 0, 0, 100]],
        ["sphere": [0, 0, -12756274, 100]],
    ]
    children.insert(
        contentsOf: oppositeBounds.map
        { bounds in
            ["boundingVolume": bounds, "geometricError": 1027, "content": ["uri": "/v1/3dtiles/opposite.glb"]]
        },
        at: 0
    )
    rootTile["children"] = children
    rootTile["boundingVolume"] = ["sphere": [0, 0, -6378137, 6500000]]
    rootTile["geometricError"] = 1000000
    rootTile["content"] = ["uri": "/v1/3dtiles/coarse.glb"]
    root["root"] = rootTile
    root["geometricError"] = 1000000
    // Google's real root is 3D Tiles 1.0 and requires this GLB-content declaration.
    root["asset"] = ["version": "1.0"]
    root["extensionsUsed"] = ["3DTILES_content_gltf"]
    root["extensionsRequired"] = ["3DTILES_content_gltf"]
    let catalog: [String: Any] = [
        "asset": ["version": "1.0"],
        "extensionsUsed": ["3DTILES_content_gltf"],
        "extensionsRequired": ["3DTILES_content_gltf"],
        "root": ["boundingVolume": ["sphere": [2, 2, 1, 6]], "geometricError": 0, "content": ["uri": "tile.glb"]],
    ]
    let resources = CaptureResources(files: [
        "/v1/3dtiles/root.json": try JSONSerialization.data(withJSONObject: root),
        "/v1/3dtiles/catalog.json": try JSONSerialization.data(withJSONObject: catalog),
        "/v1/3dtiles/tile.glb": try Data(contentsOf: referenceDirectory.appendingPathComponent("block.glb")),
    ])
    let session = EarthCaptureSession(apiKey: "fixture-key", resourceLoader: { try await resources.load(url: $0, maximumBytes: $1) })
    let request = try EarthCaptureRequest(center: EarthGeographicOrigin(latitude: 0, longitude: 0), widthMeters: 20, depthMeters: 20)
    let capture = try await session.capture(request: request)
    #expect(capture.meshes.count == 2)
    #expect(simd_distance(capture.bounds.minimum, SIMD3(-4, 0.5, -5)) < 0.001)
    let received = await resources.received()
    #expect(Set(received.map(\.path)) == ["/v1/3dtiles/root.json", "/v1/3dtiles/catalog.json", "/v1/3dtiles/tile.glb"])
    let childQuery = URLComponents(url: try #require(received.last), resolvingAgainstBaseURL: true)?.queryItems ?? []
    #expect(childQuery.contains(URLQueryItem(name: "key", value: "fixture-key")))
    #expect(childQuery.contains(URLQueryItem(name: "session", value: "fixture-session")))
    for file in capture.sourceFiles
    {
        let text = String(decoding: file.data, as: UTF8.self)
        #expect(!text.contains("fixture-key") && !text.contains("fixture-session") && !text.contains("https://"))
    }
    let container = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: container) }
    let rootURL = try await EarthCaptureStore().save(capture: capture, directoryURL: container.appendingPathComponent("capture"))
    let reopened = try await EarthCaptureImporter().importFile(fileURL: rootURL)
    #expect(reopened.bounds.minimum == capture.bounds.minimum && reopened.bounds.maximum == capture.bounds.maximum)
    #expect(reopened.sourceFiles.first { $0.relativePath.hasSuffix(".glb") }?.data == capture.sourceFiles.first { $0.relativePath.hasSuffix(".glb") }?.data)
    do
    {
        try await EarthCaptureStore().save(capture: capture, directoryURL: rootURL.deletingLastPathComponent())
        Issue.record("Save replaced an existing capture folder.")
    }
    catch EarthImportError.inaccessibleSource {}
    #expect(try Data(contentsOf: rootURL) == capture.sourceFiles.first { $0.relativePath == "tileset.json" }?.data)
    // Local imports must accept an original 1.0 GLB tileset as well as rewritten 1.1 captures.
    var localManifest = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: rootURL)) as? [String: Any])
    localManifest["asset"] = ["version": "1.0"]
    localManifest["extensionsRequired"] = ["3DTILES_content_gltf"]
    localManifest["extensionsUsed"] = ["3DTILES_content_gltf"]
    try JSONSerialization.data(withJSONObject: localManifest).write(to: rootURL)
    let originalVersion = try await EarthCaptureImporter().importFile(fileURL: rootURL)
    #expect(originalVersion.bounds.minimum == capture.bounds.minimum && originalVersion.triangleCount == capture.triangleCount)
}

@Test func unsupportedRequiredTilesetExtensionRemainsAnExplicitFailure() async throws
{
    let root: [String: Any] = [
        "asset": ["version": "1.0"],
        "extensionsRequired": ["3DTILES_unsupported"],
        "root": ["boundingVolume": ["sphere": [6378137, 0, 0, 100]], "geometricError": 0],
    ]
    let resources = CaptureResources(files: ["/v1/3dtiles/root.json": try JSONSerialization.data(withJSONObject: root)])
    let session = EarthCaptureSession(apiKey: "fixture-key", resourceLoader: { try await resources.load(url: $0, maximumBytes: $1) })
    let request = try EarthCaptureRequest(center: EarthGeographicOrigin(latitude: 0, longitude: 0))
    do
    {
        _ = try await session.capture(request: request)
        Issue.record("An unsupported required extension was ignored.")
    }
    catch let EarthImportError.unsupportedContent(reason)
    {
        #expect(reason.contains("3DTILES_unsupported"))
    }
}

@Test func captureRejectsForeignSourceHostBeforeSendingCredentials() async throws
{
    let root: [String: Any] = ["asset": ["version": "1.1"], "root": ["boundingVolume": ["sphere": [6378137, 0, 0, 100]], "geometricError": 0, "content": ["uri": "https://example.invalid/v1/3dtiles/private.glb"]]]
    let resources = CaptureResources(files: ["/v1/3dtiles/root.json": try JSONSerialization.data(withJSONObject: root)])
    let session = EarthCaptureSession(apiKey: "fixture-key", resourceLoader: { try await resources.load(url: $0, maximumBytes: $1) })
    let request = try EarthCaptureRequest(center: EarthGeographicOrigin(latitude: 0, longitude: 0))
    do
    {
        _ = try await session.capture(request: request)
        Issue.record("A foreign source URI was accepted.")
    }
    catch EarthImportError.unsupportedContent {}
    #expect(await resources.received().count == 1)
}

@Test func regionBoundsHandleBothPolesAndTheDateLine() throws
{
    // A 5 km rectangle crosses the pole: longitude must not discard nearby
    // coverage in either hemisphere simply because its angle changes abruptly.
    for latitude in [-89.999, 89.999]
    {
        let request = try EarthCaptureRequest(center: EarthGeographicOrigin(latitude: latitude, longitude: 0), widthMeters: 5000, depthMeters: 5000)
        let range = latitude > 0 ? [89.99, 90.0] : [-90.0, -89.99]
        let region = EarthTileset.BoundingVolume(box: nil, sphere: nil, region: [170 * .pi / 180, range[0] * .pi / 180, 171 * .pi / 180, range[1] * .pi / 180, 0, 100])
        #expect(try EarthRegionSelection(request: request).intersects(bounds: region, transform: matrix_identity_double4x4))
    }
    let request = try EarthCaptureRequest(center: EarthGeographicOrigin(latitude: 0, longitude: 179.999), widthMeters: 500, depthMeters: 500)
    let region = EarthTileset.BoundingVolume(box: nil, sphere: nil, region: [-.pi, -0.001, -179.99 * .pi / 180, 0.001, 0, 100])
    #expect(try EarthRegionSelection(request: request).intersects(bounds: region, transform: matrix_identity_double4x4))
}

@Test func captureCapsResponsesAndSanitizesTransportErrors() async throws
{
    let request = try EarthCaptureRequest(center: EarthGeographicOrigin(latitude: 0, longitude: 0))
    let oversized = EarthCaptureSession(apiKey: "fixture-key", limits: EarthImportLimits(maximumSourceBytes: 32), resourceLoader: { _, _ in Data(repeating: 0, count: 33) })
    do
    {
        _ = try await oversized.capture(request: request)
        Issue.record("Capture accepted a response above its byte budget.")
    }
    catch EarthImportError.limitExceeded {}
    let failing = EarthCaptureSession(apiKey: "fixture-key", resourceLoader: { _, _ in
        throw NSError(domain: "Fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "https://tile.googleapis.com/?key=fixture-key"])
    })
    do
    {
        _ = try await failing.capture(request: request)
        Issue.record("Capture ignored a transport failure.")
    }
    catch let error as EarthCaptureError
    {
        #expect(!error.localizedDescription.contains("fixture-key"))
    }
}

@Test func cancellationDuringDownloadReleasesTheSession() async throws
{
    let (started, continuation) = AsyncStream<Void>.makeStream()
    let session = EarthCaptureSession(apiKey: "fixture-key", resourceLoader: { _, _ in
        continuation.yield(())
        try await Task.sleep(for: .seconds(30))
        return Data()
    })
    let request = try EarthCaptureRequest(center: EarthGeographicOrigin(latitude: 0, longitude: 0))
    let task = Task { try await session.capture(request: request) }
    var iterator = started.makeAsyncIterator()
    _ = await iterator.next()
    do
    {
        _ = try await session.capture(request: request)
        Issue.record("A second capture entered an active session.")
    }
    catch EarthCaptureError.alreadyCapturing {}
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    let cancelledRetry = Task
    {
        withUnsafeCurrentTask { $0?.cancel() }
        return try await session.capture(request: request)
    }
    await #expect(throws: CancellationError.self) { try await cancelledRetry.value }
    continuation.finish()
}

private enum RecoveryInterruption: CaseIterable, Sendable
{
    case completed, requestLimit, smallRequestLimit, raisedRequestLimit, decodeLimit, cancelled
}

@Test(arguments: RecoveryInterruption.allCases)
private func completedDownloadsSurviveInterruptedCaptures(interruption: RecoveryInterruption) async throws
{
    let container = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: container) }
    let directory = container.appendingPathComponent("recovery")
    let rootFile = directory.appendingPathComponent("tileset.json")
    let original = try Data(contentsOf: referenceDirectory.appendingPathComponent("block.glb"))
    var children: [[String: Any]] = [[
        "boundingVolume": ["sphere": [2, 2, 1, 6]], "geometricError": 0,
        "content": ["uri": "/v1/3dtiles/tile.glb?session=fixture-session"],
    ]]
    var resources: [String: Data] = ["/v1/3dtiles/tile.glb": original]
    let empty = try JSONSerialization.data(withJSONObject: [
        "asset": ["version": "1.1"],
        "root": ["boundingVolume": ["sphere": [2, 2, 1, 6]], "geometricError": 0],
    ])
    let (requestBudget, catalogCount) = switch interruption
    {
        case .completed: (512, 0)
        case .requestLimit: (512, 511)
        case .smallRequestLimit: (3, 2)
        case .raisedRequestLimit: (513, 511)
        case .decodeLimit, .cancelled: (512, 1)
    }
    let completes = interruption == .completed || interruption == .raisedRequestLimit
    let reachesRequestLimit = interruption == .requestLimit || interruption == .smallRequestLimit
    for index in 0 ..< catalogCount
    {
        let path = "/v1/3dtiles/catalog-\(index).json"
        children.append(["boundingVolume": ["sphere": [2, 2, 1, 6]], "geometricError": 0, "content": ["uri": path]])
        resources[path] = empty
    }
    var root = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: referenceDirectory.appendingPathComponent("tileset.json"))) as? [String: Any])
    var tile = try #require(root["root"] as? [String: Any])
    tile["content"] = nil
    tile["children"] = children
    root["root"] = tile
    resources["/v1/3dtiles/root.json"] = try JSONSerialization.data(withJSONObject: root)
    let loader = CaptureResources(files: resources)
    let (started, continuation) = AsyncStream<Void>.makeStream()
    let limits = interruption == .decodeLimit ? EarthImportLimits(maximumVertices: 1) : EarthImportLimits()
    let session = EarthCaptureSession(apiKey: "fixture-key", limits: limits, resourceLoader: { url, maximumBytes in
        if interruption == .cancelled, url.path.hasSuffix("catalog-0.json")
        {
            continuation.yield(())
            try await Task.sleep(for: .seconds(30))
        }
        return try await loader.load(url: url, maximumBytes: maximumBytes)
    })
    let request = try EarthCaptureRequest(center: EarthGeographicOrigin(latitude: 0, longitude: 0), widthMeters: 20, depthMeters: 20, maximumSourceRequests: requestBudget)
    let task = Task { try await session.capture(request: request, recoveryDirectoryURL: directory) }
    if interruption == .cancelled
    {
        var iterator = started.makeAsyncIterator()
        _ = await iterator.next()
        // The first tile is already durable while the next request is suspended.
        let liveCheckpoint = try await EarthCaptureImporter().importFile(fileURL: rootFile)
        #expect(liveCheckpoint.incompleteReason == "Capture is unfinished.")
        task.cancel()
    }
    if completes
    {
        let complete = try await task.value
        #expect(complete.incompleteReason == nil)
    }
    else
    {
        do
        {
            _ = try await task.value
            Issue.record("An interrupted capture was published as complete.")
        }
        catch is CancellationError
        {
            #expect(interruption == .cancelled)
        }
        catch EarthImportError.limitExceeded
        {
            #expect(reachesRequestLimit || interruption == .decodeLimit)
        }
    }
    continuation.finish()
    let recovered = try await EarthCaptureImporter().importFile(fileURL: rootFile)
    #expect(simd_distance(recovered.bounds.minimum, SIMD3(1, 0.5, -5)) < 0.001)
    #expect(recovered.sourceFiles.first { $0.relativePath.hasSuffix(".glb") }?.data == original)
    let manifest = try String(contentsOf: rootFile, encoding: .utf8)
    #expect(!manifest.contains("fixture-key") && !manifest.contains("fixture-session") && !manifest.contains("https://"))
    if completes { #expect(recovered.incompleteReason == nil) }
    else { #expect(recovered.incompleteReason != nil) }
    if interruption == .raisedRequestLimit
    {
        #expect(await loader.received().count == 513)
    }
    if reachesRequestLimit
    {
        #expect(await loader.received().count == requestBudget)
        #expect(recovered.incompleteReason?.contains("Source request count (\(requestBudget))") == true)
        let metadata = try #require((JSONSerialization.jsonObject(with: Data(manifest.utf8)) as? [String: Any])?["extras"] as? [String: Any])
        let marker = try #require(metadata["messEarthKitIncompleteCapture"] as? [String: Any])
        #expect(marker["maximumSourceRequests"] as? Int == requestBudget)
        let copy = try await EarthCaptureStore().save(capture: recovered, directoryURL: container.appendingPathComponent("exported"))
        let reopened = try await EarthCaptureImporter().importFile(fileURL: copy)
        #expect(reopened.incompleteReason == recovered.incompleteReason)
        var corrupted = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: copy)) as? [String: Any])
        corrupted["extras"] = ["messEarthKitIncompleteCapture": ["reason": 0]]
        try JSONSerialization.data(withJSONObject: corrupted).write(to: copy)
        do
        {
            _ = try await EarthCaptureImporter().importFile(fileURL: copy)
            Issue.record("Invalid partial metadata was silently treated as complete.")
        }
        catch EarthImportError.invalidContent {}
    }
}

@Test(arguments: [0, -1])
func nonpositiveRequestBudgetsAreRejected(maximumRequests: Int) throws
{
    let origin = try EarthGeographicOrigin(latitude: 0, longitude: 0)
    #expect(throws: EarthImportError.self)
    {
        try EarthCaptureRequest(center: origin, maximumSourceRequests: maximumRequests)
    }
}

@Test func recoveryNeverReplacesAnExistingDirectory() async throws
{
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("keep.txt")
    try Data("Keep existing work".utf8).write(to: file)
    let loader = CaptureResources(files: [:])
    let session = EarthCaptureSession(apiKey: "fixture-key", resourceLoader: { try await loader.load(url: $0, maximumBytes: $1) })
    let request = try EarthCaptureRequest(center: EarthGeographicOrigin(latitude: 0, longitude: 0))
    do
    {
        _ = try await session.capture(request: request, recoveryDirectoryURL: directory)
        Issue.record("Recovery replaced an existing folder.")
    }
    catch EarthImportError.inaccessibleSource {}
    #expect(await loader.received().isEmpty)
    #expect(try String(contentsOf: file, encoding: .utf8) == "Keep existing work")
}
