import Foundation
import simd

public actor EarthCaptureSession
{
    typealias ResourceLoader = @Sendable (URL, Int) async throws -> Data
    private let apiKey: String
    private let limits: EarthImportLimits
    private let loadResource: ResourceLoader
    private var isCapturing = false
    public private(set) var lastObservation: EarthCaptureObservation?

    public init(apiKey: String, limits: EarthImportLimits = EarthImportLimits(), requestObserver: EarthRequestObserver? = nil)
    {
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.limits = limits
        let client = EarthGoogleTileClient()
        let transport = EarthRequestTransport(observer: requestObserver, loader: { url, maximumBytes in try await client.load(url: url, maximumBytes: maximumBytes) })
        loadResource = { url, maximumBytes in try await transport.load(url: url, maximumBytes: maximumBytes) }
    }

    init(apiKey: String, limits: EarthImportLimits = EarthImportLimits(), requestObserver: EarthRequestObserver? = nil, resourceLoader: @escaping ResourceLoader)
    {
        self.apiKey = apiKey
        self.limits = limits
        let transport = EarthRequestTransport(observer: requestObserver, loader: resourceLoader)
        loadResource = { url, maximumBytes in try await transport.load(url: url, maximumBytes: maximumBytes) }
    }

    /// One explicit capture per session, with bounded serial requests. An active
    /// job finishes, fails, or cancels; a second job cannot change its request.
    /// An optional new recovery directory retains each completed tile before
    /// proceeding. Interrupted traversal leaves a marked partial manifest.
    /// Once traversal finishes, later decoding errors still throw but leave
    /// complete source coverage for offline preparation with revised budgets.
    /// The caller owns directory authorization and retention.
    public func capture(
        request: EarthCaptureRequest,
        recoveryDirectoryURL: URL? = nil,
        progress: @escaping @Sendable (EarthCaptureProgress) -> Void = { _ in }
    ) async throws -> EarthCapture
    {
        try beginSourceJob()
        defer { isCapturing = false }
        let writer = try recoveryDirectoryURL.map { try EarthCaptureRecoveryWriter(directoryURL: $0) }
        var state = EarthCaptureTraversal(maximumSourceRequests: request.maximumSourceRequests, recoveryWriter: writer)
        var sourceDownloadIsComplete = false
        do
        {
            let root = try resourceURL(uri: "/v1/3dtiles/root.json", parent: URL(string: "https://tile.googleapis.com")!)
            let data = try await load(url: root, state: &state, progress: progress)
            let tileset = try decodeTileset(data: data)
            state.activeTilesets.insert(root)
            try await visit(tile: tileset.root, parentTransform: matrix_identity_double4x4, inheritedRefine: "REPLACE", parentURL: root, depth: 0, request: request, selection: EarthRegionSelection(request: request), state: &state, progress: progress)
            guard !state.selectedTiles.isEmpty else { throw EarthCaptureError.noCoverage }
            try Task.checkCancellation()
            let manifest = try EarthCaptureManifest.encode(request: request, limits: limits, tiles: state.selectedTiles, incompleteReason: nil, downloadedTiles: state.files.count, sourceRequests: state.requestCount)
            let files = [EarthSourceFile(relativePath: "tileset.json", data: manifest)] + state.files
            try checkpoint(request: request, state: state, incompleteReason: nil)
            sourceDownloadIsComplete = true
            let capture = try await EarthCaptureImporter(limits: limits).importSourceFiles(sourceFiles: files, rootSourcePath: "tileset.json")
            try Task.checkCancellation()
            progress(.init(sourceRequests: state.requestCount, visitedTiles: state.visitedTiles, downloadedTiles: state.files.count, downloadedBytes: state.downloadedBytes))
            lastObservation = EarthCaptureObservation(request: request, capture: capture, selectedTiles: state.selectedTiles.count, sourceRequests: state.requestCount, sourceBytes: state.downloadedBytes)
            return capture
        }
        catch
        {
            // Preview decoding cannot change already committed source coverage.
            // Traversal failure/cancellation still retains its partial checkpoint.
            if !sourceDownloadIsComplete
            { try? checkpoint(request: request, state: state, incompleteReason: interruptionReason(error: error)) }
            throw error
        }
    }

    /// First discovers selection using JSON only. When the planned request/tile
    /// budgets fit, reads GLBs to estimate geometry without decoding meshes.
    /// Completed sanitized sources can be imported with a revised vertex budget.
    public func precheck(
        request: EarthCaptureRequest,
        recoveryDirectoryURL: URL? = nil,
        progress: @escaping @Sendable (EarthCaptureProgress) -> Void = { _ in }
    ) async throws -> EarthCapturePrecheck
    {
        try beginSourceJob()
        defer { isCapturing = false }
        var state = EarthCaptureTraversal(maximumSourceRequests: request.maximumSourceRequests, recoveryWriter: nil, isPrechecking: true)
        do
        {
            let root = try resourceURL(uri: "/v1/3dtiles/root.json", parent: URL(string: "https://tile.googleapis.com")!)
            let data = try await load(url: root, state: &state, progress: progress)
            let tileset = try decodeTileset(data: data)
            state.activeTilesets.insert(root)
            try await visit(tile: tileset.root, parentTransform: matrix_identity_double4x4, inheritedRefine: "REPLACE", parentURL: root, depth: 0, request: request, selection: EarthRegionSelection(request: request), state: &state, progress: progress)
        }
        catch let error as EarthImportError
        {
            guard case .limitExceeded = error else { throw error }
            return precheckResult(request: request, state: state, metadataRequests: state.requestCount, selectionIsComplete: false, interruption: error.localizedDescription)
        }
        try Task.checkCancellation()
        guard !state.plannedTiles.isEmpty else { throw EarthCaptureError.noCoverage }
        let metadataRequests = state.requestCount
        let uniquePayloads = Set(state.plannedTiles.map(\.url)).count
        guard state.plannedTiles.count <= request.maximumSelectedTiles,
              metadataRequests + uniquePayloads <= request.maximumSourceRequests
        else { return precheckResult(request: request, state: state, metadataRequests: metadataRequests, selectionIsComplete: true) }

        state.recoveryWriter = try recoveryDirectoryURL.map { try EarthCaptureRecoveryWriter(directoryURL: $0) }
        var estimates: [URL: EarthCaptureGeometryEstimate] = [:]
        var geometry = try EarthCaptureGeometryEstimate()
        do
        {
            for planned in state.plannedTiles
            {
                try Task.checkCancellation()
                let data = try await selectPayload(url: planned.url, bounds: planned.bounds, transform: planned.transform, request: request, state: &state, progress: progress)
                let estimate: EarthCaptureGeometryEstimate
                if let cached = estimates[planned.url] { estimate = cached }
                else
                {
                    estimate = try EarthGLBEstimate(limits: limits).estimate(data: data)
                    estimates[planned.url] = estimate
                }
                geometry = try geometry.adding(estimate)
            }
            try Task.checkCancellation()
            let manifest = try EarthCaptureManifest.encode(request: request, limits: limits, tiles: state.selectedTiles, incompleteReason: nil, downloadedTiles: state.files.count, sourceRequests: state.requestCount)
            try checkpoint(request: request, state: state, incompleteReason: nil)
            let result = precheckResult(request: request, state: state, metadataRequests: metadataRequests, selectionIsComplete: true, geometry: geometry, sourceFiles: [EarthSourceFile(relativePath: "tileset.json", data: manifest)] + state.files)
            lastObservation = EarthCaptureObservation(precheck: result)
            return result
        }
        catch
        {
            try? checkpoint(request: request, state: state, incompleteReason: interruptionReason(error: error))
            throw error
        }
    }

    private func precheckResult(request: EarthCaptureRequest, state: EarthCaptureTraversal, metadataRequests: Int, selectionIsComplete: Bool, geometry: EarthCaptureGeometryEstimate? = nil, sourceFiles: [EarthSourceFile] = [], interruption: String? = nil) -> EarthCapturePrecheck
    {
        EarthCapturePrecheck(
            request: request,
            selectionIsComplete: selectionIsComplete,
            selectedTileCount: state.plannedTiles.count,
            metadataRequests: metadataRequests,
            uniquePayloadCount: Set(state.plannedTiles.map(\.url)).count,
            performedSourceRequests: state.requestCount,
            downloadedBytes: state.downloadedBytes,
            geometry: geometry,
            interruptionReason: interruption,
            sourceFiles: sourceFiles
        )
    }

    private func beginSourceJob() throws
    {
        guard !isCapturing else { throw EarthCaptureError.alreadyCapturing }
        guard !apiKey.isEmpty else { throw EarthCaptureError.missingAPIKey }
        guard limits.maximumSourceBytes > 0, limits.maximumNodes > 0, limits.maximumNodes <= 1000000,
              limits.maximumVertices > 0, limits.maximumVertices <= Int(UInt32.max) / 3,
              limits.maximumTextureDimension > 0, limits.maximumDecodedTextureBytes > 0
        else { throw EarthImportError.invalidContent("Capture limits must be positive and bounded.") }
        try Task.checkCancellation()
        lastObservation = nil
        isCapturing = true
    }

    private func visit(
        tile: EarthTileset.Tile,
        parentTransform: simd_double4x4,
        inheritedRefine: String,
        parentURL: URL,
        depth: Int,
        request: EarthCaptureRequest,
        selection: EarthRegionSelection,
        state: inout EarthCaptureTraversal,
        progress: @escaping @Sendable (EarthCaptureProgress) -> Void
    ) async throws
    {
        try Task.checkCancellation()
        state.visitedTiles += 1
        guard depth < 64, state.visitedTiles <= limits.maximumNodes
        else { throw EarthImportError.limitExceeded("Capture traversal nodes/depth.") }
        guard let selected = try EarthSourceTileSelection(tile: tile, parentTransform: parentTransform, inheritedRefine: inheritedRefine, selection: selection) else { return }
        let transform = selected.transform
        let refine = selected.refine
        let contents = selected.contents
        let children = selected.children
        let needsDetail = selected.needsDetail
        let descend = selected.descend
        if !descend || refine == "ADD"
        {
            for content in contents
            {
                let url = try resourceURL(uri: content.uri, parent: parentURL)
                switch url.pathExtension.lowercased()
                {
                    case "json":
                        guard state.activeTilesets.insert(url).inserted else { throw EarthImportError.invalidContent("Source tilesets form a cycle.") }
                        defer { state.activeTilesets.remove(url) }
                        let data = try await load(url: url, state: &state, progress: progress)
                        let external = try decodeTileset(data: data)
                        try await visit(tile: external.root, parentTransform: transform, inheritedRefine: refine, parentURL: url, depth: depth + 1, request: request, selection: selection, state: &state, progress: progress)
                    case "glb":
                        if needsDetail, children.isEmpty { throw EarthCaptureError.detailUnavailable }
                        if state.isPrechecking
                        {
                            guard state.plannedTiles.count < limits.maximumNodes else { throw EarthImportError.limitExceeded("Precheck selected-placement analysis count.") }
                            state.plannedTiles.append(EarthPlannedTile(url: url, bounds: tile.boundingVolume, transform: transform))
                            continue
                        }
                        guard state.selectedTiles.count < request.maximumSelectedTiles
                        else { throw EarthImportError.limitExceeded("Selected tile count (\(request.maximumSelectedTiles)). Increase Maximum Tiles, increase the detail error, or reduce the area.") }
                        _ = try await selectPayload(url: url, bounds: tile.boundingVolume, transform: transform, request: request, state: &state, progress: progress)
                    default: throw EarthImportError.unsupportedContent("Source content must be a GLB or an explicit JSON tileset.")
                }
            }
        }
        if descend
        {
            for child in children
            {
                try await visit(tile: child, parentTransform: transform, inheritedRefine: refine, parentURL: parentURL, depth: depth + 1, request: request, selection: selection, state: &state, progress: progress)
            }
        }
    }

    /// Capture and precheck commit the same source bytes and placement metadata
    /// before proceeding to any inspection/decoding that could fail.
    private func selectPayload(url: URL, bounds: EarthTileset.BoundingVolume, transform: simd_double4x4, request: EarthCaptureRequest, state: inout EarthCaptureTraversal, progress: @Sendable (EarthCaptureProgress) -> Void) async throws -> Data
    {
        let data = try await load(url: url, state: &state, progress: progress)
        let path: String
        if let existing = state.localPaths[url] { path = existing }
        else
        {
            path = "tiles/tile-\(state.files.count).glb"
            state.localPaths[url] = path
            state.files.append(EarthSourceFile(relativePath: path, data: data))
        }
        let columns = [transform.columns.0, transform.columns.1, transform.columns.2, transform.columns.3]
        state.selectedTiles.append(.init(boundingVolume: bounds, geometricError: 0, transform: columns.flatMap { [$0.x, $0.y, $0.z, $0.w] }, refine: "REPLACE", content: .init(uri: path), contents: nil, children: nil, implicitTiling: nil))
        try checkpoint(request: request, state: state, incompleteReason: state.isPrechecking ? "Precheck is unfinished." : "Capture is unfinished.")
        progress(.init(sourceRequests: state.requestCount, visitedTiles: state.visitedTiles, downloadedTiles: state.files.count, downloadedBytes: state.downloadedBytes))
        return data
    }

    private func load(
        url: URL,
        state: inout EarthCaptureTraversal,
        progress: @Sendable (EarthCaptureProgress) -> Void
    ) async throws -> Data
    {
        try Task.checkCancellation()
        if let cached = state.resources[url] { return cached }
        guard state.requestCount < state.maximumSourceRequests
        else { throw EarthImportError.limitExceeded("Source request count (\(state.maximumSourceRequests)). Increase Maximum Requests or reduce the capture area.") }
        let remaining = min(16 * 1024 * 1024, limits.maximumSourceBytes - state.downloadedBytes)
        guard remaining > 0 else { throw EarthImportError.limitExceeded("Capture download bytes.") }
        state.requestCount += 1
        let data: Data
        do { data = try await loadResource(url, remaining) }
        catch is CancellationError { throw CancellationError() }
        catch let error as EarthCaptureError { throw error }
        catch let error as EarthImportError { throw error }
        catch { throw EarthCaptureError.requestFailed(nil) }
        try Task.checkCancellation()
        guard !data.isEmpty, data.count <= remaining else { throw EarthImportError.limitExceeded("Source response bytes.") }
        state.downloadedBytes += data.count
        state.resources[url] = data
        progress(.init(sourceRequests: state.requestCount, visitedTiles: state.visitedTiles, downloadedTiles: state.files.count, downloadedBytes: state.downloadedBytes))
        return data
    }

    private func checkpoint(request: EarthCaptureRequest, state: EarthCaptureTraversal, incompleteReason: String?) throws
    {
        guard let writer = state.recoveryWriter, !state.selectedTiles.isEmpty else { return }
        let manifest = try EarthCaptureManifest.encode(request: request, limits: limits, tiles: state.selectedTiles, incompleteReason: incompleteReason, downloadedTiles: state.files.count, sourceRequests: state.requestCount)
        try writer.write(manifest: manifest, files: state.files)
    }

    private func interruptionReason(error: any Error) -> String
    {
        if error is CancellationError { return "Capture cancelled." }
        if let error = error as? EarthCaptureError { return error.localizedDescription }
        if let error = error as? EarthImportError { return error.localizedDescription }
        return "Capture interrupted."
    }

    private func resourceURL(uri: String, parent: URL) throws -> URL
    {
        try EarthSourceAccess(apiKey: apiKey).resourceURL(uri: uri, parent: parent)
    }

    private func decodeTileset(data: Data) throws -> EarthTileset
    {
        let tileset: EarthTileset
        do { tileset = try JSONDecoder().decode(EarthTileset.self, from: data) }
        catch { throw EarthImportError.invalidContent("The source tileset JSON is invalid.") }
        try tileset.validateSupportedContent()
        return tileset
    }
}

private struct EarthCaptureTraversal
{
    let maximumSourceRequests: Int
    var recoveryWriter: EarthCaptureRecoveryWriter?
    var isPrechecking = false
    var plannedTiles: [EarthPlannedTile] = []
    var visitedTiles = 0
    var downloadedBytes = 0
    var requestCount = 0
    var resources: [URL: Data] = [:]
    var localPaths: [URL: String] = [:]
    var activeTilesets: Set<URL> = []
    var files: [EarthSourceFile] = []
    var selectedTiles: [EarthTileset.Tile] = []
}

private struct EarthPlannedTile
{
    let url: URL
    let bounds: EarthTileset.BoundingVolume
    let transform: simd_double4x4
}
