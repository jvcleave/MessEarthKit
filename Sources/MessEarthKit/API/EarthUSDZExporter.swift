import Foundation

public struct EarthUSDZExportPlan: Sendable
{
    public var selectedModelCount: Int { source.selectedModelCount }
    public var estimate: EarthCaptureGeometryEstimate { source.estimate }
    public var coversEntireSource: Bool { source.coversEntireSource }
    public var canExport: Bool { source.canExport }
    public var issues: [String] { source.issues }
    public var options: EarthExportOptions { source.options }
    public let optimization: EarthUSDZOptimizationProfile?
    let identity: EarthCaptureIdentity?
    let source: EarthUSDZExportSelection
}

struct EarthUSDZExportSelection: Sendable
{
    let selectedModelCount: Int
    let estimate: EarthCaptureGeometryEstimate
    let coversEntireSource: Bool
    let options: EarthExportOptions
    let issues: [String]
    let collection: EarthPreparedCollection
    let models: [EarthGLBExportModel]
    var canExport: Bool { issues.isEmpty && models.count == selectedModelCount }
}

/// Embedded in the root USD layer as a bounded Base64 JSON customLayerData value.
/// UUIDs/fingerprints identify sources; no filesystem paths or credentials occur.
public struct EarthUSDZExportMetadata: Codable, Sendable
{
    public let formatVersion: Int
    public let sourceIdentifier: String
    public let geographicOrigin: EarthGeographicOrigin
    public let captureIdentity: EarthCaptureIdentity?
    public let sourceProfile: EarthPreparationProfile
    public let selectedModels: [Int]
    public let coversEntireSource: Bool
    public let preparationComplete: Bool
    public let attributions: [String]
    public let options: EarthExportOptions
    public let optimization: EarthUSDZOptimizationProfile?
    public let sourceVertexCount: Int
    public let sourceTriangleCount: Int
    public let vertexCount: Int
    public let triangleCount: Int
    public let maximumErrorMeters: Float

    func validate() throws
    {
        guard formatVersion == 1, sourceIdentifier.count == 64,
              sourceIdentifier.allSatisfy({ $0.isASCII && ($0.isNumber || ("a" ... "f").contains(String($0))) }),
              !selectedModels.isEmpty, selectedModels.count <= 100000,
              Set(selectedModels).count == selectedModels.count, selectedModels.allSatisfy({ $0 > 0 }),
              attributions.count <= 100000, attributions.allSatisfy({ $0.utf8.count <= 65536 }),
              sourceVertexCount > 0, sourceTriangleCount > 0, vertexCount > 0, triangleCount > 0,
              maximumErrorMeters.isFinite, maximumErrorMeters >= 0
        else { throw EarthUSDZExportError.sourceChanged }
        try options.validate()
        if let captureIdentity
        {
            try captureIdentity.validate()
            guard captureIdentity.request.center == geographicOrigin else { throw EarthUSDZExportError.sourceChanged }
        }
    }
}

