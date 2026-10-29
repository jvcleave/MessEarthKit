import Foundation
import simd

struct EarthCollectionTile
{
    let sourceID: String
    let data: Data
    let bounds: EarthTileset.BoundingVolume
    let transform: simd_double4x4
    let estimate: EarthCaptureGeometryEstimate
}

/// Spatially orders whole tiles and packs each model within its own budgets.
/// The shared local frame is established before grouping, never per-section.
struct EarthCaptureCollectionBuilder
{
    let limits: EarthImportLimits

    func build(tiles: [EarthCollectionTile], origin: EarthGeographicOrigin, name: String, incompleteReason: String?, preparationProfile: EarthPreparationProfile? = nil) throws -> EarthCaptureCollection
    {
        guard !tiles.isEmpty else { throw EarthImportError.invalidContent("The capture has no usable model sections.") }
        var ordered: [(tile: EarthCollectionTile, center: SIMD4<Double>, ordinal: Int)] = []
        for (ordinal, tile) in tiles.enumerated()
        {
            try Task.checkCancellation()
            let frame = try tile.bounds.geographicOrigin(transform: tile.transform)
            let center = origin.earthCenteredToLocal * simd_inverse(frame.earthCenteredToLocal).columns.3
            ordered.append((tile, center, ordinal))
        }
        ordered.sort
        {
            if $0.center.x != $1.center.x { return $0.center.x < $1.center.x }
            if $0.center.z != $1.center.z { return $0.center.z < $1.center.z }
            return $0.ordinal < $1.ordinal
        }
        var sections: [EarthCaptureSection] = []
        var pending: [EarthCollectionTile] = []
        var estimate = try EarthCaptureGeometryEstimate()
        func flush() throws
        {
            guard !pending.isEmpty else { return }
            guard sections.count < 64 else { throw EarthImportError.limitExceeded("This area needs more than 64 model sections. Choose a smaller area or lower detail.") }
            var localPaths: [String: String] = [:]
            var files: [EarthSourceFile] = []
            var children: [EarthTileset.Tile] = []
            for tile in pending
            {
                let path: String
                if let existing = localPaths[tile.sourceID] { path = existing }
                else
                {
                    path = "tiles/tile-\(files.count).glb"
                    localPaths[tile.sourceID] = path
                    files.append(EarthSourceFile(relativePath: path, data: tile.data))
                }
                let columns = [tile.transform.columns.0, tile.transform.columns.1, tile.transform.columns.2, tile.transform.columns.3]
                children.append(.init(boundingVolume: tile.bounds, geometricError: 0, transform: columns.flatMap { [$0.x, $0.y, $0.z, $0.w] }, refine: "REPLACE", content: .init(uri: path), contents: nil, children: nil, implicitTiling: nil))
            }
            let root = try Self.manifest(children: children, origin: origin, incompleteReason: incompleteReason, isCollection: false, preparationProfile: preparationProfile)
            let id = sections.count + 1
            sections.append(EarthCaptureSection(id: id, name: "Model \(id)", tileCount: pending.count, estimate: estimate, sourceFiles: [EarthSourceFile(relativePath: "tileset.json", data: root)] + files))
            pending = []
            estimate = try EarthCaptureGeometryEstimate()
        }
        for item in ordered
        {
            try Task.checkCancellation()
            let tile = item.tile
            guard tile.estimate.vertexCount <= limits.maximumVertices,
                  tile.estimate.decodedTextureBytes <= limits.maximumDecodedTextureBytes,
                  tile.estimate.largestTextureDimension <= limits.maximumTextureDimension
            else { throw EarthImportError.limitExceeded("One source tile is too complex for a model section. Choose lower detail, or increase the per-model limits in Advanced.") }
            let combined = try estimate.adding(tile.estimate)
            if !pending.isEmpty && (combined.vertexCount > limits.maximumVertices || combined.decodedTextureBytes > limits.maximumDecodedTextureBytes || pending.count >= 64)
            { try flush() }
            pending.append(tile)
            estimate = try estimate.adding(tile.estimate)
        }
        try flush()
        return EarthCaptureCollection(name: name, geographicOrigin: origin, sections: sections, incompleteReason: incompleteReason, preparationProfile: preparationProfile)
    }

    static func rootBounds(origin: EarthGeographicOrigin) -> EarthTileset.BoundingVolume
    {
        let center = simd_inverse(origin.earthCenteredToLocal).columns.3
        return .init(box: nil, sphere: [center.x, center.y, center.z, 20000000], region: nil)
    }

    static func manifest(children: [EarthTileset.Tile], origin: EarthGeographicOrigin, incompleteReason: String?, isCollection: Bool, preparationProfile: EarthPreparationProfile? = nil) throws -> Data
    {
        let tileset = EarthTileset(asset: .init(version: "1.1"), root: .init(boundingVolume: rootBounds(origin: origin), geometricError: 0, transform: nil, refine: "REPLACE", content: nil, contents: nil, children: children, implicitTiling: nil), extensionsRequired: nil)
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(tileset)) as! [String: Any]
        var extras: [String: Any] = ["messEarthKitSharedOrigin": ["latitude": origin.latitude, "longitude": origin.longitude, "ellipsoidHeight": origin.ellipsoidHeight]]
        if isCollection { extras["messEarthKitModelCollection"] = 1 }
        if let preparationProfile { extras["messEarthKitPreparation"] = ["profile": try JSONSerialization.jsonObject(with: JSONEncoder().encode(preparationProfile))] }
        if let incompleteReason { extras["messEarthKitIncompleteCapture"] = ["reason": String(incompleteReason.prefix(512))] }
        json["extras"] = extras
        return try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys, .withoutEscapingSlashes])
    }
}
