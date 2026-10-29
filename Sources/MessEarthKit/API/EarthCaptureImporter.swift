import Foundation
import simd

/// Serial worker for explicit local-file imports. The caller owns file authorization
/// and keeps source files accessible and unchanged until this operation completes.
public actor EarthCaptureImporter
{
    private let limits: EarthImportLimits

    public init(limits: EarthImportLimits = EarthImportLimits())
    {
        self.limits = limits
    }

    public func importFile(fileURL: URL) throws -> EarthCapture
    {
        try importSource(fileURL: fileURL, suppliedFiles: nil)
    }

    /// Reuses completed precheck downloads without another Google session or
    /// request. The current import limits and full decoder validation still apply.
    public func importPrechecked(precheck: EarthCapturePrecheck) throws -> EarthCapture
    {
        guard precheck.hasReusableSources else { throw EarthImportError.invalidContent("Precheck has no complete source snapshot. Run Precheck again after adjusting the limits.") }
        return try importSourceFiles(sourceFiles: precheck.sourceFiles, rootSourcePath: "tileset.json")
    }

    public func prepareCollection(fileURL: URL) throws -> EarthCaptureCollection
    {
        try makeCollection(fileURL: fileURL, suppliedFiles: nil)
    }

    public func prepareCollection(precheck: EarthCapturePrecheck) throws -> EarthCaptureCollection
    {
        guard precheck.hasReusableSources else { throw EarthImportError.invalidContent("The source inspection is incomplete. Reduce the area or increase the advanced source budget.") }
        return try prepareCollection(sourceFiles: precheck.sourceFiles, rootSourcePath: "tileset.json")
    }

    public func prepareCollection(sourceFiles: [EarthSourceFile], rootSourcePath: String) throws -> EarthCaptureCollection
    {
        let root = URL(fileURLWithPath: "/MessEarthCapture")
        var files: [URL: Data] = [:]
        for file in sourceFiles
        {
            let url = root.appendingPathComponent(file.relativePath).standardizedFileURL
            guard !file.relativePath.hasPrefix("/"), url.path.hasPrefix(root.path + "/"), files[url] == nil
            else { throw EarthImportError.invalidContent("Duplicate or escaping capture path.") }
            files[url] = file.data
        }
        return try makeCollection(fileURL: root.appendingPathComponent(rootSourcePath), suppliedFiles: files)
    }

    public func importSection(_ section: EarthCaptureSection) throws -> EarthCapture
    {
        try importSourceFiles(sourceFiles: section.sourceFiles, rootSourcePath: "tileset.json")
    }

    private func makeCollection(fileURL: URL, suppliedFiles: [URL: Data]?) throws -> EarthCaptureCollection
    {
        guard fileURL.pathExtension.lowercased() == "json" else { throw EarthImportError.unsupportedContent("Model collections require a tileset JSON.") }
        let graph = try readGraph(fileURL: fileURL, suppliedFiles: suppliedFiles, plansSections: true)
        guard let origin = graph.origin else { throw EarthImportError.invalidContent("A geographic collection needs a shared origin.") }
        return try EarthCaptureCollectionBuilder(limits: limits).build(tiles: graph.assembly.plannedTiles, origin: origin, name: fileURL.deletingPathExtension().lastPathComponent, incompleteReason: graph.incompleteReason, preparationProfile: graph.preparationProfile)
    }

    /// Imports host-supplied immutable bytes without opening their source files.
    /// The host owns file authorization and loading; relative references and all
    /// ordinary decoding limits are validated by this importer.
    public func importSourceFiles(sourceFiles: [EarthSourceFile], rootSourcePath: String) throws -> EarthCapture
    {
        let root = URL(fileURLWithPath: "/MessEarthCapture")
        var files: [URL: Data] = [:]
        for file in sourceFiles
        {
            let url = root.appendingPathComponent(file.relativePath).standardizedFileURL
            guard !file.relativePath.hasPrefix("/"), url.path.hasPrefix(root.path + "/"), files[url] == nil
            else { throw EarthImportError.invalidContent("Duplicate or escaping capture path.") }
            files[url] = file.data
        }
        return try importSource(fileURL: root.appendingPathComponent(rootSourcePath), suppliedFiles: files)
    }

    private func importSource(fileURL: URL, suppliedFiles: [URL: Data]?) throws -> EarthCapture
    {
        let graph = try readGraph(fileURL: fileURL, suppliedFiles: suppliedFiles, plansSections: false)
        let assembly = graph.assembly
        guard let firstVertex = assembly.meshes.first?.vertices.first
        else { throw EarthImportError.invalidContent("The capture has no usable geometry.") }
        var minimum = firstVertex.position
        var maximum = firstVertex.position
        for mesh in assembly.meshes
        {
            try Task.checkCancellation()
            for vertex in mesh.vertices
            {
                minimum = simd_min(minimum, vertex.position)
                maximum = simd_max(maximum, vertex.position)
            }
        }
        return EarthCapture(
            name: assembly.identity?.locationName ?? fileURL.deletingPathExtension().lastPathComponent,
            meshes: assembly.meshes,
            materials: assembly.materials,
            bounds: EarthBounds(minimum: minimum, maximum: maximum),
            geographicOrigin: graph.origin,
            sourceFiles: assembly.sourceFiles,
            rootSourcePath: assembly.sourceFiles[0].relativePath,
            attributions: assembly.attributions.sorted(),
            incompleteReason: graph.incompleteReason,
            preparationProfile: graph.preparationProfile,
            omittedDegenerateTriangleCount: assembly.omittedDegenerateTriangleCount,
            identity: assembly.identity
        )
    }

    private func readGraph(fileURL: URL, suppliedFiles: [URL: Data]?, plansSections: Bool) throws -> (assembly: EarthImportAssembly, origin: EarthGeographicOrigin?, incompleteReason: String?, preparationProfile: EarthPreparationProfile?)
    {
        try Task.checkCancellation()
        guard fileURL.isFileURL,
              limits.maximumSourceBytes > 0, limits.maximumVertices > 0,
              limits.maximumVertices <= Int(UInt32.max) / 3,
              limits.maximumNodes > 0, limits.maximumNodes <= 1000000,
              limits.maximumTextureDimension > 0, limits.maximumDecodedTextureBytes > 0
        else { throw EarthImportError.invalidContent("A local file and positive bounded import limits are required.") }
        let sourceURL = fileURL.standardizedFileURL.resolvingSymlinksInPath()
        let directory = fileURL.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath()
        var assembly = EarthImportAssembly(suppliedFiles: suppliedFiles)
        assembly.plansSections = plansSections
        let data = try readSource(fileURL: sourceURL, rootDirectory: directory, assembly: &assembly)
        let origin: EarthGeographicOrigin?
        var incompleteReason: String?
        var preparationProfile: EarthPreparationProfile?
        switch sourceURL.pathExtension.lowercased()
        {
            case "glb":
                let json = try EarthGLBDecoder(limits: limits).preflight(data: data, enforcesVertexBudget: false)
                let combined = try EarthCombinedGLBMetadata.read(json: json, maximumEntries: limits.maximumNodes)
                assembly.identity = try EarthCaptureIdentity.readMetadata(json: json)
                if let identity = assembly.identity, let combined, identity.request.center != combined.geographicOrigin
                { throw EarthImportError.invalidContent("Capture identity does not match the saved geographic origin.") }
                preparationProfile = try combined?.sourceProfile ?? EarthPreparationProfile.readMetadata(json: json)
                origin = combined?.geographicOrigin
                incompleteReason = combined?.preparationComplete == false ? combined?.preparationIssue : nil
                try appendGLB(data: data, transform: matrix_identity_double4x4, assembly: &assembly)
                if let combined { assembly.attributions = Set(combined.attributions) }
            case "json":
                let tileset = try decodeTileset(data: data)
                preparationProfile = try EarthPreparationProfile.readMetadata(json: JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:])
                incompleteReason = try EarthCaptureManifest.incompleteReason(data: data)
                let rootTransform = try tileset.root.localTransform()
                let inferred = try tileset.root.boundingVolume.geographicOrigin(transform: rootTransform)
                let frame = try EarthCaptureManifest.sharedOrigin(data: data) ?? inferred
                origin = frame
                var activeFiles: Set<URL> = [sourceURL]
                try appendTile(tile: tileset.root, parentTransform: matrix_identity_double4x4, earthToLocal: frame.earthCenteredToLocal, inheritedRefine: "REPLACE", tilesetURL: sourceURL, rootDirectory: directory, depth: 0, activeFiles: &activeFiles, assembly: &assembly)
            default: throw EarthImportError.unsupportedContent("Select a self-contained GLB or a local 3D Tiles tileset JSON.")
        }
        try Task.checkCancellation()
        return (assembly, origin, incompleteReason, preparationProfile)
    }

    private func appendTile(
        tile: EarthTileset.Tile,
        parentTransform: simd_double4x4,
        earthToLocal: simd_double4x4,
        inheritedRefine: String,
        tilesetURL: URL,
        rootDirectory: URL,
        depth: Int,
        activeFiles: inout Set<URL>,
        assembly: inout EarthImportAssembly
    ) throws
    {
        try Task.checkCancellation()
        assembly.nodeCount += 1
        guard depth < 64, assembly.nodeCount <= limits.maximumNodes
        else { throw EarthImportError.limitExceeded("Tileset hierarchy depth or node count.") }
        guard tile.implicitTiling == nil
        else { throw EarthImportError.unsupportedContent("Implicit tiling requires a separate traversal implementation.") }
        let refine = tile.refine ?? inheritedRefine
        guard ["ADD", "REPLACE"].contains(refine), !(tile.content != nil && tile.contents != nil)
        else { throw EarthImportError.invalidContent("Tile refinement or content declaration is invalid.") }
        let transform = parentTransform * (try tile.localTransform())
        let children = tile.children ?? []
        if children.isEmpty || refine == "ADD"
        {
            let contents = tile.contents ?? tile.content.map { [$0] } ?? []
            for content in contents
            {
                guard let components = URLComponents(string: content.uri), components.scheme == nil,
                      components.host == nil, components.query == nil, components.fragment == nil,
                      !content.uri.isEmpty, !content.uri.hasPrefix("/"),
                      let resolved = URL(string: content.uri, relativeTo: tilesetURL.deletingLastPathComponent())?.absoluteURL
                else { throw EarthImportError.unsupportedContent("Tileset resources must be relative local files.") }
                let url = resolved.standardizedFileURL.resolvingSymlinksInPath()
                let data = try readSource(fileURL: url, rootDirectory: rootDirectory, assembly: &assembly)
                switch url.pathExtension.lowercased()
                {
                    case "glb":
                        if assembly.plansSections
                        {
                            let estimate = try EarthGLBEstimate(limits: limits).estimate(data: data)
                            assembly.plannedTiles.append(EarthCollectionTile(sourceID: url.path, data: data, bounds: tile.boundingVolume, transform: transform, estimate: estimate))
                            continue
                        }
                        // 3D Tiles converts glTF's Y-up coordinates to tile Z-up before applying tile transforms.
                        let gltfToTile = simd_double4x4(columns: (SIMD4(1, 0, 0, 0), SIMD4(0, 0, 1, 0), SIMD4(0, -1, 0, 0), SIMD4(0, 0, 0, 1)))
                        try appendGLB(data: data, transform: earthToLocal * transform * gltfToTile, assembly: &assembly)
                    case "json":
                        guard activeFiles.insert(url).inserted
                        else { throw EarthImportError.invalidContent("External tileset references form a cycle.") }
                        defer { activeFiles.remove(url) }
                        let external = try decodeTileset(data: data)
                        try appendTile(tile: external.root, parentTransform: transform, earthToLocal: earthToLocal, inheritedRefine: refine, tilesetURL: url, rootDirectory: rootDirectory, depth: depth + 1, activeFiles: &activeFiles, assembly: &assembly)
                    default: throw EarthImportError.unsupportedContent("This adapter reads GLB content and external JSON tilesets only.")
                }
            }
        }
        for child in children
        {
            try appendTile(tile: child, parentTransform: transform, earthToLocal: earthToLocal, inheritedRefine: refine, tilesetURL: tilesetURL, rootDirectory: rootDirectory, depth: depth + 1, activeFiles: &activeFiles, assembly: &assembly)
        }
    }

    private func appendGLB(
        data: Data,
        transform: simd_double4x4,
        assembly: inout EarthImportAssembly
    ) throws
    {
        let part = try autoreleasepool { try EarthGLBDecoder(limits: limits).decode(data: data, transform: transform) }
        let addedVertices = part.meshes.reduce(0) { $0 + $1.vertices.count }
        guard addedVertices <= limits.maximumVertices - assembly.vertexCount
        else { throw EarthImportError.limitExceeded("Capture vertex count would reach \(assembly.vertexCount + addedVertices) (limit \(limits.maximumVertices)). Increase Maximum Vertices or reduce the area or detail.") }
        var addedTextureBytes = 0
        for material in part.materials
        {
            if let texture = material.baseColorTexture
            {
                let bytes = texture.width * texture.height * 4
                guard bytes <= limits.maximumDecodedTextureBytes - assembly.textureBytes - addedTextureBytes
                else { throw EarthImportError.limitExceeded("Capture decoded texture bytes would reach \(assembly.textureBytes + addedTextureBytes + bytes) (limit \(limits.maximumDecodedTextureBytes) bytes). Increase Maximum Textures (MiB) or reduce the area or detail.") }
                addedTextureBytes += bytes
            }
        }
        let materialOffset = assembly.materials.count
        for mesh in part.meshes
        {
            assembly.meshes.append(EarthMesh(id: assembly.meshes.count, name: mesh.name, vertices: mesh.vertices, triangleIndices: mesh.triangleIndices, materialIndex: mesh.materialIndex + materialOffset))
        }
        assembly.materials.append(contentsOf: part.materials)
        assembly.attributions.formUnion(part.attributions)
        assembly.vertexCount += addedVertices
        assembly.textureBytes += addedTextureBytes
        assembly.omittedDegenerateTriangleCount = try EarthCaptureGeometryEstimate.sum(assembly.omittedDegenerateTriangleCount, part.omittedDegenerateTriangleCount)
    }

    private func readSource(
        fileURL: URL,
        rootDirectory: URL,
        assembly: inout EarthImportAssembly
    ) throws -> Data
    {
        let prefix = rootDirectory.path.hasSuffix("/") ? rootDirectory.path : rootDirectory.path + "/"
        guard fileURL.isFileURL, fileURL.path.hasPrefix(prefix)
        else { throw EarthImportError.inaccessibleSource("A tileset resource escapes the selected directory.") }
        if let existing = assembly.sourceData[fileURL] { return existing }
        if let supplied = assembly.suppliedFiles
        {
            guard let data = supplied[fileURL] else { throw EarthImportError.inaccessibleSource(fileURL.lastPathComponent) }
            guard data.count <= limits.maximumSourceBytes - assembly.sourceBytes
            else { throw EarthImportError.limitExceeded("Capture source bytes.") }
            assembly.sourceBytes += data.count
            assembly.sourceData[fileURL] = data
            assembly.sourceFiles.append(EarthSourceFile(relativePath: String(fileURL.path.dropFirst(prefix.count)), data: data))
            return data
        }
        let values: URLResourceValues
        do { values = try fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]) }
        catch { throw EarthImportError.inaccessibleSource(fileURL.lastPathComponent) }
        guard values.isRegularFile == true, let size = values.fileSize, size > 0,
              size <= limits.maximumSourceBytes - assembly.sourceBytes
        else { throw EarthImportError.limitExceeded("Source file bytes.") }
        let data: Data
        do { data = try Data(contentsOf: fileURL) }
        catch { throw EarthImportError.inaccessibleSource(fileURL.lastPathComponent) }
        guard data.count <= limits.maximumSourceBytes - assembly.sourceBytes
        else { throw EarthImportError.limitExceeded("Source changed or exceeded the byte budget during reading.") }
        assembly.sourceBytes += data.count
        assembly.sourceData[fileURL] = data
        let relativePath = String(fileURL.path.dropFirst(prefix.count))
        assembly.sourceFiles.append(EarthSourceFile(relativePath: relativePath, data: data))
        return data
    }

    private func decodeTileset(data: Data) throws -> EarthTileset
    {
        guard data.count <= 16 * 1024 * 1024 else { throw EarthImportError.limitExceeded("Tileset JSON size.") }
        let tileset: EarthTileset
        do { tileset = try JSONDecoder().decode(EarthTileset.self, from: data) }
        catch { throw EarthImportError.invalidContent("Tileset JSON does not match the supported 3D Tiles structure.") }
        try tileset.validateSupportedContent()
        return tileset
    }
}

private struct EarthImportAssembly
{
    var identity: EarthCaptureIdentity?
    let suppliedFiles: [URL: Data]?
    var meshes: [EarthMesh] = []
    var materials: [EarthMaterial] = []
    var sourceFiles: [EarthSourceFile] = []
    var sourceData: [URL: Data] = [:]
    var attributions: Set<String> = []
    var nodeCount = 0
    var sourceBytes = 0
    var vertexCount = 0
    var textureBytes = 0
    var omittedDegenerateTriangleCount = 0
    var plansSections = false
    var plannedTiles: [EarthCollectionTile] = []
}
