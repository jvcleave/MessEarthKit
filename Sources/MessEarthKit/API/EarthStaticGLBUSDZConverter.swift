import Foundation
import simd

/// Identity and geometry inventory of the archive just published.
public struct EarthStaticGLBConversion: Sendable
{
    public let surfaceCount: Int
    public let triangleCount: Int
    public let partitionCount: Int
    public let attributions: [String]
}

/// The input needs its original GLB reader. No destination was published.
public struct EarthStaticGLBOutsideProfile: LocalizedError, Sendable
{
    public let reason: String
    public var errorDescription: String? { reason }
}

/// Converts a bounded static GLB from its delivered bytes. Call on an import worker.
/// Existing destinations are never replaced. Storage and invalid-data errors propagate.
public enum EarthStaticGLBUSDZConverter
{
    @discardableResult
    public static func write(_ data: Data, name: String, destination: URL) throws -> EarthStaticGLBConversion
    {
        guard destination.isFileURL, destination.pathExtension.lowercased() == "usdz"
        else { throw EarthUSDZExportError.invalidDestination }
        try Task.checkCancellation()
        let source: Source
        do { source = try Source(data) }
        catch let EarthImportError.unsupportedContent(reason) { throw EarthStaticGLBOutsideProfile(reason: reason) }
        catch let EarthImportError.limitExceeded(reason) { throw EarthStaticGLBOutsideProfile(reason: reason) }
        return try source.write(name: name, destination: destination)
    }

    private struct Source
    {
        let json: [String: Any]
        let earth: EarthCombinedGLBMetadata?
        let decoded: EarthGLBPart
        let options: EarthExportOptions
        let partitions: [(id: Int, meshes: [EarthMesh])]

        init(_ data: Data) throws
        {
            let limits = EarthImportLimits()
            // The shared decoder reports an oversized buffer as an invalid header.
            // It can still be valid input to a client with a larger direct-import budget.
            guard data.count <= limits.maximumSourceBytes else { throw EarthImportError.limitExceeded("Static conversion source byte budget.") }
            let reader = EarthGLBDecoder(limits: limits, skinning: .reject)
            json = try reader.preflight(data: data)
            earth = try EarthCombinedGLBMetadata.read(json: json, maximumEntries: limits.maximumNodes)
            guard let scenes = json["scenes"] as? [[String: Any]], scenes.count == 1,
                  let roots = scenes[0]["nodes"] as? [Int], roots.count == 1,
                  let nodes = json["nodes"] as? [[String: Any]], nodes.indices.contains(roots[0]),
                  let accessors = json["accessors"] as? [[String: Any]],
                  let meshes = json["meshes"] as? [[String: Any]]
            else { throw EarthImportError.unsupportedContent("Expected one static model root.") }
            try EarthStaticGLBProfile.validate(json, nodes: nodes, root: roots[0], meshes: meshes, earth: earth)
            var channels: Set<String>?
            for mesh in meshes
            {
                guard let primitives = mesh["primitives"] as? [[String: Any]] else { throw EarthImportError.invalidContent("Mesh primitives.") }
                for primitive in primitives
                {
                    guard let attributes = primitive["attributes"] as? [String: Int] else { throw EarthImportError.invalidContent("Primitive attributes.") }
                    let keys = Set(attributes.keys)
                    guard keys.isSubset(of: ["POSITION", "NORMAL", "TEXCOORD_0", "COLOR_0"]), keys.contains("POSITION"),
                          (primitive["mode"] as? Int ?? 4) == 4, primitive["targets"] == nil,
                          channels == nil || channels == keys else { throw EarthImportError.unsupportedContent("Static triangle attribute profile.") }
                    for index in attributes.values
                    {
                        guard accessors.indices.contains(index), let count = accessors[index]["count"] as? Int
                        else { throw EarthImportError.invalidContent("Invalid vertex attribute accessor.") }
                        guard count <= limits.maximumVertices else { throw EarthImportError.limitExceeded("Static conversion vertex budget.") }
                    }
                    channels = keys
                }
            }
            guard let channels, channels.isSuperset(of: ["NORMAL", "TEXCOORD_0"]) else { throw EarthImportError.unsupportedContent("Authored normals and UVs are required.") }

            decoded = try reader.decode(data: data, transform: matrix_identity_double4x4)
            guard decoded.omittedDegenerateTriangleCount == 0 else { throw EarthImportError.unsupportedContent("Omitted degenerate triangles.") }
            for material in decoded.materials
            {
                if let image = material.baseColorTexture, image.usesNearestMinification || image.usesNearestMagnification || image.mipmapFilter == .nearest
                { throw EarthImportError.unsupportedContent("Nearest filtering is outside the portable static USDZ profile.") }
            }
            for mesh in decoded.meshes where channels.contains("COLOR_0") && decoded.materials[mesh.materialIndex].baseColorTexture != nil
            {
                do { _ = try EarthUSDZShading.uniformTextureTint(mesh, material: decoded.materials[mesh.materialIndex]) }
                catch let EarthUSDZExportError.unsupportedAppearance(reason) { throw EarthImportError.unsupportedContent(reason) }
            }
            let extras = json["extras"] as? [String: Any]
            var selected: [(id: Int, meshes: [EarthMesh])] = []
            if let earth
            {
                guard earth.optimization == nil, earth.preparationComplete,
                      let flags = extras?["messEarthKitExportOptions"],
                      let groups = nodes[roots[0]]["children"] as? [Int], groups.count == earth.selectedModels.count
                else { throw EarthImportError.unsupportedContent("Expected complete unoptimized Earth model groups.") }
                options = try JSONDecoder().decode(EarthExportOptions.self, from: JSONSerialization.data(withJSONObject: flags))
                guard options == .full, channels.contains("COLOR_0")
                else { throw EarthImportError.unsupportedContent("Combined export channel profile.") }
                var offset = 0
                var visited = Set([roots[0]])
                for (group, id) in zip(groups, earth.selectedModels)
                {
                    guard visited.insert(group).inserted, nodes.indices.contains(group), nodes[group]["name"] as? String == "Model \(id)",
                          let children = nodes[group]["children"] as? [Int], !children.isEmpty
                    else { throw EarthImportError.unsupportedContent("Earth partition does not match the declared model ID.") }
                    var groupMeshes: [EarthMesh] = []
                    for child in children
                    {
                        guard visited.insert(child).inserted, nodes.indices.contains(child), let mesh = nodes[child]["mesh"] as? Int, meshes.indices.contains(mesh),
                              let primitives = meshes[mesh]["primitives"] as? [[String: Any]], primitives.count == 1,
                              decoded.meshes.indices.contains(offset), nodes[child]["name"] as? String == decoded.meshes[offset].name
                        else { throw EarthImportError.unsupportedContent("Earth partition mesh order.") }
                        groupMeshes.append(decoded.meshes[offset])
                        offset += 1
                    }
                    selected.append((id, groupMeshes))
                }
                guard visited.count == nodes.count, offset == decoded.meshes.count else { throw EarthImportError.unsupportedContent("Incomplete Earth partition inventory.") }
            }
            else
            {
                options = EarthExportOptions(includeVertexColors: channels.contains("COLOR_0"), includeTextureCoordinates: channels.contains("TEXCOORD_0"), includeTextures: decoded.materials.contains { $0.baseColorTexture != nil })
                selected = [(1, decoded.meshes)]
            }
            partitions = selected
        }

