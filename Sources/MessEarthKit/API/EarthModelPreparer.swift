import Foundation
import simd

/// Offline worker: inspects one unique payload at a time, orders placements in
/// SQLite, then writes/releases each bounded model. No aggregate scene Data or
/// native mesh arrays are retained across payloads. Oversized geometry is
/// decoded within the supported source working set and written as derived parts.
/// Raw archives are always read-only.
public actor EarthModelPreparer
{
    private var isPreparing = false

    public init() {}

    public func prepare(archive: EarthSourceArchive, directoryURL: URL, profile: EarthPreparationProfile, progress: @escaping @Sendable (EarthPreparationProgress) -> Void = { _ in }) throws -> EarthPreparedCollection
    {
        guard !isPreparing else { throw EarthCaptureError.alreadyCapturing }
        try Task.checkCancellation()
        isPreparing = true
        defer { isPreparing = false }
        return try Self.prepareSources(archive: archive, directoryURL: directoryURL, profile: profile, progress: progress)
    }

    /// One synchronous invocation owns every SQLite handle and packing buffer.
    /// Nothing captured by its local callbacks crosses an isolation boundary.
    private nonisolated static func prepareSources(archive: EarthSourceArchive, directoryURL: URL, profile: EarthPreparationProfile, progress: @Sendable (EarthPreparationProgress) -> Void) throws -> EarthPreparedCollection
    {
        let source = try EarthAcquisitionIndex(directoryURL: archive.directoryURL, creating: nil, readOnly: true)
        let current = try source.snapshot()
        guard current.state == .downloaded, current.request == archive.request else { throw EarthPreparationError.incompleteSource }
        try EarthPreparedCollectionFiles.validateDestination(directoryURL, outside: archive.directoryURL)
        let root = try source.files.checked("tileset.json", regularFile: true)
        let identifier = try source.files.integrity(root).hash
        let index = try EarthPreparationIndex(directoryURL: directoryURL, profile: profile, origin: current.request.center, sourceIdentifier: identifier)
        var state = EarthPreparationWork(totalPlacements: current.selectedTileCount)
        do
        {
            try source.forEachPlacement
            { data in
                try Task.checkCancellation()
                try autoreleasepool
                {
                    let tile = try JSONDecoder().decode(EarthTileset.Tile.self, from: data)
                    guard let uri = tile.content?.uri, uri.hasPrefix("tiles/"), uri.hasSuffix(".glb"), tile.contents == nil, (tile.children ?? []).isEmpty else { throw EarthPreparationError.sourceChanged }
                    let id = String(uri.dropFirst(6).dropLast(4))
                    guard id.count == 64, id.allSatisfy({ $0.isASCII && ($0.isNumber || ("a" ... "f").contains(String($0))) }) else { throw EarthPreparationError.sourceChanged }
                    let asset: EarthPreparedAsset
                    if let existing = try index.asset(id: id) { asset = existing }
                    else
                    {
                        guard let saved = try source.payload(id), saved.completed else { throw EarthPreparationError.sourceChanged }
                        let sourceBudget = max(profile.maximumSourceBytesPerModel, EarthGeometrySubdivision.maximumSourceBytes)
                        guard saved.bytes <= sourceBudget else { throw EarthPreparationError.sourceWorkingSet(placement: state.inspected + 1) }
                        let url = try source.files.checked(uri, regularFile: true)
                        let integrity = try source.files.integrity(url)
                        guard integrity.bytes == saved.bytes, integrity.hash == saved.hash else { throw EarthPreparationError.sourceChanged }
                        // Mapping and parsing only this bounded payload avoids a
                        // whole-capture source array. No native mesh decode here.
                        let bytes = try Data(contentsOf: url, options: .mappedIfSafe)
                        let limits = EarthImportLimits(
                            maximumSourceBytes: sourceBudget,
                            maximumVertices: profile.maximumVerticesPerModel,
                            maximumTextureDimension: profile.maximumTextureDimension,
                            maximumDecodedTextureBytes: profile.maximumDecodedTextureBytesPerModel,
                            maximumNodes: profile.maximumNodesPerPayload
                        )
                        let estimate = try EarthGLBEstimate(limits: limits).estimate(data: bytes)
                        asset = EarthPreparedAsset(id: id, bytes: saved.bytes, hash: saved.hash, estimate: estimate)
                        try index.addAsset(asset)
                    }
                    let transform = try tile.localTransform()
                    let frame = try tile.boundingVolume.geographicOrigin(transform: transform)
                    let center = current.request.center.earthCenteredToLocal * simd_inverse(frame.earthCenteredToLocal).columns.3
                    func appendUnit(_ value: EarthPreparedAsset) throws
                    {
                        let localTile = EarthTileset.Tile(boundingVolume: tile.boundingVolume, geometricError: 0, transform: tile.transform, refine: "REPLACE", content: .init(uri: "tiles/\(value.id).glb"), contents: nil, children: nil, implicitTiling: nil)
                        try index.addUnit(EarthPreparationUnit(ordinal: state.plannedUnits + 1, tile: localTile, asset: value), east: center.x, south: center.z)
                        state.plannedUnits += 1
                    }
                    let manifest = try EarthPreparedCollectionFiles.modelManifest(tiles: [tile], profile: profile, origin: current.request.center, sourceIdentifier: identifier)
                    if profile.accepts(asset.estimate), asset.bytes <= profile.maximumSourceBytesPerModel - min(profile.maximumSourceBytesPerModel, manifest.count)
                    { try appendUnit(asset) }
                    else
                    {
                        if try index.forEachDerivative(sourceID: id, appendUnit) == 0
                        {
                            let url = try source.files.checked(uri, regularFile: true)
                            let bytes = try Data(contentsOf: url, options: .mappedIfSafe)
                            let maximumBytes = profile.maximumSourceBytesPerModel - min(profile.maximumSourceBytesPerModel, manifest.count)
                            guard maximumBytes > 0 else { throw EarthPreparationError.subdivisionWorkingSet }
                            var ordinal = 0
                            try EarthGeometrySubdivision(profile: profile).writeParts(data: bytes, sourceID: id, maximumPayloadBytes: maximumBytes)
                            { data, estimate in
                                try Task.checkCancellation()
                                let digest = EarthSourceAccess.digest(data)
                                let derived = EarthPreparedAsset(id: digest, bytes: data.count, hash: digest, estimate: estimate)
                                try EarthPreparedCollectionFiles.write(data, path: "derived/\(digest).glb", files: index.files)
                                try index.addDerivative(derived, sourceID: id, ordinal: ordinal)
                                ordinal += 1
                                try appendUnit(derived)
                            }
                            guard ordinal > 0 else { throw EarthPreparationError.subdivisionWorkingSet }
                        }
                    }
                    state.inspected += 1
                }
                report(phase: .inspecting, state: &state, progress: progress)
            }
            var group: [EarthPreparationUnit] = []
            var estimate = try EarthCaptureGeometryEstimate()
            var sourceBytes = 0
            var ids = Set<String>()
            func flush() throws
            {
                guard !group.isEmpty else { return }
                let id = state.completedModels + 1
                let manifest = try EarthPreparedCollectionFiles.modelManifest(tiles: group.map(\.tile), profile: profile, origin: current.request.center, sourceIdentifier: identifier)
                try EarthPreparedCollectionFiles.createModel(id: id, files: index.files)
                var copied = Set<String>()
                var assets: [EarthPreparedAsset] = []
                for unit in group where copied.insert(unit.asset.id).inserted
                {
                    try Task.checkCancellation()
                    let derived = try index.isDerivative(id: unit.asset.id)
                    try EarthPreparedCollectionFiles.copy(asset: unit.asset, source: derived ? index.files : source.files, sourcePath: "\(derived ? "derived" : "tiles")/\(unit.asset.id).glb", destination: index.files, destinationPath: "models/model-\(id)/tiles/\(unit.asset.id).glb")
                    assets.append(unit.asset)
                }
                try EarthPreparedCollectionFiles.write(manifest, path: "models/model-\(id)/tileset.json", files: index.files)
                try index.commitModel(id: id, tileCount: group.count, estimate: estimate, bytes: EarthCaptureGeometryEstimate.sum(sourceBytes, manifest.count), assets: assets)
                state.completedModels += 1
                state.writtenPlacements += group.count
                report(phase: .writing, state: &state, force: state.completedModels == 1, progress: progress)
                group.removeAll(keepingCapacity: true)
                estimate = try EarthCaptureGeometryEstimate()
                sourceBytes = 0
                ids.removeAll(keepingCapacity: true)
            }
            try index.forEachUnit
            { unit in
                try Task.checkCancellation()
                let combined = try estimate.adding(unit.asset.estimate)
                let bytes = try EarthCaptureGeometryEstimate.sum(sourceBytes, ids.contains(unit.asset.id) ? 0 : unit.asset.bytes)
                let candidate = try EarthPreparedCollectionFiles.modelManifest(tiles: group.map(\.tile) + [unit.tile], profile: profile, origin: current.request.center, sourceIdentifier: identifier)
                if !group.isEmpty && (!profile.accepts(combined) || group.count >= profile.maximumPlacementsPerModel || bytes > profile.maximumSourceBytesPerModel - min(candidate.count, profile.maximumSourceBytesPerModel))
                { try flush() }
                guard profile.accepts(unit.asset.estimate) else { throw EarthPreparationError.subdivisionRequired(placement: unit.ordinal) }
                let single = try EarthPreparedCollectionFiles.modelManifest(tiles: [unit.tile], profile: profile, origin: current.request.center, sourceIdentifier: identifier)
                guard unit.asset.bytes <= profile.maximumSourceBytesPerModel - min(single.count, profile.maximumSourceBytesPerModel) else { throw EarthPreparationError.sourceWorkingSet(placement: unit.ordinal) }
                group.append(unit)
                estimate = try estimate.adding(unit.asset.estimate)
                if ids.insert(unit.asset.id).inserted { sourceBytes = try EarthCaptureGeometryEstimate.sum(sourceBytes, unit.asset.bytes) }
            }
            try flush()
            try Task.checkCancellation()
            guard state.writtenPlacements == state.plannedUnits, state.inspected == current.selectedTileCount, state.completedModels > 0 else { throw EarthPreparationError.sourceChanged }
            try EarthPreparedCollectionFiles.writeRoot(index: index, selection: .all(), destination: index.files, coversEntireSource: true)
            try index.finish(.ready)
            report(phase: .writing, state: &state, force: true, progress: progress)
            return try index.snapshot()
        }
        catch
        {
            let issue: String
            if error is CancellationError { issue = "Model preparation cancelled. Completed models and the raw download are retained." }
            else if let error = error as? EarthPreparationError { issue = error.localizedDescription }
            else { issue = "Model preparation interrupted. Completed models and the raw download are retained." }
            try? index.finish(.partial, issue: issue)
            if error is CancellationError || error is EarthPreparationError || error is EarthImportError { throw error }
            throw EarthPreparationError.storage
        }
    }

    private nonisolated static func report(phase: EarthPreparationProgress.Phase, state: inout EarthPreparationWork, force: Bool = false, progress: @Sendable (EarthPreparationProgress) -> Void)
    {
        if force || state.lastProgress.duration(to: .now) >= .milliseconds(200)
        {
            progress(.init(phase: phase, processedPlacements: phase == .inspecting ? state.inspected : state.writtenPlacements, totalPlacements: phase == .inspecting ? state.totalPlacements : state.plannedUnits, completedModels: state.completedModels))
            state.lastProgress = .now
        }
    }
}

private struct EarthPreparationWork
{
    let totalPlacements: Int
    var inspected = 0
    var plannedUnits = 0
    var writtenPlacements = 0
    var completedModels = 0
    var lastProgress = ContinuousClock.now
}
