import Foundation
import simd

enum EarthSourceMetadata
{
    static let maximumBytes = 16 * 1024 * 1024

    static func decode(_ data: Data) throws -> EarthTileset
    {
        guard data.count <= maximumBytes else { throw EarthAcquisitionError.metadataTooLarge }
        // Bound recursive JSON parsing before constructing a Codable tile tree.
        var depth = 0
        var quoted = false
        var escaped = false
        for byte in data
        {
            if quoted
            {
                if escaped { escaped = false }
                else if byte == 92 { escaped = true }
                else if byte == 34 { quoted = false }
            }
            else if byte == 34 { quoted = true }
            else if byte == 123 || byte == 91
            {
                depth += 1
                guard depth <= 256 else { throw EarthAcquisitionError.metadataTooLarge }
            }
            else if byte == 125 || byte == 93 { depth -= 1 }
        }
        let tileset: EarthTileset
        do { tileset = try JSONDecoder().decode(EarthTileset.self, from: data) }
        catch { throw EarthImportError.invalidContent("The source tileset JSON is invalid.") }
        try tileset.validateSupportedContent()
        return tileset
    }

    /// Retains hierarchy/placement/refinement, replacing all access URIs with
    /// deterministic local references. Session/key rotation leaves this unchanged.
    static func sanitized(_ tileset: EarthTileset, parent: URL, access: EarthSourceAccess) throws -> Data
    {
        func content(_ value: EarthTileset.Content) throws -> EarthTileset.Content
        {
            let url = try access.resourceURL(uri: value.uri, parent: parent)
            let id = access.identity(url)
            switch url.pathExtension.lowercased()
            {
                case "glb": return .init(uri: "../tiles/\(id).glb")
                case "json": return .init(uri: "\(id).json")
                default: throw EarthImportError.unsupportedContent("Source content must be a GLB or an explicit JSON tileset.")
            }
        }
        func tile(_ value: EarthTileset.Tile) throws -> EarthTileset.Tile
        {
            try .init(boundingVolume: value.boundingVolume, geometricError: value.geometricError, transform: value.transform, refine: value.refine, content: value.content.map(content), contents: value.contents?.map(content), children: value.children?.map(tile), implicitTiling: value.implicitTiling)
        }
        let safe = try EarthTileset(asset: tileset.asset, root: tile(tileset.root), extensionsRequired: tileset.extensionsRequired)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(safe)
    }

    /// Streams flattened completed placements once, after acquisition finishes.
    static func publishManifest(index: EarthAcquisitionIndex, request: EarthDownloadRequest) throws
    {
        let staging = try index.files.checked("staging/manifest.partial")
        do
        {
            guard FileManager.default.createFile(atPath: staging.path, contents: nil) else { throw EarthAcquisitionError.storage }
            let output = try FileHandle(forWritingTo: staging)
            defer { try? output.close() }
            let origin = simd_inverse(request.center.earthCenteredToLocal).columns.3
            let extras: [String: Any] = ["messEarthKitSharedOrigin": ["latitude": request.center.latitude, "longitude": request.center.longitude, "ellipsoidHeight": request.center.ellipsoidHeight]]
            let extraData = try JSONSerialization.data(withJSONObject: extras, options: [.sortedKeys])
            let sphere = try JSONSerialization.data(withJSONObject: [origin.x, origin.y, origin.z, 20000000.0])
            try output.write(contentsOf: Data("{\"asset\":{\"version\":\"1.1\"},\"extras\":".utf8))
            try output.write(contentsOf: extraData)
            try output.write(contentsOf: Data(",\"root\":{\"boundingVolume\":{\"sphere\":".utf8))
            try output.write(contentsOf: sphere)
            try output.write(contentsOf: Data("},\"geometricError\":0,\"refine\":\"REPLACE\",\"children\":[".utf8))
            var first = true
            try index.forEachPlacement
            { tile in
                try Task.checkCancellation()
                if !first { try output.write(contentsOf: Data([44])) }
                try output.write(contentsOf: tile)
                first = false
            }
            try output.write(contentsOf: Data("]}}".utf8))
            try output.synchronize()
            try output.close()
            try index.files.publish(staging: staging, path: "tileset.json")
        }
        catch is CancellationError { throw CancellationError() }
        catch { throw EarthAcquisitionError.storage }
    }
}

/// Shared selection/refinement rules for legacy inspection and raw acquisition.
struct EarthSourceTileSelection
{
    let transform: simd_double4x4
    let refine: String
    let contents: [EarthTileset.Content]
    let children: [EarthTileset.Tile]
    let needsDetail: Bool
    let descend: Bool

    init?(tile: EarthTileset.Tile, parentTransform: simd_double4x4, inheritedRefine: String, selection: EarthRegionSelection) throws
    {
        guard tile.implicitTiling == nil else { throw EarthImportError.unsupportedContent("Implicit source tiling.") }
        transform = parentTransform * (try tile.localTransform())
        guard [transform.columns.0, transform.columns.1, transform.columns.2, transform.columns.3].allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.z.isFinite && $0.w.isFinite })
        else { throw EarthImportError.invalidContent("Source transforms overflow finite coordinates.") }
        guard try selection.intersects(bounds: tile.boundingVolume, transform: transform) else { return nil }
        refine = tile.refine ?? inheritedRefine
        guard ["ADD", "REPLACE"].contains(refine), tile.geometricError.isFinite, tile.geometricError >= 0,
              !(tile.content != nil && tile.contents != nil)
        else { throw EarthImportError.invalidContent("Invalid source refinement/content metadata.") }
        contents = tile.contents ?? tile.content.map { [$0] } ?? []
        children = tile.children ?? []
        needsDetail = tile.geometricError * selection.errorScale(transform: transform) > selection.maximumGeometricErrorMeters
        descend = !children.isEmpty && (needsDetail || contents.isEmpty)
    }
}
