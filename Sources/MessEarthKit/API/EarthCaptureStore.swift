import Foundation

/// Writes original source payloads plus the local tileset manifest to a new
/// ordinary directory. The caller owns destination authorization and retention.
public actor EarthCaptureStore
{
    public init() {}

    @discardableResult
    public func save(capture: EarthCapture, directoryURL: URL) throws -> URL
    {
        try Task.checkCancellation()
        guard directoryURL.isFileURL, !FileManager.default.fileExists(atPath: directoryURL.path)
        else { throw EarthImportError.inaccessibleSource("Choose a new capture folder; existing folders are not replaced.") }
        let root = directoryURL.standardizedFileURL
        for file in capture.sourceFiles
        {
            let destination = root.appendingPathComponent(file.relativePath).standardizedFileURL
            guard !file.relativePath.hasPrefix("/"), destination.path.hasPrefix(root.path + "/")
            else { throw EarthImportError.invalidContent("Capture paths must stay inside their destination folder.") }
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        do
        {
            for file in capture.sourceFiles
            {
                try Task.checkCancellation()
                let destination = root.appendingPathComponent(file.relativePath)
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try file.data.write(to: destination, options: .atomic)
            }
            try Task.checkCancellation()
            return root.appendingPathComponent(capture.rootSourcePath)
        }
        catch
        {
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }
}
