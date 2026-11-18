import Foundation

/// The USD writer flattens static mesh transforms and authors one material per
/// primitive. Admit only graphs and appearance whose semantics it represents.
enum EarthStaticGLBProfile
{
    static func validate(_ json: [String: Any], nodes: [[String: Any]], root: Int, meshes: [[String: Any]], earth: EarthCombinedGLBMetadata?) throws
    {
        let unsupported = EarthImportError.unsupportedContent("Outside the supported static GLB hierarchy, channels or material profile.")
        guard Set(json.keys).isSubset(of: ["asset", "extensionsUsed", "extensionsRequired", "scene", "scenes", "nodes", "meshes", "materials", "images", "textures", "samplers", "buffers", "bufferViews", "accessors", "extras"]),
              (json["scene"] as? Int ?? 0) == 0,
              let scenes = json["scenes"] as? [[String: Any]], scenes.allSatisfy({ Set($0.keys).isSubset(of: ["name", "nodes"]) }),
              let asset = json["asset"] as? [String: Any], Set(asset.keys).isSubset(of: ["version", "generator", "copyright"]),
              let materials = json["materials"] as? [[String: Any]]
        else { throw unsupported }
        for key in ["extensionsUsed", "extensionsRequired"] where json[key] != nil
        {
            guard let names = json[key] as? [String], names.allSatisfy({ $0 == "KHR_materials_unlit" }) else { throw unsupported }
        }
        let tableKeys: [String: Set<String>] = [
            "buffers": ["byteLength"], "bufferViews": ["buffer", "byteOffset", "byteLength", "byteStride", "target"],
            "accessors": ["bufferView", "byteOffset", "componentType", "count", "type", "min", "max", "normalized"],
            "images": ["bufferView", "mimeType"], "textures": ["sampler", "source"],
            "samplers": ["magFilter", "minFilter", "wrapS", "wrapT"],
        ]
        for (table, keys) in tableKeys where json[table] != nil
        {
            guard let entries = json[table] as? [[String: Any]], entries.allSatisfy({ Set($0.keys).isSubset(of: keys) }) else { throw unsupported }
        }
        let meshNodes = nodes.compactMap { $0["mesh"] as? Int }
        guard meshNodes.sorted() == Array(meshes.indices) else { throw unsupported }
        if let earth
        {
            let extras = json["extras"] as? [String: Any] ?? [:]
            guard Set(extras.keys).isSubset(of: ["messEarthKitCombinedAsset", "messEarthKitCaptureIdentity", "messEarthKitExportOptions", "messEarthKitTextureMode"]),
                  nodes.count == 1 + earth.selectedModels.count + meshes.count,
                  nodes.allSatisfy({ Set($0.keys).isSubset(of: $0["mesh"] == nil ? ["name", "children"] : ["name", "mesh"]) })
            else { throw unsupported }
        }
        else
        {
            guard json["extras"] == nil, meshes.count == 1, (1 ... 2).contains(nodes.count) else { throw unsupported }
            let leaf = nodes.count == 1 ? root : 1 - root
            guard nodes[leaf]["mesh"] as? Int == 0, Set(nodes[leaf].keys).isSubset(of: ["name", "mesh", "translation"]),
                  nodes.count == 1 || (nodes[root]["children"] as? [Int] == [leaf] && Set(nodes[root].keys).isSubset(of: ["name", "children", "translation"]))
            else { throw unsupported }
        }
        var bindings: [Int] = []
        for mesh in meshes
        {
            guard Set(mesh.keys).isSubset(of: ["name", "primitives"]), let primitives = mesh["primitives"] as? [[String: Any]] else { throw unsupported }
            for primitive in primitives
            {
                guard Set(primitive.keys).isSubset(of: ["mode", "attributes", "indices", "material"]),
                      let material = primitive["material"] as? Int else { throw unsupported }
                bindings.append(material)
            }
        }
        guard bindings.sorted() == Array(materials.indices) else { throw unsupported }
        for material in materials
        {
            guard Set(material.keys).isSubset(of: ["name", "extensions", "pbrMetallicRoughness", "alphaMode", "alphaCutoff", "doubleSided"]),
                  let extensions = material["extensions"] as? [String: Any], Set(extensions.keys) == ["KHR_materials_unlit"],
                  let unlit = extensions["KHR_materials_unlit"] as? [String: Any], unlit.isEmpty,
                  (material["alphaMode"] as? String ?? "OPAQUE") == "OPAQUE", (material["alphaCutoff"] as? Double ?? 0.5) == 0.5,
                  let pbr = material["pbrMetallicRoughness"] as? [String: Any],
                  Set(pbr.keys).isSubset(of: ["baseColorFactor", "baseColorTexture", "metallicFactor", "roughnessFactor"])
            else { throw unsupported }
            if let texture = pbr["baseColorTexture"] as? [String: Any]
            {
                guard Set(texture.keys).isSubset(of: ["index", "texCoord"]), (texture["texCoord"] as? Int ?? 0) == 0 else { throw unsupported }
            }
        }
        for sampler in json["samplers"] as? [[String: Any]] ?? []
        {
            guard (sampler["wrapS"] as? Int ?? 10497) == (sampler["wrapT"] as? Int ?? 10497) else { throw unsupported }
        }
    }
}
