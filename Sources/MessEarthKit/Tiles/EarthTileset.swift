import Foundation
import simd

struct EarthTileset: Codable
{
    struct Asset: Codable
    {
        let version: String
        let tilesetVersion: String?
        let copyright: String?

        init(version: String, tilesetVersion: String? = nil, copyright: String? = nil)
        {
            self.version = version
            self.tilesetVersion = tilesetVersion
            self.copyright = copyright
        }
    }

    struct Presence: Codable {}
    struct Content: Codable { let uri: String }
    struct BoundingVolume: Codable
    {
        let box: [Double]?
        let sphere: [Double]?
        let region: [Double]?

        func geographicOrigin(transform: simd_double4x4) throws -> EarthGeographicOrigin
        {
            if let region
            {
                guard region.count == 6, region.allSatisfy(\.isFinite), region[1] <= region[3], region[4] <= region[5]
                else { throw EarthImportError.invalidContent("Tileset region bounds are invalid.") }
                let east = region[2] < region[0] ? region[2] + 2 * .pi : region[2]
                var longitude = (region[0] + east) / 2
                if longitude > .pi { longitude -= 2 * .pi }
                return try EarthGeographicOrigin(latitude: (region[1] + region[3]) * 90 / .pi, longitude: longitude * 180 / .pi, ellipsoidHeight: (region[4] + region[5]) / 2)
            }
            let values: [Double]
            if let box, box.count == 12 { values = box }
            else if let sphere, sphere.count == 4, sphere[3] >= 0 { values = sphere }
            else { throw EarthImportError.invalidContent("Tileset must have a valid root box, sphere, or region.") }
            guard values.allSatisfy(\.isFinite)
            else { throw EarthImportError.invalidContent("Tileset bounds contain non-finite values.") }
            let center = transform * SIMD4(values[0], values[1], values[2], 1)
            return try EarthGeographicOrigin.makeOrigin(earthCenteredPosition: SIMD3(center.x, center.y, center.z))
        }
    }

    struct Tile: Codable
    {
        let boundingVolume: BoundingVolume
        let geometricError: Double
        let transform: [Double]?
        let refine: String?
        let content: Content?
        let contents: [Content]?
        let children: [Tile]?
        let implicitTiling: Presence?

        func localTransform() throws -> simd_double4x4
        {
            guard let values = transform else { return matrix_identity_double4x4 }
            guard values.count == 16, values.allSatisfy(\.isFinite),
                  values[3] == 0, values[7] == 0, values[11] == 0, values[15] == 1
            else { throw EarthImportError.invalidContent("Tile transform must be a finite affine matrix.") }
            return simd_double4x4(columns: (
                SIMD4(values[0], values[1], values[2], values[3]),
                SIMD4(values[4], values[5], values[6], values[7]),
                SIMD4(values[8], values[9], values[10], values[11]),
                SIMD4(values[12], values[13], values[14], values[15])
            ))
        }
    }

    let asset: Asset
    let root: Tile
    let extensionsRequired: [String]?

    func validateSupportedContent() throws
    {
        guard ["1.0", "1.1"].contains(asset.version)
        else { throw EarthImportError.unsupportedContent("Tileset version \(asset.version).") }
        for name in extensionsRequired ?? []
        {
            // 3D Tiles 1.0 requires this declaration for direct glTF/GLB content.
            // Selected GLBs still validate their own required glTF extensions.
            guard name == "3DTILES_content_gltf"
            else { throw EarthImportError.unsupportedContent("Required tileset extension \(name).") }
        }
    }
}
