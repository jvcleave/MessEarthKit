import Foundation
import simd

/// Serializes only selected placements and local source paths; service URLs
/// and credentials never enter a complete or interrupted capture manifest.
enum EarthCaptureManifest
{
    static func encode(request: EarthCaptureRequest, limits: EarthImportLimits, tiles: [EarthTileset.Tile], incompleteReason: String?, downloadedTiles: Int, sourceRequests: Int) throws -> Data
    {
        let center = simd_inverse(request.center.earthCenteredToLocal).columns.3
        let manifest = EarthTileset(
            asset: .init(version: "1.1"),
            root: .init(boundingVolume: .init(box: nil, sphere: [center.x, center.y, center.z, 20000000], region: nil), geometricError: 0, transform: nil, refine: "REPLACE", content: nil, contents: nil, children: tiles, implicitTiling: nil),
            extensionsRequired: nil
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(manifest)
        guard let incompleteReason else { return data }
        var json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        json["extras"] = ["messEarthKitIncompleteCapture": [
            "reason": String(incompleteReason.prefix(512)),
            "downloadedTileCount": downloadedTiles,
            "sourceRequests": sourceRequests,
            "maximumSourceRequests": request.maximumSourceRequests,
            "maximumSelectedTiles": request.maximumSelectedTiles,
            "maximumVertices": limits.maximumVertices,
            "maximumDecodedTextureBytes": limits.maximumDecodedTextureBytes,
            "requestedRegion": [
                "latitude": request.center.latitude, "longitude": request.center.longitude,
                "ellipsoidHeight": request.center.ellipsoidHeight,
                "widthMeters": request.widthMeters, "depthMeters": request.depthMeters,
                "maximumGeometricErrorMeters": request.maximumGeometricErrorMeters,
            ],
        ]]
        return try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    static func incompleteReason(data: Data) throws -> String?
    {
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let extras = json?["extras"] as? [String: Any],
              let marker = extras["messEarthKitIncompleteCapture"]
        else { return nil }
        guard let metadata = marker as? [String: Any],
              let reason = metadata["reason"] as? String,
              !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, reason.count <= 512
        else { throw EarthImportError.invalidContent("Invalid incomplete-capture metadata.") }
        return reason
    }

    /// Our aligned model manifests already record their exact shared origin.
    /// Reconstructing it from ECEF bounds introduces round-trip differences and
    /// changes the frame used to import otherwise unchanged prepared models.
    static func sharedOrigin(data: Data) throws -> EarthGeographicOrigin?
    {
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let extras = json?["extras"] as? [String: Any],
              let marker = extras["messEarthKitSharedOrigin"] else { return nil }
        guard let metadata = marker as? [String: Any]
        else { throw EarthImportError.invalidContent("Invalid shared geographic origin metadata.") }
        do { return try JSONDecoder().decode(EarthGeographicOrigin.self, from: JSONSerialization.data(withJSONObject: metadata)) }
        catch { throw EarthImportError.invalidContent("Invalid shared geographic origin metadata.") }
    }
}
