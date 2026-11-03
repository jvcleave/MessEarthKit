import CryptoKit
import Foundation

enum EarthStorageMoveError: Error, LocalizedError, Sendable
{
    case busy, destinationNotEmpty, overlap, unavailable, changed, bookmark, failed, rollbackIncomplete

    var errorDescription: String?
    {
        switch self
        {
            case .busy: "Finish or stop active work and save pending changes before moving storage."
            case .destinationNotEmpty: "Choose an empty folder. Existing libraries and other files are not merged."
            case .overlap: "Choose a folder outside the current storage folder, its parents, and the app's storage-location settings."
            case .unavailable: "The selected storage folder is unavailable or cannot be written. Reconnect its drive or choose an accessible folder."
            case .changed: "Storage files changed during the move. The original library has been kept."
            case .bookmark: "The saved storage location could not be read or written. The original library has been kept."
            case .failed: "Storage could not be moved. The original library has been kept. Check folder access and available disk space."
            case .rollbackIncomplete: "The original library is intact, but incomplete copies remain in the selected folder. Review that folder in Finder before retrying."
        }
    }
}

struct EarthStorageMoveResult: Sendable
{
    let files: EarthAppFiles
    let previousRoot: URL
    let oldCopiesRemain: Bool
}

/// File-owner-confined transaction. Stage only managed entries in a new private
/// folder, verify unchanged bytes, then publish into an explicitly empty root.
final class EarthStorageRelocation
{
    private struct Entry: Equatable
    {
        let path: String
        let isDirectory: Bool
        let size: UInt64
        let modified: Date?
        let created: Date?
        let permissions: NSNumber?
    }

    private static let names = ["projects", "stats", "appSettings.json", "exportQueue.json"]
    private let source: URL
    private let destination: URL
    private let staging: URL
    private var entries: [Entry] = []
    private var published: [String] = []

    init(source: URL, destination: URL, selectionFile: URL) throws
    {
        self.source = source
        self.destination = destination
        staging = destination.appendingPathComponent(".mess-earthkit-moving-" + UUID().uuidString, isDirectory: true)
        let original = source.resolvingSymlinksInPath().pathComponents.map { $0.lowercased() }
        let target = destination.resolvingSymlinksInPath().pathComponents.map { $0.lowercased() }
        let preference = selectionFile.resolvingSymlinksInPath().pathComponents.map { $0.lowercased() }
        guard !original.starts(with: target), !target.starts(with: original),
              !preference.starts(with: original), !preference.starts(with: target)
        else { throw EarthStorageMoveError.overlap }
        for root in [source, destination]
        {
            let values = try FileManager.default.attributesOfItem(atPath: root.path)
            guard values[.type] as? FileAttributeType == .typeDirectory,
                  FileManager.default.isWritableFile(atPath: root.path)
            else { throw EarthStorageMoveError.unavailable }
        }
        try requireEmptyDestination()
    }

    func copyAndPublish(progress: @Sendable (String) -> Void) throws
    {
        entries = try inventory()
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        let count = entries.filter { !$0.isDirectory }.count
        var completed = 0
        var lastProgress = ContinuousClock.now
        for entry in entries
        {
            try Task.checkCancellation()
            let from = source.appendingPathComponent(entry.path), to = staging.appendingPathComponent(entry.path)
            if entry.isDirectory { try FileManager.default.createDirectory(at: to, withIntermediateDirectories: false) }
            else
            {
                let now = ContinuousClock.now
                if completed == 0 || lastProgress.duration(to: now) >= .milliseconds(100)
                {
                    progress("Copying storage: \(completed.formatted()) / \(count.formatted()) files")
                    lastProgress = now
                }
                try FileManager.default.copyItem(at: from, to: to)
                guard try digest(from) == digest(to) else { throw EarthStorageMoveError.changed }
                completed += 1
            }
        }
        // Children are written before restoring their directory dates/modes.
        for entry in entries.reversed() where entry.isDirectory
        {
            var attributes: [FileAttributeKey: Any] = [:]
            if let value = entry.modified { attributes[.modificationDate] = value }
            if let value = entry.created { attributes[.creationDate] = value }
            if let value = entry.permissions { attributes[.posixPermissions] = value }
            try FileManager.default.setAttributes(attributes, ofItemAtPath: staging.appendingPathComponent(entry.path).path)
        }
        guard try inventory() == entries else { throw EarthStorageMoveError.changed }
        try requireEmptyDestination(allowStaging: true)
        progress("Saving new storage location…")
        for name in Self.names where entries.contains(where: { $0.path == name })
        {
            try Task.checkCancellation()
            try FileManager.default.moveItem(at: staging.appendingPathComponent(name), to: destination.appendingPathComponent(name))
            published.append(name)
        }
        try Task.checkCancellation()
    }

    /// Before the selection bookmark commits, originals are untouched. Delete
    /// only this transaction's staged/published copies during rollback.
    func rollback() throws
    {
        for name in published.reversed() { try FileManager.default.removeItem(at: destination.appendingPathComponent(name)) }
        if FileManager.default.fileExists(atPath: staging.path) { try FileManager.default.removeItem(at: staging) }
    }

    /// After commit, always use the new library. A cleanup failure retains copies
    /// at the previous root and is reported separately from transaction failure.
    func removeOldCopies() -> Bool
    {
        defer { try? FileManager.default.removeItem(at: staging) }
        do
        {
            guard try inventory() == entries else { return false }
            for name in Self.names where entries.contains(where: { $0.path == name })
            { try FileManager.default.removeItem(at: source.appendingPathComponent(name)) }
            return true
        }
        catch { return false }
    }

    private func requireEmptyDestination(allowStaging: Bool = false) throws
    {
        let allowed = allowStaging ? [".DS_Store", staging.lastPathComponent] : [".DS_Store"]
        let children = try FileManager.default.contentsOfDirectory(at: destination, includingPropertiesForKeys: nil)
        guard children.allSatisfy({ allowed.contains($0.lastPathComponent) }) else { throw EarthStorageMoveError.destinationNotEmpty }
    }

    private func inventory() throws -> [Entry]
    {
        var found: [Entry] = []
        func visit(_ url: URL, path: String) throws
        {
            try Task.checkCancellation()
            let values = try FileManager.default.attributesOfItem(atPath: url.path)
            let type = values[.type] as? FileAttributeType
            guard type == .typeDirectory || type == .typeRegular else { throw EarthAppFilesError.invalidLocation }
            let directory = type == .typeDirectory
            found.append(Entry(
                path: path,
                isDirectory: directory,
                size: directory ? 0 : (values[.size] as? NSNumber)?.uint64Value ?? 0,
                modified: values[.modificationDate] as? Date,
                created: values[.creationDate] as? Date,
                permissions: values[.posixPermissions] as? NSNumber
            ))
            if directory
            {
                for child in try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil).sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
                { try visit(child, path: path + "/" + child.lastPathComponent) }
            }
        }
        for name in Self.names
        {
            let url = source.appendingPathComponent(name)
            do { _ = try FileManager.default.attributesOfItem(atPath: url.path) }
            catch let error as NSError where error.domain == NSCocoaErrorDomain && (error.code == NSFileNoSuchFileError || error.code == NSFileReadNoSuchFileError) { continue }
            try visit(url, path: name)
        }
        return found
    }

    private func digest(_ url: URL) throws -> SHA256.Digest
    {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var hash = SHA256()
        while true
        {
            try Task.checkCancellation()
            let bytes = try file.read(upToCount: 1024 * 1024) ?? Data()
            if bytes.isEmpty { break }
            hash.update(data: bytes)
        }
        return hash.finalize()
    }
}
