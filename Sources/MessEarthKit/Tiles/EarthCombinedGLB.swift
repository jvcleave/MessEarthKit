import Foundation
import simd

struct EarthCombinedGLBMetadata: Codable
{
    let formatVersion: Int
    let sourceIdentifier: String
    let geographicOrigin: EarthGeographicOrigin
    let sourceProfile: EarthPreparationProfile
    let destinationProfile: EarthPreparationProfile
    let selectedModels: [Int]
    let coversEntireSource: Bool
    let preparationComplete: Bool
    let preparationIssue: String?
    let attributions: [String]

    static func read(json: [String: Any], maximumEntries: Int = 4096) throws -> Self?
    {
        guard let extras = json["extras"] as? [String: Any], let value = extras["messEarthKitCombinedAsset"] else { return nil }
        do
        {
            // Admission precedes Codable arrays and the uniqueness Set. Large
            // extras must obey the caller's object budget just like glTF nodes.
            guard let object = value as? [String: Any],
                  let ids = object["selectedModels"] as? [Any], ids.count <= maximumEntries,
                  let notices = object["attributions"] as? [Any], notices.count <= maximumEntries
            else { throw EarthImportError.invalidContent("Combined-asset metadata exceeds its object budget.") }
            let metadata = try JSONDecoder().decode(Self.self, from: JSONSerialization.data(withJSONObject: value))
            guard metadata.formatVersion == 1, metadata.sourceIdentifier.count == 64,
                  metadata.sourceIdentifier.allSatisfy({ $0.isASCII && ($0.isNumber || ("a" ... "f").contains(String($0))) }),
                  !metadata.selectedModels.isEmpty, metadata.selectedModels.allSatisfy({ $0 > 0 }),
                  Set(metadata.selectedModels).count == metadata.selectedModels.count,
                  metadata.preparationComplete || (!metadata.coversEntireSource && metadata.preparationIssue?.isEmpty == false),
                  (metadata.preparationIssue?.count ?? 0) <= 512
            else { throw EarthImportError.invalidContent("Invalid combined-asset metadata.") }
            return metadata
        }
        catch { throw EarthImportError.invalidContent("Invalid combined-asset metadata.") }
    }
}

/// Bounded metadata for an uncompressed GLB. Each mesh has independent accessors
/// and indices; all coordinates are already in the collection's shared frame.
/// Binary payloads are counted here and written in the same order on export.
final class EarthCombinedGLB
{
    let profile: EarthPreparationProfile
    private let options: EarthGLBExportOptions
    private let identity: EarthCaptureIdentity?
    private(set) var binaryByteCount = 0
    private(set) var estimate: EarthCaptureGeometryEstimate
    private var meshes: [[String: Any]] = []
    private var nodes: [[String: Any]] = []
    private var roots: [Int] = []
    private var materials: [[String: Any]] = []
    private var accessors: [[String: Any]] = []
    private var views: [[String: Any]] = []
    private var images: [[String: Any]] = []
    private var textures: [[String: Any]] = []
    private var samplers: [[String: Any]] = []
    private var attributions = Set<String>()
    private var usesUnlit = false
    private var metadataBytes = 4096
    private var omittedDegenerateTriangleCount = 0

    // Confined to one actor-owned export job; never returned or shared.
    init(profile: EarthPreparationProfile, options: EarthGLBExportOptions, identity: EarthCaptureIdentity?) throws
    {
        self.profile = profile
        self.options = options
        self.identity = identity
        estimate = try EarthCaptureGeometryEstimate()
    }

