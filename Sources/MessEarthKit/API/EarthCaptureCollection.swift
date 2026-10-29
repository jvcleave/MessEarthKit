import Foundation

/// A standalone model source folder. Its tileset uses the collection's shared
/// origin, so importing a subset never changes the remaining models' positions.
public struct EarthCaptureSection: Sendable, Identifiable
{
    public let id: Int
    public let name: String
    public let tileCount: Int
    public let estimate: EarthCaptureGeometryEstimate
    public let sourceFiles: [EarthSourceFile]
}

/// Source-only collection. Preparing it does not allocate decoded mesh arrays;
/// clients can import one section at a time for preview or conversion.
public struct EarthCaptureCollection: Sendable
{
    public let name: String
    public let geographicOrigin: EarthGeographicOrigin
    public let sections: [EarthCaptureSection]
    public let incompleteReason: String?
    public let preparationProfile: EarthPreparationProfile?

    public func selecting(_ ids: Set<Int>) throws -> Self
    {
        guard !ids.isEmpty, ids.isSubset(of: Set(sections.map(\.id)))
        else { throw EarthImportError.invalidContent("Choose at least one available model section.") }
        return Self(name: name, geographicOrigin: geographicOrigin, sections: sections.filter { ids.contains($0.id) }, incompleteReason: incompleteReason, preparationProfile: preparationProfile)
    }

    /// Standard local 3D Tiles; every child folder can also be imported on its
    /// own. Raw GLBs are copied byte-for-byte, with no mesh clipping or merging.
    public func sourceFiles() throws -> [EarthSourceFile]
    {
        var children: [EarthTileset.Tile] = []
        var files: [EarthSourceFile] = []
        for section in sections
        {
            try Task.checkCancellation()
            let path = "models/model-\(section.id)"
            children.append(.init(boundingVolume: EarthCaptureCollectionBuilder.rootBounds(origin: geographicOrigin), geometricError: 0, transform: nil, refine: "REPLACE", content: .init(uri: path + "/tileset.json"), contents: nil, children: nil, implicitTiling: nil))
            files += section.sourceFiles.map { EarthSourceFile(relativePath: path + "/" + $0.relativePath, data: $0.data) }
        }
        let root = try EarthCaptureCollectionBuilder.manifest(children: children, origin: geographicOrigin, incompleteReason: incompleteReason, isCollection: true, preparationProfile: preparationProfile)
        return [EarthSourceFile(relativePath: "tileset.json", data: root)] + files
    }
}
