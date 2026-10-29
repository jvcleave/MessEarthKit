import Foundation
import MessEarthKit

struct EarthConfirmedSelection: Sendable, Equatable
{
    let draft: EarthProjectDraft
    let location: EarthProjectLocation
    let request: EarthDownloadRequest

    init(draft: EarthProjectDraft, location: EarthProjectLocation) throws
    {
        guard location.address == draft.address else { throw EarthProjectCaptureError.changedSelection }
        self.draft = draft
        self.location = location
        request = try Self.request(draft: draft, origin: location.origin)
    }

    static func request(draft: EarthProjectDraft, origin: EarthGeographicOrigin) throws -> EarthDownloadRequest
    {
        try draft.validate()
        guard !draft.address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let width = Double(draft.widthMeters), let height = Double(draft.heightMeters),
              width.isFinite, height.isFinite, width > 0, height > 0
        else { throw EarthProjectCaptureError.invalidInput }
        return try EarthDownloadRequest(center: origin, widthMeters: width, depthMeters: height, maximumGeometricErrorMeters: draft.detail.errorMeters)
    }
}

enum EarthProjectCaptureError: Error, LocalizedError, Sendable
{
    case invalidInput, changedSelection, workInProgress

    var errorDescription: String?
    {
        switch self
        {
            case .invalidInput: "Enter an address and positive finite Width and Height values."
            case .changedSelection: "The project selection changed. Review its map again before downloading."
            case .workInProgress: "Wait for the current operation to finish before deleting."
        }
    }
}

/// The app's capture boundary, with narrow injected lookup/transfer/preparation
/// operations. Production uses the existing services; tests use local sources.
actor EarthProjectCaptureService
{
    typealias Lookup = @Sendable (String) async throws -> EarthProjectLocation
    typealias Acquire = @Sendable (EarthSourceArchive, String, @escaping @Sendable (EarthCaptureProgress) -> Void) async throws -> EarthSourceArchive
    typealias Prepare = @Sendable (EarthSourceArchive, EarthPreparationProfile, @escaping @Sendable (EarthPreparationProgress) -> Void) async throws -> EarthPreparedCollection

    private let id: UUID
    private let files: EarthAppFiles
    private let store: EarthProjectStore
    private let lookup: Lookup
    private let acquire: Acquire
    private let prepare: Prepare

    init(id: UUID, files: EarthAppFiles, store: EarthProjectStore, lookup: @escaping Lookup, acquire: @escaping Acquire, prepare: @escaping Prepare)
    {
        self.id = id
        self.files = files
        self.store = store
        self.lookup = lookup
        self.acquire = acquire
        self.prepare = prepare
    }

    /// Map confirmation is independent of credentials and Google transport.
    func confirm(draft: EarthProjectDraft) async throws -> EarthConfirmedSelection
    {
        // Validate the SDK's geographic dimension domain before lookup I/O.
        _ = try EarthConfirmedSelection.request(draft: draft, origin: EarthGeographicOrigin(latitude: 0, longitude: 0))
        let record = try await store.record(id: id)
        guard record.draft == draft else { throw EarthProjectCaptureError.changedSelection }
        let location: EarthProjectLocation
        if let cached = record.resolvedLocation, cached.address == draft.address { location = cached }
        else { location = try await lookup(draft.address) }
        try Task.checkCancellation()
        let selection = try EarthConfirmedSelection(draft: draft, location: location)
        guard try await store.record(id: id).draft == draft else { throw EarthProjectCaptureError.changedSelection }
        _ = try await store.recordLocation(id: id, location: location)
        return selection
    }

    /// A committed, resumable project pointer precedes the first Google request.
    func start(selection: EarthConfirmedSelection) async throws -> EarthSourceArchive
    {
        guard try await store.record(id: id).draft == selection.draft else { throw EarthProjectCaptureError.changedSelection }
        let directory = try await files.newArtifactDirectory(projectID: id, kind: .sources)
        let archive = try await EarthSourceArchive.create(request: selection.request, directoryURL: directory)
        guard let captureID = UUID(uuidString: directory.lastPathComponent) else { throw EarthAppFilesError.invalidLocation }
        _ = try await store.recordCapture(id: id, capture: .init(id: captureID, request: archive.request), expectedDraft: selection.draft)
        return archive
    }

    func download(archive: EarthSourceArchive, apiKey: String, progress: @escaping @Sendable (EarthCaptureProgress) -> Void) async throws -> EarthSourceArchive
    {
        try await requireCurrent(archive)
        let completed = try await acquire(archive, apiKey, progress)
        try await requireCurrent(completed)
        return completed
    }

    func revealCapture(_ captureID: UUID) async throws
    {
        let record = try await store.record(id: id)
        guard let variant = record.captures.first(where: { $0.id == captureID }) else { throw EarthProjectStoreError.captureNotFound }
        let url = try await files.resolve(reference: variant.capture.reference, projectID: id)
        try await files.validateArtifactDirectory(url, projectID: id, kind: .sources)
        await files.reveal(url)
    }

    func prepareModels(archive: EarthSourceArchive, progress: @escaping @Sendable (EarthPreparationProgress) -> Void) async throws -> EarthPreparedCollection
    {
        try await requireCurrent(archive)
        let profile = try EarthPreparationProfile(name: "Project preview")
        let current = try await store.open(id: id)
        if let ready = current.prepared, ready.state == .ready, ready.profile == profile { return ready }
        let result = try await prepare(archive, profile, progress)
        try Task.checkCancellation()
        try await requireCurrent(archive)
        guard let preparationID = UUID(uuidString: result.directoryURL.lastPathComponent),
              let captureID = UUID(uuidString: archive.directoryURL.lastPathComponent)
        else { throw EarthAppFilesError.invalidLocation }
        _ = try await store.recordPreparation(id: id, preparation: .init(id: preparationID, captureID: captureID, profile: result.profile))
        return result
    }

    private func requireCurrent(_ archive: EarthSourceArchive) async throws
    {
        try await files.validateArtifactDirectory(archive.directoryURL, projectID: id, kind: .sources)
        let record = try await store.record(id: id)
        guard record.currentCapture?.id.uuidString == archive.directoryURL.lastPathComponent,
              record.currentCapture?.request == archive.request else { throw EarthProjectStoreError.sourceMismatch }
    }
}
