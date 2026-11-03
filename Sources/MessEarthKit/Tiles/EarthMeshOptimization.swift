import EarthMeshOptimizer
import Foundation
import simd

enum EarthMeshOptimization
{
    static func optimize(_ mesh: EarthMesh, material: EarthMaterial, options: EarthExportOptions, profile: EarthMeshOptimizationProfile) throws -> (mesh: EarthMesh, error: Float)
    {
        try Task.checkCancellation()
        var source: [Float] = []
        source.reserveCapacity(mesh.vertices.count * 12)
        for vertex in mesh.vertices
        {
            // Omitted channels must not create remapping seams or constrain
            // simplification. Flat preview normals can split every source face.
            let normal = options.includeNormals ? vertex.normal : SIMD3<Float>(0, 1, 0)
            let uv = options.includeTextureCoordinates ? vertex.textureCoordinate : .zero
            let color = options.includeVertexColors ? vertex.color : SIMD4<Float>(repeating: 1)
            source.append(contentsOf: [vertex.position.x, vertex.position.y, vertex.position.z, normal.x, normal.y, normal.z, uv.x, uv.y, color.x, color.y, color.z, color.w])
        }
        let result = source.withUnsafeBytes
        { bytes in mesh.triangleIndices.withUnsafeBufferPointer
        { indices in EMOOptimize(bytes.bindMemory(to: EMOVertex.self).baseAddress, mesh.vertices.count, indices.baseAddress, indices.count, profile.triangleFraction, profile.maximumErrorMeters, material.alphaMode == .blend ? 1 : 0) }
        }
        defer { EMORelease(result) }
        try Task.checkCancellation()
        guard result.status == 0, let vertices = result.vertices, let indices = result.indices,
              result.vertexCount > 0, result.indexCount > 0,
              result.errorMeters.isFinite, result.errorMeters <= profile.maximumErrorMeters + 0.000001
        else { throw EarthMeshOptimizationError.failed }
        let scalars = UnsafeRawPointer(vertices).assumingMemoryBound(to: Float.self)
        var output: [EarthVertex] = []
        output.reserveCapacity(result.vertexCount)
        for i in 0 ..< result.vertexCount
        {
            let p = scalars.advanced(by: i * 12)
            output.append(EarthVertex(position: SIMD3(p[0], p[1], p[2]), normal: SIMD3(p[3], p[4], p[5]), textureCoordinate: SIMD2(p[6], p[7]), color: SIMD4(p[8], p[9], p[10], p[11])))
        }
        return (EarthMesh(id: mesh.id, name: mesh.name, vertices: output, triangleIndices: Array(UnsafeBufferPointer(start: indices, count: result.indexCount)), materialIndex: mesh.materialIndex), result.errorMeters)
    }

    static func optimize(_ capture: EarthCapture, options: EarthExportOptions, profile: EarthMeshOptimizationProfile) throws -> (capture: EarthCapture, error: Float)
    {
        var meshes: [EarthMesh] = []
        var error: Float = 0
        var minimum = SIMD3<Float>(repeating: .infinity), maximum = SIMD3<Float>(repeating: -.infinity)
        for mesh in capture.meshes
        {
            guard capture.materials.indices.contains(mesh.materialIndex) else { throw EarthMeshOptimizationError.failed }
            let result = try optimize(mesh, material: capture.materials[mesh.materialIndex], options: options, profile: profile)
            meshes.append(result.mesh)
            error = max(error, result.error)
            for vertex in result.mesh.vertices
            {
                minimum = simd_min(minimum, vertex.position)
                maximum = simd_max(maximum, vertex.position)
            }
        }
        return (replacingMeshes(capture, meshes: meshes, bounds: EarthBounds(minimum: minimum, maximum: maximum)), error)
    }

    static func previewCapture(_ capture: EarthCapture, maximumVertices: Int) throws -> EarthCapture
    {
        var meshes: [EarthMesh] = []
        var count = 0
        for mesh in capture.meshes
        {
            let vertices = try EarthFlatMesh.vertices(mesh.vertices, indices: mesh.triangleIndices, maximumVertices: maximumVertices - count)
            count += vertices.count
            meshes.append(EarthMesh(id: mesh.id, name: mesh.name, vertices: vertices, triangleIndices: vertices.indices.map { UInt32($0) }, materialIndex: mesh.materialIndex))
        }
        return replacingMeshes(capture, meshes: meshes, bounds: capture.bounds)
    }

    private static func replacingMeshes(_ capture: EarthCapture, meshes: [EarthMesh], bounds: EarthBounds) -> EarthCapture
    {
        EarthCapture(
            name: capture.name,
            meshes: meshes,
            materials: capture.materials,
            bounds: bounds,
            geographicOrigin: capture.geographicOrigin,
            sourceFiles: capture.sourceFiles,
            rootSourcePath: capture.rootSourcePath,
            attributions: capture.attributions,
            incompleteReason: capture.incompleteReason,
            preparationProfile: capture.preparationProfile,
            omittedDegenerateTriangleCount: capture.omittedDegenerateTriangleCount,
            identity: capture.identity
        )
    }
}
