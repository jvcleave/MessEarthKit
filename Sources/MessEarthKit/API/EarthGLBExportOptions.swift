/// Output-only choices. Positions, triangle indices, placement and attribution
/// are always retained; source and prepared model data are never modified.
public struct EarthGLBExportOptions: Codable, Equatable, Sendable
{
    public var includeNormals: Bool
    public var includeVertexColors: Bool
    public var includeTextureCoordinates: Bool
    public var includeMaterials: Bool
    public var includeTextures: Bool

    public static let full = Self()
    public static let untextured = Self(includeTextures: false)
    public static let minimal = Self(
        includeNormals: false,
        includeVertexColors: false,
        includeTextureCoordinates: false,
        includeMaterials: false,
        includeTextures: false
    )

    public init(
        includeNormals: Bool = true,
        includeVertexColors: Bool = true,
        includeTextureCoordinates: Bool = true,
        includeMaterials: Bool = true,
        includeTextures: Bool = true
    )
    {
        self.includeNormals = includeNormals
        self.includeVertexColors = includeVertexColors
        self.includeTextureCoordinates = includeTextureCoordinates
        self.includeMaterials = includeMaterials
        self.includeTextures = includeTextures
    }

    func validate() throws
    {
        guard !includeTextures || (includeTextureCoordinates && includeMaterials)
        else { throw EarthGLBExportError.invalidOptions }
    }

    var vertexByteStride: Int
    { 12 + (includeNormals ? 12 : 0) + (includeTextureCoordinates ? 8 : 0) + (includeVertexColors ? 16 : 0) }
}
