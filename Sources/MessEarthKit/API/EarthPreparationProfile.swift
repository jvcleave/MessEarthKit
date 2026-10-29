import Foundation

/// Permission for derivatives only; original downloads are never changed.
public enum EarthPreparationAppearancePolicy: String, Codable, Sendable
{
    case preserveAppearance
    /// Cropped textures regenerate mipmaps; new clipped normals approximate
    /// the original lighting interpolant. Full-resolution base pixels remain.
    case optimizedCopy
}

/// Destination requirements for one independently loadable model. Reaching a
/// packing target starts another model; it never caps total collection size.
public struct EarthPreparationProfile: Codable, Equatable, Sendable
{
    public let name: String
    public let version: Int
    public let maximumVerticesPerModel: Int
    public let maximumIndicesPerModel: Int
    public let maximumDecodedTextureBytesPerModel: Int
    public let maximumTextureDimension: Int
    public let maximumSourceBytesPerModel: Int
    public let maximumPlacementsPerModel: Int
    public let maximumNodesPerPayload: Int
    public let appearancePolicy: EarthPreparationAppearancePolicy

    public init(
        name: String = "Native preview",
        version: Int = 2,
        maximumVerticesPerModel: Int = 2000000,
        maximumIndicesPerModel: Int = 6000000,
        maximumDecodedTextureBytesPerModel: Int = 256 * 1024 * 1024,
        maximumTextureDimension: Int = 8192,
        maximumSourceBytesPerModel: Int = 128 * 1024 * 1024,
        maximumPlacementsPerModel: Int = 64,
        maximumNodesPerPayload: Int = 4096,
        appearancePolicy: EarthPreparationAppearancePolicy = .preserveAppearance
    ) throws
    {
        guard !name.isEmpty, name.count <= 128, (1 ... 2).contains(version),
              version >= 2 || appearancePolicy == .preserveAppearance,
              maximumVerticesPerModel > 0, maximumVerticesPerModel <= Int(UInt32.max) / 3,
              maximumIndicesPerModel > 0, maximumIndicesPerModel <= Int(UInt32.max),
              maximumDecodedTextureBytesPerModel > 0, maximumTextureDimension > 0,
              maximumSourceBytesPerModel > 0,
              (1 ... 100000).contains(maximumPlacementsPerModel),
              (1 ... 1000000).contains(maximumNodesPerPayload)
        else { throw EarthPreparationError.invalidProfile }
        self.name = name
        self.version = version
        self.maximumVerticesPerModel = maximumVerticesPerModel
        self.maximumIndicesPerModel = maximumIndicesPerModel
        self.maximumDecodedTextureBytesPerModel = maximumDecodedTextureBytesPerModel
        self.maximumTextureDimension = maximumTextureDimension
        self.maximumSourceBytesPerModel = maximumSourceBytesPerModel
        self.maximumPlacementsPerModel = maximumPlacementsPerModel
        self.maximumNodesPerPayload = maximumNodesPerPayload
        self.appearancePolicy = appearancePolicy
    }

    private enum CodingKeys: String, CodingKey
    {
        case name, version, maximumVerticesPerModel, maximumIndicesPerModel, maximumDecodedTextureBytesPerModel
        case maximumTextureDimension, maximumSourceBytesPerModel, maximumPlacementsPerModel, maximumNodesPerPayload
        case appearancePolicy
    }