/// File-backed standard USDZ output. One decoded prepared model and its native
/// geometry conversion are resident at a time, with small archive I/O buffers.
public actor EarthUSDZExporter
{
    private var isWorking = false

    public init() {}

    public func preflight(
        collection: EarthPreparedCollection,
        selection: EarthModelSelection = .all(),
        destination: EarthPreparationProfile,
        options: EarthExportOptions = .full,
        optimization: EarthUSDZOptimizationProfile? = nil,
        identity: EarthCaptureIdentity? = nil,
        progress: @escaping @Sendable (EarthGLBExportProgress) -> Void = { _ in }
    ) async throws -> EarthUSDZExportPlan
    {
        guard !isWorking else { throw EarthCaptureError.alreadyCapturing }
        isWorking = true
        defer { isWorking = false }
        try options.validate()
        let (snapshot, count, estimate) = try EarthGLBExporter.inspect(collection: collection, selection: selection, includeTextures: options.includeTextures)
        if let identity
        {
            try identity.validate()
            guard identity.request.center == snapshot.geographicOrigin else { throw EarthUSDZExportError.sourceChanged }
        }
        var issues = EarthGLBExporter.requirementIssues(estimate, profile: destination)
        var models: [EarthGLBExportModel] = []
        if issues.isEmpty
        {
            var offset = 0
            while offset < snapshot.modelCount
            {
                try Task.checkCancellation()
                let page = try await snapshot.models(offset: offset)
                guard !page.isEmpty else { throw EarthUSDZExportError.sourceChanged }
                for model in page where selection.includes(model.id)
                {
                    let capture = try await snapshot.importModel(id: model.id)
                    if options.includeTextures
                    {
                        for image in capture.materials.compactMap(\.baseColorTexture)
                            where image.usesNearestMagnification || image.usesNearestMinification || image.mipmapFilter == .nearest
                        { _ = image; issues.append("Nearest texture filtering requires GLB; standard USD Preview Surface does not express it.") }
                    }
                    if options.includeTextures && options.includeVertexColors
                    {
                        for mesh in capture.meshes where capture.materials[mesh.materialIndex].baseColorTexture != nil
                        {
                            do { _ = try EarthUSDZShading.uniformTextureTint(mesh, material: capture.materials[mesh.materialIndex]) }
                            catch let EarthUSDZExportError.unsupportedAppearance(reason) { issues.append(reason) }
                        }
                    }
                    models.append(EarthGLBExportModel(id: model.id, fingerprint: EarthGLBExporter.fingerprint(capture)))
                    progress(EarthGLBExportProgress(phase: .checking, completedModels: models.count, totalModels: count))
                }
                offset += page.count
            }
            guard models.count == count else { throw EarthUSDZExportError.sourceChanged }
        }
        let source = EarthUSDZExportSelection(selectedModelCount: count, estimate: estimate, coversEntireSource: snapshot.coversEntireSource && count == snapshot.modelCount, options: options, issues: Array(Set(issues)).sorted(), collection: snapshot, models: models)
        return EarthUSDZExportPlan(optimization: optimization, identity: identity, source: source)
    }

    /// Metadata inspection only. Caller owns file authorization; geometry/images
    /// are never loaded. Returns nil for a USDZ without this exporter marker.
    public func metadata(fileURL: URL) throws -> EarthUSDZExportMetadata?
    {
        do
        {
            guard let text = try EarthUSDZArchive.rootText(fileURL) else { return nil }
            let marker = "string messEarthKitExport = \""
            guard let start = text.range(of: marker), let end = text[start.upperBound...].firstIndex(of: "\"") else { return nil }
            guard let data = Data(base64Encoded: String(text[start.upperBound ..< end])), data.count <= 1024 * 1024 else { throw EarthUSDZExportError.sourceChanged }
            let info = try JSONDecoder().decode(EarthUSDZExportMetadata.self, from: data)
            try info.validate()
            return info
        }
        catch let error as EarthUSDZExportError { throw error }
        catch { throw EarthUSDZExportError.storage }
    }

    public func export(
        plan: EarthUSDZExportPlan,
        fileURL: URL,
        progress: @escaping @Sendable (EarthGLBExportProgress) -> Void = { _ in }
    ) async throws -> EarthUSDZExportResult
    {
        guard !isWorking else { throw EarthCaptureError.alreadyCapturing }
        isWorking = true
        defer { isWorking = false }
        try Task.checkCancellation()
        guard plan.canExport else { throw EarthUSDZExportError.requirements(plan.issues) }
        let sourceRoot = plan.source.collection.directoryURL.standardizedFileURL.resolvingSymlinksInPath().path
        let destination = fileURL.standardizedFileURL.resolvingSymlinksInPath().path
        guard fileURL.isFileURL, fileURL.pathExtension.lowercased() == "usdz", destination != sourceRoot,
              !destination.hasPrefix(sourceRoot + "/"), !FileManager.default.fileExists(atPath: fileURL.path)
        else { throw EarthUSDZExportError.invalidDestination }
        var ancestor = fileURL.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath()
        while ancestor.path != "/"
        {
            guard !FileManager.default.fileExists(atPath: ancestor.appendingPathComponent("preparation.sqlite").path) else { throw EarthUSDZExportError.invalidDestination }
            ancestor.deleteLastPathComponent()
        }
        let current = try await EarthPreparedCollection.open(directoryURL: plan.source.collection.directoryURL)
        guard current.sourceIdentifier == plan.source.collection.sourceIdentifier,
              current.profile == plan.source.collection.profile,
              current.modelCount == plan.source.collection.modelCount,
              current.state == plan.source.collection.state,
              current.coversEntireSource == plan.source.collection.coversEntireSource
        else { throw EarthUSDZExportError.sourceChanged }
        let staging = fileURL.deletingLastPathComponent().appendingPathComponent(".earth-usdz-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        do
        {
            try FileManager.default.createDirectory(at: staging.appendingPathComponent("textures"), withIntermediateDirectories: true)
            var textures: [String: URL] = [:]
            var payloads: [(name: String, url: URL)] = []
            var sourceVertices = 0, sourceTriangles = 0, vertices = 0, triangles = 0
            var error: Float = 0
            var attributions = Set<String>()
            for (ordinal, selected) in plan.source.models.enumerated()
            {
                try Task.checkCancellation()
                let capture = try await current.importModel(id: selected.id)
                guard EarthGLBExporter.fingerprint(capture) == selected.fingerprint else { throw EarthUSDZExportError.sourceChanged }
                let stem = "model\(selected.id)"
                let geometry = staging.appendingPathComponent(stem + ".usdc")
                let appearance = staging.appendingPathComponent(stem + ".usda")
                try autoreleasepool
                {
                    var meshes: [EarthMesh] = []
                    for mesh in capture.meshes
                    {
                        sourceVertices = try EarthCaptureGeometryEstimate.sum(sourceVertices, mesh.vertices.count)
                        sourceTriangles = try EarthCaptureGeometryEstimate.sum(sourceTriangles, mesh.triangleIndices.count / 3)
                        if let optimization = plan.optimization
                        {
                            do
                            {
                                let profile = try EarthMeshOptimizationProfile(triangleFraction: optimization.triangleFraction, maximumErrorMeters: optimization.maximumErrorMeters)
                                let reduced = try EarthMeshOptimization.optimize(mesh, material: capture.materials[mesh.materialIndex], options: plan.options, profile: profile)
                                meshes.append(reduced.mesh); error = max(error, reduced.error)
                            }
                            catch is EarthMeshOptimizationError { throw EarthUSDZExportError.optimization }
                        }
                        else { meshes.append(mesh) }
                    }
                    let count = try EarthUSDZGeometry.write(meshes, options: plan.options, fileURL: geometry)
                    vertices = try EarthCaptureGeometryEstimate.sum(vertices, count)
                    for mesh in meshes { triangles = try EarthCaptureGeometryEstimate.sum(triangles, mesh.triangleIndices.count / 3) }
                    try EarthUSDZShading.write(meshes: meshes, materials: capture.materials, geometryName: geometry.lastPathComponent, options: plan.options, optimization: plan.optimization, fileURL: appearance, staging: staging, textures: &textures)
                }
                attributions.formUnion(capture.attributions)
                payloads.append((geometry.lastPathComponent, geometry)); payloads.append((appearance.lastPathComponent, appearance))
                progress(EarthGLBExportProgress(phase: .writing, completedModels: ordinal + 1, totalModels: plan.selectedModelCount))
            }
            let metadata = EarthUSDZExportMetadata(
                formatVersion: 1,
                sourceIdentifier: current.sourceIdentifier,
                geographicOrigin: current.geographicOrigin,
                captureIdentity: plan.identity,
                sourceProfile: current.profile,
                selectedModels: plan.source.models.map(\.id),
                coversEntireSource: plan.coversEntireSource,
                preparationComplete: current.state == .ready,
                attributions: attributions.sorted(),
                options: plan.options,
                optimization: plan.optimization,
                sourceVertexCount: sourceVertices,
                sourceTriangleCount: sourceTriangles,
                vertexCount: vertices,
                triangleCount: triangles,
                maximumErrorMeters: error
            )
            try metadata.validate()
            let info = try JSONEncoder().encode(metadata)
            guard info.count <= 1024 * 1024 else { throw EarthUSDZExportError.requirements(["Export metadata exceeds 1 MiB."]) }
            let root = staging.appendingPathComponent("scene.usda")
            let text = try EarthUSDTextWriter(root)
            let title = plan.identity.map { $0.locationName + " - " + $0.detailName } ?? "Earth Models"
            try text.write(
                "#usda 1.0\n(\n defaultPrim = \"World\"\n metersPerUnit = 1\n upAxis = \"Y\"\n customLayerData = {\n  string title = \(try EarthUSDZShading.quoted(title))\n  string author = \(try EarthUSDZShading.quoted(attributions.sorted().joined(separator: " | ")))\n  string messEarthKitExport = \"\(info.base64EncodedString())\"\n }\n)\ndef Xform \"World\"\n{\n"
            )
            for selected in plan.source.models
            { try text.write(" def Xform \"Model\(selected.id)\" (\n  prepend references = @model\(selected.id).usda@\n )\n {\n }\n") }
            try text.write("}\n"); try text.finish()
            let packed = staging.appendingPathComponent("delivery.usdz")
            let archive = try EarthUSDZArchive(fileURL: packed)
            try archive.append(root, name: root.lastPathComponent)
            for payload in payloads { try archive.append(payload.url, name: payload.name) }
            for name in textures.keys.sorted() { try archive.append(textures[name]!, name: name) }
            let bytes = try archive.finish()
            try Task.checkCancellation()
            try FileManager.default.linkItem(at: packed, to: fileURL)
            return EarthUSDZExportResult(fileURL: fileURL, byteCount: bytes, sourceVertexCount: sourceVertices, sourceTriangleCount: sourceTriangles, vertexCount: vertices, triangleCount: triangles, textureCount: textures.count, maximumErrorMeters: error, optimization: plan.optimization)
        }
        catch is CancellationError { throw CancellationError() }
        catch let error as EarthUSDZExportError { throw error }
        catch { throw EarthUSDZExportError.storage }
    }
}
