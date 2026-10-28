import Foundation
import simd

public struct EarthVertex: Sendable
{
    public let position: SIMD3<Float>
    public let normal: SIMD3<Float>
    /// glTF coordinates: (0, 0) addresses the top-left of the image.
    public let textureCoordinate: SIMD2<Float>
    public let color: SIMD4<Float>
}

public struct EarthMesh: Sendable, Identifiable
{
    public let id: Int
    public let name: String
    public let vertices: [EarthVertex]
    public let triangleIndices: [UInt32]
    public let materialIndex: Int
}

public enum EarthTextureWrap: Sendable
{
    case repeatTexture, mirroredRepeat, clampToEdge
}

public enum EarthMipmapFilter: Sendable
{
    case none, nearest, linear
}

public struct EarthTexture: Sendable
{
    public let encodedImage: Data
    public let mimeType: String
    public let width: Int
    public let height: Int
    public let wrapS: EarthTextureWrap
    public let wrapT: EarthTextureWrap
    public let usesNearestMagnification: Bool
    public let usesNearestMinification: Bool
    public let mipmapFilter: EarthMipmapFilter
}

public enum EarthAlphaMode: Sendable
{
    case opaque, mask, blend
}

public struct EarthMaterial: Sendable
{
    public let name: String
    public let baseColor: SIMD4<Float>
    public let baseColorTexture: EarthTexture?
    public let metallic: Float
    public let roughness: Float
    public let isUnlit: Bool
    public let isDoubleSided: Bool
    public let alphaMode: EarthAlphaMode
    public let alphaCutoff: Float
}

public struct EarthBounds: Sendable
{
    public let minimum: SIMD3<Float>
    public let maximum: SIMD3<Float>

    public var center: SIMD3<Float> { (minimum + maximum) * 0.5 }
    public var dimensions: SIMD3<Float> { maximum - minimum }
}

/// An original local source file, retained without conversion for later delivery decisions.
public struct EarthSourceFile: Sendable
{
    public let relativePath: String
    public let data: Data

    public init(relativePath: String, data: Data)
    {
        self.relativePath = relativePath
        self.data = data
    }
}

public struct EarthCapture: Sendable
{
    public let name: String
    public let meshes: [EarthMesh]
    public let materials: [EarthMaterial]
    public let bounds: EarthBounds
    public let geographicOrigin: EarthGeographicOrigin?
    public let sourceFiles: [EarthSourceFile]
    public let rootSourcePath: String
    public let attributions: [String]
    /// Non-nil for an interrupted capture. The selected source files remain
    /// usable, but do not represent the complete requested region.
    public let incompleteReason: String?

    public var vertexCount: Int { meshes.reduce(0) { $0 + $1.vertices.count } }
    public var triangleCount: Int { meshes.reduce(0) { $0 + $1.triangleIndices.count / 3 } }
    public var sourceByteCount: Int { sourceFiles.reduce(0) { $0 + $1.data.count } }
}

public struct EarthImportLimits: Sendable
{
    public let maximumSourceBytes: Int
    public let maximumVertices: Int
    public let maximumTextureDimension: Int
    public let maximumDecodedTextureBytes: Int
    public let maximumNodes: Int

    public init(
        maximumSourceBytes: Int = 128 * 1024 * 1024,
        maximumVertices: Int = 2000000,
        maximumTextureDimension: Int = 8192,
        maximumDecodedTextureBytes: Int = 256 * 1024 * 1024,
        maximumNodes: Int = 4096
    )
    {
        self.maximumSourceBytes = maximumSourceBytes
        self.maximumVertices = maximumVertices
        self.maximumTextureDimension = maximumTextureDimension
        self.maximumDecodedTextureBytes = maximumDecodedTextureBytes
        self.maximumNodes = maximumNodes
    }
}

public enum EarthImportError: Error, LocalizedError, Sendable
{
    case invalidContent(String)
    case unsupportedContent(String)
    case limitExceeded(String)
    case inaccessibleSource(String)

    public var errorDescription: String?
    {
        switch self
        {
            case let .invalidContent(reason): "Invalid 3D content: \(reason)"
            case let .unsupportedContent(reason): "Unsupported 3D content: \(reason)"
            case let .limitExceeded(reason): "Capture limit exceeded: \(reason)"
            case let .inaccessibleSource(reason): "Cannot read source: \(reason)"
        }
    }
}
