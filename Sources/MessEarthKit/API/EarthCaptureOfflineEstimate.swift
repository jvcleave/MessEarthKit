import Foundation
import simd

/// Small local calibration record. No keys, service URLs, or payloads.
public struct EarthCaptureObservation: Codable, Sendable
{
    public let latitude: Double
    public let longitude: Double
    public let ellipsoidHeight: Double
    public let widthMeters: Double
    public let depthMeters: Double
    public let detailErrorMeters: Double
    public let selectedTiles: Int
    public let sourceRequests: Int
    public let sourceBytes: Int
    public let vertices: Int
    public let geometryBytes: Int
    public let textureBytes: Int
    public let isDecoded: Bool
    public let recordedAt: Date

    public init?(precheck: EarthCapturePrecheck, recordedAt: Date = Date())
    {
        guard precheck.selectionIsComplete, precheck.hasReusableSources, let geometry = precheck.geometry else { return nil }
        self.init(request: precheck.request, tiles: precheck.selectedTileCount, requests: precheck.performedSourceRequests, bytes: precheck.downloadedBytes, geometry: geometry, isDecoded: false, recordedAt: recordedAt)
    }

    public init?(request: EarthCaptureRequest, capture: EarthCapture, selectedTiles: Int, sourceRequests: Int, sourceBytes: Int, recordedAt: Date = Date())
    {
        guard capture.incompleteReason == nil else { return nil }
        var textureBytes = 0
        for material in capture.materials
        {
            guard let texture = material.baseColorTexture else { continue }
            guard let bytes = try? EarthCaptureGeometryEstimate.product(EarthCaptureGeometryEstimate.product(texture.width, texture.height), 4),
                  let total = try? EarthCaptureGeometryEstimate.sum(textureBytes, bytes) else { return nil }
            textureBytes = total
        }
        guard let geometry = try? EarthCaptureGeometryEstimate(vertices: capture.vertexCount, indices: capture.triangleCount * 3, textureBytes: textureBytes) else { return nil }
        self.init(request: request, tiles: selectedTiles, requests: sourceRequests, bytes: sourceBytes, geometry: geometry, isDecoded: true, recordedAt: recordedAt)
    }

    private init?(request: EarthCaptureRequest, tiles: Int, requests: Int, bytes: Int, geometry: EarthCaptureGeometryEstimate, isDecoded: Bool, recordedAt: Date)
    {
        latitude = request.center.latitude
        longitude = request.center.longitude
        ellipsoidHeight = request.center.ellipsoidHeight
        widthMeters = request.widthMeters
        depthMeters = request.depthMeters
        detailErrorMeters = request.maximumGeometricErrorMeters
        selectedTiles = tiles
        sourceRequests = requests
        sourceBytes = bytes
        vertices = geometry.vertexCount
        geometryBytes = geometry.geometryBufferBytes
        textureBytes = geometry.decodedTextureBytes
        self.isDecoded = isDecoded
        self.recordedAt = recordedAt
        guard isUsable else { return nil }
    }

    public var isUsable: Bool
    {
        [latitude, longitude, ellipsoidHeight, widthMeters, depthMeters, detailErrorMeters, recordedAt.timeIntervalSince1970].allSatisfy(\.isFinite)
            && (-90 ... 90).contains(latitude) && (-180 ... 180).contains(longitude)
            && (10 ... 5000).contains(widthMeters) && (10 ... 5000).contains(depthMeters)
            && (0.1 ... 1000).contains(detailErrorMeters)
            && selectedTiles > 0 && sourceRequests > 0 && sourceBytes > 0 && vertices > 0 && geometryBytes > 0 && textureBytes >= 0
    }

    public func matchesSelection(_ other: Self) -> Bool
    {
        latitude == other.latitude && longitude == other.longitude && ellipsoidHeight == other.ellipsoidHeight
            && widthMeters == other.widthMeters && depthMeters == other.depthMeters && detailErrorMeters == other.detailErrorMeters
    }
}

/// A zero-network heuristic, never a capture eligibility decision. The first 64
/// observations are considered; only the same detail and centers within 2 km
/// qualify. Area-scaled measurements receive broad 0.5x–2x headroom. These ranges
/// are not statistically calibrated and do not bound future service content.
public struct EarthCaptureOfflineEstimate: Sendable
{
    public let sampleCount: Int
    public let selectedTiles: ClosedRange<Int>?
    public let sourceRequests: ClosedRange<Int>?
    public let sourceBytes: ClosedRange<Int>?
    public let vertices: ClosedRange<Int>?
    public let geometryBytes: ClosedRange<Int>?
    public let textureBytes: ClosedRange<Int>?

    public init(request: EarthCaptureRequest, observations: [EarthCaptureObservation])
    {
        let targetPosition = simd_inverse(request.center.earthCenteredToLocal).columns.3
        let references = observations.prefix(64).compactMap
        { sample -> (sample: EarthCaptureObservation, scale: Double)? in
            guard sample.isUsable, sample.detailErrorMeters == request.maximumGeometricErrorMeters,
                  let origin = try? EarthGeographicOrigin(latitude: sample.latitude, longitude: sample.longitude, ellipsoidHeight: sample.ellipsoidHeight),
                  simd_distance(targetPosition, simd_inverse(origin.earthCenteredToLocal).columns.3) <= 2000
            else { return nil }
            return (sample, request.widthMeters * request.depthMeters / (sample.widthMeters * sample.depthMeters))
        }
        sampleCount = references.count
        func range(_ value: (EarthCaptureObservation) -> Int, overhead: Int = 0) -> ClosedRange<Int>?
        {
            let values = references.map { Double(max(0, value($0.sample) - overhead)) * $0.scale }
            guard let minimum = values.min(), let maximum = values.max() else { return nil }
            let low = floor(minimum * 0.5) + Double(overhead)
            let high = ceil(maximum * 2) + Double(overhead)
            guard low.isFinite, high.isFinite, low >= 0, high < Double(Int.max) else { return nil }
            return Int(low) ... Int(high)
        }
        selectedTiles = range(\.selectedTiles, overhead: 1)
        sourceRequests = range(\.sourceRequests, overhead: 1)
        sourceBytes = range(\.sourceBytes)
        vertices = range(\.vertices)
        geometryBytes = range(\.geometryBytes)
        textureBytes = range(\.textureBytes)
    }
}
