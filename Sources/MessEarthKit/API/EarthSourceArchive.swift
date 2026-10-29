import Foundation

/// Source selection only. Downloading has no aggregate request, tile, byte,
/// vertex or texture budget. Dimensions describe a conservative surface
/// footprint; source tiles intersecting its edges are retained whole.
public struct EarthDownloadRequest: Codable, Equatable, Sendable
{
    public let center: EarthGeographicOrigin
    public let widthMeters: Double
    public let depthMeters: Double
    public let maximumGeometricErrorMeters: Double

    public init(center: EarthGeographicOrigin, widthMeters: Double = 200, depthMeters: Double = 200, maximumGeometricErrorMeters: Double = 4) throws
    {
        guard widthMeters.isFinite, depthMeters.isFinite, maximumGeometricErrorMeters.isFinite,
              widthMeters > 0, widthMeters <= 2 * .pi * 6378137,
              depthMeters > 0, depthMeters <= .pi * 6378137,
              maximumGeometricErrorMeters > 0
        else { throw EarthImportError.invalidContent("Enter positive finite dimensions and resolution. Width must fit within one Earth circumference and depth within half a circumference.") }
        self.center = center
        self.widthMeters = widthMeters
        self.depthMeters = depthMeters
        self.maximumGeometricErrorMeters = maximumGeometricErrorMeters
    }

    private enum CodingKeys: String, CodingKey { case center, widthMeters, depthMeters, maximumGeometricErrorMeters }

    public init(from decoder: any Decoder) throws
    {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            center: values.decode(EarthGeographicOrigin.self, forKey: .center),
            widthMeters: values.decode(Double.self, forKey: .widthMeters),
            depthMeters: values.decode(Double.self, forKey: .depthMeters),
            maximumGeometricErrorMeters: values.decode(Double.self, forKey: .maximumGeometricErrorMeters)
        )
    }
}

/// A snapshot of a durable raw download, independent of mesh/image codecs.
/// The host owns directory access and retention. A completed archive is immutable.
public struct EarthSourceArchive: Sendable
{
    public enum State: String, Codable, Sendable { case downloading, paused, downloaded }

    public let directoryURL: URL
    public let request: EarthDownloadRequest
    public let state: State
    public let completedPayloadCount: Int
    /// Discovered placements; a lower bound until acquisition completes.
    public let selectedTileCount: Int
    /// Job attempts across resumes, separate from the clearable usage ledger.
    public let sourceRequests: Int
    /// Unique committed GLB bytes, excluding metadata/journal overhead.
    public let downloadedBytes: Int
    public let interruptionReason: String?
    public var rootSourceURL: URL? { state == .downloaded ? directoryURL.appendingPathComponent("tileset.json") : nil }

    /// Initializes a paused journal offline so a host can persist its project
    /// reference before any request. The destination must not exist. Begin its
    /// first transfer using EarthSourceAcquisition.download with resuming: true.
    public static func create(request: EarthDownloadRequest, directoryURL: URL) async throws -> Self
    {
        try Task.checkCancellation()
        return try EarthAcquisitionIndex(directoryURL: directoryURL, creating: request).snapshot()
    }

    /// Reads the journal without contacting the service or decoding any models.
    public static func open(directoryURL: URL) async throws -> Self
    {
        try EarthAcquisitionIndex(directoryURL: directoryURL, creating: nil, readOnly: true).snapshot()
    }

    /// Completed-manifest identity used by prepared collections. For recovery,
    /// use matchesSource to check original payload hashes too. Reads bounded
    /// file buffers only; no transport, payload decode or journal writes.
    public func sourceIdentifier() async throws -> String
    {
        try Task.checkCancellation()
        let index = try EarthAcquisitionIndex(directoryURL: directoryURL, creating: nil, readOnly: true)
        let current = try index.snapshot()
        guard state == .downloaded, current.state == .downloaded, current.request == request
        else { throw EarthAcquisitionError.invalidArchive }
        return try index.files.integrity(index.files.checked("tileset.json", regularFile: true)).hash
    }
}

public enum EarthAcquisitionError: Error, Equatable, LocalizedError, Sendable
{
    case storage
    case invalidArchive
    case archiveInUse
    case sourceChanged
    case metadataTooLarge

    public var errorDescription: String?
    {
        switch self
        {
            case .storage: "The download could not be stored. Check available disk space and folder access. Completed files are retained."
            case .invalidArchive: "This folder is not a valid source archive for this selection."
            case .archiveInUse: "This source archive is already in use by another download."
            case .sourceChanged: "The source hierarchy or version has changed. Completed files are retained; start a new download to avoid mixing source versions."
            case .metadataTooLarge: "Source metadata exceeds the bounded JSON parser's size or nesting support. Completed files are retained."
        }
    }
}
