import Foundation
import MessEarthKit

/// The example owns recovery locations and retention. The package checkpoints
/// sanitized source data into the new directory supplied for each attempt.
actor EarthCaptureRecoveryService
{
    private let baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
        .appendingPathComponent("MessEarthKit/Recoveries", isDirectory: true)
    private var attemptedDirectory: URL?
    private let estimateStore = EarthCaptureEstimateStore()

    func capture(request: EarthCaptureRequest, apiKey: String, limits: EarthImportLimits, progress: @escaping @Sendable (EarthCaptureProgress) -> Void) async throws -> EarthCapture
    {
        let directory = try newRecoveryDirectory()
        let session = EarthCaptureSession(apiKey: apiKey, limits: limits)
        do
        {
            let capture = try await session.capture(request: request, recoveryDirectoryURL: directory, progress: progress)
            if let observation = await session.lastObservation { _ = await estimateStore.record(observation) }
            return capture
        }
        catch
        {
            let originalError = error
            guard !Task.isCancelled, let root = publishedRoot(directory: directory) else { throw originalError }
            do { return try await EarthCaptureImporter(limits: limits).importFile(fileURL: root) }
            catch { throw originalError } // Raw files remain available if preview decoding also fails.
        }
    }

    func precheck(request: EarthCaptureRequest, apiKey: String, limits: EarthImportLimits, progress: @escaping @Sendable (EarthCaptureProgress) -> Void) async throws -> EarthCapturePrecheck
    {
        let directory = try newRecoveryDirectory()
        let session = EarthCaptureSession(apiKey: apiKey, limits: limits)
        let result = try await session.precheck(request: request, recoveryDirectoryURL: directory, progress: progress)
        if let observation = await session.lastObservation { _ = await estimateStore.record(observation) }
        return result
    }

    func estimateHistory() async -> EarthCaptureObservationHistory { await estimateStore.load() }

    private func newRecoveryDirectory() throws -> URL
    {
        guard let baseURL else { throw EarthImportError.inaccessibleSource("The application support folder is unavailable.") }
        do { try FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true) }
        catch { throw EarthImportError.inaccessibleSource("Could not create the download recovery folder.") }
        let directory = baseURL.appendingPathComponent("Capture-\(UUID().uuidString)", isDirectory: true)
        attemptedDirectory = directory
        return directory
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
