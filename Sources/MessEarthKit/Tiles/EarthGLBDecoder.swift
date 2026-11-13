import Foundation
import MessGLBKit
import simd

struct EarthGLBPart
{
    let meshes: [EarthMesh]
    let materials: [EarthMaterial]
    let attributions: [String]
    let omittedDegenerateTriangleCount: Int
}

/// Adapts the shared decoder to capture types and derivative metadata.
struct EarthGLBDecoder
{
    private let decoder: GLBDecoder

    init(limits: EarthImportLimits, skinning: EarthCaptureImporter.GLBSkinning = .reject)
    {
        decoder = GLBDecoder(
            limits: GLBImportLimits(
                maximumSourceBytes: limits.maximumSourceBytes,
                maximumVertices: limits.maximumVertices,
                maximumTextureDimension: limits.maximumTextureDimension,
                maximumDecodedTextureBytes: limits.maximumDecodedTextureBytes,
                maximumNodes: limits.maximumNodes
            ),
            skinning: skinning == .bakeReferencePose ? .bakeReferencePose : .reject
        )
    }

    func preflight(data: Data, enforcesVertexBudget: Bool = true) throws -> [String: Any]
    {
        do { return try decoder.preflight(data: data, enforcesVertexBudget: enforcesVertexBudget) }
        catch let error as GLBImportError { throw Self.captureError(error) }
    }

    func decode(
        data: Data,
        transform: simd_double4x4,
        allowsDegenerateOnlyScene: Bool = false
    ) throws -> EarthGLBPart
    {
        let geometry: GLBGeometry
        do { geometry = try decoder.decode(data: data, transform: transform, allowsDegenerateOnlyScene: allowsDegenerateOnlyScene) }
        catch let error as GLBImportError { throw Self.captureError(error) }

        var recordedOmissions = 0
        if let extras = geometry.extras,
           let json = try JSONSerialization.jsonObject(with: extras, options: [.fragmentsAllowed]) as? [String: Any],
           let value = json["messEarthKitOmittedDegenerateTriangleCount"]
        {
            guard let encoded = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]),
                  let count = try? JSONDecoder().decode(Int.self, from: encoded), count >= 0
            else { throw EarthImportError.invalidContent("Invalid omitted-triangle count metadata.") }
            recordedOmissions = count
        }
        var meshes: [EarthMesh] = []
        meshes.reserveCapacity(geometry.meshes.count)
        for source in geometry.meshes
        {
            try Task.checkCancellation()
            var vertices: [EarthVertex] = []
            vertices.reserveCapacity(source.vertices.count)
            for (index, vertex) in source.vertices.enumerated()
            {
                if index.isMultiple(of: 4096) { try Task.checkCancellation() }
                vertices.append(EarthVertex(position: vertex.position, normal: vertex.normal, textureCoordinate: vertex.textureCoordinate, color: vertex.color))
            }
            meshes.append(EarthMesh(id: source.id, name: source.name, vertices: vertices, triangleIndices: source.triangleIndices, materialIndex: source.materialIndex))
        }
        return EarthGLBPart(
            meshes: meshes,
            materials: geometry.materials.map(Self.captureMaterial),
            attributions: geometry.attributions,
            omittedDegenerateTriangleCount: try EarthCaptureGeometryEstimate.sum(recordedOmissions, geometry.omittedDegenerateTriangleCount)
        )
    }

    private static func captureError(_ error: GLBImportError) -> EarthImportError
    {
        switch error
        {
            case let .invalidContent(reason): .invalidContent(reason)
            case let .unsupportedContent(reason): .unsupportedContent(reason)
            case let .limitExceeded(reason): .limitExceeded(reason)
        }
    }

    private static func captureMaterial(_ material: GLBMaterial) -> EarthMaterial
    {
        let alphaMode: EarthAlphaMode
        switch material.alphaMode
        {
            case .opaque: alphaMode = .opaque
            case .mask: alphaMode = .mask
            case .blend: alphaMode = .blend
        }
        let texture = material.baseColorTexture.map
        { texture in
            let mipmapFilter: EarthMipmapFilter
            switch texture.mipmapFilter
            {
                case .none: mipmapFilter = .none
                case .nearest: mipmapFilter = .nearest
                case .linear: mipmapFilter = .linear
            }
            return EarthTexture(
                encodedImage: texture.encodedImage,
                mimeType: texture.mimeType,
                width: texture.width,
                height: texture.height,
                wrapS: captureWrap(texture.wrapS),
                wrapT: captureWrap(texture.wrapT),
                usesNearestMagnification: texture.usesNearestMagnification,
                usesNearestMinification: texture.usesNearestMinification,
                mipmapFilter: mipmapFilter
            )
        }
        return EarthMaterial(
            name: material.name,
            baseColor: material.baseColor,
            baseColorTexture: texture,
            metallic: material.metallic,
            roughness: material.roughness,
            isUnlit: material.isUnlit,
            isDoubleSided: material.isDoubleSided,
            alphaMode: alphaMode,
            alphaCutoff: material.alphaCutoff
        )
    }

    private static func captureWrap(_ wrap: GLBTextureWrap) -> EarthTextureWrap
    {
        switch wrap
        {
            case .repeatTexture: .repeatTexture
            case .mirroredRepeat: .mirroredRepeat
            case .clampToEdge: .clampToEdge
        }
    }
}
