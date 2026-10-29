import Foundation
import MessEarthKit

struct EarthOpenedProject: Sendable
{
    let record: EarthProjectRecord
    let archive: EarthSourceArchive?
    let prepared: EarthPreparedCollection?

    var status: String
    {
        guard let archive else { return "Draft" }
        if archive.state != .downloaded { return "Paused" }
        if let prepared { return prepared.state == .ready ? "Ready" : "Preparation incomplete" }
        return "Downloaded"
    }
}

struct EarthProjectLibrary: Sendable
{
    let projects: [EarthOpenedProject]
    let failures: [EarthProjectLoadFailure]
}

struct EarthProjectLoadFailure: Sendable, Identifiable
{
    let id: UUID
    let message: String
}

/// Journal-only card state. Reading cards never imports models or activates a
/// source; unavailable inactive files remain errors on their own cards.
struct EarthProjectCaptureStatus: Sendable
{
    let archive: EarthSourceArchive?
    let errorMessage: String?

    var title: String
    {
        guard let archive else { return "Unavailable" }
        return archive.state == .downloaded ? "Downloaded" : "Paused"
    }

    var summary: String?
    {
        guard let archive else { return nil }
        return "\(archive.completedPayloadCount.formatted()) GLB files · \(ByteCountFormatter.string(fromByteCount: Int64(archive.downloadedBytes), countStyle: .file))"
    }
}

