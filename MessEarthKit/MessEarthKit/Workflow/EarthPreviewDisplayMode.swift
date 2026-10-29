enum EarthPreviewDisplayMode: String, CaseIterable, Identifiable, Sendable
{
    case textured = "Textured"
    case solid = "Solid (no textures)"
    case wireframe = "Wireframe (no textures)"

    var id: Self { self }
    var usesTextures: Bool { self == .textured }
}
