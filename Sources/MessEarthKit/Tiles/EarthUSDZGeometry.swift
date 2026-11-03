import Foundation
import ModelIO
import simd

/// Native objects never leave this synchronous call on the export worker.
enum EarthUSDZGeometry
{
    static func write(_ meshes: [EarthMesh], options: EarthExportOptions, fileURL: URL) throws -> Int
    {
        guard MDLAsset.canExportFileExtension("usdc") else { throw EarthUSDZExportError.requirements(["Binary USD export is unavailable on this system."]) }
        let asset = MDLAsset()
        asset.upAxis = SIMD3(0, 1, 0)
        for (index, source) in meshes.enumerated()
        {
            try Task.checkCancellation()
            var values: [Float] = []
            values.reserveCapacity(source.vertices.count * 12)
            for vertex in source.vertices
            { values.append(contentsOf: [vertex.position.x, vertex.position.y, vertex.position.z, vertex.normal.x, vertex.normal.y, vertex.normal.z, vertex.textureCoordinate.x, 1 - vertex.textureCoordinate.y, vertex.color.x, vertex.color.y, vertex.color.z, vertex.color.w]) }
            let descriptor = MDLVertexDescriptor()
            descriptor.attributes[0] = MDLVertexAttribute(name: MDLVertexAttributePosition, format: .float3, offset: 0, bufferIndex: 0)
            if options.includeNormals { descriptor.attributes[1] = MDLVertexAttribute(name: MDLVertexAttributeNormal, format: .float3, offset: 12, bufferIndex: 0) }
            if options.includeTextureCoordinates { descriptor.attributes[2] = MDLVertexAttribute(name: MDLVertexAttributeTextureCoordinate, format: .float2, offset: 24, bufferIndex: 0) }
            if options.includeVertexColors { descriptor.attributes[3] = MDLVertexAttribute(name: MDLVertexAttributeColor, format: .float4, offset: 32, bufferIndex: 0) }
            descriptor.layouts[0] = MDLVertexBufferLayout(stride: 48)
            let data = values.withUnsafeBytes { Data($0) }
            let indices = source.triangleIndices.withUnsafeBytes { Data($0) }
            let submesh = MDLSubmesh(indexBuffer: MDLMeshBufferData(type: .index, data: indices), indexCount: source.triangleIndices.count, indexType: .uInt32, geometryType: .triangles, material: nil)
            let mesh = MDLMesh(vertexBuffer: MDLMeshBufferData(type: .vertex, data: data), vertexCount: source.vertices.count, descriptor: descriptor, submeshes: [submesh])
            mesh.name = "Mesh\(index)"
            asset.add(mesh)
        }
        try asset.export(to: fileURL)
        try Task.checkCancellation()
        // Model I/O may reorder vertex storage. Verify that corner order and
        // admitted attributes remain intact before layering opacity/color data.
        let restored = MDLAsset(url: fileURL)
        var seen: [String: MDLMesh] = [:]
        func visit(_ object: MDLObject)
        {
            if let mesh = object as? MDLMesh { seen[mesh.name] = mesh }
            for child in object.children.objects { visit(child) }
        }
        for index in 0 ..< restored.count { visit(restored.object(at: index)) }
        guard seen.count == meshes.count else { throw EarthUSDZExportError.unsupportedAppearance("The native geometry writer changed the mesh inventory.") }
        var vertices = 0
        for (index, source) in meshes.enumerated()
        {
            guard let mesh = seen["Mesh\(index)"], mesh.path.hasSuffix("/Geom/Mesh\(index)"),
                  let positions = mesh.vertexAttributeData(forAttributeNamed: MDLVertexAttributePosition, as: .float3),
                  let submeshes = mesh.submeshes as? [MDLSubmesh], submeshes.count == 1, let sub = submeshes.first,
                  sub.geometryType == .triangles, sub.indexCount == source.triangleIndices.count
            else { throw EarthUSDZExportError.unsupportedAppearance("The native geometry writer changed mesh topology.") }
            let normals = mesh.vertexAttributeData(forAttributeNamed: MDLVertexAttributeNormal, as: .float3)
            let uv = mesh.vertexAttributeData(forAttributeNamed: MDLVertexAttributeTextureCoordinate, as: .float2)
            let colors = mesh.vertexAttributeData(forAttributeNamed: MDLVertexAttributeColor, as: .float4)
            let indices = sub.indexBuffer.map().bytes
            for corner in 0 ..< sub.indexCount
            {
                if corner.isMultiple(of: 4096) { try Task.checkCancellation() }
                let ordinal: Int
                switch sub.indexType
                {
                    case .uInt8: ordinal = Int(indices.load(fromByteOffset: corner, as: UInt8.self))
                    case .uInt16: ordinal = Int(indices.loadUnaligned(fromByteOffset: corner * 2, as: UInt16.self))
                    case .uInt32: ordinal = Int(indices.loadUnaligned(fromByteOffset: corner * 4, as: UInt32.self))
                    default: throw EarthUSDZExportError.storage
                }
                guard ordinal < mesh.vertexCount else { throw EarthUSDZExportError.storage }
                let expected = source.vertices[Int(source.triangleIndices[corner])]
                let p = positions.dataStart.advanced(by: ordinal * positions.stride).assumingMemoryBound(to: Float.self)
                guard SIMD3(p[0], p[1], p[2]) == expected.position else { throw EarthUSDZExportError.unsupportedAppearance("The native writer changed triangle order or positions.") }
                if options.includeNormals
                {
                    guard let normals else { throw EarthUSDZExportError.storage }
                    let n = normals.dataStart.advanced(by: ordinal * normals.stride).assumingMemoryBound(to: Float.self)
                    guard simd_distance(SIMD3(n[0], n[1], n[2]), expected.normal) <= 0.00001 else { throw EarthUSDZExportError.unsupportedAppearance("The native writer changed source normals.") }
                }
                if options.includeTextureCoordinates
                {
                    guard let uv else { throw EarthUSDZExportError.storage }
                    let t = uv.dataStart.advanced(by: ordinal * uv.stride).assumingMemoryBound(to: Float.self)
                    guard SIMD2(t[0], t[1]) == SIMD2(expected.textureCoordinate.x, 1 - expected.textureCoordinate.y) else { throw EarthUSDZExportError.unsupportedAppearance("The native writer changed source UV coordinates.") }
                }
                if options.includeVertexColors
                {
                    guard let colors else { throw EarthUSDZExportError.storage }
                    let c = colors.dataStart.advanced(by: ordinal * colors.stride).assumingMemoryBound(to: Float.self)
                    guard SIMD3(c[0], c[1], c[2]) == SIMD3(expected.color.x, expected.color.y, expected.color.z) else { throw EarthUSDZExportError.unsupportedAppearance("The native writer changed source vertex colors.") }
                }
            }
            vertices = try EarthCaptureGeometryEstimate.sum(vertices, mesh.vertexCount)
        }
        return vertices
    }
}
