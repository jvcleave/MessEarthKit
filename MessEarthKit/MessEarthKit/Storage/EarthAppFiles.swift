import AppKit
import Foundation
import MessEarthKit

enum EarthAppFilesError: Error, Equatable, LocalizedError, Sendable
{
    case unavailableRoot
    case invalidLocation
    case missingFile
    case invalidMetadata
    case storage
    case deletionIncomplete
    case renameIncomplete
    case invalidExportName
    case exportInUse
    case exportChanged

    var errorDescription: String?
    {
        switch self
        {
            case .unavailableRoot: "The MessEarthKit storage folder is unavailable."
            case .invalidLocation: "The file location is outside its permitted storage area or contains an unsupported link."
            case .missingFile: "A required project file is missing."
            case .invalidMetadata: "The project metadata is empty, oversized or invalid."
            case .storage: "The file operation failed. Check folder access and available disk space."
            case .deletionIncomplete: "Deletion could not finish or fully restore its files. Refresh the project to review its saved state. Retained files may be in Trash or the project's deletion folder."
            case .renameIncomplete: "Rename could not finish or fully restore its files. Reload export history and review the export folder in Finder."
            case .exportChanged: "The exported file changed while the viewer was loading. Open it again."
            case .exportInUse: "An export is still loading in the viewer. Close it or wait for loading to finish before changing its files."
            case .invalidExportName: "Enter a shorter filename using letters, numbers, spaces, periods, hyphens or underscores. The export extension is kept."
        }
    }
}

enum EarthAppMetadata: Sendable
{
    case settings
    case exportQueue
    case project(UUID)
    case exports(UUID)
}

struct EarthProjectExportDestination: Sendable
{
    let id: UUID
    let fileURL: URL
}

enum EarthProjectArtifact: String, Sendable
{
    case sources, prepared, output
}

struct EarthProjectFileLocations: Sendable
{
    let id: UUID
    let directoryURL: URL
    let manifestURL: URL
    let sourcesURL: URL
    let preparedURL: URL
    let outputURL: URL
}

struct EarthAppDirectory: Sendable
{
    let url: URL
    let createdAt: Date
}

/// Retained by the operation or opened catalog, independently of its screen.
/// Creation is restricted to the app-files owner after validating access.
final class EarthFileAccess: @unchecked Sendable
{
    let url: URL
    fileprivate let isDirectory: Bool
    fileprivate let scopedURL: URL
    private let isAccessing: Bool

    fileprivate init(url: URL, isDirectory: Bool, scopedURL: URL)
    {
        self.url = url.standardizedFileURL
        self.isDirectory = isDirectory
        self.scopedURL = scopedURL
        isAccessing = scopedURL.startAccessingSecurityScopedResource()
    }

    deinit { if isAccessing { scopedURL.stopAccessingSecurityScopedResource() } }
}

