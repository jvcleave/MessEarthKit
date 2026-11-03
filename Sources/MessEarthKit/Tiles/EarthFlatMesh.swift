import Foundation
import simd

/// Immutable triangle corners for deliveries that omit authored normals.
enum EarthFlatMesh
{
    enum Failure: Error { case capacity, invalidGeometry }

    static func vertices(_ vertices: [EarthVertex], indices: [UInt32], maximumVertices: Int) throws -> [EarthVertex]
    {
        guard indices.count >= 3, indices.count.isMultiple(of: 3), indices.allSatisfy({ Int($0) < vertices.count })
        else { throw Failure.invalidGeometry }
        guard indices.count <= maximumVertices, indices.count <= Int(UInt32.max) else { throw Failure.capacity }
        var flat: [EarthVertex] = []
        flat.reserveCapacity(indices.count)
        for corner in stride(from: 0, to: indices.count, by: 3)
        {
            if corner.isMultiple(of: 4096) { try Task.checkCancellation() }
            let first = vertices[Int(indices[corner])], second = vertices[Int(indices[corner + 1])], third = vertices[Int(indices[corner + 2])]
            let origin = SIMD3<Double>(first.position)
            let cross = simd_cross(SIMD3<Double>(second.position) - origin, SIMD3<Double>(third.position) - origin)
            let scale = max(abs(cross.x), abs(cross.y), abs(cross.z))
            guard scale.isFinite, scale > 0 else { throw Failure.invalidGeometry }
            let normal = SIMD3<Float>(simd_normalize(cross / scale))
            for vertex in [first, second, third]
            { flat.append(EarthVertex(position: vertex.position, normal: normal, textureCoordinate: vertex.textureCoordinate, color: vertex.color)) }
        }
        return flat
    }
}
