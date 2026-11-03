import CryptoKit
import Foundation

enum EarthExportCollectionError: Error, LocalizedError, Sendable
{
    case sourceChanged, failed, cleanupIncomplete

    var errorDescription: String?
    {
        switch self
        {
            case .sourceChanged: "An export changed during collection. Collect the saved results again."
            case .failed: "The exports could not be collected. Check folder access and available disk space."
            case .cleanupIncomplete: "Collection stopped, but incomplete copies remain in the selected folder. Review that folder in Finder."
        }
    }
}

struct EarthExportCollectionFile: Sendable
{
    let source: URL
    let name: String
}

/// An app-files-owned copy transaction. Payloads are streamed with bounded
/// buffers and verified before the complete batch folder is published.
enum EarthExportCollection
{
    @concurrent static func copy(files: [EarthExportCollectionFile], to parent: URL, progress: @Sendable (Int, Int) -> Void) async throws -> URL
    {
        let manager = FileManager.default
        let staging = parent.appendingPathComponent(".mess-earthkit-collecting-" + UUID().uuidString, isDirectory: true)
        var created = false
        do
        {
            try Task.checkCancellation()
            try manager.createDirectory(at: staging, withIntermediateDirectories: false)
            created = true
            for (index, file) in files.enumerated()
            {
                try Task.checkCancellation()
                progress(index, files.count)
                try copyFile(file.source, to: staging.appendingPathComponent(file.name))
            }
            try Task.checkCancellation()
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd HHmmss"
            let stem = "MessEarthKit Exports " + formatter.string(from: Date())
            var destination = parent.appendingPathComponent(stem, isDirectory: true)
            var suffix = 2
            while manager.fileExists(atPath: destination.path)
            {
                destination = parent.appendingPathComponent("\(stem) (\(suffix))", isDirectory: true)
                suffix += 1
            }
            // Publication wins a simultaneous cancellation, just like export.
            try manager.moveItem(at: staging, to: destination)
            progress(files.count, files.count)
            return destination
        }
        catch
        {
            if created
            {
                do { try manager.removeItem(at: staging) }
                catch { throw EarthExportCollectionError.cleanupIncomplete }
            }
            if error is CancellationError { throw CancellationError() }
            if let error = error as? EarthExportCollectionError { throw error }
            throw EarthExportCollectionError.failed
        }
    }

    private static func copyFile(_ source: URL, to destination: URL) throws
    {
        let manager = FileManager.default
        let before = try manager.attributesOfItem(atPath: source.path)
        guard before[.type] as? FileAttributeType == .typeRegular else { throw EarthAppFilesError.invalidLocation }
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        guard manager.createFile(atPath: destination.path, contents: nil) else { throw EarthExportCollectionError.failed }
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        var original = SHA256()
        var count: UInt64 = 0
        while true
        {
            try Task.checkCancellation()
            let bytes = try input.read(upToCount: 1024 * 1024) ?? Data()
            if bytes.isEmpty { break }
            try output.write(contentsOf: bytes)
            original.update(data: bytes)
            count += UInt64(bytes.count)
        }
        try output.synchronize()
        let verification = try FileHandle(forReadingFrom: destination)
        defer { try? verification.close() }
        var copied = SHA256()
        while true
        {
            try Task.checkCancellation()
            let bytes = try verification.read(upToCount: 1024 * 1024) ?? Data()
            if bytes.isEmpty { break }
            copied.update(data: bytes)
        }
        let after = try manager.attributesOfItem(atPath: source.path)
        guard before[.size] as? NSNumber == after[.size] as? NSNumber,
              before[.modificationDate] as? Date == after[.modificationDate] as? Date,
              before[.systemFileNumber] as? NSNumber == after[.systemFileNumber] as? NSNumber,
              count == (before[.size] as? NSNumber)?.uint64Value,
              original.finalize() == copied.finalize()
        else { throw EarthExportCollectionError.sourceChanged }
    }
}
