import Foundation
import MessEarthKit

struct EarthConfirmedSelection: Sendable, Equatable
{
    let locationID: UUID
    let area: EarthLocationArea
    let detail: EarthProjectDetail
    let request: EarthDownloadRequest

    init(location: EarthLocationRecord) throws
    {
        let detail = location.nextVariantDetail
        locationID = location.id
        area = location.area
        self.detail = detail
        request = try area.request(detail: detail)
    }
}

enum EarthProjectCaptureError: Error, LocalizedError, Sendable
{
    case invalidInput, changedSelection, workInProgress

    var errorDescription: String?
    {
        switch self
        {
            case .invalidInput: "Enter positive finite Width and Height values for this location."
            case .changedSelection: "The project selection changed. Review its map again before downloading."
            case .workInProgress: "Wait for the current operation to finish before deleting."
        }
    }
}

/// The app's capture boundary, with narrow injected lookup/transfer/preparation
/// operations. Production uses the existing services; tests use local sources.
actor EarthProjectCaptureService
{
    typealias Lookup = @Sendable (String) async throws -> EarthMapSearchResult
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

    /// Searching moves a map starting point without creating or moving areas.
    func search(address: String) async throws -> EarthMapSearchResult
    {
        guard !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              try await store.record(id: id).searchAddress == address else { throw EarthProjectCaptureError.invalidInput }
        let record = try await store.record(id: id)
        if let cached = record.searchResult, cached.address == address { return cached }
        let result = try await lookup(address)
        try Task.checkCancellation()
        _ = try await store.recordSearch(id: id, result: result)
        return result
    }

    func start(selection: EarthConfirmedSelection) async throws -> EarthSourceArchive
    {
        let record = try await store.record(id: id)
        guard let location = record.locations.first(where: { $0.id == selection.locationID }),
              location.area == selection.area, location.nextVariantDetail == selection.detail
        else { throw EarthProjectStoreError.changedLocation }
        let directory = try await files.newArtifactDirectory(projectID: id, kind: .sources)
        let archive = try await EarthSourceArchive.create(request: selection.request, directoryURL: directory)
        guard let captureID = UUID(uuidString: directory.lastPathComponent) else { throw EarthAppFilesError.invalidLocation }
        let capture = EarthProjectCapture(id: captureID, request: archive.request)
        _ = try await store.recordCapture(id: id, capture: capture, selection: selection)
        return archive
    }

    func download(archive: EarthSourceArchive, apiKey: String, progress: @escaping @Sendable (EarthCaptureProgress) -> Void) async throws -> EarthSourceArchive
    {
        try await requireCurrent(archive)
        let completed = try await acquire(archive, apiKey, progress)
        try await requireCurrent(completed)
        return completed
    }

    func revealCapture(_ captureID: UUID, preparedModels: Bool = false) async throws
    {
        let record = try await store.record(id: id)
        guard let variant = record.captures.first(where: { $0.id == captureID }) else { throw EarthProjectStoreError.captureNotFound }
        let url: URL
        if preparedModels
        {
            guard let preparation = variant.preparation else { throw EarthProjectStoreError.sourceMismatch }
            url = try await files.resolve(reference: preparation.reference, projectID: id)
            try await files.validateArtifactDirectory(url, projectID: id, kind: .prepared)
            let collection = try await EarthPreparedCollection.open(directoryURL: url)
            guard collection.profile == preparation.profile else { throw EarthProjectStoreError.sourceMismatch }
        }
        else
        {
            url = try await files.resolve(reference: variant.capture.reference, projectID: id)
            try await files.validateArtifactDirectory(url, projectID: id, kind: .sources)
        }
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
              let captureID = UUID(uuidString: archive.directoryURL.lastPathComponent),
              let variantID = current.record.selectedCaptureID
        else { throw EarthAppFilesError.invalidLocation }
        _ = try await store.recordPreparation(id: id, variantID: variantID, preparation: .init(id: preparationID, captureID: captureID, profile: result.profile))
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
