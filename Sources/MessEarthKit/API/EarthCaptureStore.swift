import Foundation

/// Writes original source payloads plus the local tileset manifest to a new
/// ordinary directory. The caller owns destination authorization and retention.
public actor EarthCaptureStore
{
    public init() {}

    /// Adds or refreshes optional display identity on a prepared catalog and
    /// each independently importable model. No source payload is decoded/changed.
    /// Callers retain authorization for the collection throughout this operation.
    public func recordIdentity(_ identity: EarthCaptureIdentity, collection: EarthPreparedCollection) throws
    {
        try Task.checkCancellation()
        try identity.validate()
        let index = try EarthPreparationIndex(directoryURL: collection.directoryURL)
        let lock = try EarthAcquisitionLock(files: index.files)
        defer { withExtendedLifetime(lock) {} }
        let current = try index.snapshot()
        guard current.sourceIdentifier == collection.sourceIdentifier,
              current.profile == collection.profile, current.modelCount == collection.modelCount,
              current.state == collection.state, current.state != .preparing,
              identity.request.center == current.geographicOrigin
        else { throw EarthPreparationError.sourceChanged }
        if let saved = try EarthPreparedCaptureInfo.read(files: index.files),
           saved.info.identity == identity, saved.info.modelID == nil
        { return }
        try index.forEachModel
        { model in
            try Task.checkCancellation()
            let data = try EarthPreparedCaptureInfo(identity: identity, modelID: model.id).encoded()
            try EarthPreparedCollectionFiles.write(data, path: "models/model-\(model.id)/" + EarthPreparedCaptureInfo.fileName, files: index.files)
        }
        try Task.checkCancellation()
        // Root publication marks a complete annotation. A retry after interruption
        // rewrites the model companions before publishing this final snapshot.
        try EarthPreparedCollectionFiles.write(EarthPreparedCaptureInfo(identity: identity).encoded(), path: EarthPreparedCaptureInfo.fileName, files: index.files)
    }

    /// Exports a paged file-backed catalog without materializing source Data or
    /// decoding models. Original IDs, placement and destination profile survive.
    @discardableResult
    public func save(collection: EarthPreparedCollection, selection: EarthModelSelection = .all(), directoryURL: URL) throws -> URL
    {
        try EarthPreparedCollectionFiles.export(collection: collection, selection: selection, directoryURL: directoryURL)
    }

    @discardableResult
    public func save(collection: EarthCaptureCollection, directoryURL: URL) throws -> URL
    {
        try write(sourceFiles: collection.sourceFiles(), rootSourcePath: "tileset.json", directoryURL: directoryURL)
    }

    @discardableResult
    public func save(capture: EarthCapture, directoryURL: URL) throws -> URL
    {
        try write(sourceFiles: capture.sourceFiles, rootSourcePath: capture.rootSourcePath, directoryURL: directoryURL)
    }

    private func write(sourceFiles: [EarthSourceFile], rootSourcePath: String, directoryURL: URL) throws -> URL
    {
        try Task.checkCancellation()
        guard directoryURL.isFileURL, !FileManager.default.fileExists(atPath: directoryURL.path)
        else { throw EarthImportError.inaccessibleSource("Choose a new capture folder; existing folders are not replaced.") }
        let root = directoryURL.standardizedFileURL
        for file in sourceFiles
        {
            let destination = root.appendingPathComponent(file.relativePath).standardizedFileURL
            guard !file.relativePath.hasPrefix("/"), destination.path.hasPrefix(root.path + "/")
            else { throw EarthImportError.invalidContent("Capture paths must stay inside their destination folder.") }
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        do
        {
            for file in sourceFiles
            {
                try Task.checkCancellation()
                let destination = root.appendingPathComponent(file.relativePath)
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try file.data.write(to: destination, options: .atomic)
            }
            try Task.checkCancellation()
            return root.appendingPathComponent(rootSourcePath)
        }
        catch
        {
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }
}
