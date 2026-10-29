import CryptoKit
import Darwin
import Foundation

/// All payload paths are generated identifiers confined to this owned folder.
/// Hashing uses 1 MiB reads, including validation on restart.
struct EarthAcquisitionFiles
{
    let directoryURL: URL

    func checked(_ relativePath: String, regularFile: Bool = false) throws -> URL
    {
        let parts = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\\") })
        else { throw EarthAcquisitionError.invalidArchive }
        var url = directoryURL
        for part in parts
        {
            url.appendPathComponent(String(part))
            if let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey]), values.isSymbolicLink == true
            { throw EarthAcquisitionError.invalidArchive }
        }
        if regularFile
        {
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey]), values.isRegularFile == true
            else { throw EarthAcquisitionError.invalidArchive }
        }
        return url
    }

    func integrity(_ url: URL) throws -> (bytes: Int, hash: String)
    {
        do
        {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var hash = SHA256()
            var count = 0
            while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty
            {
                try Task.checkCancellation()
                hash.update(data: data)
                let sum = count.addingReportingOverflow(data.count)
                guard !sum.overflow else { throw EarthAcquisitionError.storage }
                count = sum.partialValue
            }
            return (count, hash.finalize().map { String(format: "%02x", $0) }.joined())
        }
        catch is CancellationError { throw CancellationError() }
        catch { throw EarthAcquisitionError.storage }
    }

    func write(_ data: Data, to path: String) throws
    {
        do { try data.write(to: checked(path), options: .atomic) }
        catch let error as EarthAcquisitionError { throw error }
        catch { throw EarthAcquisitionError.storage }
    }

    /// Container integrity only, with constant memory. Codec/material/geometry
    /// support is deliberately deferred until offline model preparation.
    func validateGLB(_ url: URL, bytes: Int) throws
    {
        do
        {
            let input = try FileHandle(forReadingFrom: url)
            defer { try? input.close() }
            let header = try input.read(upToCount: 12) ?? Data()
            func word(_ data: Data, _ offset: Int) -> UInt32
            { data.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self)) } }
            guard header.count == 12, word(header, 0) == 0x46546C67, word(header, 4) == 2,
                  Int(word(header, 8)) == bytes
            else { throw EarthImportError.invalidContent("Invalid source GLB header or length.") }
            var offset = 12
            var first = true
            while offset < bytes
            {
                try Task.checkCancellation()
                let chunk = try input.read(upToCount: 8) ?? Data()
                guard chunk.count == 8 else { throw EarthImportError.invalidContent("Truncated source GLB chunk.") }
                let length = Int(word(chunk, 0))
                guard length.isMultiple(of: 4), length <= bytes - offset - 8,
                      !first || (word(chunk, 4) == 0x4E4F534A && length > 0)
                else { throw EarthImportError.invalidContent("Invalid source GLB chunks.") }
                offset += 8 + length
                try input.seek(toOffset: UInt64(offset))
                first = false
            }
            guard !first else { throw EarthImportError.invalidContent("Source GLB has no JSON chunk.") }
        }
        catch is CancellationError { throw CancellationError() }
        catch let error as EarthImportError { throw error }
        catch { throw EarthAcquisitionError.storage }
    }

    func publish(staging: URL, path: String) throws
    {
        do
        {
            let handle = try FileHandle(forWritingTo: staging)
            try handle.synchronize()
            try handle.close()
            let destination = try checked(path)
            // rename is atomic on this volume and replaces only this owned file.
            guard rename(staging.path, destination.path) == 0 else { throw EarthAcquisitionError.storage }
            let directory = Darwin.open(destination.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            guard directory >= 0 else { throw EarthAcquisitionError.storage }
            defer { Darwin.close(directory) }
            guard fsync(directory) == 0 else { throw EarthAcquisitionError.storage }
        }
        catch { throw EarthAcquisitionError.storage }
    }
}

/// An OS lock prevents separate workers/processes from changing the same job.
/// Closing a crashed process releases it; no persistent "busy" flag can strand it.
final class EarthAcquisitionLock
{
    private let descriptor: Int32

    init(files: EarthAcquisitionFiles) throws
    {
        let path = try files.checked("acquisition.lock")
        descriptor = Darwin.open(path.path, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw EarthAcquisitionError.storage }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0
        else
        {
            Darwin.close(descriptor)
            throw EarthAcquisitionError.archiveInUse
        }
    }

    deinit { flock(descriptor, LOCK_UN); Darwin.close(descriptor) }
}
