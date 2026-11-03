import Foundation

/// Explicit geometry reduction in local meters. Delivery codecs remain standard.
public struct EarthMeshOptimizationProfile: Codable, Equatable, Sendable
{
    public let triangleFraction: Float
    public let maximumErrorMeters: Float

    public init(triangleFraction: Float = 0.5, maximumErrorMeters: Float = 0.1) throws
    {
        guard triangleFraction.isFinite, triangleFraction > 0, triangleFraction <= 1,
              maximumErrorMeters.isFinite, maximumErrorMeters >= 0
        else { throw EarthMeshOptimizationError.invalidProfile }
        self.triangleFraction = triangleFraction
        self.maximumErrorMeters = maximumErrorMeters
    }

    private enum CodingKeys: String, CodingKey { case triangleFraction, maximumErrorMeters }

    public init(from decoder: any Decoder) throws
    {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(triangleFraction: values.decode(Float.self, forKey: .triangleFraction), maximumErrorMeters: values.decode(Float.self, forKey: .maximumErrorMeters))
    }
}

/// Recorded source/output counts, distinct from the requested target fraction.
public struct EarthMeshOptimizationResult: Codable, Equatable, Sendable
{
    public let profile: EarthMeshOptimizationProfile
    public let sourceVertexCount: Int
    public let sourceTriangleCount: Int
    public let vertexCount: Int
    public let triangleCount: Int
    public let maximumErrorMeters: Float

    func validate() throws
    {
        guard sourceVertexCount > 0, sourceTriangleCount > 0,
              vertexCount > 0, vertexCount <= sourceVertexCount,
              triangleCount > 0, triangleCount <= sourceTriangleCount,
              maximumErrorMeters.isFinite, maximumErrorMeters >= 0,
              maximumErrorMeters <= profile.maximumErrorMeters + 0.000001
        else { throw EarthMeshOptimizationError.failed }
    }
}

public enum EarthMeshOptimizationError: Error, Equatable, LocalizedError, Sendable
{
    case invalidProfile, failed

    public var errorDescription: String?
    { "The geometry optimization could not preserve the requested constraints." }
}
