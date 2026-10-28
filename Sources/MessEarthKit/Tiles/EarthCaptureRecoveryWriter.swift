import Foundation

/// Confined to one capture actor/job. Publish payloads first, then atomically
/// replace the manifest, so an earlier checkpoint survives a later failure.
final class EarthCaptureRecoveryWriter
{
    let directoryURL: URL
    private var createdDirectory = false
    private var writtenPaths: Set<String> = []

    init(directoryURL: URL) throws
    {
        guard directoryURL.isFileURL, !FileManager.default.fileExists(atPath: directoryURL.path)
        else { throw EarthImportError.inaccessibleSource("Choose a new recovery folder; existing folders are not replaced.") }
        self.directoryURL = directoryURL.standardizedFileURL
    }

    func write(manifest: Data, files: [EarthSourceFile]) throws
    {
        do
        {
            if !createdDirectory
            {
                try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: false)
                createdDirectory = true
            }
            let resolvedRoot = directoryURL.resolvingSymlinksInPath().path + "/"
            for file in files where !writtenPaths.contains(file.relativePath)
            {
                let destination = directoryURL.appendingPathComponent(file.relativePath).standardizedFileURL
                guard !file.relativePath.hasPrefix("/"), destination.path.hasPrefix(directoryURL.path + "/"),
                      destination.resolvingSymlinksInPath().path.hasPrefix(resolvedRoot),
                      !FileManager.default.fileExists(atPath: destination.path)
                else { throw EarthImportError.inaccessibleSource("A recovery payload path is outside its folder or already exists.") }
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try file.data.write(to: destination, options: .atomic)
                writtenPaths.insert(file.relativePath)
            }
            let rootFile = directoryURL.appendingPathComponent("tileset.json")
            guard rootFile.resolvingSymlinksInPath().path.hasPrefix(resolvedRoot)
            else { throw EarthImportError.inaccessibleSource("The recovery manifest is outside its folder.") }
            try manifest.write(to: rootFile, options: .atomic)
        }
        catch let error as EarthImportError { throw error }
        catch
        {
            throw EarthImportError.inaccessibleSource("Could not checkpoint downloaded tiles. Previously completed recovery files are kept.")
        }
    }
}
