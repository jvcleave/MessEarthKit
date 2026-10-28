import EarthDracoBridge
import Foundation
import GLTFKit2
import ImageIO
import simd

struct EarthGLBPart
{
    var meshes: [EarthMesh] = []
    var materials: [EarthMaterial] = []
    var attributions: [String] = []
    var vertexCount = 0
}

/// All native objects are created, traversed, and released within the import worker.
struct EarthGLBDecoder
{
    let limits: EarthImportLimits

    func decode(
        data: Data,
        transform: simd_double4x4
    ) throws -> EarthGLBPart
    {
        try preflight(data: data)
        EarthInstallDracoDecoder()
        let asset: GLTFAsset
        do
        {
            asset = try GLTFAsset(data: data, options: [:])
        }
        catch
        {
            throw EarthImportError.invalidContent("The native GLB decoder rejected this payload.")
        }
        guard let scene = asset.defaultScene ?? (asset.scenes.count == 1 ? asset.scenes.first : nil)
        else { throw EarthImportError.unsupportedContent("A default scene or one unambiguous scene is required.") }
        var part = EarthGLBPart()
        if let copyright = asset.copyright, !copyright.isEmpty { part.attributions.append(copyright) }
        var materialIndices: [ObjectIdentifier: Int] = [:]
        var textureBytes = 0
        for material in asset.materials
        {
            materialIndices[ObjectIdentifier(material)] = part.materials.count
            let value = try makeMaterial(material: material)
            if let texture = value.baseColorTexture
            {
                let bytes = texture.width * texture.height * 4
                guard bytes <= limits.maximumDecodedTextureBytes - textureBytes
                else { throw EarthImportError.limitExceeded("GLB decoded texture bytes.") }
                textureBytes += bytes
            }
            part.materials.append(value)
        }
        var visitedNodes = 0
        var activeNodes: Set<ObjectIdentifier> = []
        for node in scene.nodes
        {
            try appendNode(node: node, parentTransform: transform, depth: 0, visitedNodes: &visitedNodes, activeNodes: &activeNodes, materialIndices: materialIndices, part: &part)
        }
        guard !part.meshes.isEmpty
        else { throw EarthImportError.invalidContent("The selected scene has no triangle geometry.") }
        return part
    }

