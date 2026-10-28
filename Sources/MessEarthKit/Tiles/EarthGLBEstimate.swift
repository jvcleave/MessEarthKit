import Foundation
import ImageIO

/// Reads declared counts and image headers only. No native decoder, vertex
/// arrays, image rasterization, or GPU resources are created here.
struct EarthGLBEstimate
{
    let limits: EarthImportLimits

    func estimate(data: Data) throws -> EarthCaptureGeometryEstimate
    {
        let json = try EarthGLBDecoder(limits: limits).preflight(data: data, enforcesVertexBudget: false)
        let scenes = json["scenes"] as? [[String: Any]] ?? []
        let sceneIndex = json["scene"] as? Int ?? (scenes.count == 1 ? 0 : -1)
        guard scenes.indices.contains(sceneIndex) else { throw EarthImportError.unsupportedContent("A default scene or one unambiguous scene is required.") }
        let nodes = json["nodes"] as? [[String: Any]] ?? []
        let meshes = json["meshes"] as? [[String: Any]] ?? []
        let accessors = json["accessors"] as? [[String: Any]] ?? []
        var activeNodes = Set<Int>()
        var visited = 0
        var result = try EarthCaptureGeometryEstimate()

        func count(_ index: Int?) throws -> Int
        {
            guard let index, accessors.indices.contains(index), let value = accessors[index]["count"] as? Int, value > 0
            else { throw EarthImportError.invalidContent("Invalid geometry accessor in precheck.") }
            return value
        }

        func visit(_ index: Int, depth: Int) throws
        {
            try Task.checkCancellation()
            visited += 1
            guard nodes.indices.contains(index), depth < 64, visited <= limits.maximumNodes, activeNodes.insert(index).inserted
            else { throw EarthImportError.invalidContent("Invalid or cyclic GLB hierarchy in precheck.") }
            defer { activeNodes.remove(index) }
            let node = nodes[index]
            if let meshIndex = node["mesh"] as? Int
            {
                guard meshes.indices.contains(meshIndex) else { throw EarthImportError.invalidContent("Invalid mesh in precheck.") }
                for primitive in meshes[meshIndex]["primitives"] as? [[String: Any]] ?? []
                {
                    guard primitive["mode"] as? Int ?? 4 == 4 else { throw EarthImportError.unsupportedContent("Precheck requires triangle primitives.") }
                    let attributes = primitive["attributes"] as? [String: Any] ?? [:]
                    let positions = try count(attributes["POSITION"] as? Int)
                    let indices = try primitive["indices"].map { _ in try count(primitive["indices"] as? Int) } ?? positions
                    guard indices.isMultiple(of: 3) else { throw EarthImportError.invalidContent("Invalid triangle count in precheck.") }
                    let vertices = attributes["NORMAL"] == nil ? indices : positions
                    result = try result.adding(EarthCaptureGeometryEstimate(vertices: vertices, indices: indices))
                }
            }
            for child in node["children"] as? [Int] ?? [] { try visit(child, depth: depth + 1) }
        }

        for root in scenes[sceneIndex]["nodes"] as? [Int] ?? [] { try visit(root, depth: 0) }
        guard result.vertexCount > 0 else { throw EarthImportError.invalidContent("The selected scene has no triangle geometry.") }
        let textures = json["textures"] as? [[String: Any]] ?? []
        let images = json["images"] as? [[String: Any]] ?? []
        var textureBytes = 0
        var largestDimension = 0
        for material in json["materials"] as? [[String: Any]] ?? []
        {
            try Task.checkCancellation()
            guard let pbr = material["pbrMetallicRoughness"] as? [String: Any], let base = pbr["baseColorTexture"] as? [String: Any] else { continue }
            guard let textureIndex = base["index"] as? Int, textures.indices.contains(textureIndex),
                  let imageIndex = textures[textureIndex]["source"] as? Int, images.indices.contains(imageIndex)
            else { throw EarthImportError.invalidContent("Invalid base-color texture in precheck.") }
            let encoded = try imageData(images[imageIndex], json: json, data: data)
            guard let source = CGImageSourceCreateWithData(encoded as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
                  width > 0, height > 0
            else { throw EarthImportError.invalidContent("Invalid image header in precheck.") }
            textureBytes = try EarthCaptureGeometryEstimate.sum(textureBytes, EarthCaptureGeometryEstimate.product(EarthCaptureGeometryEstimate.product(width, height), 4))
            largestDimension = max(largestDimension, max(width, height))
        }
        return try EarthCaptureGeometryEstimate(vertices: result.vertexCount, indices: result.indexCount, textureBytes: textureBytes, textureDimension: largestDimension)
    }

    private func imageData(_ image: [String: Any], json: [String: Any], data: Data) throws -> Data
    {
        if let uri = image["uri"] as? String, let separator = uri.range(of: ";base64,"), let encoded = Data(base64Encoded: String(uri[separator.upperBound...]))
        { return encoded }
        let views = json["bufferViews"] as? [[String: Any]] ?? []
        guard let index = image["bufferView"] as? Int, views.indices.contains(index),
              views[index]["buffer"] as? Int ?? 0 == 0,
              let length = views[index]["byteLength"] as? Int, length > 0
        else { throw EarthImportError.invalidContent("Missing embedded image in precheck.") }
        let offset = views[index]["byteOffset"] as? Int ?? 0
        let jsonLength = Int(data.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: 12, as: UInt32.self)) })
        var chunk = 20 + jsonLength
        while chunk <= data.count - 8
        {
            try Task.checkCancellation()
            let words = data.withUnsafeBytes { bytes in (0 ..< 2).map { UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: chunk + $0 * 4, as: UInt32.self)) } }
            let count = Int(words[0])
            guard count <= data.count - chunk - 8 else { throw EarthImportError.invalidContent("Truncated GLB chunk in precheck.") }
            if words[1] == 0x004E4942
            {
                guard offset >= 0, offset <= count, length <= count - offset else { throw EarthImportError.invalidContent("Image exceeds its GLB buffer in precheck.") }
                return data.subdata(in: chunk + 8 + offset ..< chunk + 8 + offset + length)
            }
            chunk += 8 + count
        }
        throw EarthImportError.invalidContent("Missing GLB binary chunk in precheck.")
    }
}
