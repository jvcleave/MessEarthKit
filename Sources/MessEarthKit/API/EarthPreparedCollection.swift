import Foundation

/// File references and small estimates only; no decoded geometry or GLB Data.
public struct EarthPreparedModel: Sendable, Identifiable
{
    public let id: Int
    public var name: String { "Model \(id)" }
    public let tileCount: Int
    public let estimate: EarthCaptureGeometryEstimate
    public let sourceByteCount: Int
    public let rootSourceURL: URL
}

/// All-model selection stays constant-sized for large catalogs. Explicit
/// exceptions/subsets contain only user-selected IDs, never an implicit ID array.
public enum EarthModelSelection: Sendable
{
    case all(excluding: Set<Int> = [])
    case only(Set<Int>)

    public func includes(_ id: Int) -> Bool
    {
        switch self
        {
            case let .all(excluding): !excluding.contains(id)
            case let .only(ids): ids.contains(id)
        }
    }

    public func count(modelCount: Int) throws -> Int
    {
        let ids: Set<Int>
        let count: Int
        switch self
        {
            case let .all(excluding): ids = excluding; count = modelCount - excluding.count
            case let .only(selected): ids = selected; count = selected.count
        }
        // Exported subsets retain original (possibly sparse) model IDs. The
        // catalog validates membership; this helper only computes the count.
        guard modelCount >= 0, count >= 0, count <= modelCount, ids.allSatisfy({ $0 > 0 }) else { throw EarthPreparationError.invalidCollection }
        return count
    }
}

/// A durable paged model catalog. A ready collection covers the entire raw
/// archive; a partial catalog contains only independently committed models.
public struct EarthPreparedCollection: Sendable
{
    public enum State: String, Sendable { case preparing, partial, ready }
    public let directoryURL: URL
    public let profile: EarthPreparationProfile
    public let geographicOrigin: EarthGeographicOrigin
    public let sourceIdentifier: String
    public let state: State
    public let modelCount: Int
    public let coversEntireSource: Bool
    public let interruptionReason: String?
    public var rootSourceURL: URL? { state == .ready ? directoryURL.appendingPathComponent("tileset.json") : nil }

    public static func open(directoryURL: URL) async throws -> Self
    { try EarthPreparationIndex(directoryURL: directoryURL).snapshot() }

    /// Recovery matching checks original payload hashes as well as manifest
    /// identity. Two downloads can share tile URIs/placements while the service
    /// supplies different bytes. No payload decoding or network access occurs.
    public func matchesSource(_ archive: EarthSourceArchive) async throws -> Bool
    {
        try Task.checkCancellation()
        let source = try EarthAcquisitionIndex(directoryURL: archive.directoryURL, creating: nil, readOnly: true)
        let current = try source.snapshot()
        guard archive.state == .downloaded, current.state == .downloaded, current.selectedTileCount > 0, current.request == archive.request,
              current.request.center == geographicOrigin,
              try source.files.integrity(source.files.checked("tileset.json", regularFile: true)).hash == sourceIdentifier
        else { return false }
        let prepared = try EarthPreparationIndex(directoryURL: directoryURL)
        guard try prepared.snapshot().sourceIdentifier == sourceIdentifier else { return false }
        var matches = true
        try source.forEachPlacement
        { data in
            try Task.checkCancellation()
            guard matches else { return }
            guard let tile = try? JSONDecoder().decode(EarthTileset.Tile.self, from: data),
                  let uri = tile.content?.uri, uri.hasPrefix("tiles/"), uri.hasSuffix(".glb") else { matches = false; return }
            let id = String(uri.dropFirst(6).dropLast(4))
            guard let original = try source.payload(id), original.completed,
                  let recorded = try prepared.asset(id: id),
                  original.hash == recorded.hash, original.bytes == recorded.bytes else { matches = false; return }
        }
        return matches
    }

    /// A page is limited to 256 items; there is no total model-count ceiling.
    public func models(offset: Int = 0, limit: Int = 50) async throws -> [EarthPreparedModel]
    {
        guard offset >= 0, (1 ... 256).contains(limit) else { throw EarthPreparationError.invalidCollection }
        return try EarthPreparationIndex(directoryURL: directoryURL).models(offset: offset, limit: limit)
    }

    public func importModel(id: Int) async throws -> EarthCapture
    {
        let index = try EarthPreparationIndex(directoryURL: directoryURL)
        let snapshot = try index.snapshot()
        guard snapshot.profile == profile, snapshot.sourceIdentifier == sourceIdentifier else { throw EarthPreparationError.invalidCollection }
        let model = try index.model(id: id)
        let capture = try await EarthCaptureImporter(limits: profile.importLimits).importFile(fileURL: model.rootSourceURL)
        guard capture.triangleCount <= profile.maximumIndicesPerModel / 3 else { throw EarthPreparationError.invalidCollection }
        return capture
    }
}
