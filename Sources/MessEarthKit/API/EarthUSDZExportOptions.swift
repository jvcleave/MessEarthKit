import Foundation

/// An explicit permission for a new optimized delivery; sources are immutable.
public struct EarthUSDZOptimizationProfile: Codable, Equatable, Sendable
{
    public let triangleFraction: Float
    public let maximumErrorMeters: Float
    public let maximumTextureDimension: Int?

    public init(triangleFraction: Float = 0.5, maximumErrorMeters: Float = 0.1, maximumTextureDimension: Int? = nil) throws
    {
        guard triangleFraction.isFinite, triangleFraction > 0, triangleFraction <= 1,
              maximumErrorMeters.isFinite, maximumErrorMeters >= 0,
              maximumTextureDimension == nil || (1 ... 16384).contains(maximumTextureDimension!)
        else { throw EarthUSDZExportError.invalidOptions }
        self.triangleFraction = triangleFraction
        self.maximumErrorMeters = maximumErrorMeters
        self.maximumTextureDimension = maximumTextureDimension
    }

    private enum CodingKeys: String, CodingKey { case triangleFraction, maximumErrorMeters, maximumTextureDimension }

    public init(from decoder: any Decoder) throws
    {
        let value = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(triangleFraction: value.decode(Float.self, forKey: .triangleFraction), maximumErrorMeters: value.decode(Float.self, forKey: .maximumErrorMeters), maximumTextureDimension: value.decodeIfPresent(Int.self, forKey: .maximumTextureDimension))
    }
}

public enum EarthUSDZExportError: Error, Equatable, LocalizedError, Sendable
{
    case invalidOptions, invalidDestination, sourceChanged, storage, optimization
    case unsupportedAppearance(String)
    case requirements([String])

    public var errorDescription: String?
    {
        switch self
        {
            case .invalidOptions: "Choose valid USDZ channel and optimization settings."
            case .invalidDestination: "Choose a new .usdz file outside the prepared collection. Existing files are retained."
            case .sourceChanged: "The prepared selection changed. Check the export again."
            case .storage: "The USDZ could not be written. Source models are retained."
            case .optimization: EarthMeshOptimizationError.failed.errorDescription
            case let .unsupportedAppearance(reason): "USDZ cannot preserve this appearance: " + reason
            case let .requirements(issues): "USDZ export requirements: " + issues.joined(separator: " ")
        }
    }
}

public struct EarthUSDZExportResult: Sendable
{
    public let fileURL: URL
    public let byteCount: Int
    public let sourceVertexCount: Int
    public let sourceTriangleCount: Int
    public let vertexCount: Int
    public let triangleCount: Int
    public let textureCount: Int
    public let maximumErrorMeters: Float
    public let optimization: EarthUSDZOptimizationProfile?
}
