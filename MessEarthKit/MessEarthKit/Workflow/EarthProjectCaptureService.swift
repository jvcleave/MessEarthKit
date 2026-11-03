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
            case .workInProgress: "Wait for the current operation to finish."
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
    private let captureStore = EarthCaptureStore()

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

    func download(variantID: UUID? = nil, archive: EarthSourceArchive, apiKey: String, progress: @escaping @Sendable (EarthCaptureProgress) -> Void) async throws -> EarthSourceArchive
    {
        let variantID = try await resolveVariantID(variantID)
        try await requireVariant(archive, variantID: variantID)
        let completed = try await acquire(archive, apiKey, progress)
        try await requireVariant(completed, variantID: variantID)
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
            guard let location = record.locations.first(where: { $0.id == variant.locationID })
            else { throw EarthProjectStoreError.captureNotFound }
            let identity = try EarthCaptureIdentity(locationName: location.title, request: variant.capture.request, detailName: variant.title)
            let access = try await files.accessForReading(url)
            defer { withExtendedLifetime(access) {} }
            try await captureStore.recordIdentity(identity, collection: collection)
        }
        else
        {
            url = try await files.resolve(reference: variant.capture.reference, projectID: id)
            try await files.validateArtifactDirectory(url, projectID: id, kind: .sources)
        }
        await files.reveal(url)
    }

    func prepareModels(variantID: UUID? = nil, archive: EarthSourceArchive, progress: @escaping @Sendable (EarthPreparationProgress) -> Void) async throws -> EarthPreparedCollection
    {
        let variantID = try await resolveVariantID(variantID)
        try await requireVariant(archive, variantID: variantID)
        let profile = try EarthPreparationProfile(name: "Project preview")
        let current = try await store.openVariant(id: id, variantID: variantID)
        if let ready = current.prepared, ready.state == .ready, ready.profile == profile
        {
            let identity = try EarthCaptureIdentity(locationName: current.location.title, request: current.variant.capture.request, detailName: current.variant.title)
            let access = try await files.accessForReading(ready.directoryURL)
            defer { withExtendedLifetime(access) {} }
            try await captureStore.recordIdentity(identity, collection: ready)
            return ready
        }
        let result = try await prepare(archive, profile, progress)
        try Task.checkCancellation()
        try await requireVariant(archive, variantID: variantID)
        guard let preparationID = UUID(uuidString: result.directoryURL.lastPathComponent),
              let captureID = UUID(uuidString: archive.directoryURL.lastPathComponent)
        else { throw EarthAppFilesError.invalidLocation }
        let identity = try EarthCaptureIdentity(locationName: current.location.title, request: current.variant.capture.request, detailName: current.variant.title)
        let access = try await files.accessForReading(result.directoryURL)
        defer { withExtendedLifetime(access) {} }
        try await captureStore.recordIdentity(identity, collection: result)
        _ = try await store.recordPreparation(id: id, variantID: variantID, preparation: .init(id: preparationID, captureID: captureID, profile: result.profile))
        return result
    }

    private func resolveVariantID(_ variantID: UUID?) async throws -> UUID
    {
        if let variantID { return variantID }
        guard let selected = try await store.record(id: id).selectedCaptureID else { throw EarthProjectStoreError.captureNotFound }
        return selected
    }

    private func requireVariant(_ archive: EarthSourceArchive, variantID: UUID) async throws
    {
        try await files.validateArtifactDirectory(archive.directoryURL, projectID: id, kind: .sources)
        let record = try await store.record(id: id)
        guard let variant = record.captures.first(where: { $0.id == variantID }),
              variant.capture.id.uuidString == archive.directoryURL.lastPathComponent,
              variant.capture.request == archive.request else { throw EarthProjectStoreError.sourceMismatch }
    }
}