/// Application policy and small metadata I/O only. SDK workers retain their
/// own streaming, SQLite connections and atomic artifact publication.
actor EarthAppFiles
{
    typealias Trash = @Sendable (URL) throws -> Void
    static let maximumMetadataBytes = 1024 * 1024
    nonisolated let storageRootURL: URL
    private let rootAccess: EarthFileAccess
    private var exportReads: [UUID: (projectID: UUID, exportID: UUID)] = [:]
    private let trash: Trash
    private var isMovingStorage = false
    private var storageWasMoved = false

    private struct StorageLocation: Codable
    {
        let version: Int
        let bookmark: Data
    }

    init(storageRootURL: URL, trash: @escaping Trash = EarthAppFiles.moveToTrash) throws
    {
        guard storageRootURL.isFileURL, !storageRootURL.pathComponents.contains(".."), storageRootURL.path != "/"
        else { throw EarthAppFilesError.invalidLocation }
        self.storageRootURL = storageRootURL.standardizedFileURL
        rootAccess = EarthFileAccess(url: storageRootURL, isDirectory: true, scopedURL: storageRootURL)
        self.trash = trash
    }

    @concurrent static func openDefault() async throws -> EarthAppFiles
    {
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        else { throw EarthAppFilesError.unavailableRoot }
        return try await openStorage(defaultRoot: documents.appendingPathComponent("MessEarthKit", isDirectory: true), selectionFile: storageLocationFileURL())
    }

    static func storageLocationFileURL() throws -> URL
    {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { throw EarthAppFilesError.unavailableRoot }
        return support.appendingPathComponent("MessEarthKit/StorageLocation.json")
    }

    /// The bootstrap selection stays outside movable project/settings storage.
    /// An explicit but unusable selection never falls back to a new library.
    @concurrent static func openStorage(defaultRoot: URL, selectionFile: URL) async throws -> EarthAppFiles
    {
        do
        {
            let files: EarthAppFiles
            let selectionAttributes: [FileAttributeKey: Any]?
            do { selectionAttributes = try FileManager.default.attributesOfItem(atPath: selectionFile.path) }
            catch let error as NSError where error.domain == NSCocoaErrorDomain && (error.code == NSFileNoSuchFileError || error.code == NSFileReadNoSuchFileError) { selectionAttributes = nil }
            if let selectionAttributes
            {
                guard selectionAttributes[.type] as? FileAttributeType == .typeRegular else { throw EarthStorageMoveError.bookmark }
                let input = try FileHandle(forReadingFrom: selectionFile)
                defer { try? input.close() }
                let data = try input.read(upToCount: maximumMetadataBytes + 1) ?? Data()
                guard !data.isEmpty, data.count <= maximumMetadataBytes else { throw EarthStorageMoveError.bookmark }
                let selection = try JSONDecoder().decode(StorageLocation.self, from: data)
                guard selection.version == 1, !selection.bookmark.isEmpty else { throw EarthStorageMoveError.bookmark }
                var stale = false
                let root = try URL(resolvingBookmarkData: selection.bookmark, options: [.withSecurityScope, .withoutUI, .withoutMounting], relativeTo: nil, bookmarkDataIsStale: &stale)
                files = try EarthAppFiles(storageRootURL: root)
                try await files.requireExistingStorage()
                if stale { try saveStorageLocation(root, selectionFile: selectionFile) }
            }
            else { files = try EarthAppFiles(storageRootURL: defaultRoot) }
            try await files.initialize()
            return files
        }
        catch let error as EarthStorageMoveError { throw error }
        catch { throw EarthAppFilesError.unavailableRoot }
    }

    /// Called only after app owners settle their jobs/saves and close databases.
    /// No actor reentrancy during copy/commit; old owners reject subsequent I/O.
    func moveStorage(to destination: URL, selectionFile: URL, progress: @Sendable (String) -> Void) throws -> EarthStorageMoveResult
    {
        guard !isMovingStorage, !storageWasMoved, exportReads.isEmpty else { throw EarthStorageMoveError.busy }
        let target = try EarthAppFiles(storageRootURL: destination)
        let relocation: EarthStorageRelocation
        do { relocation = try EarthStorageRelocation(source: storageRootURL, destination: target.storageRootURL, selectionFile: selectionFile) }
        catch let error as EarthStorageMoveError { throw error }
        catch { throw EarthStorageMoveError.unavailable }
        isMovingStorage = true
        defer { isMovingStorage = false }
        do
        {
            try relocation.copyAndPublish(progress: progress)
            try Task.checkCancellation()
            try Self.saveStorageLocation(destination, selectionFile: selectionFile)
        }
        catch
        {
            do { try relocation.rollback() }
            catch { throw EarthStorageMoveError.rollbackIncomplete }
            if error is CancellationError { throw CancellationError() }
            if let error = error as? EarthStorageMoveError { throw error }
            throw EarthStorageMoveError.failed
        }
        storageWasMoved = true
        progress("Removing previous storage copies…")
        let removed = relocation.removeOldCopies()
        return EarthStorageMoveResult(files: target, previousRoot: storageRootURL, oldCopiesRemain: !removed)
    }

    private func requireExistingStorage() throws
    {
        guard try attributes(storageRootURL)?[.type] as? FileAttributeType == .typeDirectory,
              FileManager.default.isWritableFile(atPath: storageRootURL.path)
        else { throw EarthStorageMoveError.unavailable }
    }

    private static func saveStorageLocation(_ root: URL, selectionFile: URL) throws
    {
        do
        {
            let bookmark = try root.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
            let data = try JSONEncoder().encode(StorageLocation(version: 1, bookmark: bookmark))
            guard data.count <= maximumMetadataBytes else { throw EarthStorageMoveError.bookmark }
            try FileManager.default.createDirectory(at: selectionFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: selectionFile, options: .atomic)
        }
        catch { throw EarthStorageMoveError.bookmark }
    }

    func initialize() throws
    {
        try ensureManagedDirectory(storageRootURL)
        try ensureManagedDirectory(storageRootURL.appendingPathComponent("projects", isDirectory: true))
        try ensureManagedDirectory(storageRootURL.appendingPathComponent("stats", isDirectory: true))
    }

    func projectLocations(id: UUID) throws -> EarthProjectFileLocations
    {
        let root = storageRootURL.appendingPathComponent("projects/\(id.uuidString)", isDirectory: true)
        _ = try checkedManagedURL(root)
        return EarthProjectFileLocations(
            id: id,
            directoryURL: root,
            manifestURL: root.appendingPathComponent("project.json"),
            sourcesURL: root.appendingPathComponent("sources", isDirectory: true),
            preparedURL: root.appendingPathComponent("prepared", isDirectory: true),
            outputURL: root.appendingPathComponent("output", isDirectory: true)
        )
    }

    func projectIDs() throws -> [UUID]
    {
        let parent = storageRootURL.appendingPathComponent("projects", isDirectory: true)
        _ = try checkedManagedURL(parent)
        do
        {
            return try FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]).map
            { url in
                _ = try checkedManagedURL(url)
                guard let id = UUID(uuidString: url.lastPathComponent), url.lastPathComponent == id.uuidString,
                      let values = try attributes(url), values[.type] as? FileAttributeType == .typeDirectory
                else { throw EarthAppFilesError.invalidLocation }
                return id
            }.sorted { $0.uuidString < $1.uuidString }
        }
        catch let error as EarthAppFilesError { throw error }
        catch { throw EarthAppFilesError.storage }
    }

    func createProjectMetadata(_ data: Data, id: UUID) throws
    {
        let folder = try projectLocations(id: id).directoryURL
        guard try attributes(folder) == nil else { throw EarthAppFilesError.invalidLocation }
        try writeMetadata(data, location: .project(id))
    }

    func trashProject(id: UUID) throws
    {
        guard !exportReads.values.contains(where: { $0.projectID == id }) else { throw EarthAppFilesError.exportInUse }
        let folder = try projectLocations(id: id).directoryURL
        guard let values = try attributes(folder), values[.type] as? FileAttributeType == .typeDirectory
        else { throw EarthAppFilesError.missingFile }
        do { try trash(folder) }
        catch { throw EarthAppFilesError.storage }
    }

    /// Detach metadata first so an interruption cannot leave live references to
    /// moved files. Normal failures restore files and the original metadata.
    func trashCaptures(projectID: UUID, deletionID: UUID, captureIDs: [UUID], preparationIDs: [UUID], originalMetadata: Data, updatedMetadata: Data) throws
    {
        guard try readMetadata(.project(projectID)) == originalMetadata else { throw EarthAppFilesError.invalidMetadata }
        let project = try projectLocations(id: projectID)
        var targets = captureIDs.map { project.sourcesURL.appendingPathComponent($0.uuidString, isDirectory: true) }
        targets += preparationIDs.map { project.preparedURL.appendingPathComponent($0.uuidString, isDirectory: true) }
        for target in targets
        {
            _ = try checkedManagedURL(target)
            if let values = try attributes(target), values[.type] as? FileAttributeType != .typeDirectory
            { throw EarthAppFilesError.invalidLocation }
        }
        let folder = project.directoryURL.appendingPathComponent("Deleted-Captures-\(deletionID.uuidString)-\(UUID().uuidString)", isDirectory: true)
        try ensureManagedDirectory(folder)
        var moved: [(original: URL, staged: URL)] = []
        var committed = false
        do
        {
            try writeMetadata(updatedMetadata, location: .project(projectID))
            committed = true
            for target in targets where try attributes(target) != nil
            {
                let staged = folder.appendingPathComponent("\(target.deletingLastPathComponent().lastPathComponent)-\(target.lastPathComponent)", isDirectory: true)
                try FileManager.default.moveItem(at: target, to: staged)
                moved.append((target, staged))
            }
            if moved.isEmpty { try FileManager.default.removeItem(at: folder) }
            else { try trash(folder) }
        }
        catch
        {
            do
            {
                for item in moved.reversed() { try FileManager.default.moveItem(at: item.staged, to: item.original) }
                if committed { try writeMetadata(originalMetadata, location: .project(projectID)) }
                try FileManager.default.removeItem(at: folder)
            }
            catch { throw EarthAppFilesError.deletionIncomplete }
            throw EarthAppFilesError.storage
        }
    }

    /// Creates parents only: SDK artifact writers require a new destination.
    func newArtifactDirectory(projectID: UUID, kind: EarthProjectArtifact) throws -> URL
    {
        let parent = try artifactParent(projectID: projectID, kind: kind)
        try ensureManagedDirectory(parent)
        let destination = parent.appendingPathComponent(UUID().uuidString, isDirectory: true)
        _ = try checkedManagedURL(destination)
        guard try attributes(destination) == nil else { throw EarthAppFilesError.invalidLocation }
        return destination
    }

    func artifactDirectories(projectID: UUID, kind: EarthProjectArtifact) throws -> [EarthAppDirectory]
    {
        let parent = try artifactParent(projectID: projectID, kind: kind)
        _ = try checkedManagedURL(parent)
        guard let values = try attributes(parent) else { return [] }
        guard values[.type] as? FileAttributeType == .typeDirectory else { throw EarthAppFilesError.invalidLocation }
        do
        {
            let urls = try FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            return try urls.map
            { url in
                _ = try checkedManagedURL(url)
                guard let values = try attributes(url), values[.type] as? FileAttributeType == .typeDirectory,
                      let date = values[.creationDate] as? Date else { throw EarthAppFilesError.invalidLocation }
                return EarthAppDirectory(url: url, createdAt: date)
            }.sorted { $0.createdAt > $1.createdAt }
        }
        catch let error as EarthAppFilesError { throw error }
        catch { throw EarthAppFilesError.storage }
    }

    /// Each export owns a fresh output folder; SDK publication creates the file.
    func newGLBExportDestination(projectID: UUID, name: String, detail: EarthProjectDetail, options: EarthGLBExportOptions) throws -> EarthProjectExportDestination
    {
        try newExportDestination(projectID: projectID, name: name, detail: detail, options: options, format: .glb)
    }

    func newExportDestination(projectID: UUID, name: String, detail: EarthProjectDetail, options: EarthExportOptions, format: EarthExportFormat, exportID: UUID = UUID()) throws -> EarthProjectExportDestination
    {
        let fileName = try exportFileName(name: name, detail: detail, options: options, format: format)
        let parent = try artifactParent(projectID: projectID, kind: .output)
        try ensureManagedDirectory(parent)
        let directory = parent.appendingPathComponent(exportID.uuidString, isDirectory: true)
        _ = try checkedManagedURL(directory)
        guard try attributes(directory) == nil else { throw EarthAppFilesError.invalidLocation }
        try ensureManagedDirectory(directory)
        guard let id = UUID(uuidString: directory.lastPathComponent) else { throw EarthAppFilesError.invalidLocation }
        return .init(id: id, fileURL: directory.appendingPathComponent(fileName))
    }

    /// Naming suggestions use the same rules without creating an output folder.
    /// Older files without recorded channel choices omit the content suffix.
    func glbExportFileName(name: String, detail: EarthProjectDetail, options: EarthGLBExportOptions?) throws -> String
    {
        try exportFileName(name: name, detail: detail, options: options, format: .glb)
    }

    func exportFileName(name: String, detail: EarthProjectDetail, options: EarthExportOptions?, format: EarthExportFormat) throws -> String
    {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_"))
        var stem = name.components(separatedBy: allowed.inverted).filter { !$0.isEmpty }.joined(separator: "_")
            .trimmingCharacters(in: CharacterSet(charactersIn: ".-_"))
        while stem.utf8.count > 200 { stem.removeLast() }
        guard !stem.isEmpty else { throw EarthLocationNamingError.invalidName }
        var suffix = ""
        if let options
        {
            var contents = ["geom"]
            if options.includeNormals { contents.append("norm") }
            if options.includeVertexColors { contents.append("vcol") }
            if options.includeTextureCoordinates { contents.append("uv") }
            if options.includeMaterials { contents.append("mat") }
            if options.includeTextures { contents.append("tex") }
            suffix = "_" + contents.joined(separator: "_")
        }
        let optimized = format.isOptimized ? "_optimized" : ""
        return "\(stem)_\(detail.title)\(optimized)\(suffix).\(format.fileExtension)"
    }

    /// Reentrant actor scope: loading never blocks unrelated metadata work, but
    /// mutations of this export/project cannot move files still used by a decoder.
    func withExportRead<Result: Sendable>(projectID: UUID, record: EarthProjectExportRecord, operation: @Sendable (URL, Int) async throws -> Result) async throws -> Result
    {
        try Task.checkCancellation()
        let url = try exportFileURL(projectID: projectID, record: record)
        let access = try accessForReading(url)
        guard let size = try exportFileByteCount(projectID: projectID, record: record), let before = try attributes(url) else { throw EarthAppFilesError.missingFile }
        let token = UUID()
        exportReads[token] = (projectID, record.id)
        defer { exportReads.removeValue(forKey: token); withExtendedLifetime(access) {} }
        let result = try await operation(url, size)
        try Task.checkCancellation()
        guard let after = try attributes(url), before[.size] as? NSNumber == after[.size] as? NSNumber,
              before[.modificationDate] as? Date == after[.modificationDate] as? Date,
              before[.systemFileNumber] as? NSNumber == after[.systemFileNumber] as? NSNumber
        else { throw EarthAppFilesError.exportChanged }
        return result
    }

    private func requireExportIdle(projectID: UUID, exportID: UUID) throws
    {
        guard !exportReads.values.contains(where: { $0.projectID == projectID && $0.exportID == exportID }) else { throw EarthAppFilesError.exportInUse }
    }

    func exportFileURL(projectID: UUID, record: EarthProjectExportRecord) throws -> URL
    {
        try record.validate()
        return try resolve(reference: record.reference, projectID: projectID)
    }

    func exportFileIsAvailable(projectID: UUID, record: EarthProjectExportRecord) throws -> Bool
    { try exportFileByteCount(projectID: projectID, record: record) != nil }

    func exportFileByteCount(projectID: UUID, record: EarthProjectExportRecord) throws -> Int?
    {
        let url = try exportFileURL(projectID: projectID, record: record)
        guard let values = try attributes(url) else { return nil }
        guard values[.type] as? FileAttributeType == .typeRegular, let size = values[.size] as? NSNumber
        else { throw EarthAppFilesError.invalidLocation }
        return size.intValue > 0 ? size.intValue : nil
    }

    /// Resolve exact saved identities, including a later history rename. Read
    /// tokens prevent project/output mutation until the copy worker settles.
    func collectExports(_ entries: [EarthExportQueueEntry], to parent: URL, progress: @escaping @Sendable (Int, Int) -> Void) async throws -> URL
    {
        guard !entries.isEmpty, !isMovingStorage, !storageWasMoved,
              parent.isFileURL, !parent.pathComponents.contains("..")
        else { throw EarthAppFilesError.invalidLocation }
        let access = EarthFileAccess(url: parent, isDirectory: true, scopedURL: parent)
        let resolved = parent.resolvingSymlinksInPath()
        guard try attributes(parent)?[.type] as? FileAttributeType == .typeDirectory,
              !resolved.pathComponents.map({ $0.lowercased() }).starts(with: storageRootURL.resolvingSymlinksInPath().pathComponents.map { $0.lowercased() }),
              FileManager.default.isWritableFile(atPath: parent.path)
        else { throw EarthAppFilesError.invalidLocation }
        var tokens: [UUID] = []
        defer
        {
            for token in tokens { exportReads.removeValue(forKey: token) }
            withExtendedLifetime(access) {}
            withExtendedLifetime(rootAccess) {}
        }
        var copies: [EarthExportCollectionFile] = []
        var names: Set<String> = []
        var histories: [UUID: [EarthProjectExportRecord]] = [:]
        for entry in entries
        {
            try entry.validate()
            guard entry.phase == .complete, let saved = entry.result else { throw EarthAppFilesError.missingFile }
            let projectID = entry.request.projectID
            if histories[projectID] == nil
            {
                do { histories[projectID] = try await EarthProjectExportHistoryStore(projectID: projectID, files: self).records() }
                catch
                {
                    // A published result with an explicit failed history write
                    // retains its own validated reference, even if history is bad.
                    guard entry.isUnrecorded else { throw error }
                }
            }
            // Reentrancy during history I/O must not admit a storage move.
            guard !isMovingStorage, !storageWasMoved else { throw EarthStorageMoveError.busy }
            let record: EarthProjectExportRecord
            if let current = histories[projectID]?.first(where: { $0.id == saved.id }) { record = current }
            else if entry.isUnrecorded { record = saved }
            else { throw EarthAppFilesError.missingFile }
            let source = try exportFileURL(projectID: projectID, record: record)
            guard try exportFileByteCount(projectID: projectID, record: record) != nil else { throw EarthAppFilesError.missingFile }
            let companion = EarthGLBInfo.companionURL(source)
            let hasCompanion = try record.format.isGLB && attributes(companion) != nil
            if hasCompanion
            {
                _ = try checkedManagedURL(companion)
                guard try attributes(companion)?[.type] as? FileAttributeType == .typeRegular else { throw EarthAppFilesError.invalidLocation }
            }
            let fileExtension = source.pathExtension
            let originalStem = source.deletingPathExtension().lastPathComponent
            var name = record.fileName
            var suffix = 2
            while names.contains(name.lowercased()) || (hasCompanion && names.contains((name + ".info.json").lowercased()))
            {
                let ending = "_\(suffix).\(fileExtension)"
                var stem = originalStem
                while (stem + ending).utf8.count > 245 { stem.removeLast() }
                name = stem + ending
                suffix += 1
            }
            names.insert(name.lowercased())
            copies.append(.init(source: source, name: name))
            if hasCompanion
            {
                names.insert((name + ".info.json").lowercased())
                copies.append(.init(source: companion, name: name + ".info.json"))
            }
            let token = UUID()
            exportReads[token] = (projectID, record.id)
            tokens.append(token)
        }
        return try await EarthExportCollection.copy(files: copies, to: resolved, progress: progress)
    }

    /// Keep the optional companion with its GLB. All moves and the metadata
    /// write run without actor suspension; ordinary failures restore the files.
    func renameExport(projectID: UUID, record: EarthProjectExportRecord, name: String, originalMetadata: Data, updatedMetadata: Data) throws
    {
        try requireExportIdle(projectID: projectID, exportID: record.id)
        guard try readMetadata(.exports(projectID)) == originalMetadata else { throw EarthAppFilesError.invalidMetadata }
        let renamed = try record.renamed(to: name)
        guard try exportFileIsAvailable(projectID: projectID, record: record) else { throw EarthAppFilesError.missingFile }
        if renamed.fileName == record.fileName { return }
        let original = try exportFileURL(projectID: projectID, record: record)
        let destination = try exportFileURL(projectID: projectID, record: renamed)
        var moves = [(original: original, destination: destination)]
        if record.format == .glb
        {
            let companion = try checkedManagedURL(EarthGLBInfo.companionURL(original))
            let renamedCompanion = try checkedManagedURL(EarthGLBInfo.companionURL(destination))
            if let values = try attributes(companion)
            {
                guard values[.type] as? FileAttributeType == .typeRegular else { throw EarthAppFilesError.invalidLocation }
                moves.append((companion, renamedCompanion))
            }
            // Also reserve the optional companion's destination when absent.
            try checkExportRenameDestination(renamedCompanion, original: companion)
        }
        for move in moves { try checkExportRenameDestination(move.destination, original: move.original) }
        var moved: [(original: URL, destination: URL)] = []
        do
        {
            for move in moves
            {
                try FileManager.default.moveItem(at: move.original, to: move.destination)
                moved.append(move)
            }
            try writeMetadata(updatedMetadata, location: .exports(projectID))
        }
        catch
        {
            do { for item in moved.reversed() { try FileManager.default.moveItem(at: item.destination, to: item.original) } }
            catch { throw EarthAppFilesError.renameIncomplete }
            if let error = error as? EarthAppFilesError { throw error }
            throw EarthAppFilesError.storage
        }
    }

    private func checkExportRenameDestination(_ destination: URL, original: URL) throws
    {
        guard let values = try attributes(destination) else { return }
        // A case-only rename on a case-insensitive volume resolves to the same
        // file. FileManager supports that move without replacing another file.
        guard destination.lastPathComponent.compare(original.lastPathComponent, options: .caseInsensitive) == .orderedSame,
              let originalValues = try attributes(original),
              let originalNumber = originalValues[.systemFileNumber] as? NSNumber,
              let destinationNumber = values[.systemFileNumber] as? NSNumber,
              originalNumber == destinationNumber
        else { throw EarthAppFilesError.invalidLocation }
    }

    /// Detach history before moving the export's entire UUID folder to Trash.
    /// A missing folder can still be explicitly removed from history.
    func trashExport(projectID: UUID, record: EarthProjectExportRecord, originalMetadata: Data, updatedMetadata: Data) throws
    {
        try requireExportIdle(projectID: projectID, exportID: record.id)
        guard try readMetadata(.exports(projectID)) == originalMetadata else { throw EarthAppFilesError.invalidMetadata }
        let directory = try exportFileURL(projectID: projectID, record: record).deletingLastPathComponent()
        try validateArtifactDirectory(directory, projectID: projectID, kind: .output)
        let values = try attributes(directory)
        if let values, values[.type] as? FileAttributeType != .typeDirectory { throw EarthAppFilesError.invalidLocation }
        try writeMetadata(updatedMetadata, location: .exports(projectID))
        do { if values != nil { try trash(directory) } }
        catch
        {
            do { try writeMetadata(originalMetadata, location: .exports(projectID)) }
            catch { throw EarthAppFilesError.deletionIncomplete }
            throw EarthAppFilesError.storage
        }
    }

    func discardEmptyExportDirectory(containing fileURL: URL, projectID: UUID) throws
    {
        let directory = fileURL.deletingLastPathComponent()
        try validateArtifactDirectory(directory, projectID: projectID, kind: .output)
        do
        {
            guard try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty else { return }
            try FileManager.default.removeItem(at: directory)
        }
        catch { throw EarthAppFilesError.storage }
    }

    func requestUsageURL() throws -> URL
    {
        let folder = storageRootURL.appendingPathComponent("stats", isDirectory: true)
        try ensureManagedDirectory(folder)
        let url = folder.appendingPathComponent("RequestUsage.sqlite")
        for suffix in ["", "-wal", "-shm", "-journal"]
        {
            let file = URL(fileURLWithPath: url.path + suffix)
            _ = try checkedManagedURL(file)
            if let values = try attributes(file), values[.type] as? FileAttributeType != .typeRegular
            { throw EarthAppFilesError.invalidLocation }
        }
        return url
    }

    func validateArtifactDirectory(_ url: URL, projectID: UUID, kind: EarthProjectArtifact) throws
    {
        let parent = try artifactParent(projectID: projectID, kind: kind)
        guard UUID(uuidString: url.lastPathComponent) != nil,
              url.standardizedFileURL.pathComponents == parent.appendingPathComponent(url.lastPathComponent).standardizedFileURL.pathComponents
        else { throw EarthAppFilesError.invalidLocation }
        _ = try checkedManagedURL(url)
    }

    func resolve(reference: String, projectID: UUID) throws -> URL
    {
        let components = reference.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty, components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\\") && !$0.contains("\0") })
        else { throw EarthAppFilesError.invalidLocation }
        let root = try projectLocations(id: projectID).directoryURL
        let url = root.appendingPathComponent(reference)
        _ = try checkedManagedURL(url)
        guard contains(url, root: root) else { throw EarthAppFilesError.invalidLocation }
        return url
    }

    func readMetadata(_ location: EarthAppMetadata) throws -> Data?
    {
        let url = try metadataURL(location)
        _ = try checkedManagedURL(url)
        guard let values = try attributes(url)
        else
        {
            switch location
            {
                case .settings, .exportQueue, .exports: return nil
                case .project: throw EarthAppFilesError.missingFile
            }
        }
        guard values[.type] as? FileAttributeType == .typeRegular,
              let size = values[.size] as? NSNumber, size.intValue > 0, size.intValue <= Self.maximumMetadataBytes
        else { throw EarthAppFilesError.invalidMetadata }
        do
        {
            let file = try FileHandle(forReadingFrom: url)
            defer { try? file.close() }
            let data = try file.read(upToCount: Self.maximumMetadataBytes + 1) ?? Data()
            guard !data.isEmpty, data.count <= Self.maximumMetadataBytes else { throw EarthAppFilesError.invalidMetadata }
            return data
        }
        catch let error as EarthAppFilesError { throw error }
        catch { throw EarthAppFilesError.storage }
    }

    func writeMetadata(_ data: Data, location: EarthAppMetadata) throws
    {
        guard !data.isEmpty, data.count <= Self.maximumMetadataBytes else { throw EarthAppFilesError.invalidMetadata }
        let url = try metadataURL(location)
        try ensureManagedDirectory(url.deletingLastPathComponent())
        _ = try checkedManagedURL(url)
        if let values = try attributes(url), values[.type] as? FileAttributeType != .typeRegular
        { throw EarthAppFilesError.invalidLocation }
        do { try data.write(to: url, options: .atomic) }
        catch { throw EarthAppFilesError.storage }
    }

    func accessForReading(_ url: URL) throws -> EarthFileAccess
    {
        guard url.isFileURL, !url.pathComponents.contains("..") else { throw EarthAppFilesError.invalidLocation }
        // Start the scope before inspecting a user-authorized external URL.
        let scopedURL = contains(url, root: storageRootURL) ? rootAccess.scopedURL : url
        let access = EarthFileAccess(url: url, isDirectory: true, scopedURL: scopedURL)
        guard let values = try attributes(url), let type = values[.type] as? FileAttributeType,
              type == .typeDirectory || type == .typeRegular else { throw EarthAppFilesError.missingFile }
        if contains(url, root: storageRootURL) { _ = try checkedManagedURL(url) }
        return type == .typeDirectory ? access : EarthFileAccess(url: url, isDirectory: false, scopedURL: scopedURL)
    }

    func accessForExport(_ url: URL) throws -> EarthFileAccess
    {
        guard url.isFileURL, !url.pathComponents.contains("..") else { throw EarthAppFilesError.invalidLocation }
        let access = EarthFileAccess(url: url, isDirectory: true, scopedURL: contains(url, root: storageRootURL) ? rootAccess.scopedURL : url)
        if contains(url, root: storageRootURL)
        {
            _ = try checkedManagedURL(url)
            let relative = Array(url.standardizedFileURL.pathComponents.dropFirst(storageRootURL.pathComponents.count))
            guard relative.count >= 4, relative[0] == "projects", UUID(uuidString: relative[1]) != nil,
                  relative[2] == EarthProjectArtifact.output.rawValue else { throw EarthAppFilesError.invalidLocation }
        }
        guard try attributes(url) == nil else { throw EarthAppFilesError.invalidLocation }
        let parent = url.deletingLastPathComponent()
        guard let values = try attributes(parent), values[.type] as? FileAttributeType == .typeDirectory,
              FileManager.default.isWritableFile(atPath: parent.path) else { throw EarthAppFilesError.storage }
        return access
    }

    func isPreparedCollection(directoryURL: URL, access: EarthFileAccess) throws -> Bool
    {
        try checkAccess(directoryURL, access: access)
        guard access.isDirectory else { return false }
        let marker = directoryURL.appendingPathComponent("preparation.sqlite")
        try checkAccess(marker, access: access)
        guard let values = try attributes(marker) else { return false }
        guard values[.type] as? FileAttributeType == .typeRegular else { throw EarthAppFilesError.invalidLocation }
        return true
    }

    func reveal(_ url: URL) async
    {
        await MainActor.run { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }

    private nonisolated static func moveToTrash(_ url: URL) throws
    {
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }

    private func metadataURL(_ location: EarthAppMetadata) throws -> URL
    {
        switch location
        {
            case .settings: return storageRootURL.appendingPathComponent("appSettings.json")
            case .exportQueue: return storageRootURL.appendingPathComponent("exportQueue.json")
            case let .project(id): return try projectLocations(id: id).manifestURL
            case let .exports(id):
                let project = try projectLocations(id: id)
                guard let values = try attributes(project.manifestURL), values[.type] as? FileAttributeType == .typeRegular
                else { throw EarthAppFilesError.missingFile }
                return project.directoryURL.appendingPathComponent("exports.json")
        }
    }

    private func artifactParent(projectID: UUID, kind: EarthProjectArtifact) throws -> URL
    {
        try projectLocations(id: projectID).directoryURL.appendingPathComponent(kind.rawValue, isDirectory: true)
    }

    private func contains(_ url: URL, root: URL) -> Bool
    {
        url.standardizedFileURL.pathComponents.starts(with: root.standardizedFileURL.pathComponents)
    }

    private func checkedManagedURL(_ url: URL) throws -> URL
    {
        guard !isMovingStorage, !storageWasMoved else { throw EarthStorageMoveError.busy }
        guard url.isFileURL, !url.pathComponents.contains(".."), contains(url, root: storageRootURL)
        else { throw EarthAppFilesError.invalidLocation }
        let checked = url.standardizedFileURL
        var current = storageRootURL
        let relative = checked.pathComponents.dropFirst(storageRootURL.pathComponents.count)
        for component in [""] + Array(relative)
        {
            if !component.isEmpty { current.appendPathComponent(component) }
            if let values = try attributes(current), values[.type] as? FileAttributeType == .typeSymbolicLink
            { throw EarthAppFilesError.invalidLocation }
        }
        guard contains(checked.resolvingSymlinksInPath(), root: storageRootURL.resolvingSymlinksInPath())
        else { throw EarthAppFilesError.invalidLocation }
        return checked
    }

    private func ensureManagedDirectory(_ url: URL) throws
    {
        _ = try checkedManagedURL(url)
        if let values = try attributes(url)
        {
            guard values[.type] as? FileAttributeType == .typeDirectory else { throw EarthAppFilesError.invalidLocation }
            return
        }
        do { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        catch { throw EarthAppFilesError.storage }
        _ = try checkedManagedURL(url)
    }

    private func checkAccess(_ url: URL, access: EarthFileAccess) throws
    {
        guard url.isFileURL, !url.pathComponents.contains(".."),
              url.standardizedFileURL == access.url || (access.isDirectory && contains(url, root: access.url)),
              url.resolvingSymlinksInPath() == access.url.resolvingSymlinksInPath()
              || (access.isDirectory && contains(url.resolvingSymlinksInPath(), root: access.url.resolvingSymlinksInPath()))
        else { throw EarthAppFilesError.invalidLocation }
        if contains(url, root: storageRootURL) { _ = try checkedManagedURL(url) }
    }

    private func attributes(_ url: URL) throws -> [FileAttributeKey: Any]?
    {
        do { return try FileManager.default.attributesOfItem(atPath: url.path) }
        catch let error as NSError where error.domain == NSCocoaErrorDomain && (error.code == NSFileNoSuchFileError || error.code == NSFileReadNoSuchFileError) { return nil }
        catch { throw EarthAppFilesError.storage }
    }
}
