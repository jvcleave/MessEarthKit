import Foundation
import ImageIO
import ModelIO
import simd

/// Reads this SDK's own current USDZ deliveries into CPU values. This is not a
/// general-purpose USD importer. Native objects stay on this actor's worker;
/// the caller retains authorization to the unchanged file throughout the read.
public actor EarthUSDZExportReader
{
    private let limits: EarthImportLimits

    public init(limits: EarthImportLimits = EarthImportLimits(maximumSourceBytes: 512 * 1024 * 1024, maximumVertices: 2000000, maximumNodes: 100000))
    { self.limits = limits }

    public func read(fileURL: URL) throws -> EarthCapture
    {
        do
        {
            try Task.checkCancellation()
            guard limits.maximumVertices > 0, limits.maximumVertices <= Int.max / 3, limits.maximumNodes > 0, limits.maximumSourceBytes > 0 else { throw EarthImportError.limitExceeded("Export viewer admission settings.") }
            guard fileURL.isFileURL, fileURL.pathExtension.lowercased() == "usdz" else { throw EarthUSDZArchiveReader.invalid() }
            let archive = try EarthUSDZArchiveReader(fileURL, maximumBytes: limits.maximumSourceBytes)
            guard let root = String(data: try archive.data("scene.usda", maximumBytes: 8 * 1024 * 1024), encoding: .utf8),
                  let start = root.range(of: "string messEarthKitExport = \""), let end = root[start.upperBound...].firstIndex(of: "\""),
                  let data = Data(base64Encoded: String(root[start.upperBound ..< end])), data.count <= 1024 * 1024
            else { throw EarthUSDZArchiveReader.invalid() }
            let metadata = try JSONDecoder().decode(EarthUSDZExportMetadata.self, from: data)
            try metadata.validate()
            guard limits.maximumVertices > 0, limits.maximumNodes > 0,
                  metadata.vertexCount <= limits.maximumVertices, metadata.triangleCount <= limits.maximumVertices,
                  metadata.selectedModels.count <= limits.maximumNodes
            else { throw EarthImportError.limitExceeded("Exported USDZ geometry or nodes.") }
            // Exact root/reference structure prevents this read contract from
            // accidentally admitting a different composed USD scene.
            let title = metadata.captureIdentity.map { $0.locationName + " - " + $0.detailName } ?? "Earth Models"
            var expectedRoot = "#usda 1.0\n(\n defaultPrim = \"World\"\n metersPerUnit = 1\n upAxis = \"Y\"\n customLayerData = {\n  string title = \(try EarthUSDZShading.quoted(title))\n  string author = \(try EarthUSDZShading.quoted(metadata.attributions.sorted().joined(separator: " | ")))\n  string messEarthKitExport = \"\(data.base64EncodedString())\"\n }\n)\ndef Xform \"World\"\n{\n"
            for model in metadata.selectedModels { expectedRoot += " def Xform \"Model\(model)\" (\n  prepend references = @model\(model).usda@\n )\n {\n }\n" }
            expectedRoot += "}\n"
            guard root == expectedRoot else { throw EarthUSDZArchiveReader.invalid() }
            var appearances: [Int: EarthUSDZAppearanceReader] = [:]
            var admittedNames: Set<String> = ["scene.usda"]
            var texturePaths = Set<String>()
            for model in metadata.selectedModels
            {
                try Task.checkCancellation()
                let geometry = "model\(model).usdc", appearance = "model\(model).usda"
                let bytes = try archive.data(geometry, maximumBytes: limits.maximumSourceBytes)
                guard bytes.starts(with: Data("PXR-USDC".utf8)), let text = String(data: try archive.data(appearance, maximumBytes: 32 * 1024 * 1024), encoding: .utf8)
                else { throw EarthUSDZArchiveReader.invalid() }
                let parsed = try EarthUSDZAppearanceReader(text: text, geometryName: geometry)
                let meshNodes = parsed.nodes.keys.filter { $0.hasPrefix("/Model/Geom/Mesh") }
                guard !meshNodes.isEmpty else { throw EarthUSDZArchiveReader.invalid() }
                for path in meshNodes
                {
                    guard let ordinal = Int(path.dropFirst("/Model/Geom/Mesh".count)) else { throw EarthUSDZArchiveReader.invalid() }
                    let surface = try parsed.surface(mesh: ordinal, options: metadata.options)
                    if let texture = surface.texturePath
                    {
                        let suffix = texture.hasSuffix(".png") ? ".png" : texture.hasSuffix(".jpg") ? ".jpg" : ""
                        let hash = texture.dropFirst("textures/".count).dropLast(suffix.count)
                        guard texture.hasPrefix("textures/"), !suffix.isEmpty, hash.count == 64,
                              hash.allSatisfy({ $0.isASCII && ($0.isNumber || ("a" ... "f").contains(String($0))) })
                        else { throw EarthUSDZArchiveReader.invalid() }
                        texturePaths.insert(texture)
                    }
                }
                appearances[model] = parsed
                admittedNames.formUnion([geometry, appearance])
            }
            admittedNames.formUnion(texturePaths)
            guard Set(archive.members.keys) == admittedNames else { throw EarthUSDZArchiveReader.invalid() }
            var images: [String: (Data, Int, Int, String)] = [:]
            var decodedBytes = 0
            for path in texturePaths.sorted()
            {
                let bytes = try archive.data(path, maximumBytes: min(limits.maximumSourceBytes, 128 * 1024 * 1024))
                guard let image = CGImageSourceCreateWithData(bytes as CFData, nil), CGImageSourceGetCount(image) == 1,
                      let properties = CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any],
                      let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
                      width > 0, height > 0, width <= limits.maximumTextureDimension, height <= limits.maximumTextureDimension,
                      width <= Int.max / height / 4, width * height * 4 <= limits.maximumDecodedTextureBytes - decodedBytes
                else { throw EarthImportError.limitExceeded("Exported USDZ textures.") }
                decodedBytes += width * height * 4
                let type = CGImageSourceGetType(image) as String?
                guard type == "public.png" || type == "public.jpeg" else { throw EarthUSDZArchiveReader.invalid() }
                images[path] = (bytes, width, height, type == "public.png" ? "image/png" : "image/jpeg")
            }
            return try autoreleasepool
            {
                let asset = MDLAsset(url: fileURL)
                var meshes: [EarthMesh] = [], materials: [EarthMaterial] = []
                var vertexCount = 0, indexCount = 0, nodeCount = 0
                var seen = Set<String>()
                var minimum = SIMD3<Float>(repeating: .infinity), maximum = SIMD3<Float>(repeating: -.infinity)
                func visit(_ object: MDLObject) throws
                {
                    try Task.checkCancellation()
                    nodeCount += 1
                    guard nodeCount <= limits.maximumNodes else { throw EarthImportError.limitExceeded("Exported USDZ nodes.") }
                    if let transform = object.transform
                    { guard let matrix = transform.localTransform?(atTime: 0), matrix == matrix_identity_float4x4 else { throw EarthUSDZArchiveReader.invalid() } }
                    if let mesh = object as? MDLMesh
                    {
                        let parts = mesh.path.split(separator: "/")
                        guard parts.count == 4, parts[0] == "World", parts[1].hasPrefix("Model"), parts[2] == "Geom", parts[3].hasPrefix("Mesh"),
                              let model = Int(parts[1].dropFirst(5)), let ordinal = Int(parts[3].dropFirst(4)), let appearance = appearances[model], seen.insert(mesh.path).inserted
                        else { throw EarthUSDZArchiveReader.invalid() }
                        let surface = try appearance.surface(mesh: ordinal, options: metadata.options)
                        guard mesh.vertexCount >= 3, mesh.vertexCount <= limits.maximumVertices - vertexCount else { throw EarthImportError.limitExceeded("Exported USDZ vertices.") }
                        let positions = try Self.attribute(mesh, name: MDLVertexAttributePosition, components: 3)
                        let normals = metadata.options.includeNormals ? try Self.attribute(mesh, name: MDLVertexAttributeNormal, components: 3) : nil
                        let uv = metadata.options.includeTextureCoordinates ? try Self.attribute(mesh, name: MDLVertexAttributeTextureCoordinate, components: 2) : nil
                        let colors = metadata.options.includeVertexColors ? try Self.attribute(mesh, name: MDLVertexAttributeColor, components: 4) : nil
                        var vertices: [EarthVertex] = []
                        vertices.reserveCapacity(mesh.vertexCount)
                        for index in 0 ..< mesh.vertexCount
                        {
                            if index.isMultiple(of: 4096) { try Task.checkCancellation() }
                            let p = Self.value(positions, index: index, components: 3), n = normals.map { Self.value($0, index: index, components: 3) } ?? .zero
                            let coordinate = uv.map { Self.value($0, index: index, components: 2) } ?? .zero
                            let color = colors.map { Self.value($0, index: index, components: 4) } ?? SIMD4(repeating: 1)
                            guard (0 ..< 3).allSatisfy({ p[$0].isFinite && n[$0].isFinite }), normals == nil || simd_length_squared(SIMD3(n.x, n.y, n.z)) > 0.000001,
                                  coordinate.x.isFinite, coordinate.y.isFinite, (0 ..< 4).allSatisfy({ color[$0].isFinite && color[$0] >= 0 }), color.w <= 1
                            else { throw EarthUSDZArchiveReader.invalid() }
                            let position = SIMD3(p.x, p.y, p.z)
                            minimum = simd_min(minimum, position); maximum = simd_max(maximum, position)
                            vertices.append(EarthVertex(position: position, normal: SIMD3(n.x, n.y, n.z), textureCoordinate: metadata.options.includeTextureCoordinates ? SIMD2(coordinate.x, 1 - coordinate.y) : .zero, color: color))
                        }
                        guard let submeshes = mesh.submeshes as? [MDLSubmesh], submeshes.count == 1, let submesh = submeshes.first,
                              submesh.geometryType == .triangles, submesh.indexCount >= 3, submesh.indexCount.isMultiple(of: 3),
                              indexCount <= limits.maximumVertices * 3, submesh.indexCount <= limits.maximumVertices * 3 - indexCount
                        else { throw EarthImportError.limitExceeded("Exported USDZ triangle indices.") }
                        let indexSize: Int
                        switch submesh.indexType { case .uInt8: indexSize = 1; case .uInt16: indexSize = 2; case .uInt32: indexSize = 4; default: throw EarthUSDZArchiveReader.invalid() }
                        guard submesh.indexCount <= submesh.indexBuffer.length / indexSize else { throw EarthUSDZArchiveReader.invalid() }
                        let bytes = submesh.indexBuffer.map().bytes
                        var indices: [UInt32] = []
                        indices.reserveCapacity(submesh.indexCount)
                        for index in 0 ..< submesh.indexCount
                        {
                            if index.isMultiple(of: 4096) { try Task.checkCancellation() }
                            let value: UInt32
                            switch submesh.indexType
                            {
                                case .uInt8: value = UInt32(bytes.load(fromByteOffset: index, as: UInt8.self))
                                case .uInt16: value = UInt32(bytes.loadUnaligned(fromByteOffset: index * 2, as: UInt16.self))
                                case .uInt32: value = bytes.loadUnaligned(fromByteOffset: index * 4, as: UInt32.self)
                                default: throw EarthUSDZArchiveReader.invalid()
                            }
                            guard value < vertices.count else { throw EarthUSDZArchiveReader.invalid() }
                            indices.append(value)
                        }
                        if normals == nil
                        {
                            vertices = try Self.flatVertices(vertices, indices: indices, maximumVertices: limits.maximumVertices - vertexCount)
                            indices = indices.indices.map { UInt32($0) }
                        }
                        try appearance.validateColors(mesh: ordinal, vertices: vertices, indices: indices, surface: surface, options: metadata.options)
                        let source = surface.material
                        let texture: EarthTexture?
                        if let path = surface.texturePath, let image = images[path]
                        { texture = EarthTexture(encodedImage: image.0, mimeType: image.3, width: image.1, height: image.2, wrapS: surface.wrapS, wrapT: surface.wrapT, usesNearestMagnification: false, usesNearestMinification: false, mipmapFilter: surface.mipmap) }
                        else { texture = nil }
                        let materialIndex = materials.count
                        materials.append(
                            EarthMaterial(name: source.name, baseColor: source.baseColor, baseColorTexture: texture, metallic: source.metallic, roughness: source.roughness, isUnlit: source.isUnlit, isDoubleSided: source.isDoubleSided, alphaMode: source.alphaMode, alphaCutoff: source.alphaCutoff)
                        )
                        meshes.append(EarthMesh(id: meshes.count, name: "Model \(model) - Mesh \(ordinal)", vertices: vertices, triangleIndices: indices, materialIndex: materialIndex))
                        vertexCount += vertices.count; indexCount += indices.count
                    }
                    for child in object.children.objects { try visit(child) }
                }
                for index in 0 ..< asset.count { try visit(asset.object(at: index)) }
                let expectedMeshes = appearances.values.reduce(0) { count, appearance in count + appearance.nodes.keys.filter { $0.hasPrefix("/Model/Geom/Mesh") }.count }
                guard meshes.count == expectedMeshes, indexCount / 3 == metadata.triangleCount, !meshes.isEmpty else { throw EarthUSDZArchiveReader.invalid() }
                return EarthCapture(
                    name: title,
                    meshes: meshes,
                    materials: materials,
                    bounds: EarthBounds(minimum: minimum, maximum: maximum),
                    geographicOrigin: metadata.geographicOrigin,
                    sourceFiles: [EarthSourceFile(relativePath: fileURL.lastPathComponent, data: try archive.originalBytes())],
                    rootSourcePath: fileURL.lastPathComponent,
                    attributions: metadata.attributions,
                    incompleteReason: metadata.preparationComplete && metadata.coversEntireSource ? nil : "The exported selection does not cover the complete source.",
                    preparationProfile: metadata.sourceProfile,
                    omittedDegenerateTriangleCount: 0,
                    identity: metadata.captureIdentity
                )
            }
        }
        catch is CancellationError { throw CancellationError() }
        catch let error as EarthImportError { throw error }
        catch { throw EarthImportError.invalidContent("The exported USDZ could not be read.") }
    }

    /// Missing normals mean flat faces. Native addNormals can leave zero normals
    /// on valid geometry; calculate from unchanged corners without native welding.
    private static func flatVertices(_ vertices: [EarthVertex], indices: [UInt32], maximumVertices: Int) throws -> [EarthVertex]
    {
        do { return try EarthFlatMesh.vertices(vertices, indices: indices, maximumVertices: maximumVertices) }
        catch EarthFlatMesh.Failure.capacity { throw EarthImportError.limitExceeded("Exported USDZ flat-normal vertex expansion.") }
        catch EarthFlatMesh.Failure.invalidGeometry { throw EarthImportError.invalidContent("The exported USDZ contains a zero-area triangle without normals.") }
    }

    private static func attribute(_ mesh: MDLMesh, name: String, components: Int) throws -> MDLVertexAttributeData
    {
        let format: MDLVertexFormat = components == 2 ? .float2 : components == 3 ? .float3 : .float4
        guard let data = mesh.vertexAttributeData(forAttributeNamed: name, as: format), data.stride >= components * 4,
              (mesh.vertexCount - 1) <= (Int.max - components * 4) / data.stride,
              (mesh.vertexCount - 1) * data.stride + components * 4 <= data.bufferSize
        else { throw EarthUSDZArchiveReader.invalid() }
        return data
    }

    private static func value(_ data: MDLVertexAttributeData, index: Int, components: Int) -> SIMD4<Float>
    {
        let pointer = data.dataStart.advanced(by: index * data.stride)
        var value = SIMD4<Float>.zero
        for component in 0 ..< components { value[component] = pointer.loadUnaligned(fromByteOffset: component * 4, as: Float.self) }
        return value
    }
}
