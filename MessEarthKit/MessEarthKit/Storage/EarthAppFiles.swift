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

    var errorDescription: String?
    {
        switch self
        {
            case .unavailableRoot: "The MessEarthKit documents folder is unavailable."
            case .invalidLocation: "The file location is outside its permitted storage area or contains an unsupported link."
            case .missingFile: "A required project file is missing."
            case .invalidMetadata: "The project metadata is empty, oversized or invalid."
            case .storage: "The file operation failed. Check folder access and available disk space."
            case .deletionIncomplete: "Deletion could not finish or fully restore its files. Refresh the project to review its saved state. Retained files may be in Trash or the project's deletion folder."
        }
    }
}

enum EarthAppMetadata: Sendable
{
    case settings
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
    private let scopedURL: URL
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
    private let trash: Trash

    init(storageRootURL: URL, trash: @escaping Trash = EarthAppFiles.moveToTrash) throws
    {
        guard storageRootURL.isFileURL, !storageRootURL.pathComponents.contains(".."), storageRootURL.path != "/"
        else { throw EarthAppFilesError.invalidLocation }
        self.storageRootURL = storageRootURL.standardizedFileURL
        self.trash = trash
    }

    static func openDefault() async throws -> EarthAppFiles
    {
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        else { throw EarthAppFilesError.unavailableRoot }
        let files = try EarthAppFiles(storageRootURL: documents.appendingPathComponent("MessEarthKit", isDirectory: true))
        try await files.initialize()
        return files
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
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_"))
        var stem = name.components(separatedBy: allowed.inverted).filter { !$0.isEmpty }.joined(separator: "_")
            .trimmingCharacters(in: CharacterSet(charactersIn: ".-_"))
        while stem.utf8.count > 200 { stem.removeLast() }
        guard !stem.isEmpty else { throw EarthLocationNamingError.invalidName }
        var contents = ["geom"]
        if options.includeNormals { contents.append("norm") }
        if options.includeVertexColors { contents.append("vcol") }
        if options.includeTextureCoordinates { contents.append("uv") }
        if options.includeMaterials { contents.append("mat") }
        if options.includeTextures { contents.append("tex") }
        let suffix = contents.joined(separator: "_")
        let directory = try newArtifactDirectory(projectID: projectID, kind: .output)
        try ensureManagedDirectory(directory)
        guard let id = UUID(uuidString: directory.lastPathComponent) else { throw EarthAppFilesError.invalidLocation }
        return .init(id: id, fileURL: directory.appendingPathComponent("\(stem)_\(detail.title)_\(suffix).glb"))
    }

    func exportFileURL(projectID: UUID, record: EarthProjectExportRecord) throws -> URL
    {
        try record.validate()
        return try resolve(reference: record.reference, projectID: projectID)
    }

    func exportFileIsAvailable(projectID: UUID, record: EarthProjectExportRecord) throws -> Bool
    {
        let url = try exportFileURL(projectID: projectID, record: record)
        guard let values = try attributes(url) else { return false }
        guard values[.type] as? FileAttributeType == .typeRegular, let size = values[.size] as? NSNumber
        else { throw EarthAppFilesError.invalidLocation }
        return size.intValue > 0
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
                case .settings, .exports: return nil
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
        let access = EarthFileAccess(url: url, isDirectory: true, scopedURL: url)
        guard let values = try attributes(url), let type = values[.type] as? FileAttributeType,
              type == .typeDirectory || type == .typeRegular else { throw EarthAppFilesError.missingFile }
        if contains(url, root: storageRootURL) { _ = try checkedManagedURL(url) }
        return type == .typeDirectory ? access : EarthFileAccess(url: url, isDirectory: false, scopedURL: url)
    }

    func accessForExport(_ url: URL) throws -> EarthFileAccess
    {
        guard url.isFileURL, !url.pathComponents.contains("..") else { throw EarthAppFilesError.invalidLocation }
        let access = EarthFileAccess(url: url, isDirectory: true, scopedURL: url)
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
