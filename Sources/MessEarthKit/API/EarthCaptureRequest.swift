import Foundation

public struct EarthCaptureRequest: Sendable
{
    public let center: EarthGeographicOrigin
    public let widthMeters: Double
    public let depthMeters: Double
    public let maximumGeometricErrorMeters: Double
    /// Maximum uncached source requests, including JSON metadata and GLB payloads.
    public let maximumSourceRequests: Int
    /// Maximum selected GLB placements, including placements that reuse a download.
    public let maximumSelectedTiles: Int

    public init(
        center: EarthGeographicOrigin,
        widthMeters: Double = 200,
        depthMeters: Double = 200,
        maximumGeometricErrorMeters: Double = 4,
        maximumSourceRequests: Int = 512,
        maximumSelectedTiles: Int = 256
    ) throws
    {
        guard widthMeters.isFinite, depthMeters.isFinite, maximumGeometricErrorMeters.isFinite,
              (10 ... 5000).contains(widthMeters), (10 ... 5000).contains(depthMeters),
              (0.1 ... 1000).contains(maximumGeometricErrorMeters)
        else { throw EarthImportError.invalidContent("Region dimensions must be 10–5000 m and detail error 0.1–1000 m.") }
        guard maximumSourceRequests > 0
        else { throw EarthImportError.invalidContent("Maximum Requests must be a positive whole number.") }
        guard maximumSelectedTiles > 0
        else { throw EarthImportError.invalidContent("Maximum Tiles must be a positive whole number.") }
        self.center = center
        self.widthMeters = widthMeters
        self.depthMeters = depthMeters
        self.maximumGeometricErrorMeters = maximumGeometricErrorMeters
        self.maximumSourceRequests = maximumSourceRequests
        self.maximumSelectedTiles = maximumSelectedTiles
    }
}

public struct EarthCaptureProgress: Sendable
{
    public let sourceRequests: Int
    public let visitedTiles: Int
    public let downloadedTiles: Int
    public let downloadedBytes: Int
}

public enum EarthCaptureError: Error, LocalizedError, Sendable
{
    case missingAPIKey
    case alreadyCapturing
    case authenticationRejected
    case serviceRejected(reason: EarthServiceRejection, statusCode: Int)
    case requestFailed(Int?)
    case noCoverage
    case detailUnavailable

    public var errorDescription: String?
    {
        switch self
        {
            case .missingAPIKey: "Enter a Google Maps Tile API key."
            case .alreadyCapturing: "A capture is already running."
            case .authenticationRejected: "Google rejected the API key or this project's Map Tiles access."
            case let .serviceRejected(reason, code): "Google Map Tiles rejected the request (HTTP \(code)). \(reason.guidance)"
            case .requestFailed(429): "Google Map Tiles quota or rate limit reached (HTTP 429). Check the project's Map Tiles quotas in Google Cloud. Changing the region or detail will not reset the quota."
            case let .requestFailed(code): code.map { "Tile service request failed (HTTP \($0))." } ?? "The tile service could not be reached."
            case .noCoverage: "No 3D tile content covers this region."
            case .detailUnavailable: "The source does not provide the requested detail for part of this area. Increase the detail error or choose another area."
        }
    }
}

public enum EarthServiceRejection: Sendable
{
    case invalidKey, ipRestricted, apiRestricted, applicationRestricted, apiDisabled, billingDisabled, quotaExceeded, permissionDenied

    var guidance: String
    {
        switch self
        {
            case .invalidKey: "The API key is invalid, expired or missing. Enter the current key string."
            case .ipRestricted: "Google blocked this request because its public IP address is not allowed by the API key. In Google Cloud Console, open APIs & Services → Credentials → this key → Application restrictions → IP addresses. Add your current public outbound IPv4 and IPv6 addresses, then save and retry. Network or VPN changes and temporary IPv6 addresses can change the address Google sees."
            case .apiRestricted: "The key's API restrictions do not allow Map Tiles API (tile.googleapis.com)."
            case .applicationRestricted: "The key's application restriction does not allow this direct HTTPS macOS client. Check the key's allowed client restrictions."
            case .apiDisabled: "Enable Map Tiles API in the project associated with this key."
            case .billingDisabled: "The key's project needs an active linked billing account."
            case .quotaExceeded: "The project reached a service quota or request rate limit. Check Map Tiles quotas before retrying."
            case .permissionDenied: "Check the key, project billing, Map Tiles enablement and key restrictions, including both public IPv4 and IPv6 addresses."
        }
    }
}
