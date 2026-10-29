import Foundation
import MessEarthKit

/// App locations are injected; transport/journal I/O remains SDK-owned.
actor EarthSourceDownloadService
{
    private let appFiles: EarthAppFiles
    private let projectID: UUID
    private let observer: EarthRequestObserver?

    init(appFiles: EarthAppFiles, projectID: UUID, observer: EarthRequestObserver?)
    {
        self.appFiles = appFiles
        self.projectID = projectID
        self.observer = observer
    }

    func newDirectory() async throws -> URL
    {
        try await appFiles.newArtifactDirectory(projectID: projectID, kind: .sources)
    }

    func download(request: EarthDownloadRequest, apiKey: String, directoryURL: URL, resuming: Bool, progress: @escaping @Sendable (EarthCaptureProgress) -> Void) async throws -> EarthSourceArchive
    {
        try await appFiles.validateArtifactDirectory(directoryURL, projectID: projectID, kind: .sources)
        return try await EarthSourceAcquisition(apiKey: apiKey, requestObserver: observer).download(request: request, directoryURL: directoryURL, resuming: resuming, progress: progress)
    }

    func showFiles(_ directoryURL: URL) async { await appFiles.reveal(directoryURL) }
}