/// Project semantics and current schemas live here. AppFiles performs all I/O;
/// per-project mutation chains preserve ordering across actor suspension points.
actor EarthProjectStore
{
    private let files: EarthAppFiles
    private var mutations: [UUID: (id: UUID, task: Task<EarthProjectRecord, Error>)] = [:]
    private var unavailableProjects: Set<UUID> = []

    init(files: EarthAppFiles) { self.files = files }

    func create() async throws -> EarthProjectRecord
    {
        let record = EarthProjectRecord(id: UUID(), date: Date())
        try await files.createProjectMetadata(Self.encode(record), id: record.id)
        return record
    }

    func record(id: UUID) async throws -> EarthProjectRecord
    {
        guard !unavailableProjects.contains(id) else { throw EarthAppFilesError.missingFile }
        if let pending = mutations[id] { return try await pending.task.value }
        return try await Self.read(id: id, files: files)
    }

    func deleteProject(id: UUID) async throws
    {
        guard !unavailableProjects.contains(id) else { throw EarthAppFilesError.missingFile }
        unavailableProjects.insert(id)
        do
        {
            if let pending = mutations[id] { _ = try await pending.task.value }
            try await files.trashProject(id: id)
        }
        catch
        {
            unavailableProjects.remove(id)
            throw error
        }
    }

    func deleteCapture(id: UUID, captureID: UUID) async throws -> EarthProjectRecord
    {
        try await mutate(id: id, deletingCaptureID: captureID)
        { record in
            guard let index = record.locations.firstIndex(where: { $0.variants.contains { $0.id == captureID } })
            else { throw EarthProjectStoreError.captureNotFound }
            record.locations[index].variants.removeAll { $0.id == captureID }
            if record.selectedCaptureID == captureID { record.selectedCaptureID = record.captures.last?.id }
        }
    }

    func deleteLocation(id: UUID, locationID: UUID) async throws -> EarthProjectRecord
    {
        try await mutate(id: id, deletingLocationID: locationID)
        { record in
            guard let location = record.locations.first(where: { $0.id == locationID }) else { throw EarthProjectStoreError.locationNotFound }
            record.locations.removeAll { $0.id == locationID }
            if record.editingLocationID == locationID { record.editingLocationID = record.locations.last?.id }
            if location.variants.contains(where: { $0.id == record.selectedCaptureID }) { record.selectedCaptureID = record.captures.last?.id }
        }
    }

    func updateTitle(id: UUID, title: String) async throws -> EarthProjectRecord
    {
        try await updateEditor(id: id, title: title)
    }

    func updateEditor(id: UUID, title: String? = nil, searchAddress: String? = nil, locations: [UUID: EarthLocationEdit] = [:]) async throws -> EarthProjectRecord
    {
        try await mutate(id: id)
        { record in
            if let title { record.title = title }
            if let searchAddress
            {
                if record.searchAddress != searchAddress { record.searchResult = nil }
                record.searchAddress = searchAddress
            }
            for (locationID, edit) in locations
            {
                guard let index = record.locations.firstIndex(where: { $0.id == locationID }) else { throw EarthProjectStoreError.locationNotFound }
                try record.locations[index].apply(edit)
            }
        }
    }

    func recordSearch(id: UUID, result: EarthMapSearchResult) async throws -> EarthProjectRecord
    {
        try await mutate(id: id)
        { record in
            guard record.searchAddress == result.address else { throw EarthProjectStoreError.changedLocation }
            record.searchResult = result
        }
    }

    func addLocation(id: UUID, center: EarthGeographicOrigin, title: String) async throws -> EarthProjectRecord
    {
        let location = EarthLocationRecord(date: Date(), title: title, area: .init(center: center))
        return try await mutate(id: id)
        { record in
            record.locations.append(location)
            record.editingLocationID = location.id
        }
    }

    func copyLocation(id: UUID, locationID: UUID, captureID: UUID? = nil) async throws -> EarthProjectRecord
    {
        try await mutate(id: id)
        { record in
            guard let original = record.locations.first(where: { $0.id == locationID }) else { throw EarthProjectStoreError.locationNotFound }
            let detail: EarthProjectDetail
            if let captureID
            {
                guard let variant = original.variants.first(where: { $0.id == captureID }) else { throw EarthProjectStoreError.captureNotFound }
                detail = variant.detail
            }
            else { detail = original.variantDetail ?? original.variants.last?.detail ?? .standard }
            let copy = EarthLocationRecord(
                date: Date(),
                title: String((original.displayTitle + " Copy").prefix(100)),
                area: original.area,
                detail: detail
            )
            record.locations.append(copy)
            record.editingLocationID = copy.id
        }
    }

    func editLocation(id: UUID, locationID: UUID) async throws -> EarthProjectRecord
    {
        try await mutate(id: id)
        { record in
            guard record.locations.contains(where: { $0.id == locationID }) else { throw EarthProjectStoreError.locationNotFound }
            record.editingLocationID = locationID
        }
    }

    func addVariant(id: UUID, locationID: UUID) async throws -> EarthProjectRecord
    {
        try await mutate(id: id)
        { record in
            guard let index = record.locations.firstIndex(where: { $0.id == locationID }) else { throw EarthProjectStoreError.locationNotFound }
            guard record.locations[index].variantDetail == nil else { return }
            record.locations[index].variantDetail = record.locations[index].variants.last?.detail ?? .standard
            record.editingLocationID = locationID
        }
    }

    /// Freeze and pin one exact location/detail before transport. Editing and
    /// operation selection are independent; neither is inferred from map search.
    func recordCapture(id: UUID, capture: EarthProjectCapture, selection: EarthConfirmedSelection) async throws -> EarthProjectRecord
    {
        let url = try await files.resolve(reference: capture.reference, projectID: id)
        let archive = try await EarthSourceArchive.open(directoryURL: url)
        guard archive.request == capture.request, capture.request == selection.request else { throw EarthProjectStoreError.sourceMismatch }
        return try await mutate(id: id)
        { record in
            guard let index = record.locations.firstIndex(where: { $0.id == selection.locationID }) else { throw EarthProjectStoreError.locationNotFound }
            let location = record.locations[index]
            if let existing = record.captures.first(where: { $0.id == capture.id })
            {
                guard existing.capture == capture, existing.locationID == selection.locationID else { throw EarthProjectStoreError.sourceMismatch }
            }
            else
            {
                guard location.area == selection.area, location.variantDetail == selection.detail else { throw EarthProjectStoreError.changedLocation }
                let date = Date()
                if location.frozenAt == nil { record.locations[index].frozenAt = date }
                record.locations[index].variants.append(.init(capture: capture, locationID: location.id, detail: selection.detail, createdAt: date))
                record.locations[index].variantDetail = nil
            }
            record.selectedCaptureID = capture.id
        }
    }

    func recordPreparation(id: UUID, preparation: EarthProjectPreparation) async throws -> EarthProjectRecord
    {
        let current = try await open(id: id)
        guard let archive = current.archive, current.record.currentCapture?.id == preparation.captureID
        else { throw EarthProjectStoreError.sourceMismatch }
        let url = try await files.resolve(reference: preparation.reference, projectID: id)
        let prepared = try await EarthPreparedCollection.open(directoryURL: url)
        guard prepared.profile == preparation.profile, try await prepared.matchesSource(archive)
        else { throw EarthProjectStoreError.sourceMismatch }
        return try await mutate(id: id)
        { record in
            guard record.currentCapture?.id == preparation.captureID else { throw EarthProjectStoreError.sourceMismatch }
            guard let locationIndex = record.locations.firstIndex(where: { $0.variants.contains { $0.id == preparation.captureID } }),
                  let variantIndex = record.locations[locationIndex].variants.firstIndex(where: { $0.id == preparation.captureID })
            else { throw EarthProjectStoreError.captureNotFound }
            record.locations[locationIndex].variants[variantIndex].preparation = preparation
        }
    }

    /// Validate a requested variant before changing selection. Missing/corrupt
    /// files cannot displace the current valid capture or erase its preparation.
    func selectCapture(id: UUID, captureID: UUID) async throws -> EarthOpenedProject
    {
        var candidate = try await record(id: id)
        guard let variant = candidate.captures.first(where: { $0.id == captureID }) else { throw EarthProjectStoreError.captureNotFound }
        let previousID = candidate.selectedCaptureID
        candidate.selectedCaptureID = variant.id
        let validated = try await Self.open(record: candidate, files: files)
        try Task.checkCancellation()
        let updated = try await mutate(id: id)
        { record in
            guard record.selectedCaptureID == previousID, record.captures.first(where: { $0.id == captureID }) == variant
            else { throw EarthProjectStoreError.sourceMismatch }
            record.selectedCaptureID = variant.id
        }
        return EarthOpenedProject(record: updated, archive: validated.archive, prepared: validated.prepared)
    }

    func captureStatuses(id: UUID) async throws -> [UUID: EarthProjectCaptureStatus]
    {
        let record = try await record(id: id)
        var statuses: [UUID: EarthProjectCaptureStatus] = [:]
        for variant in record.captures
        {
            try Task.checkCancellation()
            do
            {
                let url = try await files.resolve(reference: variant.capture.reference, projectID: id)
                let archive = try await EarthSourceArchive.open(directoryURL: url)
                guard archive.request == variant.capture.request else { throw EarthProjectStoreError.sourceMismatch }
                statuses[variant.id] = .init(archive: archive, errorMessage: archive.interruptionReason)
            }
            catch is CancellationError { throw CancellationError() }
            catch { statuses[variant.id] = .init(archive: nil, errorMessage: error.localizedDescription) }
        }
        return statuses
    }

    func open(id: UUID) async throws -> EarthOpenedProject
    {
        let record = try await record(id: id)
        return try await Self.open(record: record, files: files)
    }

    private static func open(record: EarthProjectRecord, files: EarthAppFiles) async throws -> EarthOpenedProject
    {
        let id = record.id
        try record.validate(id: id)
        var archive: EarthSourceArchive?
        if let capture = record.currentCapture
        {
            let url = try await files.resolve(reference: capture.reference, projectID: id)
            let source = try await EarthSourceArchive.open(directoryURL: url)
            guard source.request == capture.request else { throw EarthProjectStoreError.sourceMismatch }
            archive = source
        }
        var prepared: EarthPreparedCollection?
        if let reference = record.currentPreparation
        {
            guard let archive else { throw EarthProjectStoreError.sourceMismatch }
            let url = try await files.resolve(reference: reference.reference, projectID: id)
            let models = try await EarthPreparedCollection.open(directoryURL: url)
            guard models.profile == reference.profile, try await models.matchesSource(archive)
            else { throw EarthProjectStoreError.sourceMismatch }
            prepared = models
        }
        return EarthOpenedProject(record: record, archive: archive, prepared: prepared)
    }

    func library() async throws -> EarthProjectLibrary
    {
        let ids = try await files.projectIDs()
        var projects: [EarthOpenedProject] = []
        var failures: [EarthProjectLoadFailure] = []
        for id in ids
        {
            try Task.checkCancellation()
            do { projects.append(try await open(id: id)) }
            catch { failures.append(.init(id: id, message: error.localizedDescription)) }
        }
        projects.sort
        {
            if $0.record.modifiedAt == $1.record.modifiedAt { return $0.record.id.uuidString < $1.record.id.uuidString }
            return $0.record.modifiedAt > $1.record.modifiedAt
        }
        return EarthProjectLibrary(projects: projects, failures: failures)
    }

    private func mutate(id: UUID, deletingCaptureID: UUID? = nil, deletingLocationID: UUID? = nil, change: @escaping @Sendable (inout EarthProjectRecord) throws -> Void) async throws -> EarthProjectRecord
    {
        guard !unavailableProjects.contains(id) else { throw EarthAppFilesError.missingFile }
        let previous = mutations[id]?.task
        let token = UUID()
        let files = files
        let task = Task
        {
            var record: EarthProjectRecord
            if let previous { record = try await previous.value }
            else { record = try await Self.read(id: id, files: files) }
            let original = record
            try change(&record)
            record.modifiedAt = max(Date(), record.modifiedAt)
            try record.validate(id: id)
            if let deletionID = deletingCaptureID ?? deletingLocationID
            {
                guard let metadata = try await files.readMetadata(.project(id)),
                      try JSONDecoder().decode(EarthProjectRecord.self, from: metadata) == original
                else { throw EarthProjectStoreError.sourceMismatch }
                let removed = original.captures.filter { old in !record.captures.contains { $0.id == old.id } }
                let retainedPreparations = Set(record.captures.compactMap { $0.preparation?.id })
                let preparedIDs = Set(removed.compactMap { $0.preparation?.id }).subtracting(retainedPreparations)
                try await files.trashCaptures(
                    projectID: id,
                    deletionID: deletionID,
                    captureIDs: removed.map(\.id),
                    preparationIDs: Array(preparedIDs),
                    originalMetadata: metadata,
                    updatedMetadata: Self.encode(record)
                )
            }
            else { try await files.writeMetadata(Self.encode(record), location: .project(id)) }
            return record
        }
        mutations[id] = (token, task)
        defer { if mutations[id]?.id == token { mutations[id] = nil } }
        return try await task.value
    }

    private static func read(id: UUID, files: EarthAppFiles) async throws -> EarthProjectRecord
    {
        guard let data = try await files.readMetadata(.project(id)) else { throw EarthProjectStoreError.invalidRecord }
        let record: EarthProjectRecord
        do { record = try JSONDecoder().decode(EarthProjectRecord.self, from: data) }
        catch let error as EarthProjectStoreError { throw error }
        catch { throw EarthProjectStoreError.invalidRecord }
        try record.validate(id: id)
        return record
    }

    private static func encode(_ record: EarthProjectRecord) throws -> Data
    {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(record)
    }
}
