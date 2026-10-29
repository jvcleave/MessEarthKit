import Foundation
import MessEarthKit

actor EarthModelPreparationService
{
    private let appFiles: EarthAppFiles
    private let projectID: UUID

    init(appFiles: EarthAppFiles, projectID: UUID)
    {
        self.appFiles = appFiles
        self.projectID = projectID
    }

    func prepare(archive: EarthSourceArchive, profile: EarthPreparationProfile, progress: @escaping @Sendable (EarthPreparationProgress) -> Void) async throws -> EarthPreparedCollection
    {
        try await appFiles.validateArtifactDirectory(archive.directoryURL, projectID: projectID, kind: .sources)
        let directory = try await appFiles.newArtifactDirectory(projectID: projectID, kind: .prepared)
        return try await EarthModelPreparer().prepare(archive: archive, directoryURL: directory, profile: profile, progress: progress)
    }

    /// Only the current project's catalogs are considered; malformed catalogs
    /// report an error rather than being silently skipped or imported elsewhere.
    func latest(for archive: EarthSourceArchive) async throws -> EarthPreparedCollection?
    {
        try await appFiles.validateArtifactDirectory(archive.directoryURL, projectID: projectID, kind: .sources)
        let identifier = try await archive.sourceIdentifier()
        let candidates = try await appFiles.artifactDirectories(projectID: projectID, kind: .prepared)
        var partial: EarthPreparedCollection?
        for candidate in candidates
        {
            try Task.checkCancellation()
            try await appFiles.validateArtifactDirectory(candidate.url, projectID: projectID, kind: .prepared)
            let catalog = try await EarthPreparedCollection.open(directoryURL: candidate.url)
            guard catalog.sourceIdentifier == identifier, catalog.modelCount > 0,
                  try await catalog.matchesSource(archive) else { continue }
            if catalog.state == .ready { return catalog }
            if catalog.state == .partial, partial == nil { partial = catalog }
        }
        return partial
    }
}