    public init(from decoder: any Decoder) throws
    {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            name: values.decode(String.self, forKey: .name),
            version: values.decode(Int.self, forKey: .version),
            maximumVerticesPerModel: values.decode(Int.self, forKey: .maximumVerticesPerModel),
            maximumIndicesPerModel: values.decode(Int.self, forKey: .maximumIndicesPerModel),
            maximumDecodedTextureBytesPerModel: values.decode(Int.self, forKey: .maximumDecodedTextureBytesPerModel),
            maximumTextureDimension: values.decode(Int.self, forKey: .maximumTextureDimension),
            maximumSourceBytesPerModel: values.decode(Int.self, forKey: .maximumSourceBytesPerModel),
            maximumPlacementsPerModel: values.decode(Int.self, forKey: .maximumPlacementsPerModel),
            maximumNodesPerPayload: values.decode(Int.self, forKey: .maximumNodesPerPayload),
            appearancePolicy: values.decodeIfPresent(EarthPreparationAppearancePolicy.self, forKey: .appearancePolicy) ?? .preserveAppearance
        )
    }

    static func readMetadata(json: [String: Any]) throws -> Self?
    {
        guard let extras = json["extras"] as? [String: Any], let marker = extras["messEarthKitPreparation"] else { return nil }
        guard let metadata = marker as? [String: Any],
              metadata["formatVersion"] == nil || metadata["formatVersion"] as? Int == 1,
              let profile = metadata["profile"] as? [String: Any]
        else { throw EarthImportError.invalidContent("Invalid preparation profile metadata.") }
        do { return try JSONDecoder().decode(Self.self, from: JSONSerialization.data(withJSONObject: profile)) }
        catch { throw EarthImportError.invalidContent("Invalid or unsupported preparation profile metadata.") }
    }

    public var importLimits: EarthImportLimits
    {
        EarthImportLimits(
            maximumSourceBytes: maximumSourceBytesPerModel,
            maximumVertices: maximumVerticesPerModel,
            maximumTextureDimension: maximumTextureDimension,
            maximumDecodedTextureBytes: maximumDecodedTextureBytesPerModel,
            maximumNodes: max(maximumNodesPerPayload, maximumPlacementsPerModel + 1)
        )
    }

    func accepts(_ estimate: EarthCaptureGeometryEstimate) -> Bool
    {
        estimate.vertexCount <= maximumVerticesPerModel && estimate.indexCount <= maximumIndicesPerModel
            && estimate.decodedTextureBytes <= maximumDecodedTextureBytesPerModel && estimate.largestTextureDimension <= maximumTextureDimension
    }
}

public enum EarthPreparationError: Error, Equatable, LocalizedError, Sendable
{
    case invalidProfile
    case incompleteSource
    case invalidCollection
    case invalidDestination
    case storage
    case sourceChanged
    case subdivisionRequired(placement: Int)
    case sourceWorkingSet(placement: Int)
    case subdivisionWorkingSet
    case textureSubdivisionRequired
    case textureSubdivisionWorkingSet
    case textureMipmapsUnsupported
    case textureInterpolationUnsupported
    case texturePixelFormatUnsupported

    public var errorDescription: String?
    {
        switch self
        {
            case .invalidProfile: "The destination profile has invalid or unsupported requirements."
            case .incompleteSource: "Finish the raw download before preparing models."
            case .invalidCollection: "This folder is not a valid prepared model collection."
            case .invalidDestination: "Choose a new destination folder outside the source archive or prepared collection."
            case .storage: "Model preparation could not write its files. Check disk space and folder access. Completed models and the raw download are retained."
            case .sourceChanged: "A source file changed or is missing. The raw archive was not modified."
            case let .subdivisionRequired(placement): "Prepared part \(placement) still exceeds this destination's requirements. Completed models and the original download are retained."
            case let .sourceWorkingSet(placement): "Source tile or prepared part \(placement) exceeds the supported source working set. The original download is retained."
            case .subdivisionWorkingSet: "This source exceeds the supported geometry-subdivision working set or cannot fit one triangle in the destination. The original download is retained."
            case .textureSubdivisionRequired: "A source texture needs a subdivision mode that this destination does not support. The original download is retained."
            case .textureSubdivisionWorkingSet: "Texture subdivision exceeds the supported source working set or cannot fit the required border in this destination. The original download is retained."
            case .textureMipmapsUnsupported: "Preserving appearance cannot split this texture's filtering exactly. Try optimized-copy preparation to regenerate crop mipmaps; original downloads are retained."
            case .textureInterpolationUnsupported: "Preserving appearance cannot split this texture without changing smooth lighting. Try optimized-copy preparation; original downloads are retained."
            case .texturePixelFormatUnsupported: "Texture subdivision requires supported 8-bit RGB or grayscale samples without lossy alpha conversion. The original image and download are retained."
        }
    }
}

public struct EarthPreparationProgress: Sendable
{
    public enum Phase: Sendable { case inspecting, writing }
    public let phase: Phase
    public let processedPlacements: Int
    public let totalPlacements: Int
    public let completedModels: Int
}
