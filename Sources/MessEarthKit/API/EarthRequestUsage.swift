import Foundation

public enum EarthRequestKind: String, Codable, Sendable
{
    case session, metadata, tile
}

public enum EarthRequestOutcome: String, Codable, Sendable
{
    case succeeded, failed, cancelled
}

/// Local attempted-request telemetry, not server delivery or billing. Events
/// deliberately contain no URLs, keys, session tokens, or response bodies.
public enum EarthRequestEvent: Sendable
{
    case started(id: UUID, kind: EarthRequestKind, at: Date)
    case finished(id: UUID, outcome: EarthRequestOutcome, at: Date, statusCode: Int?, receivedBytes: Int?)
}

public typealias EarthRequestObserver = @Sendable (EarthRequestEvent) async -> Void

public struct EarthRequestUsageSnapshot: Sendable
{
    public let asOf: Date
    public let trackingStartedAt: Date?
    public let lastClearedAt: Date?
    public let totalRequests: Int?
    public let sessionRequests: Int?
    public let metadataRequests: Int?
    public let tileRequests: Int?
    public let succeededRequests: Int?
    public let failedRequests: Int?
    public let cancelledRequests: Int?
    public let pendingRequests: Int?
    public let nextExpiration: Date?
    public let trackingIssue: String?

    public static func unavailable(at date: Date) -> Self
    {
        Self(
            asOf: date,
            trackingStartedAt: nil,
            lastClearedAt: nil,
            totalRequests: nil,
            sessionRequests: nil,
            metadataRequests: nil,
            tileRequests: nil,
            succeededRequests: nil,
            failedRequests: nil,
            cancelledRequests: nil,
            pendingRequests: nil,
            nextExpiration: nil,
            trackingIssue: "Local request history is unavailable. Tracking is incomplete."
        )
    }
}
