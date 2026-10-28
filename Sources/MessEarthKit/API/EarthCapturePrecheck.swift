import Foundation

/// Declared geometry and base-level RGBA storage, before native mesh decoding.
/// These are estimates, not validation of the payload or peak process/GPU memory.
public struct EarthCaptureGeometryEstimate: Sendable
{
    public let vertexCount: Int
    public let indexCount: Int
    public let geometryBufferBytes: Int
    public let decodedTextureBytes: Int
    public let largestTextureDimension: Int

    init(vertices: Int = 0, indices: Int = 0, textureBytes: Int = 0, textureDimension: Int = 0) throws
    {
        vertexCount = vertices
        indexCount = indices
        geometryBufferBytes = try Self.sum(Self.product(vertices, MemoryLayout<EarthVertex>.stride), Self.product(indices, MemoryLayout<UInt32>.stride))
        decodedTextureBytes = textureBytes
        largestTextureDimension = textureDimension
    }

    func adding(_ other: Self) throws -> Self
    {
        try Self(vertices: Self.sum(vertexCount, other.vertexCount), indices: Self.sum(indexCount, other.indexCount), textureBytes: Self.sum(decodedTextureBytes, other.decodedTextureBytes), textureDimension: max(largestTextureDimension, other.largestTextureDimension))
    }

    static func sum(_ first: Int, _ second: Int) throws -> Int
    {
        let value = first.addingReportingOverflow(second)
        guard !value.overflow, value.partialValue >= 0 else { throw EarthImportError.limitExceeded("Precheck count arithmetic.") }
        return value.partialValue
    }

    static func product(_ first: Int, _ second: Int) throws -> Int
    {
        let value = first.multipliedReportingOverflow(by: second)
        guard !value.overflow, value.partialValue >= 0 else { throw EarthImportError.limitExceeded("Precheck size arithmetic.") }
        return value.partialValue
    }
}

/// A sanitized, immutable precheck. Counts are lower bounds when selection is
/// incomplete. Reusable sources contain no service URLs, keys, or session tokens.
public struct EarthCapturePrecheck: Sendable
{
    public let request: EarthCaptureRequest
    public let selectionIsComplete: Bool
    public let selectedTileCount: Int
    public let metadataRequests: Int
    public let uniquePayloadCount: Int
    public let performedSourceRequests: Int
    public let downloadedBytes: Int
    public let geometry: EarthCaptureGeometryEstimate?
    public let interruptionReason: String?
    let sourceFiles: [EarthSourceFile]

    public var plannedSourceRequests: Int { metadataRequests + uniquePayloadCount }
    public var hasReusableSources: Bool { !sourceFiles.isEmpty }

    /// Budget changes can reuse a complete source snapshot; changing selection
    /// needs a new precheck. Import limits are always revalidated by the importer.
    public func matchesSelection(_ other: EarthCaptureRequest) -> Bool
    {
        request.center.latitude == other.center.latitude && request.center.longitude == other.center.longitude
            && request.center.ellipsoidHeight == other.center.ellipsoidHeight
            && request.widthMeters == other.widthMeters && request.depthMeters == other.depthMeters
            && request.maximumGeometricErrorMeters == other.maximumGeometricErrorMeters
    }
}
