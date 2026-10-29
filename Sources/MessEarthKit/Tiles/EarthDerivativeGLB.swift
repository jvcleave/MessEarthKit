import Foundation
import simd

/// Internal static triangle derivative, not a public delivery-codec decision.
/// Node transforms, UV transforms, normals and reflected winding were baked by
/// the decoder; tile placement remains in the unchanged external tileset.
enum EarthDerivativeGLB
{
    static func encode(vertices: [EarthVertex], indices: [UInt32], material: EarthMaterial, name: String, attributions: [String], sourceID: String, preparationProfile: EarthPreparationProfile? = nil) throws -> Data
    {
        guard !vertices.isEmpty, !indices.isEmpty else { throw EarthImportError.invalidContent("Empty subdivision output.") }
        var binary = Data()
        func word(_ value: UInt32)
        {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { binary.append(contentsOf: $0) }
        }
        var minimum = vertices[0].position
        var maximum = minimum
        for (index, vertex) in vertices.enumerated()
        {
            if index.isMultiple(of: 4096) { try Task.checkCancellation() }
            minimum = simd_min(minimum, vertex.position)
            maximum = simd_max(maximum, vertex.position)
            for value in [vertex.position.x, vertex.position.y, vertex.position.z, vertex.normal.x, vertex.normal.y, vertex.normal.z, vertex.textureCoordinate.x, vertex.textureCoordinate.y, vertex.color.x, vertex.color.y, vertex.color.z, vertex.color.w]
            { word(value.bitPattern) }
        }
        let vertexLength = binary.count
        for (index, value) in indices.enumerated()
        {
            if index.isMultiple(of: 12288) { try Task.checkCancellation() }
            word(value)
        }
        let indexLength = binary.count - vertexLength
        var views: [[String: Any]] = [
            ["buffer": 0, "byteOffset": 0, "byteLength": vertexLength, "byteStride": 48, "target": 34962],
            ["buffer": 0, "byteOffset": vertexLength, "byteLength": indexLength, "target": 34963],
        ]
        var accessors: [[String: Any]] = []
        for (offset, type) in [(0, "VEC3"), (12, "VEC3"), (24, "VEC2"), (32, "VEC4")]
        { accessors.append(["bufferView": 0, "byteOffset": offset, "componentType": 5126, "count": vertices.count, "type": type]) }
        accessors[0]["min"] = [minimum.x, minimum.y, minimum.z]
        accessors[0]["max"] = [maximum.x, maximum.y, maximum.z]
        accessors.append(["bufferView": 1, "componentType": 5125, "count": indices.count, "type": "SCALAR"])
        var pbr: [String: Any] = ["baseColorFactor": [material.baseColor.x, material.baseColor.y, material.baseColor.z, material.baseColor.w], "metallicFactor": material.metallic, "roughnessFactor": material.roughness]
        let alpha: String
        switch material.alphaMode { case .opaque: alpha = "OPAQUE"; case .mask: alpha = "MASK"; case .blend: alpha = "BLEND" }
        var modelMaterial: [String: Any] = ["name": material.name, "alphaMode": alpha, "alphaCutoff": material.alphaCutoff, "doubleSided": material.isDoubleSided]
        if material.isUnlit { modelMaterial["extensions"] = ["KHR_materials_unlit": [:]] }
        var json: [String: Any] = [
            "asset": ["version": "2.0", "generator": "MessEarthKit geometry subdivision", "copyright": attributions.joined(separator: "; ")],
            "scene": 0, "scenes": [["nodes": [0]]], "nodes": [["mesh": 0, "name": name]],
            "meshes": [["name": name, "primitives": [["mode": 4, "attributes": ["POSITION": 0, "NORMAL": 1, "TEXCOORD_0": 2, "COLOR_0": 3], "indices": 4, "material": 0]]]],
            "accessors": accessors, "extras": ["messEarthKitDerivative": ["version": 1, "sourcePayload": sourceID]],
        ]
        if let preparationProfile
        {
            var extras = json["extras"] as! [String: Any]
            extras["messEarthKitPreparation"] = ["profile": try JSONSerialization.jsonObject(with: JSONEncoder().encode(preparationProfile))]
            json["extras"] = extras
        }
        if material.isUnlit { json["extensionsUsed"] = ["KHR_materials_unlit"] }
        if let image = material.baseColorTexture
        {
            let offset = binary.count
            binary.append(image.encodedImage)
            views.append(["buffer": 0, "byteOffset": offset, "byteLength": image.encodedImage.count])
            json["images"] = [["bufferView": 2, "mimeType": image.mimeType]]
            func wrap(_ value: EarthTextureWrap) -> Int
            { switch value { case .repeatTexture: 10497; case .mirroredRepeat: 33648; case .clampToEdge: 33071 } }
            let minFilter: Int
            switch image.mipmapFilter
            {
                case .none: minFilter = image.usesNearestMinification ? 9728 : 9729
                case .nearest: minFilter = image.usesNearestMinification ? 9984 : 9985
                case .linear: minFilter = image.usesNearestMinification ? 9986 : 9987
            }
            json["samplers"] = [["wrapS": wrap(image.wrapS), "wrapT": wrap(image.wrapT), "magFilter": image.usesNearestMagnification ? 9728 : 9729, "minFilter": minFilter]]
            json["textures"] = [["source": 0, "sampler": 0]]
            pbr["baseColorTexture"] = ["index": 0, "texCoord": 0]
        }
        while !binary.count.isMultiple(of: 4) { binary.append(0) }
        modelMaterial["pbrMetallicRoughness"] = pbr
        json["materials"] = [modelMaterial]
        json["buffers"] = [["byteLength": binary.count]]
        json["bufferViews"] = views
        var encoded = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys, .withoutEscapingSlashes])
        while !encoded.count.isMultiple(of: 4) { encoded.append(32) }
        let total = try EarthCaptureGeometryEstimate.sum(28, EarthCaptureGeometryEstimate.sum(encoded.count, binary.count))
        guard total <= Int(UInt32.max) else { throw EarthPreparationError.subdivisionWorkingSet }
        var output = Data()
        func outputWord(_ value: UInt32)
        { var little = value.littleEndian; withUnsafeBytes(of: &little) { output.append(contentsOf: $0) } }
        for value in [UInt32(0x46546C67), 2, UInt32(total), UInt32(encoded.count), 0x4E4F534A] { outputWord(value) }
        output.append(encoded)
        outputWord(UInt32(binary.count)); outputWord(0x004E4942)
        output.append(binary)
        return output
    }
}
