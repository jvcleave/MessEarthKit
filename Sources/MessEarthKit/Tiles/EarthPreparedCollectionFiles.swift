import CryptoKit
import Foundation

enum EarthPreparedCollectionFiles
{
    static func validateDestination(_ destination: URL, outside source: URL) throws
    {
        let input = source.standardizedFileURL.resolvingSymlinksInPath().path
        let output = destination.standardizedFileURL.resolvingSymlinksInPath().path
        guard destination.isFileURL, output != input, !output.hasPrefix(input + "/") else { throw EarthPreparationError.invalidDestination }
    }

    static func createModel(id: Int, files: EarthAcquisitionFiles) throws
    {
        do
        {
            let directory = try files.checked("models/model-\(id)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            try FileManager.default.createDirectory(at: directory.appendingPathComponent("tiles"), withIntermediateDirectories: false)
        }
        catch { throw EarthPreparationError.storage }
    }

    /// Explicit bounded copy: never hard-link a derivative to immutable sources.
    static func copy(asset: EarthPreparedAsset, source: EarthAcquisitionFiles, sourcePath: String, destination: EarthAcquisitionFiles, destinationPath: String) throws
    {
        do
        {
            let input = try FileHandle(forReadingFrom: source.checked(sourcePath, regularFile: true))
            defer { try? input.close() }
            let staging = try destination.checked("staging/payload.partial")
            guard FileManager.default.createFile(atPath: staging.path, contents: nil) else { throw EarthPreparationError.storage }
            let output = try FileHandle(forWritingTo: staging)
            defer { try? output.close() }
            var hash = SHA256()
            var count = 0
            while let data = try input.read(upToCount: 1024 * 1024), !data.isEmpty
            {
                try Task.checkCancellation()
                count = try EarthCaptureGeometryEstimate.sum(count, data.count)
                guard count <= asset.bytes else { throw EarthPreparationError.sourceChanged }
                hash.update(data: data)
                try output.write(contentsOf: data)
            }
            guard count == asset.bytes, hash.finalize().map({ String(format: "%02x", $0) }).joined() == asset.hash else { throw EarthPreparationError.sourceChanged }
            try output.close()
            try destination.publish(staging: staging, path: destinationPath)
        }
        catch is CancellationError { throw CancellationError() }
        catch let error as EarthPreparationError { throw error }
        catch { throw EarthPreparationError.storage }
    }

    static func modelManifest(tiles: [EarthTileset.Tile], profile: EarthPreparationProfile, origin: EarthGeographicOrigin, sourceIdentifier: String) throws -> Data
    {
        let manifest = try EarthCaptureCollectionBuilder.manifest(children: tiles, origin: origin, incompleteReason: nil, isCollection: false)
        return try addingPreparationMetadata(manifest, profile: profile, sourceIdentifier: sourceIdentifier, coversEntireSource: false)
    }

    static func write(_ data: Data, path: String, files: EarthAcquisitionFiles) throws
    {
        do
        {
            let staging = try files.checked("staging/manifest.partial")
            try data.write(to: staging)
            try files.publish(staging: staging, path: path)
        }
        catch { throw EarthPreparationError.storage }
    }

    /// Only a fixed-size header and one catalog row are materialized at a time.
    static func writeRoot(index: EarthPreparationIndex, selection: EarthModelSelection, destination: EarthAcquisitionFiles, coversEntireSource: Bool, incompleteReason: String? = nil) throws
    {
        let snapshot = try index.snapshot()
        let template = try EarthCaptureCollectionBuilder.manifest(children: [], origin: snapshot.geographicOrigin, incompleteReason: incompleteReason, isCollection: true)
        let data = try addingPreparationMetadata(template, profile: snapshot.profile, sourceIdentifier: snapshot.sourceIdentifier, coversEntireSource: coversEntireSource)
        guard let range = data.range(of: Data("\"children\":[]".utf8)) else { throw EarthPreparationError.invalidCollection }
        do
        {
            let staging = try destination.checked("staging/root.partial")
            guard FileManager.default.createFile(atPath: staging.path, contents: nil) else { throw EarthPreparationError.storage }
            let output = try FileHandle(forWritingTo: staging)
            defer { try? output.close() }
            try output.write(contentsOf: data[..<range.lowerBound])
            try output.write(contentsOf: Data("\"children\":[".utf8))
            var first = true
            try index.forEachModel
            { model in
                try Task.checkCancellation()
                guard selection.includes(model.id) else { return }
                let child = EarthTileset.Tile(
                    boundingVolume: EarthCaptureCollectionBuilder.rootBounds(origin: snapshot.geographicOrigin),
                    geometricError: 0,
                    transform: nil,
                    refine: "REPLACE",
                    content: .init(uri: "models/model-\(model.id)/tileset.json"),
                    contents: nil,
                    children: nil,
                    implicitTiling: nil
                )
                if !first { try output.write(contentsOf: Data([44])) }
                try output.write(contentsOf: JSONEncoder().encode(child))
                first = false
            }
            try output.write(contentsOf: Data([93]))
            try output.write(contentsOf: data[range.upperBound...])
            try output.close()
            try destination.publish(staging: staging, path: "tileset.json")
        }
        catch is CancellationError { throw CancellationError() }
        catch let error as EarthPreparationError { throw error }
        catch { throw EarthPreparationError.storage }
    }

    static func export(collection: EarthPreparedCollection, selection: EarthModelSelection, directoryURL: URL) throws -> URL
    {
        try Task.checkCancellation()
        let source = try EarthPreparationIndex(directoryURL: collection.directoryURL)
        let snapshot = try source.snapshot()
        let selected = try source.validate(selection)
        guard selected > 0 else { throw EarthPreparationError.invalidCollection }
        try validateDestination(directoryURL, outside: collection.directoryURL)
        guard directoryURL.isFileURL, !FileManager.default.fileExists(atPath: directoryURL.path) else { throw EarthPreparationError.invalidCollection }
        let entire = snapshot.coversEntireSource && selected == snapshot.modelCount
        let destination = try EarthPreparationIndex(directoryURL: directoryURL, profile: snapshot.profile, origin: snapshot.geographicOrigin, sourceIdentifier: snapshot.sourceIdentifier, coversEntireSource: entire)
        do
        {
            func copyModel(_ model: EarthPreparedModel) throws
            {
                try Task.checkCancellation()
                try EarthPreparedCollectionFiles.createModel(id: model.id, files: destination.files)
                var assets: [EarthPreparedAsset] = []
                try source.forEachAsset(modelID: model.id)
                { asset in
                    let path = "models/model-\(model.id)/tiles/\(asset.id).glb"
                    try EarthPreparedCollectionFiles.copy(asset: asset, source: source.files, sourcePath: path, destination: destination.files, destinationPath: path)
                    assets.append(asset)
                }
                guard let length = try model.rootSourceURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                      length > 0, length <= snapshot.profile.maximumSourceBytesPerModel else { throw EarthPreparationError.invalidCollection }
                let manifest = try Data(contentsOf: model.rootSourceURL, options: .mappedIfSafe)
                guard manifest.count == length else { throw EarthPreparationError.sourceChanged }
                try EarthPreparedCollectionFiles.write(manifest, path: "models/model-\(model.id)/tileset.json", files: destination.files)
                try destination.commitModel(id: model.id, tileCount: model.tileCount, estimate: model.estimate, bytes: model.sourceByteCount, assets: assets)
            }
            switch selection
            {
                case let .only(ids):
                    for id in ids.sorted() { try copyModel(source.model(id: id)) }
                case .all:
                    try source.forEachModel { if selection.includes($0.id) { try copyModel($0) } }
            }
            let issue = snapshot.state == .ready ? nil : snapshot.interruptionReason ?? "Model preparation is incomplete."
            try EarthPreparedCollectionFiles.writeRoot(index: destination, selection: .all(), destination: destination.files, coversEntireSource: entire, incompleteReason: issue)
            try destination.finish(issue == nil ? .ready : .partial, issue: issue)
            return directoryURL.appendingPathComponent("tileset.json")
        }
        catch
        {
            // Export owns only this newly created destination; source/preparation
            // jobs have separate retention and are never rolled back here.
            try? FileManager.default.removeItem(at: directoryURL)
            if error is CancellationError || error is EarthPreparationError || error is EarthImportError { throw error }
            throw EarthPreparationError.storage
        }
    }

    private static func addingPreparationMetadata(_ data: Data, profile: EarthPreparationProfile, sourceIdentifier: String, coversEntireSource: Bool) throws -> Data
    {
        var json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        var extras = json["extras"] as? [String: Any] ?? [:]
        extras["messEarthKitPreparation"] = ["formatVersion": 1, "profile": try JSONSerialization.jsonObject(with: JSONEncoder().encode(profile)), "sourceIdentifier": sourceIdentifier, "coversEntireSource": coversEntireSource]
        json["extras"] = extras
        return try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys, .withoutEscapingSlashes])
    }
}
