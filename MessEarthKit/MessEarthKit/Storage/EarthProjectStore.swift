import Foundation
import MessEarthKit

struct EarthOpenedVariant: Sendable
{
    let location: EarthLocationRecord
    let variant: EarthProjectCaptureVariant
    let archive: EarthSourceArchive
    let prepared: EarthPreparedCollection?
}

struct EarthOpenedProject: Sendable
{
    let record: EarthProjectRecord
    let archive: EarthSourceArchive?
    let prepared: EarthPreparedCollection?

    var status: String
    {
        guard let archive else { return "Draft" }
        if archive.state != .downloaded { return EarthProjectCaptureStatus(archive: archive, errorMessage: archive.interruptionReason).title }
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
    var canChangeDetail = false
    var canChangeArea = false

    static func isUnstarted(_ archive: EarthSourceArchive) -> Bool
    {
        archive.state == .paused && archive.sourceRequests == 0 && archive.completedPayloadCount == 0 && archive.interruptionReason == nil
    }

    var title: String
    {
        guard let archive else { return "Unavailable" }
        if archive.state == .downloaded { return "Downloaded" }
        return archive.sourceRequests == 0 ? "Not downloaded" : "Paused"
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
    typealias CityLookup = @Sendable (EarthGeographicOrigin) async throws -> String

    private let files: EarthAppFiles
    private let cityLookup: CityLookup
    private var mutations: [UUID: (id: UUID, task: Task<EarthProjectRecord, Error>)] = [:]
    private var unavailableProjects: Set<UUID> = []

    init(files: EarthAppFiles, cityLookup: @escaping CityLookup = { try await EarthCityLookup().resolve(center: $0) })
    {
        self.files = files
        self.cityLookup = cityLookup
    }

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
        var resolvedEdits = locations
        var expectedNames: [UUID: EarthLocationName] = [:]
        if !locations.isEmpty
        {
            let snapshot = try await record(id: id)
            for (locationID, edit) in locations
            {
                guard let saved = snapshot.locations.first(where: { $0.id == locationID }) else { throw EarthProjectStoreError.locationNotFound }
                if saved.isFrozen, edit.area != saved.area { throw EarthProjectStoreError.frozenLocation }
                if case .automatic = edit.name
                {
                    guard case .automatic = saved.name else { throw EarthProjectStoreError.changedLocation }
                    var resolved = edit
                    if edit.area.center != saved.area.center
                    {
                        let city = try await cityLookup(edit.area.center)
                        resolved.name = .automatic(city: city)
                    }
                    else { resolved.name = saved.name }
                    try resolved.name.validate()
                    resolvedEdits[locationID] = resolved
                    expectedNames[locationID] = saved.name
                }
            }
        }
        let edits = resolvedEdits
        let nameChecks = expectedNames
        return try await mutate(id: id)
        { record in
            if let title { record.title = title }
            if let searchAddress
            {
                if record.searchAddress != searchAddress { record.searchResult = nil }
                record.searchAddress = searchAddress
            }
            for (locationID, edit) in edits
            {
                guard let index = record.locations.firstIndex(where: { $0.id == locationID }) else { throw EarthProjectStoreError.locationNotFound }
                if let expected = nameChecks[locationID], record.locations[index].name != expected { throw EarthProjectStoreError.changedLocation }
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

    func addLocation(id: UUID, center: EarthGeographicOrigin, title: String? = nil) async throws -> EarthProjectRecord
    {
        let name: EarthLocationName
        if let title { name = .custom(title) }
        else
        {
            let city = try await cityLookup(center)
            name = .automatic(city: city)
        }
        try name.validate()
        let location = EarthLocationRecord(date: Date(), name: name, area: .init(center: center))
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
            let area: EarthLocationArea
            if let captureID
            {
                guard let variant = original.variants.first(where: { $0.id == captureID }) else { throw EarthProjectStoreError.captureNotFound }
                detail = variant.detail
                area = variant.capture.request == (try? original.area.request(detail: variant.detail)) ? original.area : variant.capture.area
            }
            else { detail = original.variantDetail ?? original.variants.last?.detail ?? .standard; area = original.area }
            let name: EarthLocationName
            switch original.name
            {
                case let .automatic(city): name = .automatic(city: city)
                case .custom: name = .custom(String((original.displayTitle + " Copy").prefix(100)))
            }
            let copy = EarthLocationRecord(
                date: Date(),
                name: name,
                area: area,
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
            if let existing = record.captures.first(where: { $0.capture.id == capture.id })
            {
                guard existing.capture == capture, existing.locationID == selection.locationID else { throw EarthProjectStoreError.sourceMismatch }
                record.selectedCaptureID = existing.id
            }
            else
            {
                guard location.area == selection.area, location.nextVariantDetail == selection.detail else { throw EarthProjectStoreError.changedLocation }
                let date = Date()
                if location.frozenAt == nil { record.locations[index].frozenAt = date }
                record.locations[index].variants.append(.init(capture: capture, locationID: location.id, detail: selection.detail, createdAt: date))
                record.locations[index].variantDetail = nil
                record.selectedCaptureID = capture.id
            }
        }
    }

    /// An unused variant can change detail offline. Retain its original empty
    /// journal as history rather than rewriting a registered source request.
    func changeVariantDetail(id: UUID, captureID: UUID, detail: EarthProjectDetail) async throws -> EarthProjectRecord
    {
        let current = try await record(id: id)
        guard let previous = current.captures.first(where: { $0.id == captureID }) else { throw EarthProjectStoreError.captureNotFound }
        if previous.detail == detail { return current }
        let status = try await captureStatus(id: id, variant: previous)
        guard status.canChangeDetail else { throw EarthProjectStoreError.lockedVariantDetail }
        let request = try EarthDownloadRequest(
            center: previous.capture.request.center,
            widthMeters: previous.capture.request.widthMeters,
            depthMeters: previous.capture.request.depthMeters,
            maximumGeometricErrorMeters: detail.errorMeters
        )
        let directory = try await files.newArtifactDirectory(projectID: id, kind: .sources)
        let archive = try await EarthSourceArchive.create(request: request, directoryURL: directory)
        guard let sourceID = UUID(uuidString: archive.directoryURL.lastPathComponent) else { throw EarthAppFilesError.invalidLocation }
        let capture = EarthProjectCapture(id: sourceID, request: request)
        return try await mutate(id: id)
        { record in
            guard let locationIndex = record.locations.firstIndex(where: { $0.id == previous.locationID }),
                  let variantIndex = record.locations[locationIndex].variants.firstIndex(where: { $0.id == captureID }),
                  record.locations[locationIndex].variants[variantIndex] == previous
            else { throw EarthProjectStoreError.sourceMismatch }
            record.locations[locationIndex].variants[variantIndex] = EarthProjectCaptureVariant(
                id: previous.id,
                capture: capture,
                locationID: previous.locationID,
                detail: detail,
                createdAt: previous.createdAt,
                previousCaptures: previous.previousCaptures + [previous.capture]
            )
        }
    }

    func areaAdjustment(id: UUID, locationID: UUID) async throws -> EarthLocationAreaAdjustment
    {
        let location = try await adjustableLocation(id: id, locationID: locationID)
        return EarthLocationAreaAdjustment(location: location)
    }

    /// All replacement journals are created offline before one metadata save
    /// publishes the shared box and every current variant source together.
    func applyAreaAdjustment(id: UUID, adjustment: EarthLocationAreaAdjustment) async throws -> EarthProjectRecord
    {
        let location = try await adjustableLocation(id: id, locationID: adjustment.locationID)
        guard adjustment.matches(location) else { throw EarthProjectStoreError.changedLocation }
        _ = try adjustment.area.request(detail: .standard)
        if adjustment.area == location.area { return try await record(id: id) }
        let name: EarthLocationName
        if case .automatic = location.name, adjustment.area.center != location.area.center
        {
            let city = try await cityLookup(adjustment.area.center)
            name = .automatic(city: city)
            try name.validate()
        }
        else { name = location.name }
        var replacements: [EarthProjectCapture] = []
        for variant in location.variants
        {
            try Task.checkCancellation()
            let request = try adjustment.area.request(detail: variant.detail)
            let directory = try await files.newArtifactDirectory(projectID: id, kind: .sources)
            let archive = try await EarthSourceArchive.create(request: request, directoryURL: directory)
            guard let sourceID = UUID(uuidString: archive.directoryURL.lastPathComponent) else { throw EarthAppFilesError.invalidLocation }
            replacements.append(EarthProjectCapture(id: sourceID, request: archive.request))
        }
        // Actor suspension while creating journals can admit another operation.
        // Recheck completion and the exact snapshot before publishing any source.
        let verified = try await adjustableLocation(id: id, locationID: adjustment.locationID)
        guard adjustment.matches(verified) else { throw EarthProjectStoreError.changedLocation }
        let captures = replacements
        return try await mutate(id: id)
        { record in
            guard let locationIndex = record.locations.firstIndex(where: { $0.id == adjustment.locationID }),
                  adjustment.matches(record.locations[locationIndex])
            else { throw EarthProjectStoreError.changedLocation }
            for (variantIndex, capture) in captures.enumerated()
            {
                let previous = record.locations[locationIndex].variants[variantIndex]
                record.locations[locationIndex].variants[variantIndex] = EarthProjectCaptureVariant(
                    id: previous.id,
                    capture: capture,
                    locationID: previous.locationID,
                    detail: previous.detail,
                    createdAt: previous.createdAt,
                    previousCaptures: previous.previousCaptures + [previous.capture]
                )
            }
            record.locations[locationIndex].area = adjustment.area
            record.locations[locationIndex].name = name
        }
    }

    private func adjustableLocation(id: UUID, locationID: UUID) async throws -> EarthLocationRecord
    {
        let record = try await record(id: id)
        guard let location = record.locations.first(where: { $0.id == locationID }) else { throw EarthProjectStoreError.locationNotFound }
        guard !location.variants.isEmpty else { throw EarthProjectStoreError.frozenLocation }
        for variant in location.variants
        {
            guard try await captureStatus(id: id, variant: variant).canChangeArea else { throw EarthProjectStoreError.capturedLocation }
        }
        return location
    }

    func recordPreparation(id: UUID, variantID: UUID, preparation: EarthProjectPreparation) async throws -> EarthProjectRecord
    {
        let current = try await openVariant(id: id, variantID: variantID)
        guard current.variant.capture.id == preparation.captureID
        else { throw EarthProjectStoreError.sourceMismatch }
        let url = try await files.resolve(reference: preparation.reference, projectID: id)
        let prepared = try await EarthPreparedCollection.open(directoryURL: url)
        guard prepared.profile == preparation.profile, try await prepared.matchesSource(current.archive)
        else { throw EarthProjectStoreError.sourceMismatch }
        return try await mutate(id: id)
        { record in
            guard let locationIndex = record.locations.firstIndex(where: { $0.variants.contains { $0.id == variantID } }),
                  let variantIndex = record.locations[locationIndex].variants.firstIndex(where: { $0.id == variantID })
            else { throw EarthProjectStoreError.captureNotFound }
            guard record.locations[locationIndex].variants[variantIndex].capture == current.variant.capture
            else { throw EarthProjectStoreError.sourceMismatch }
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
                statuses[variant.id] = try await captureStatus(id: id, variant: variant)
            }
            catch is CancellationError { throw CancellationError() }
            catch { statuses[variant.id] = .init(archive: nil, errorMessage: error.localizedDescription) }
        }
        return statuses
    }

    private func captureStatus(id: UUID, variant: EarthProjectCaptureVariant) async throws -> EarthProjectCaptureStatus
    {
        let url = try await files.resolve(reference: variant.capture.reference, projectID: id)
        let archive = try await EarthSourceArchive.open(directoryURL: url)
        guard archive.request == variant.capture.request else { throw EarthProjectStoreError.sourceMismatch }
        var canChangeArea = variant.preparation == nil && archive.state != .downloaded
        var canChangeDetail = variant.preparation == nil && EarthProjectCaptureStatus.isUnstarted(archive)
        if canChangeArea
        {
            for previous in variant.previousCaptures
            {
                try Task.checkCancellation()
                let previousURL = try await files.resolve(reference: previous.reference, projectID: id)
                let previousArchive = try await EarthSourceArchive.open(directoryURL: previousURL)
                guard previousArchive.request == previous.request else { throw EarthProjectStoreError.sourceMismatch }
                if previousArchive.state == .downloaded { canChangeArea = false }
                if !EarthProjectCaptureStatus.isUnstarted(previousArchive) { canChangeDetail = false }
            }
        }
        return .init(archive: archive, errorMessage: archive.interruptionReason, canChangeDetail: canChangeDetail, canChangeArea: canChangeArea)
    }

    func open(id: UUID) async throws -> EarthOpenedProject
    {
        let record = try await record(id: id)
        return try await Self.open(record: record, files: files)
    }

    func openVariant(id: UUID, variantID: UUID) async throws -> EarthOpenedVariant
    {
        let record = try await record(id: id)
        return try await Self.openVariant(record: record, variantID: variantID, files: files)
    }

    private static func open(record: EarthProjectRecord, files: EarthAppFiles) async throws -> EarthOpenedProject
    {
        try record.validate(id: record.id)
        guard let variantID = record.selectedCaptureID else { return .init(record: record, archive: nil, prepared: nil) }
        let opened = try await openVariant(record: record, variantID: variantID, files: files)
        return .init(record: record, archive: opened.archive, prepared: opened.prepared)
    }

    private static func openVariant(record: EarthProjectRecord, variantID: UUID, files: EarthAppFiles) async throws -> EarthOpenedVariant
    {
        guard let location = record.locations.first(where: { $0.variants.contains { $0.id == variantID } }),
              let variant = location.variants.first(where: { $0.id == variantID })
        else { throw EarthProjectStoreError.captureNotFound }
        let sourceURL = try await files.resolve(reference: variant.capture.reference, projectID: record.id)
        let archive = try await EarthSourceArchive.open(directoryURL: sourceURL)
        guard archive.request == variant.capture.request else { throw EarthProjectStoreError.sourceMismatch }
        var prepared: EarthPreparedCollection?
        if let reference = variant.preparation
        {
            let url = try await files.resolve(reference: reference.reference, projectID: record.id)
            let models = try await EarthPreparedCollection.open(directoryURL: url)
            guard models.profile == reference.profile, try await models.matchesSource(archive)
            else { throw EarthProjectStoreError.sourceMismatch }
            prepared = models
        }
        return EarthOpenedVariant(location: location, variant: variant, archive: archive, prepared: prepared)
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
                    captureIDs: removed.flatMap(\.sourceCaptures).map(\.id),
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
