import Foundation
import MessEarthKit
import Metal

struct EarthRegionPreviewResult: Sendable
{
    let renderer: EarthPreviewRenderer
    let scene: EarthPreparedPreview
    let appearancePolicy: EarthPreparationAppearancePolicy
}

/// Owns authorization and recorded source/preparation identity throughout both
/// preview passes. A renderer result cannot adopt a replacement project capture.
actor EarthRegionPreviewService
{
    typealias Build = @Sendable (EarthPreparedCollection, @escaping @Sendable (EarthRegionPreviewProgress) -> Void, @escaping @Sendable () async throws -> Void) async throws -> EarthRegionPreviewResult

    private let projectID: UUID
    private let files: EarthAppFiles
    private let store: EarthProjectStore
    private let build: Build

    init(projectID: UUID, files: EarthAppFiles, store: EarthProjectStore, build: @escaping Build = EarthRegionPreviewService.buildScene)
    {
        self.projectID = projectID
        self.files = files
        self.store = store
        self.build = build
    }

    func load(collection: EarthPreparedCollection, progress: @escaping @Sendable (EarthRegionPreviewProgress) -> Void) async throws -> EarthRegionPreviewResult
    {
        try Task.checkCancellation()
        let access = try await files.accessForReading(collection.directoryURL)
        defer { withExtendedLifetime(access) {} }
        let opened = try await store.open(id: projectID)
        guard let capture = opened.record.currentCapture, let preparation = opened.record.currentPreparation,
              opened.archive?.state == .downloaded, let recorded = opened.prepared,
              recorded.directoryURL == collection.directoryURL, recorded.sourceIdentifier == collection.sourceIdentifier,
              recorded.profile == collection.profile, recorded.modelCount == collection.modelCount
        else { throw EarthRegionPreviewError.sourceChanged }
        try await files.validateArtifactDirectory(collection.directoryURL, projectID: projectID, kind: .prepared)
        let result = try await build(collection, progress)
        { [self] in try await requireCurrent(capture: capture, preparation: preparation) }
        try Task.checkCancellation()
        try await requireCurrent(capture: capture, preparation: preparation)
        return result
    }

    private func requireCurrent(capture: EarthProjectCapture, preparation: EarthProjectPreparation) async throws
    {
        try Task.checkCancellation()
        let current = try await store.record(id: projectID)
        guard current.currentCapture == capture, current.currentPreparation == preparation
        else { throw EarthRegionPreviewError.sourceChanged }
    }

    private nonisolated static func buildScene(collection: EarthPreparedCollection, progress: @escaping @Sendable (EarthRegionPreviewProgress) -> Void, validateSource: @escaping @Sendable () async throws -> Void) async throws -> EarthRegionPreviewResult
    {
        guard let device = MTLCreateSystemDefaultDevice()
        else { throw EarthImportError.unsupportedContent("A Metal device is unavailable.") }
        let scene = try await EarthRegionPreviewLoader(device: device).load(collection: collection, progress: progress, validateSource: validateSource)
        try Task.checkCancellation()
        return try EarthRegionPreviewResult(renderer: EarthPreviewRenderer(device: device), scene: scene, appearancePolicy: collection.profile.appearancePolicy)
    }
}