    func append(_ capture: EarthCapture, modelID: Int) throws
    {
        try Task.checkCancellation()
        let materialOffset = materials.count
        let root = nodes.count
        roots.append(root)
        nodes.append([:])
        var children: [Int] = []
        var geometry = try EarthCaptureGeometryEstimate()
        var attributeLayout = [(offset: 0, semantic: "POSITION", type: "VEC3")]
        var offset = 12
        if options.includeNormals { attributeLayout.append((offset, "NORMAL", "VEC3")); offset += 12 }
        if options.includeTextureCoordinates { attributeLayout.append((offset, "TEXCOORD_0", "VEC2")); offset += 8 }
        if options.includeVertexColors { attributeLayout.append((offset, "COLOR_0", "VEC4")) }
        for mesh in capture.meshes
        {
            try Task.checkCancellation()
            guard capture.materials.indices.contains(mesh.materialIndex), let first = mesh.vertices.first else { throw EarthGLBExportError.sourceChanged }
            let vertexBytes = try EarthCaptureGeometryEstimate.product(mesh.vertices.count, options.vertexByteStride)
            let indexBytes = try EarthCaptureGeometryEstimate.product(mesh.triangleIndices.count, 4)
            let vertexView = views.count
            try record(["buffer": 0, "byteOffset": binaryByteCount, "byteLength": vertexBytes, "byteStride": options.vertexByteStride, "target": 34962], in: &views)
            binaryByteCount = try EarthCaptureGeometryEstimate.sum(binaryByteCount, vertexBytes)
            let indexView = views.count
            try record(["buffer": 0, "byteOffset": binaryByteCount, "byteLength": indexBytes, "target": 34963], in: &views)
            binaryByteCount = try EarthCaptureGeometryEstimate.sum(binaryByteCount, indexBytes)
            var minimum = first.position
            var maximum = minimum
            for (ordinal, vertex) in mesh.vertices.enumerated()
            {
                if ordinal.isMultiple(of: 4096) { try Task.checkCancellation() }
                minimum = simd_min(minimum, vertex.position)
                maximum = simd_max(maximum, vertex.position)
            }
            var attributes: [String: Int] = [:]
            for attribute in attributeLayout
            {
                var value: [String: Any] = ["bufferView": vertexView, "byteOffset": attribute.offset, "componentType": 5126, "count": mesh.vertices.count, "type": attribute.type]
                if attribute.semantic == "POSITION" { value["min"] = [minimum.x, minimum.y, minimum.z]; value["max"] = [maximum.x, maximum.y, maximum.z] }
                attributes[attribute.semantic] = accessors.count
                try record(value, in: &accessors)
            }
            let indexAccessor = accessors.count
            try record(["bufferView": indexView, "componentType": 5125, "count": mesh.triangleIndices.count, "type": "SCALAR"], in: &accessors)
            let meshIndex = meshes.count
            var primitive: [String: Any] = ["mode": 4, "attributes": attributes, "indices": indexAccessor]
            if options.includeMaterials { primitive["material"] = materialOffset + mesh.materialIndex }
            try record(["name": mesh.name, "primitives": [primitive]], in: &meshes)
            children.append(nodes.count)
            try record(["mesh": meshIndex, "name": mesh.name], in: &nodes)
            geometry = try geometry.adding(EarthCaptureGeometryEstimate(vertices: mesh.vertices.count, indices: mesh.triangleIndices.count))
        }
        let modelNode: [String: Any] = ["name": "Model \(modelID)", "children": children]
        try consume(modelNode)
        nodes[root] = modelNode
        var textureBytes = 0
        var largestTexture = 0
        for material in capture.materials where options.includeMaterials
        {
            var pbr: [String: Any] = ["baseColorFactor": [material.baseColor.x, material.baseColor.y, material.baseColor.z, material.baseColor.w], "metallicFactor": material.metallic, "roughnessFactor": material.roughness]
            var encoded: [String: Any] = ["name": material.name, "doubleSided": material.isDoubleSided, "alphaCutoff": material.alphaCutoff]
            switch material.alphaMode { case .opaque: encoded["alphaMode"] = "OPAQUE"; case .mask: encoded["alphaMode"] = "MASK"; case .blend: encoded["alphaMode"] = "BLEND" }
            if material.isUnlit { encoded["extensions"] = ["KHR_materials_unlit": [:]]; usesUnlit = true }
            if options.includeTextures, let image = material.baseColorTexture
            {
                let imageIndex = images.count
                let view = views.count
                try record(["buffer": 0, "byteOffset": binaryByteCount, "byteLength": image.encodedImage.count], in: &views)
                binaryByteCount = try EarthCaptureGeometryEstimate.sum(binaryByteCount, Self.aligned(image.encodedImage.count))
                try record(["bufferView": view, "mimeType": image.mimeType], in: &images)
                try record(Self.sampler(image), in: &samplers)
                try record(["source": imageIndex, "sampler": imageIndex], in: &textures)
                pbr["baseColorTexture"] = ["index": imageIndex, "texCoord": 0]
                textureBytes = try EarthCaptureGeometryEstimate.sum(textureBytes, EarthCaptureGeometryEstimate.product(EarthCaptureGeometryEstimate.product(image.width, image.height), 4))
                largestTexture = max(largestTexture, max(image.width, image.height))
            }
            encoded["pbrMetallicRoughness"] = pbr
            try record(encoded, in: &materials)
        }
        geometry = try geometry.adding(EarthCaptureGeometryEstimate(textureBytes: textureBytes, textureDimension: largestTexture))
        estimate = try estimate.adding(geometry)
        guard profile.accepts(estimate) else { throw EarthGLBExportError.requirements(["Decoded models exceed the destination's combined geometry or texture budget."]) }
        for value in capture.attributions where attributions.insert(value).inserted { try consume(["copyright": value]) }
        omittedDegenerateTriangleCount = try EarthCaptureGeometryEstimate.sum(omittedDegenerateTriangleCount, capture.omittedDegenerateTriangleCount)
    }