        func write(name: String, destination: URL) throws -> EarthStaticGLBConversion
        {
            guard !FileManager.default.fileExists(atPath: destination.path) else { throw EarthUSDZExportError.invalidDestination }
            let work = destination.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: work.appendingPathComponent("textures"), withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: work) }
            var images: [String: URL] = [:]
            var layers: [URL] = []
            var vertexCount = 0
            for partition in partitions
            {
                try Task.checkCancellation()
                let geometry = work.appendingPathComponent("model\(partition.id).usdc")
                let appearance = work.appendingPathComponent("model\(partition.id).usda")
                vertexCount += try EarthUSDZGeometry.write(partition.meshes, options: options, fileURL: geometry)
                try EarthUSDZShading.write(meshes: partition.meshes, materials: decoded.materials, geometryName: geometry.lastPathComponent, preserveGLBAttributes: true, options: options, optimization: nil, fileURL: appearance, staging: work, textures: &images)
                layers.append(contentsOf: [geometry, appearance])
            }
            let root = work.appendingPathComponent("scene.usda")
            let writer = try EarthUSDTextWriter(root)
            let asset = json["asset"] as? [String: Any]
            let identity = try EarthCaptureIdentity.readMetadata(json: json)
            let title = identity.map { $0.locationName + " - " + $0.detailName } ?? (earth == nil ? name : "Earth Models")
            let attributions = earth?.attributions ?? decoded.attributions
            let triangles = decoded.meshes.reduce(0) { $0 + $1.triangleIndices.count / 3 }
            try writer.write("#usda 1.0\n(\n defaultPrim = \"World\"\n metersPerUnit = 1\n upAxis = \"Y\"\n customLayerData = {\n  string title = \(try EarthUSDZShading.quoted(title))\n  string author = \(try EarthUSDZShading.quoted(attributions.sorted().joined(separator: " | ")))\n")
            if let earth
            {
                let info = EarthUSDZExportMetadata(
                    formatVersion: 1,
                    sourceIdentifier: earth.sourceIdentifier,
                    geographicOrigin: earth.geographicOrigin,
                    captureIdentity: identity,
                    sourceProfile: earth.sourceProfile,
                    glbDestinationProfile: earth.destinationProfile,
                    selectedModels: earth.selectedModels,
                    coversEntireSource: earth.coversEntireSource,
                    preparationComplete: earth.preparationComplete,
                    attributions: attributions.sorted(),
                    options: options,
                    optimization: nil,
                    sourceVertexCount: decoded.meshes.reduce(0) { $0 + $1.vertices.count },
                    sourceTriangleCount: triangles,
                    vertexCount: vertexCount,
                    triangleCount: triangles,
                    maximumErrorMeters: 0
                )
                try info.validate()
                try writer.write("  string messEarthKitExport = \"\(try JSONEncoder().encode(info).base64EncodedString())\"\n")
            }
            else if let copyright = asset?["copyright"] as? String
            { try writer.write("  string copyright = \(try EarthUSDZShading.quoted(copyright))\n") }
            try writer.write(" }\n)\ndef Xform \"World\"\n{\n")
            for partition in partitions
            { try writer.write(" def Xform \"Model\(partition.id)\" (\n  prepend references = @model\(partition.id).usda@\n )\n {\n }\n") }
            try writer.write("}\n")
            try writer.finish()
            let staged = work.appendingPathComponent("candidate.usdz")
            let archive = try EarthUSDZArchive(fileURL: staged)
            for layer in [root] + layers { try archive.append(layer, name: layer.lastPathComponent) }
            for (name, image) in images.sorted(by: { $0.key < $1.key }) { try archive.append(image, name: name) }
            _ = try archive.finish()
            try Task.checkCancellation()
            try FileManager.default.linkItem(at: staged, to: destination)
            return EarthStaticGLBConversion(surfaceCount: decoded.meshes.count, triangleCount: triangles, partitionCount: partitions.count, attributions: attributions)
        }
    }
}
