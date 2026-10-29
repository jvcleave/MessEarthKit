import Foundation
import simd

/// Serial, file-backed source acquisition. No mesh/image decoder or import
/// budget participates in download admission or completion.
public actor EarthSourceAcquisition
{
    typealias Downloader = @Sendable (URL, URL) async throws -> Int
    private let access: EarthSourceAccess
    private let transport: EarthRequestTransport
    private let downloader: Downloader
    private var isDownloading = false

    public init(apiKey: String, requestObserver: EarthRequestObserver? = nil)
    {
        access = EarthSourceAccess(apiKey: apiKey.trimmingCharacters(in: .whitespacesAndNewlines))
        let client = EarthGoogleTileClient()
        transport = EarthRequestTransport(observer: requestObserver, loader: { try await client.load(url: $0, maximumBytes: $1) })
        downloader = { try await client.download(url: $0, to: $1) }
    }

    init(apiKey: String, requestObserver: EarthRequestObserver? = nil, metadataLoader: @escaping EarthRequestTransport.Loader, downloader: @escaping Downloader)
    {
        access = EarthSourceAccess(apiKey: apiKey)
        transport = EarthRequestTransport(observer: requestObserver, loader: metadataLoader)
        self.downloader = downloader
    }

    /// A new job requires a new folder. Resume refreshes metadata from the root,
    /// then reuses completed files with matching source fingerprints and SHA-256.
    /// Incomplete files retry from byte zero; no HTTP range support is assumed.
    public func download(
        request: EarthDownloadRequest,
        directoryURL: URL,
        resuming: Bool = false,
        progress: @escaping @Sendable (EarthCaptureProgress) -> Void = { _ in }
    ) async throws -> EarthSourceArchive
    {
        guard !isDownloading else { throw EarthCaptureError.alreadyCapturing }
        try Task.checkCancellation()
        guard !access.apiKey.isEmpty else { throw EarthCaptureError.missingAPIKey }
        isDownloading = true
        defer { isDownloading = false }
        let index = try EarthAcquisitionIndex(directoryURL: directoryURL, creating: resuming ? nil : request)
        let lock = try EarthAcquisitionLock(files: index.files)
        defer { withExtendedLifetime(lock) {} }
        let previous = try index.snapshot()
        guard previous.request == request else { throw EarthAcquisitionError.invalidArchive }
        if previous.state == .downloaded { return previous }
        let run = try index.begin(request: request)
        var state = EarthAcquisitionTraversal(run: run, sourceRequests: previous.sourceRequests, downloadedTiles: previous.completedPayloadCount, downloadedBytes: previous.downloadedBytes)
        do
        {
            let root = try access.resourceURL(uri: "/v1/3dtiles/root.json", parent: URL(string: "https://tile.googleapis.com")!)
            try await visitMetadata(url: root, parentTransform: matrix_identity_double4x4, inheritedRefine: "REPLACE", depth: 0, selection: EarthRegionSelection(request: request), index: index, state: &state, progress: progress)
            guard state.selectedTiles > 0 else { throw EarthCaptureError.noCoverage }
            try Task.checkCancellation()
            try EarthSourceMetadata.publishManifest(index: index, request: request)
            try index.finish(state: .downloaded)
            let archive = try index.snapshot()
            progress(.init(sourceRequests: archive.sourceRequests, visitedTiles: state.visitedTiles, downloadedTiles: archive.completedPayloadCount, downloadedBytes: archive.downloadedBytes))
            return archive
        }
        catch
        {
            let reason: String
            if error is CancellationError { reason = "Download paused. Resume to continue with completed files." }
            else if let error = error as? EarthAcquisitionError { reason = error.localizedDescription }
            else if let error = error as? EarthCaptureError { reason = error.localizedDescription }
            else { reason = "Download interrupted. Completed source files are retained." }
            try? index.finish(state: .paused, issue: reason)
            throw error
        }
    }

    private func visitMetadata(url: URL, parentTransform: simd_double4x4, inheritedRefine: String, depth: Int, selection: EarthRegionSelection, index: EarthAcquisitionIndex, state: inout EarthAcquisitionTraversal, progress: @Sendable (EarthCaptureProgress) -> Void) async throws
    {
        let id = access.identity(url)
        guard depth < 64, state.activeMetadata.insert(id).inserted else { throw EarthImportError.invalidContent("Source tilesets contain a cycle or excessive nesting.") }
        defer { state.activeMetadata.remove(id) }
        try Task.checkCancellation()
        try index.requestStarted()
        state.sourceRequests += 1
        let data: Data
        do { data = try await transport.load(url: url, maximumBytes: EarthSourceMetadata.maximumBytes) }
        catch EarthImportError.limitExceeded { throw EarthAcquisitionError.metadataTooLarge }
        let tileset = try EarthSourceMetadata.decode(data)
        try index.registerMetadata(id: id, data: EarthSourceMetadata.sanitized(tileset, parent: url, access: access))
        try await visit(tile: tileset.root, parentTransform: parentTransform, inheritedRefine: inheritedRefine, parentURL: url, depth: depth, selection: selection, index: index, state: &state, progress: progress)
    }

    private func visit(tile: EarthTileset.Tile, parentTransform: simd_double4x4, inheritedRefine: String, parentURL: URL, depth: Int, selection: EarthRegionSelection, index: EarthAcquisitionIndex, state: inout EarthAcquisitionTraversal, progress: @Sendable (EarthCaptureProgress) -> Void) async throws
    {
        try Task.checkCancellation()
        guard depth < 64 else { throw EarthImportError.invalidContent("Source hierarchy exceeds supported structural nesting.") }
        state.visitedTiles += 1
        guard let selected = try EarthSourceTileSelection(tile: tile, parentTransform: parentTransform, inheritedRefine: inheritedRefine, selection: selection) else { return }
        if !selected.descend || selected.refine == "ADD"
        {
            for content in selected.contents
            {
                let url = try access.resourceURL(uri: content.uri, parent: parentURL)
                switch url.pathExtension.lowercased()
                {
                    case "json":
                        try await visitMetadata(url: url, parentTransform: selected.transform, inheritedRefine: selected.refine, depth: depth + 1, selection: selection, index: index, state: &state, progress: progress)
                    case "glb":
                        if selected.needsDetail, selected.children.isEmpty { throw EarthCaptureError.detailUnavailable }
                        let path = "tiles/\(access.identity(url)).glb"
                        let transform = selected.transform
                        let columns = [transform.columns.0, transform.columns.1, transform.columns.2, transform.columns.3]
                        let placement = EarthTileset.Tile(boundingVolume: tile.boundingVolume, geometricError: 0, transform: columns.flatMap { [$0.x, $0.y, $0.z, $0.w] }, refine: "REPLACE", content: .init(uri: path), contents: nil, children: nil, implicitTiling: nil)
                        try index.place(tile: placement, run: state.run, ordinal: state.selectedTiles)
                        state.selectedTiles += 1
                        try await acquirePayload(url: url, index: index, state: &state)
                        if state.lastProgress.duration(to: .now) >= .milliseconds(200)
                        {
                            progress(.init(sourceRequests: state.sourceRequests, visitedTiles: state.visitedTiles, downloadedTiles: state.downloadedTiles, downloadedBytes: state.downloadedBytes))
                            state.lastProgress = .now
                        }
                    default: throw EarthImportError.unsupportedContent("Source content must be a GLB or an explicit JSON tileset.")
                }
            }
        }
        if selected.descend
        {
            for child in selected.children
            { try await visit(tile: child, parentTransform: selected.transform, inheritedRefine: selected.refine, parentURL: parentURL, depth: depth + 1, selection: selection, index: index, state: &state, progress: progress) }
        }
    }

    private func acquirePayload(url: URL, index: EarthAcquisitionIndex, state: inout EarthAcquisitionTraversal) async throws
    {
        let id = access.identity(url)
        let path = "tiles/\(id).glb"
        let destination = try index.files.checked(path)
        if let saved = try index.payload(id), !saved.hash.isEmpty
        {
            if saved.completed, saved.validatedRun == state.run { return }
            if let values = try? destination.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]), values.isRegularFile == true, values.fileSize == saved.bytes
            {
                let actual = try index.files.integrity(destination)
                if actual.hash == saved.hash
                {
                    try index.complete(id, run: state.run)
                    if !saved.completed { state.downloadedTiles += 1; state.downloadedBytes += saved.bytes }
                    return
                }
            }
            if saved.completed { state.downloadedTiles -= 1; state.downloadedBytes -= saved.bytes }
        }
        try index.pending(id)
        let staging = try index.files.checked("staging/\(id).partial")
        do { if FileManager.default.fileExists(atPath: staging.path) { try FileManager.default.removeItem(at: staging) } }
        catch { throw EarthAcquisitionError.storage }
        try Task.checkCancellation()
        try index.requestStarted()
        state.sourceRequests += 1
        _ = try await transport.download(url: url, to: staging, using: downloader)
        try Task.checkCancellation()
        let integrity = try index.files.integrity(staging)
        guard integrity.bytes > 0 else { throw EarthImportError.invalidContent("Empty source payload.") }
        try index.files.validateGLB(staging, bytes: integrity.bytes)
        try index.stage(id, bytes: integrity.bytes, hash: integrity.hash)
        try index.files.publish(staging: staging, path: path)
        try index.complete(id, run: state.run)
        state.downloadedTiles += 1
        state.downloadedBytes += integrity.bytes
    }
}

private struct EarthAcquisitionTraversal
{
    let run: Int
    var sourceRequests: Int
    var downloadedTiles: Int
    var downloadedBytes: Int
    var visitedTiles = 0
    var selectedTiles = 0
    var activeMetadata: Set<String> = []
    var lastProgress = ContinuousClock.now
}