    func finish(collection: EarthPreparedCollection, modelIDs: [Int], coversEntireSource: Bool) throws -> Data
    {
        // Include the shared root in the destination's node budget.
        guard nodes.count < profile.maximumNodesPerPayload else { throw EarthGLBExportError.requirements(["The combined scene exceeds the destination's node budget."]) }
        let sharedRoot = nodes.count
        let name = identity?.locationName ?? "Earth Models"
        try record(["name": name, "children": roots], in: &nodes)
        let metadata = EarthCombinedGLBMetadata(
            formatVersion: 1,
            sourceIdentifier: collection.sourceIdentifier,
            geographicOrigin: collection.geographicOrigin,
            sourceProfile: collection.profile,
            destinationProfile: profile,
            selectedModels: modelIDs,
            coversEntireSource: coversEntireSource,
            preparationComplete: collection.state == .ready,
            preparationIssue: collection.state == .ready ? nil : String((collection.interruptionReason ?? "Model preparation is incomplete.").prefix(512)),
            attributions: attributions.sorted()
        )
        var json: [String: Any] = [
            "asset": ["version": "2.0", "generator": "MessEarthKit combined export", "copyright": attributions.sorted().joined(separator: "; ")],
            "scene": 0, "scenes": [["name": name, "nodes": [sharedRoot]]], "nodes": nodes,
            "meshes": meshes, "accessors": accessors,
            "buffers": [["byteLength": binaryByteCount]], "bufferViews": views,
            "extras": [
                "messEarthKitCombinedAsset": try JSONSerialization.jsonObject(with: JSONEncoder().encode(metadata)),
                "messEarthKitTextureMode": options.includeTextures ? "included" : "omitted",
                "messEarthKitExportOptions": try JSONSerialization.jsonObject(with: JSONEncoder().encode(options)),
            ],
        ]
        if !materials.isEmpty { json["materials"] = materials }
        if !images.isEmpty { json["images"] = images; json["textures"] = textures; json["samplers"] = samplers }
        if usesUnlit { json["extensionsUsed"] = ["KHR_materials_unlit"] }
        if let identity
        {
            var extras = json["extras"] as! [String: Any]
            extras["messEarthKitCaptureIdentity"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(identity))
            json["extras"] = extras
        }
        if omittedDegenerateTriangleCount > 0
        {
            var extras = json["extras"] as! [String: Any]
            extras["messEarthKitOmittedDegenerateTriangleCount"] = omittedDegenerateTriangleCount
            json["extras"] = extras
        }
        var data = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys, .withoutEscapingSlashes])
        while !data.count.isMultiple(of: 4) { data.append(32) }
        guard data.count <= 16 * 1024 * 1024 else { throw EarthGLBExportError.requirements(["Combined scene metadata exceeds the importer's 16 MiB JSON working set."]) }
        return data
    }

    private func record(_ value: [String: Any], in array: inout [[String: Any]]) throws
    {
        try consume(value)
        guard array.count < profile.maximumNodesPerPayload else { throw EarthGLBExportError.requirements(["The combined scene exceeds the destination's object/accessor budget."]) }
        array.append(value)
    }

    private func consume(_ value: [String: Any]) throws
    {
        metadataBytes = try EarthCaptureGeometryEstimate.sum(metadataBytes, JSONSerialization.data(withJSONObject: value).count + 1)
        guard metadataBytes <= 16 * 1024 * 1024 else { throw EarthGLBExportError.requirements(["Combined scene metadata exceeds the importer's 16 MiB JSON working set."]) }
    }

    private static func sampler(_ image: EarthTexture) -> [String: Any]
    {
        func wrap(_ value: EarthTextureWrap) -> Int
        { switch value { case .repeatTexture: 10497; case .mirroredRepeat: 33648; case .clampToEdge: 33071 } }
        let filter: Int
        switch image.mipmapFilter
        {
            case .none: filter = image.usesNearestMinification ? 9728 : 9729
            case .nearest: filter = image.usesNearestMinification ? 9984 : 9985
            case .linear: filter = image.usesNearestMinification ? 9986 : 9987
        }
        return ["wrapS": wrap(image.wrapS), "wrapT": wrap(image.wrapT), "minFilter": filter, "magFilter": image.usesNearestMagnification ? 9728 : 9729]
    }

    static func aligned(_ count: Int) throws -> Int
    { try EarthCaptureGeometryEstimate.sum(count, (4 - count % 4) % 4) }

    static func writeWords(_ words: [UInt32], to output: FileHandle) throws
    {
        var data = Data(capacity: words.count * 4)
        for var word in words.map(\.littleEndian) { withUnsafeBytes(of: &word) { data.append(contentsOf: $0) } }
        try output.write(contentsOf: data)
    }

    static func writeBinary(_ capture: EarthCapture, options: EarthGLBExportOptions, to output: FileHandle) throws
    {
        var data = Data(capacity: 65584)
        func flush() throws
        {
            try Task.checkCancellation()
            try output.write(contentsOf: data)
            data.removeAll(keepingCapacity: true)
        }
        func word(_ value: UInt32)
        {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        for mesh in capture.meshes
        {
            for vertex in mesh.vertices
            {
                word(vertex.position.x.bitPattern); word(vertex.position.y.bitPattern); word(vertex.position.z.bitPattern)
                if options.includeNormals
                { word(vertex.normal.x.bitPattern); word(vertex.normal.y.bitPattern); word(vertex.normal.z.bitPattern) }
                if options.includeTextureCoordinates
                { word(vertex.textureCoordinate.x.bitPattern); word(vertex.textureCoordinate.y.bitPattern) }
                if options.includeVertexColors
                { word(vertex.color.x.bitPattern); word(vertex.color.y.bitPattern); word(vertex.color.z.bitPattern); word(vertex.color.w.bitPattern) }
                if data.count >= 65536 { try flush() }
            }
            for index in mesh.triangleIndices
            {
                word(index)
                if data.count >= 65536 { try flush() }
            }
            try flush()
        }
        guard options.includeTextures else { return }
        for material in capture.materials
        {
            guard let image = material.baseColorTexture else { continue }
            for offset in stride(from: 0, to: image.encodedImage.count, by: 1024 * 1024)
            {
                try Task.checkCancellation()
                try output.write(contentsOf: image.encodedImage.subdata(in: offset ..< min(image.encodedImage.count, offset + 1024 * 1024)))
            }
            let padding = (4 - image.encodedImage.count % 4) % 4
            if padding > 0 { try output.write(contentsOf: Data(repeating: 0, count: padding)) }
        }
    }
}
