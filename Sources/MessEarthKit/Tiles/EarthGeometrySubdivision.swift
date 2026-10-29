import Foundation
import simd

/// A source working set is separate from the destination's per-model targets.
/// Native topology admission also runs before decoding; this does not promise
/// arbitrary-memory or isolated decoding of untrusted native content.
struct EarthGeometrySubdivision
{
    static let maximumSourceBytes = 128 * 1024 * 1024
    static let maximumSourceVertices = 2000000

    let profile: EarthPreparationProfile

    func writeParts(data: Data, sourceID: String, maximumPayloadBytes: Int, emit: (Data, EarthCaptureGeometryEstimate) throws -> Void) throws
    {
        guard data.count <= Self.maximumSourceBytes, maximumPayloadBytes > 0 else { throw EarthPreparationError.subdivisionWorkingSet }
        let limits = EarthImportLimits(maximumSourceBytes: Self.maximumSourceBytes, maximumVertices: Self.maximumSourceVertices, maximumTextureDimension: EarthTextureRaster.maximumDimension, maximumDecodedTextureBytes: EarthTextureRaster.maximumBytes, maximumNodes: profile.maximumNodesPerPayload)
        let estimate = try EarthGLBEstimate(limits: limits).estimate(data: data)
        guard estimate.largestTextureDimension <= EarthTextureRaster.maximumDimension, estimate.decodedTextureBytes <= EarthTextureRaster.maximumBytes else { throw EarthPreparationError.textureSubdivisionWorkingSet }
        guard estimate.vertexCount <= Self.maximumSourceVertices, estimate.indexCount <= Self.maximumSourceVertices * 3 else { throw EarthPreparationError.subdivisionWorkingSet }
        guard profile.maximumVerticesPerModel >= 3, profile.maximumIndicesPerModel >= 3 else { throw EarthPreparationError.invalidProfile }
        let part = try EarthGLBDecoder(limits: limits).decode(data: data, transform: matrix_identity_double4x4)
        var omittedDegenerateTriangleCount = part.omittedDegenerateTriangleCount
        for mesh in part.meshes
        {
            try Task.checkCancellation()
            guard part.materials.indices.contains(mesh.materialIndex) else { throw EarthImportError.invalidContent("Subdivision material is missing.") }
            let material = part.materials[mesh.materialIndex]
            if let image = material.baseColorTexture,
               image.width > profile.maximumTextureDimension || image.height > profile.maximumTextureDimension || image.width > profile.maximumDecodedTextureBytesPerModel / 4 / image.height
            {
                try EarthTextureSubdivision(profile: profile).write(mesh: mesh, material: material)
                { clipped, cropped in
                    try writeMesh(clipped, material: cropped, attributions: part.attributions, sourceID: sourceID, maximumPayloadBytes: maximumPayloadBytes, omittedDegenerateTriangleCount: &omittedDegenerateTriangleCount, emit: emit)
                }
            }
            else { try writeMesh(mesh, material: material, attributions: part.attributions, sourceID: sourceID, maximumPayloadBytes: maximumPayloadBytes, omittedDegenerateTriangleCount: &omittedDegenerateTriangleCount, emit: emit) }
        }
    }

    private func writeMesh(_ mesh: EarthMesh, material: EarthMaterial, attributions: [String], sourceID: String, maximumPayloadBytes: Int, omittedDegenerateTriangleCount: inout Int, emit: (Data, EarthCaptureGeometryEstimate) throws -> Void) throws
    {
        var cursor = 0
        while cursor < mesh.triangleIndices.count
        {
            try Task.checkCancellation()
            var triangleTarget = min(profile.maximumIndicesPerModel / 3, (mesh.triangleIndices.count - cursor) / 3)
            while true
            {
                var vertices: [EarthVertex] = []
                var indices: [UInt32] = []
                var remap: [UInt32: UInt32] = [:]
                var next = cursor
                while next < mesh.triangleIndices.count, indices.count / 3 < triangleTarget
                {
                    if indices.count.isMultiple(of: 12288) { try Task.checkCancellation() }
                    let triangle = Array(mesh.triangleIndices[next ..< next + 3])
                    let missing = Set(triangle.filter { remap[$0] == nil }).count
                    if !indices.isEmpty, vertices.count + missing > profile.maximumVerticesPerModel { break }
                    for source in triangle
                    {
                        guard mesh.vertices.indices.contains(Int(source)) else { throw EarthImportError.invalidContent("Subdivision index is outside its source mesh.") }
                        if let existing = remap[source] { indices.append(existing) }
                        else
                        {
                            let id = UInt32(vertices.count)
                            vertices.append(mesh.vertices[Int(source)])
                            remap[source] = id
                            indices.append(id)
                        }
                    }
                    next += 3
                }
                let bytes = try EarthDerivativeGLB.encode(vertices: vertices, indices: indices, material: material, name: mesh.name, attributions: attributions, sourceID: sourceID, preparationProfile: profile, omittedDegenerateTriangleCount: omittedDegenerateTriangleCount)
                if bytes.count <= maximumPayloadBytes
                {
                    let texture = material.baseColorTexture
                    let estimate = try EarthCaptureGeometryEstimate(vertices: vertices.count, indices: indices.count, textureBytes: texture.map { $0.width * $0.height * 4 } ?? 0, textureDimension: texture.map { max($0.width, $0.height) } ?? 0)
                    try emit(bytes, estimate)
                    // The count belongs to this source, not to every split part.
                    omittedDegenerateTriangleCount = 0
                    cursor = next
                    break
                }
                guard indices.count > 3 else { throw EarthPreparationError.subdivisionWorkingSet }
                triangleTarget = max(1, indices.count / 6)
            }
        }
    }
}
