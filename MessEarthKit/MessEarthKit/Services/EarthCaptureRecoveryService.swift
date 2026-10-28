import Foundation
import MessEarthKit

/// The example owns recovery locations and retention. The package checkpoints
/// sanitized source data into the new directory supplied for each attempt.
actor EarthCaptureRecoveryService
{
    private let baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
        .appendingPathComponent("MessEarthKit/Recoveries", isDirectory: true)
    private let importer = EarthCaptureImporter()
    private var attemptedDirectory: URL?

    func capture(request: EarthCaptureRequest, apiKey: String, progress: @escaping @Sendable (EarthCaptureProgress) -> Void) async throws -> EarthCapture
    {
        guard let baseURL else { throw EarthImportError.inaccessibleSource("The application support folder is unavailable.") }
        do { try FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true) }
        catch { throw EarthImportError.inaccessibleSource("Could not create the download recovery folder.") }
        let directory = baseURL.appendingPathComponent("Capture-\(UUID().uuidString)", isDirectory: true)
        attemptedDirectory = directory
        do
        {
            return try await EarthCaptureSession(apiKey: apiKey).capture(request: request, recoveryDirectoryURL: directory, progress: progress)
        }
        catch
        {
            let originalError = error
            guard !Task.isCancelled, let root = publishedRoot(directory: directory) else { throw originalError }
            do { return try await importer.importFile(fileURL: root) }
            catch { throw originalError } // Raw files remain available if preview decoding also fails.
        }
    }

    func mostRecentDownload() -> URL?
    {
        if let attemptedDirectory, let root = publishedRoot(directory: attemptedDirectory) { return root }
        guard let baseURL,
              let directories = try? FileManager.default.contentsOfDirectory(at: baseURL, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles])
        else { return nil }
        let candidates = directories.compactMap
        { directory -> (URL, Date)? in
            guard let values = try? directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  values.isDirectory == true, values.isSymbolicLink != true,
                  let root = publishedRoot(directory: directory),
                  let date = try? root.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            else { return nil }
            return (root, date)
        }
        return candidates.max { $0.1 < $1.1 }?.0
    }

    private func publishedRoot(directory: URL) -> URL?
    {
        let root = directory.appendingPathComponent("tileset.json")
        guard let values = try? root.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true, values.isSymbolicLink != true
        else { return nil }
        return root
    }
}