    private func preflight(data: Data) throws
    {
        guard data.count >= 20, data.count <= limits.maximumSourceBytes
        else { throw EarthImportError.invalidContent("GLB header or file size is invalid.") }
        let header = data.withUnsafeBytes
        { bytes in
            (0 ..< 5).map { UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: $0 * 4, as: UInt32.self)) }
        }
        guard header[0] == 0x46546C67, header[1] == 2, header[2] == data.count,
              header[4] == 0x4E4F534A, header[3] <= 16 * 1024 * 1024,
              Int(header[3]) <= data.count - 20
        else { throw EarthImportError.invalidContent("Expected a complete glTF 2.0 binary with a JSON chunk.") }
        guard let json = try JSONSerialization.jsonObject(with: data.subdata(in: 20 ..< 20 + Int(header[3]))) as? [String: Any],
              let asset = json["asset"] as? [String: Any], asset["version"] as? String == "2.0"
        else { throw EarthImportError.invalidContent("GLB asset metadata is invalid.") }
        let supportedExtensions: Set<String> = ["KHR_materials_unlit", "KHR_texture_transform", "KHR_mesh_quantization", "KHR_draco_mesh_compression"]
        let extensions = Set((json["extensionsUsed"] as? [String] ?? []) + (json["extensionsRequired"] as? [String] ?? []))
        if let unsupported = extensions.subtracting(supportedExtensions).sorted().first
        {
            throw EarthImportError.unsupportedContent("glTF extension \(unsupported).")
        }
        for field in ["animations", "skins"]
        {
            if let values = json[field] as? [Any], !values.isEmpty
            {
                throw EarthImportError.unsupportedContent("Animated or skinned assets are outside the static capture adapter.")
            }
        }
        for buffer in json["buffers"] as? [[String: Any]] ?? []
        {
            guard buffer["uri"] == nil
            else { throw EarthImportError.unsupportedContent("GLBs must contain their binary buffers.") }
        }
        for image in json["images"] as? [[String: Any]] ?? []
        {
            if let uri = image["uri"] as? String, !uri.hasPrefix("data:")
            {
                throw EarthImportError.unsupportedContent("GLB textures must be embedded; external resource URLs are not read.")
            }
        }
        for sampler in json["samplers"] as? [[String: Any]] ?? []
        {
            guard sampler["magFilter"] == nil || [9728, 9729].contains(sampler["magFilter"] as? Int ?? 0),
                  sampler["minFilter"] == nil || [9728, 9729, 9984, 9985, 9986, 9987].contains(sampler["minFilter"] as? Int ?? 0)
            else { throw EarthImportError.unsupportedContent("Unknown texture filter.") }
        }
        for field in ["nodes", "meshes", "materials", "images", "accessors"]
        {
            guard (json[field] as? [Any] ?? []).count <= limits.maximumNodes
            else { throw EarthImportError.limitExceeded("GLB \(field) count.") }
        }
        let primitiveCount = (json["meshes"] as? [[String: Any]] ?? []).reduce(0) { $0 + ($1["primitives"] as? [Any] ?? []).count }
        guard primitiveCount <= limits.maximumNodes else { throw EarthImportError.limitExceeded("GLB primitive count.") }
        for accessor in json["accessors"] as? [[String: Any]] ?? []
        {
            guard let count = accessor["count"] as? Int, count > 0, count <= limits.maximumVertices * 3
            else { throw EarthImportError.limitExceeded("GLB accessor element count.") }
        }
    }

    private func appendNode(
        node: GLTFNode,
        parentTransform: simd_double4x4,
        depth: Int,
        visitedNodes: inout Int,
        activeNodes: inout Set<ObjectIdentifier>,
        materialIndices: [ObjectIdentifier: Int],
        part: inout EarthGLBPart
    ) throws
    {
        try Task.checkCancellation()
        visitedNodes += 1
        let identity = ObjectIdentifier(node)
        guard depth < 64, visitedNodes <= limits.maximumNodes, activeNodes.insert(identity).inserted
        else { throw EarthImportError.invalidContent("GLB hierarchy is cyclic or exceeds the node/depth budget.") }
        defer { activeNodes.remove(identity) }
        guard node.skin == nil, node.meshInstances == nil, node.weights == nil
        else { throw EarthImportError.unsupportedContent("Skinning, instancing, and morph weights are not supported.") }
        let matrix = node.matrix
        let transform = parentTransform * simd_double4x4(columns: (
            SIMD4<Double>(matrix.columns.0),
            SIMD4<Double>(matrix.columns.1),
            SIMD4<Double>(matrix.columns.2),
            SIMD4<Double>(matrix.columns.3)
        ))
        let linear = simd_double3x3(columns: (
            SIMD3(transform.columns.0.x, transform.columns.0.y, transform.columns.0.z),
            SIMD3(transform.columns.1.x, transform.columns.1.y, transform.columns.1.z),
            SIMD3(transform.columns.2.x, transform.columns.2.y, transform.columns.2.z)
        ))
        let determinant = simd_determinant(linear)
        guard determinant.isFinite, abs(determinant) > 1e-12,
              transform.columns.0.w == 0, transform.columns.1.w == 0,
              transform.columns.2.w == 0, transform.columns.3.w == 1
        else { throw EarthImportError.invalidContent("Node transform is singular or non-affine.") }
        if let mesh = node.mesh
        {
            for primitive in mesh.primitives
            {
                guard primitive.primitiveType == .triangles, primitive.targets.isEmpty,
                      let positionAccessor = primitive.attribute(forName: "POSITION")?.accessor
                else { throw EarthImportError.unsupportedContent("Only static triangle primitives are supported.") }
                let positions = try EarthAccessorReader.readFloats(accessor: positionAccessor, dimension: .vector3, componentCount: 3, maximumCount: limits.maximumVertices)
                let count = positionAccessor.count
                let indices: [UInt32]
                if let indexAccessor = primitive.indices
                {
                    indices = try EarthAccessorReader.readIndices(accessor: indexAccessor, vertexCount: count, maximumCount: limits.maximumVertices * 3)
                }
                else
                {
                    indices = (0 ..< count).map { UInt32($0) }
                }
                guard indices.count.isMultiple(of: 3)
                else { throw EarthImportError.invalidContent("Triangle index count must be a multiple of three.") }
                let normals: [Float]?
                if let accessor = primitive.attribute(forName: "NORMAL")?.accessor
                {
                    guard accessor.count == count else { throw EarthImportError.invalidContent("Normal count differs from positions.") }
                    normals = try EarthAccessorReader.readFloats(accessor: accessor, dimension: .vector3, componentCount: 3, maximumCount: limits.maximumVertices)
                }
                else { normals = nil }
                let textureParams = primitive.material?.metallicRoughness?.baseColorTexture
                let coordinateSet = textureParams?.transform?.hasTexCoord == true ? Int(textureParams?.transform?.texCoord ?? 0) : textureParams?.texCoord ?? 0
                var coordinates = [Float](repeating: 0, count: count * 2)
                if let accessor = primitive.attribute(forName: "TEXCOORD_\(coordinateSet)")?.accessor
                {
                    guard accessor.count == count else { throw EarthImportError.invalidContent("UV count differs from positions.") }
                    coordinates = try EarthAccessorReader.readFloats(accessor: accessor, dimension: .vector2, componentCount: 2, maximumCount: limits.maximumVertices)
                }
                else if textureParams != nil
                {
                    throw EarthImportError.invalidContent("Material UV set is missing.")
                }
                var colors = [Float](repeating: 1, count: count * 4)
                if let accessor = primitive.attribute(forName: "COLOR_0")?.accessor
                {
                    let dimension = accessor.dimension == .vector3 ? 3 : 4
                    guard accessor.count == count else { throw EarthImportError.invalidContent("Color count differs from positions.") }
                    let values = try EarthAccessorReader.readFloats(accessor: accessor, dimension: dimension == 3 ? .vector3 : .vector4, componentCount: dimension, maximumCount: limits.maximumVertices)
                    for index in 0 ..< count
                    {
                        for component in 0 ..< dimension { colors[index * 4 + component] = values[index * dimension + component] }
                    }
                }
                let normalTransform = simd_transpose(simd_inverse(linear))
                let uvTransform = textureParams?.transform?.matrix ?? matrix_identity_float4x4
                var vertices: [EarthVertex] = []
                vertices.reserveCapacity(count)
                for index in 0 ..< count
                {
                    if index.isMultiple(of: 4096) { try Task.checkCancellation() }
                    let position = transform * SIMD4<Double>(Double(positions[index * 3]), Double(positions[index * 3 + 1]), Double(positions[index * 3 + 2]), 1)
                    let localPosition = SIMD3<Float>(Float(position.x), Float(position.y), Float(position.z))
                    guard localPosition.x.isFinite, localPosition.y.isFinite, localPosition.z.isFinite
                    else { throw EarthImportError.invalidContent("Transformed geometry contains non-finite positions.") }
                    var normal = SIMD3<Float>(0, 1, 0)
                    if let normals
                    {
                        let transformed = normalTransform * SIMD3<Double>(Double(normals[index * 3]), Double(normals[index * 3 + 1]), Double(normals[index * 3 + 2]))
                        guard simd_length_squared(transformed) > 1e-20
                        else { throw EarthImportError.invalidContent("Geometry contains a zero normal.") }
                        normal = SIMD3<Float>(simd_normalize(transformed))
                    }
                    let uv = uvTransform * SIMD4(coordinates[index * 2], coordinates[index * 2 + 1], 0, 1)
                    guard uv.x.isFinite, uv.y.isFinite
                    else { throw EarthImportError.invalidContent("Transformed texture coordinates are non-finite.") }
                    vertices.append(EarthVertex(position: localPosition, normal: normal, textureCoordinate: SIMD2(uv.x, uv.y), color: SIMD4(colors[index * 4], colors[index * 4 + 1], colors[index * 4 + 2], colors[index * 4 + 3])))
                }
                var triangleIndices = indices
                if determinant < 0
                {
                    for index in stride(from: 0, to: triangleIndices.count, by: 3) { triangleIndices.swapAt(index + 1, index + 2) }
                }
                if normals == nil
                {
                    guard indices.count <= limits.maximumVertices else { throw EarthImportError.limitExceeded("Flat-normal vertex expansion.") }
                    var flatVertices: [EarthVertex] = []
                    flatVertices.reserveCapacity(indices.count)
                    for index in stride(from: 0, to: triangleIndices.count, by: 3)
                    {
                        if index.isMultiple(of: 4096) { try Task.checkCancellation() }
                        let triangle = (0 ..< 3).map { vertices[Int(triangleIndices[index + $0])] }
                        let cross = simd_cross(triangle[1].position - triangle[0].position, triangle[2].position - triangle[0].position)
                        guard simd_length_squared(cross) > 1e-20
                        else { throw EarthImportError.invalidContent("Cannot generate a normal for a degenerate triangle.") }
                        for vertex in triangle { flatVertices.append(EarthVertex(position: vertex.position, normal: simd_normalize(cross), textureCoordinate: vertex.textureCoordinate, color: vertex.color)) }
                    }
                    vertices = flatVertices
                    triangleIndices = (0 ..< vertices.count).map { UInt32($0) }
                }
                let materialIndex: Int
                if let material = primitive.material
                {
                    guard let index = materialIndices[ObjectIdentifier(material)]
                    else { throw EarthImportError.invalidContent("Primitive material is not part of the asset.") }
                    materialIndex = index
                }
                else
                {
                    materialIndex = part.materials.count
                    part.materials.append(EarthMaterial(name: "Default", baseColor: SIMD4(repeating: 1), baseColorTexture: nil, metallic: 1, roughness: 1, isUnlit: false, isDoubleSided: false, alphaMode: .opaque, alphaCutoff: 0.5))
                }
                guard vertices.count <= limits.maximumVertices - part.vertexCount
                else { throw EarthImportError.limitExceeded("Prepared vertex count.") }
                part.meshes.append(EarthMesh(id: part.meshes.count, name: node.name ?? mesh.name ?? "Mesh \(part.meshes.count + 1)", vertices: vertices, triangleIndices: triangleIndices, materialIndex: materialIndex))
                part.vertexCount += vertices.count
            }
        }
        for child in node.childNodes
        {
            try appendNode(node: child, parentTransform: transform, depth: depth + 1, visitedNodes: &visitedNodes, activeNodes: &activeNodes, materialIndices: materialIndices, part: &part)
        }
    }

    private func makeMaterial(material: GLTFMaterial) throws -> EarthMaterial
    {
        guard material.specularGlossiness == nil, material.normalTexture == nil,
              material.occlusionTexture == nil, material.metallicRoughness?.metallicRoughnessTexture == nil,
              material.specular == nil, material.transmission == nil, material.diffuseTransmission == nil,
              material.volume == nil, material.clearcoat == nil, material.sheen == nil,
              material.iridescence == nil, material.anisotropy == nil,
              material.indexOfRefraction == nil, material.dispersion == nil,
              material.emissive?.emissiveTexture == nil,
              (material.emissive?.emissiveFactor ?? .zero) == .zero
        else { throw EarthImportError.unsupportedContent("The initial material adapter supports base-color textures and factors; additional material maps require a verified mapping.") }
        let texture: EarthTexture?
        if let params = material.metallicRoughness?.baseColorTexture
        {
            guard let image = params.texture.source
            else { throw EarthImportError.invalidContent("Base-color texture has no source image.") }
            let dataURIMime = image.uri?.absoluteString.split(separator: ";", maxSplits: 1).first.map { String($0.dropFirst(5)) }
            guard let mime = image.mimeType ?? dataURIMime, ["image/png", "image/jpeg"].contains(mime)
            else { throw EarthImportError.unsupportedContent("Base-color textures must be embedded PNG or JPEG images.") }
            let encoded: Data
            if let view = image.bufferView, let buffer = view.buffer.data,
               view.offset >= 0, view.length > 0, view.offset <= buffer.count, view.length <= buffer.count - view.offset
            {
                encoded = buffer.subdata(in: view.offset ..< view.offset + view.length)
            }
            else if let uri = image.uri?.absoluteString,
                    let separator = uri.range(of: ";base64,"),
                    let data = Data(base64Encoded: String(uri[separator.upperBound...]))
            {
                encoded = data
            }
            else { throw EarthImportError.invalidContent("Embedded image payload is missing.") }
            guard let source = CGImageSourceCreateWithData(encoded as CFData, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int,
                  width > 0, height > 0, width <= limits.maximumTextureDimension, height <= limits.maximumTextureDimension,
                  width <= limits.maximumDecodedTextureBytes / 4 / height
            else { throw EarthImportError.limitExceeded("Invalid image or texture dimensions exceed the budget.") }
            let sampler = params.texture.sampler
            let nearestMinification: Bool
            let mipmapFilter: EarthMipmapFilter
            // glTF permits omitted filters. GLTFKit2 represents an omitted
            // minFilter as zero; explicit invalid values were rejected above.
            let minification = sampler?.minMipFilter ?? .linearLinear
            switch minification.rawValue == 0 ? GLTFMinMipFilter.linearLinear : minification
            {
                case .nearest: nearestMinification = true; mipmapFilter = .none
                case .linear: nearestMinification = false; mipmapFilter = .none
                case .nearestNearest: nearestMinification = true; mipmapFilter = .nearest
                case .linearNearest: nearestMinification = false; mipmapFilter = .nearest
                case .nearestLinear: nearestMinification = true; mipmapFilter = .linear
                case .linearLinear: nearestMinification = false; mipmapFilter = .linear
                default: throw EarthImportError.unsupportedContent("Unknown texture minification filter.")
            }
            texture = EarthTexture(
                encodedImage: encoded,
                mimeType: mime,
                width: width,
                height: height,
                wrapS: try wrapMode(mode: sampler?.wrapS ?? .repeat),
                wrapT: try wrapMode(mode: sampler?.wrapT ?? .repeat),
                usesNearestMagnification: sampler?.magFilter == .nearest,
                usesNearestMinification: nearestMinification,
                mipmapFilter: mipmapFilter
            )
        }
        else { texture = nil }
        let mode: EarthAlphaMode
        switch material.alphaMode
        {
            case .opaque: mode = .opaque
            case .mask: mode = .mask
            case .blend: mode = .blend
            default: throw EarthImportError.unsupportedContent("Unknown material alpha mode.")
        }
        let color = material.metallicRoughness?.baseColorFactor ?? SIMD4<Float>(repeating: 1)
        let metallic = material.metallicRoughness?.metallicFactor ?? 1
        let roughness = material.metallicRoughness?.roughnessFactor ?? 1
        guard color.x.isFinite, color.y.isFinite, color.z.isFinite, color.w.isFinite,
              [color.x, color.y, color.z, color.w].allSatisfy({ (0 ... 1).contains($0) }),
              (0 ... 1).contains(metallic), (0 ... 1).contains(roughness),
              material.alphaCutoff.isFinite, material.alphaCutoff >= 0
        else { throw EarthImportError.invalidContent("Material factors are invalid.") }
        return EarthMaterial(name: material.name ?? "Material", baseColor: color, baseColorTexture: texture, metallic: metallic, roughness: roughness, isUnlit: material.isUnlit, isDoubleSided: material.isDoubleSided, alphaMode: mode, alphaCutoff: material.alphaCutoff)
    }

    private func wrapMode(mode: GLTFAddressMode) throws -> EarthTextureWrap
    {
        switch mode
        {
            case .repeat: .repeatTexture
            case .mirroredRepeat: .mirroredRepeat
            case .clampToEdge: .clampToEdge
            default: throw EarthImportError.unsupportedContent("Unknown texture wrap mode.")
        }
    }
}
