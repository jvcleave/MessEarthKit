import Foundation
import MessEarthKit
import Observation

/// The library retains this owner, including its workflow, across navigation.
/// Form edits are queued independently of view/task lifetime.
@MainActor
@Observable
final class EarthProjectViewModel: Identifiable
{
    let id: UUID
    let downloads: EarthSourceDownloadViewModel
    let preview: EarthRegionPreviewViewModel
    let export: EarthProjectExportViewModel
    private(set) var searchAddress: String
    private(set) var searchResult: EarthMapSearchResult?
    private(set) var locations: [EarthLocationRecord]
    private(set) var editingLocationID: UUID?
    private(set) var expandedLocationIDs: Set<UUID>
    private(set) var mapFocus: EarthProjectMapFocus?
    var mapCenter: EarthGeographicOrigin?
    private(set) var areaAdjustment: EarthLocationAreaAdjustment?
    var editingLocation: EarthLocationRecord?
    {
        guard let original = locations.first(where: { $0.id == editingLocationID }) else { return nil }
        if let areaAdjustment, areaAdjustment.locationID == original.id { return areaAdjustment.editingLocation(original) }
        return original
    }

    private(set) var mapEdit = EarthMapAreaEditing()
    var displayedLocationArea: EarthLocationArea?
    {
        if mapEdit.locationID == editingLocationID, let preview = mapEdit.preview { return preview }
        return editingLocation?.area
    }

    var captures: [EarthProjectCaptureVariant] { locations.flatMap(\.variants) }
    private(set) var title: String
    var displayTitle: String
    {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "Untitled Project" : name
    }

    private(set) var selectedCaptureID: UUID?
    private(set) var captureStatuses: [UUID: EarthProjectCaptureStatus] = [:]
    private(set) var operationCaptureID: UUID?
    private var revealErrors: [UUID: String] = [:]
    private(set) var savedStatus: String
    private(set) var isSaving = false
    private(set) var persistenceError: String?
    private(set) var prepared: EarthPreparedCollection?
    private(set) var confirmation: EarthConfirmedSelection?
    private(set) var mapInputError: String?
    private(set) var phase: EarthProjectJobPhase = .idle
    private(set) var jobError: String?
    private(set) var progressText = ""
    private var jobFailureStatus = "Operation failed"
    @ObservationIgnored private let captureService: EarthProjectCaptureService
    @ObservationIgnored private let settings: EarthSettingsViewModel
    private let downloadQueue: EarthDownloadQueue
    @ObservationIgnored private var jobTask: Task<Void, Never>?
    @ObservationIgnored private var jobID = UUID()
    @ObservationIgnored private let store: EarthProjectStore
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var pendingSearch: String?
    @ObservationIgnored private var pendingLocations: [UUID: EarthLocationEdit] = [:]
    @ObservationIgnored private var pendingTitle: String?
    @ObservationIgnored private var captureStatusRevisions: [UUID: UInt64] = [:]
    private var hasPendingEdits: Bool { pendingSearch != nil || pendingTitle != nil || !pendingLocations.isEmpty }

    init(opened: EarthOpenedProject, store: EarthProjectStore, appFiles: EarthAppFiles, settings: EarthSettingsViewModel, downloadQueue: EarthDownloadQueue, preparationGate: EarthPreparationGate)
    {
        id = opened.record.id
        searchAddress = opened.record.searchAddress
        searchResult = opened.record.searchResult
        locations = opened.record.locations
        editingLocationID = opened.record.editingLocationID
        expandedLocationIDs = Set(opened.record.editingLocationID.map { [$0] } ?? [])
        title = opened.record.title
        selectedCaptureID = opened.record.selectedCaptureID
        savedStatus = opened.status
        prepared = opened.prepared
        mapCenter = opened.record.searchResult?.origin ?? opened.record.editingLocation?.area.center
        self.store = store
        self.settings = settings
        self.downloadQueue = downloadQueue
        let location = EarthLocationLookup()
        let sources = EarthSourceDownloadService(appFiles: appFiles, projectID: opened.record.id, observer: settings.usage.requestObserver)
        let models = EarthModelPreparationService(appFiles: appFiles, projectID: opened.record.id, gate: preparationGate)
        captureService = EarthProjectCaptureService(
            id: opened.record.id,
            files: appFiles,
            store: store,
            lookup: { address in
                let result = try await location.resolve(address: address)
                return try EarthMapSearchResult(address: address, title: result.title, origin: EarthGeographicOrigin(latitude: result.latitude, longitude: result.longitude))
            },
            acquire: { archive, key, progress in
                try await sources.download(request: archive.request, apiKey: key, directoryURL: archive.directoryURL, resuming: true, progress: progress)
            },
            prepare: { archive, profile, progress in try await models.prepare(archive: archive, profile: profile, progress: progress) }
        )
        downloads = EarthSourceDownloadViewModel(observer: settings.usage.requestObserver, appFiles: appFiles, projectID: opened.record.id)
        downloads.restore(opened.archive)
        preview = EarthRegionPreviewViewModel(service: EarthRegionPreviewService(projectID: opened.record.id, files: appFiles, store: store))
        export = EarthProjectExportViewModel(service: EarthProjectExportService(
            projectID: opened.record.id,
            files: appFiles,
            store: store,
            prepare: { archive, profile, progress in try await models.prepare(archive: archive, profile: profile, progress: progress) }
        ))
        refreshMapSelection()
        updateCaptureStatus()
        if let center = mapCenter { mapFocus = .init(center: center) }
        export.reloadHistory()
    }

    var status: String
    {
        if persistenceError != nil { return "Changes not saved" }
        if phase != .idle { return phase.title }
        if hasActiveDownloads { return "Downloads in progress" }
        if jobError != nil { return jobFailureStatus }
        if export.isLoading { return "Exporting model" }
        if preview.isLoading { return "Loading preview" }
        if preview.errorMessage != nil { return "Preview unavailable" }
        return savedStatus
    }

    func setAddress(_ value: String)
    {
        guard !isBusy, searchAddress != value else { return }
        searchAddress = value
        searchResult = nil
        pendingSearch = value
        savePendingEdits()
    }

    func setTitle(_ value: String)
    {
        guard !isBusy, title != value else { return }
        title = value
        pendingTitle = value
        savePendingEdits()
    }

    private func editLocation(_ change: (inout EarthLocationEdit) -> Void)
    {
        guard !isBusy, canEditCurrentLocation, let index = locations.firstIndex(where: { $0.id == editingLocationID }) else { return }
        var edit = editingLocation?.edit ?? locations[index].edit
        change(&edit)
        if var adjustment = areaAdjustment, adjustment.locationID == editingLocationID
        {
            adjustment.area = edit.area
            areaAdjustment = adjustment
            refreshMapSelection()
            return
        }
        do { try locations[index].apply(edit) }
        catch { mapInputError = error.localizedDescription; return }
        pendingLocations[locations[index].id] = edit
        refreshMapSelection()
        savePendingEdits()
    }

    func setLocationTitle(_ value: String) { editLocation { $0.title = value } }

    func canRenameLocation(_ locationID: UUID) -> Bool
    { !isBusy && areaAdjustment == nil && !locationHasActiveDownloads(locationID) }

    func prepareLocationRename(_ locationID: UUID, onReady: @escaping @MainActor (EarthLocationRenameViewModel) -> Void)
    {
        guard canRenameLocation(locationID) else { return }
        let job = begin(.editingLocation)
        jobTask = Task
        { [weak self, store, id] in
            guard let self else { return }
            defer { finish(job) }
            do
            {
                try await flushEdits()
                let record = try await store.record(id: id)
                try Task.checkCancellation()
                guard let location = record.locations.first(where: { $0.id == locationID })
                else { throw EarthProjectStoreError.locationNotFound }
                onReady(EarthLocationRenameViewModel(projectID: id, location: location, store: store, onSaved: { [weak self] in self?.adoptEditor($0) }))
            }
            catch
            {
                jobError = error is CancellationError ? nil : error.localizedDescription
                jobFailureStatus = "Location rename unavailable"
            }
        }
    }

    func restoreAutomaticLocationName()
    {
        guard !isBusy, canEditCurrentLocation, areaAdjustment == nil, let locationID = editingLocationID else { return }
        let job = begin(.editingLocation)
        jobTask = Task
        { [weak self, store, id] in
            guard let self else { return }
            defer { finish(job) }
            do
            {
                try await flushEdits()
                let record = try await store.restoreAutomaticLocationName(id: id, locationID: locationID)
                adoptEditor(record)
            }
            catch
            {
                jobError = error is CancellationError ? nil : error.localizedDescription
                jobFailureStatus = "Automatic name unavailable"
            }
        }
    }

    func setWidth(_ value: String) { editLocation { $0.area.widthMeters = value } }
    func setHeight(_ value: String) { editLocation { $0.area.heightMeters = value } }

    func beginMapAreaEdit(kind: EarthMapAreaDrag, start: EarthGeographicOrigin)
    {
        guard !isBusy, canEditCurrentLocation, let location = editingLocation else { return }
        do { try mapEdit.begin(location: location, kind: kind, start: start); mapInputError = nil }
        catch { mapInputError = error.localizedDescription }
    }

    func updateMapAreaEdit(to point: EarthGeographicOrigin) { mapEdit.update(to: point) }

    @discardableResult
    func finishMapAreaEdit() -> Bool
    {
        guard mapEdit.isEditing else { return false }
        do
        {
            let area = try mapEdit.finish(location: editingLocation)
            editLocation { $0.area = area }
            return editingLocation?.area == area
        }
        catch { mapInputError = error.localizedDescription; return false }
    }

    func cancelMapAreaEdit() { mapEdit.cancel() }

    var isBusy: Bool { phase != .idle || preview.isLoading || export.isBusy || mapEdit.isEditing }
    var canMoveStorage: Bool { !isBusy && !isSaving && !hasPendingEdits && persistenceError == nil && !hasActiveDownloads && !export.isLoadingHistory }
    var canAddVariant: Bool { confirmation != nil && areaAdjustment == nil && !isBusy && canEditCurrentLocation }
    var canApplyAreaAdjustment: Bool { confirmation != nil && areaAdjustment != nil && !isBusy }
    var hasAPIKey: Bool { !settings.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var selectedCapture: EarthProjectCaptureVariant? { captures.first { $0.id == selectedCaptureID } }

    func downloadJob(_ captureID: UUID) -> EarthDownloadJob?
    {
        guard let job = downloadQueue.jobs[.init(projectID: id, variantID: captureID)],
              captures.first(where: { $0.id == captureID })?.capture.id == job.sourceID else { return nil }
        return job
    }

    var hasActiveDownloads: Bool { captures.contains { downloadJob($0.id)?.phase.isActive == true } }
    var canEditCurrentLocation: Bool { editingLocationID.map { !locationHasActiveDownloads($0) } ?? true }

    func locationHasActiveDownloads(_ locationID: UUID) -> Bool
    { locations.first(where: { $0.id == locationID })?.variants.contains { downloadJob($0.id)?.phase.isActive == true } == true }

    func canDeleteLocation(_ locationID: UUID) -> Bool
    { !isBusy && !isSaving && !locationHasActiveDownloads(locationID) }

    func canDeleteCapture(_ captureID: UUID) -> Bool
    { !isBusy && !isSaving && downloadJob(captureID)?.phase.isActive != true }

    func canDownload(_ captureID: UUID) -> Bool
    { !isBusy && areaAdjustment == nil && hasAPIKey && downloadJob(captureID)?.phase.isActive != true && captureStatuses[captureID]?.archive?.state != .downloaded }

    func pauseDownload(_ captureID: UUID)
    { downloadQueue.pause(.init(projectID: id, variantID: captureID)) }

    func setLocationExpanded(_ expanded: Bool, locationID: UUID)
    {
        guard locations.contains(where: { $0.id == locationID }) else { return }
        if expanded { expandedLocationIDs.insert(locationID) }
        else { expandedLocationIDs.remove(locationID) }
    }

    func addLocation()
    {
        guard let center = mapCenter else { return }
        changeLocation { [store, id] in try await store.addLocation(id: id, center: center) }
    }

    func copyLocation(_ locationID: UUID, captureID: UUID? = nil)
    { changeLocation { [store, id] in try await store.copyLocation(id: id, locationID: locationID, captureID: captureID) } }

    func canAdjustArea(_ locationID: UUID) -> Bool
    {
        guard !isBusy, areaAdjustment == nil, !locationHasActiveDownloads(locationID),
              let location = locations.first(where: { $0.id == locationID }), !location.variants.isEmpty else { return false }
        return location.variants.allSatisfy { captureStatuses[$0.id]?.canChangeArea == true }
    }

    func adjustLocationArea(_ locationID: UUID)
    {
        guard canAdjustArea(locationID) else { return }
        let job = begin(.editingLocation)
        jobTask = Task
        { [weak self, store, id] in
            guard let self else { return }
            defer { finish(job) }
            do
            {
                try await flushEdits()
                let adjustment = try await store.areaAdjustment(id: id, locationID: locationID)
                let record = try await store.editLocation(id: id, locationID: adjustment.locationID)
                try Task.checkCancellation()
                adoptEditor(record)
                mapEdit.cancel()
                areaAdjustment = adjustment
                refreshMapSelection()
                let request = try adjustment.area.request(detail: .standard)
                mapFocus = .init(center: adjustment.area.center, width: request.widthMeters, height: request.depthMeters)
            }
            catch { jobError = error is CancellationError ? nil : error.localizedDescription; jobFailureStatus = "Area adjustment unavailable" }
        }
    }

    func cancelAreaAdjustment()
    {
        guard !isBusy, areaAdjustment != nil else { return }
        mapEdit.cancel()
        areaAdjustment = nil
        refreshMapSelection()
        if let location = editingLocation, let request = try? location.area.request(detail: .standard)
        { mapFocus = .init(center: location.area.center, width: request.widthMeters, height: request.depthMeters) }
    }

    func showLocation(_ locationID: UUID)
    { changeLocation { [store, id] in try await store.editLocation(id: id, locationID: locationID) } }

    func canChangeVariantDetail(_ captureID: UUID) -> Bool
    { !isBusy && areaAdjustment == nil && downloadJob(captureID)?.phase.isActive != true && captureStatuses[captureID]?.canChangeDetail == true }

    func setVariantDetail(_ value: EarthProjectDetail, captureID: UUID)
    {
        guard canChangeVariantDetail(captureID), let variant = captures.first(where: { $0.id == captureID }), variant.detail != value else { return }
        let job = begin(.editingVariant, captureID: captureID)
        jobTask = Task
        { [weak self, store, id] in
            guard let self else { return }
            defer { finish(job) }
            do
            {
                try await flushEdits()
                let record = try await store.changeVariantDetail(id: id, captureID: captureID, detail: value)
                adoptEditor(record)
                if selectedCaptureID == captureID { apply(opened: try await store.open(id: id), restoresEditor: false) }
                await refreshCaptureStatuses()
            }
            catch { await failed(error, job: job) }
        }
    }

    func addVariant(_ locationID: UUID)
    {
        guard canAddVariant, let confirmation, confirmation.locationID == locationID else { return }
        let job = begin(.addingVariant)
        jobTask = Task
        { [weak self, captureService] in
            guard let self else { return }
            defer { finish(job) }
            do
            {
                try await flushEdits()
                let archive = try await captureService.start(selection: confirmation)
                try await apply(archive: archive)
                operationCaptureID = selectedCaptureID
                prepared = nil
                preview.clear()
            }
            catch { await failed(error, job: job) }
        }
    }

    private func changeLocation(_ operation: @escaping @Sendable () async throws -> EarthProjectRecord)
    {
        guard !isBusy else { return }
        cancelAreaAdjustment()
        let job = begin(.editingLocation)
        jobTask = Task
        { [weak self] in
            guard let self else { return }
            defer { finish(job) }
            do
            {
                try await flushEdits()
                let record = try await operation()
                adoptEditor(record)
                if let location = editingLocation
                {
                    if let request = try? location.area.request(detail: .standard)
                    { mapFocus = .init(center: location.area.center, width: request.widthMeters, height: request.depthMeters) }
                    else { mapFocus = .init(center: location.area.center) }
                }
            }
            catch { jobError = error.localizedDescription; jobFailureStatus = "Location unavailable" }
        }
    }

    func captureStatus(_ captureID: UUID) -> String
    {
        if let job = downloadJob(captureID)
        {
            if job.phase.isActive { return job.phase.title }
            if job.errorMessage != nil { return job.progressText }
        }
        if operationCaptureID == captureID
        {
            if phase != .idle { return phase.title }
            if jobError != nil { return jobFailureStatus }
        }
        if let status = captureStatuses[captureID], status.archive == nil { return status.title }
        if selectedCaptureID == captureID
        {
            if preview.isLoading { return "Loading preview" }
            if preview.errorMessage != nil { return "Preview unavailable" }
            return savedStatus
        }
        return captureStatuses[captureID]?.title ?? "Checking files…"
    }

    func captureError(_ captureID: UUID) -> String?
    {
        if let job = downloadJob(captureID), job.phase.isActive || job.errorMessage != nil { return job.errorMessage }
        if operationCaptureID == captureID, let jobError { return jobError }
        if selectedCaptureID == captureID, let error = preview.errorMessage { return error }
        if let error = revealErrors[captureID] { return error }
        // A retry supersedes the cached archive interruption. Fresh job failures
        // above still appear before the archive snapshot is refreshed.
        if operationCaptureID == captureID, phase == .downloading { return nil }
        return captureStatuses[captureID]?.errorMessage
    }

    func refreshCaptureStatuses() async
    {
        let expectedCaptures = Dictionary(uniqueKeysWithValues: captures.map { ($0.id, $0.capture) })
        let expectedRevisions = captureStatusRevisions
        do
        {
            let statuses = try await store.captureStatuses(id: id)
            try Task.checkCancellation()
            for variant in captures where expectedCaptures[variant.id] == variant.capture && captureStatusRevisions[variant.id] == expectedRevisions[variant.id]
            { captureStatuses[variant.id] = statuses[variant.id] }
        }
        catch is CancellationError { }
        catch
        {
            for variant in captures where expectedCaptures[variant.id] == variant.capture && captureStatusRevisions[variant.id] == expectedRevisions[variant.id]
            { captureStatuses[variant.id] = .init(archive: nil, errorMessage: error.localizedDescription) }
        }
    }

    func revealCapture(_ captureID: UUID, preparedModels: Bool = false)
    {
        guard captures.contains(where: { $0.id == captureID }) else { return }
        revealErrors[captureID] = nil
        Task
        { [weak self, captureService] in
            do { try await captureService.revealCapture(captureID, preparedModels: preparedModels) }
            catch { self?.revealErrors[captureID] = error.localizedDescription }
        }
    }

    func retrySave() { savePendingEdits() }

    func deleteProject() async throws
    {
        guard !isBusy, !hasActiveDownloads else { throw EarthProjectCaptureError.workInProgress }
        let job = begin(.deleting)
        defer { finish(job) }
        if let saveTask { await saveTask.value }
        preview.clear()
        try await store.deleteProject(id: id)
    }

    func deleteCapture(_ captureID: UUID) async throws
    {
        guard canDeleteCapture(captureID) else { throw EarthProjectCaptureError.workInProgress }
        let job = begin(.deleting, captureID: captureID)
        defer { finish(job) }
        do
        {
            try await flushEdits()
            let record = try await store.deleteCapture(id: id, captureID: captureID)
            await adoptAfterDeletion(record)
        }
        catch
        {
            if let record = try? await store.record(id: id) { await adoptAfterDeletion(record) }
            if !captures.contains(where: { $0.id == captureID }) { operationCaptureID = nil }
            jobError = error.localizedDescription
            jobFailureStatus = "Deletion failed"
            throw error
        }
    }

    func deleteLocation(_ locationID: UUID) async throws
    {
        guard canDeleteLocation(locationID) else { throw EarthProjectCaptureError.workInProgress }
        let job = begin(.deleting)
        defer { finish(job) }
        do
        {
            try await flushEdits()
            let record = try await store.deleteLocation(id: id, locationID: locationID)
            await adoptAfterDeletion(record)
        }
        catch
        {
            if let record = try? await store.record(id: id) { await adoptAfterDeletion(record) }
            jobError = error.localizedDescription
            jobFailureStatus = "Deletion failed"
            throw error
        }
    }

    private func adoptAfterDeletion(_ record: EarthProjectRecord) async
    {
        preview.clear()
        adoptEditor(record)
        selectedCaptureID = record.selectedCaptureID
        downloads.restore(nil)
        prepared = nil
        savedStatus = captures.isEmpty ? "Draft" : "Unavailable"
        let retainedIDs = Set(captures.map(\.id))
        captureStatuses = captureStatuses.filter { retainedIDs.contains($0.key) }
        captureStatusRevisions = captureStatusRevisions.filter { retainedIDs.contains($0.key) }
        revealErrors = revealErrors.filter { retainedIDs.contains($0.key) }
        await refreshCaptureStatuses()
        do { apply(opened: try await store.open(id: id), restoresEditor: false) }
        catch
        {
            if let selectedCaptureID { captureStatuses[selectedCaptureID] = .init(archive: nil, errorMessage: error.localizedDescription) }
        }
    }

    func selectCapture(_ captureID: UUID, onSelected: @escaping @MainActor () -> Void)
    {
        guard !isBusy, captures.contains(where: { $0.id == captureID }) else { return }
        cancelAreaAdjustment()
        if selectedCaptureID == captureID
        {
            onSelected()
            return
        }
        let job = begin(.selectingCapture, captureID: captureID)
        jobTask = Task
        { [weak self, store, id] in
            guard let self else { return }
            defer { finish(job) }
            do
            {
                try await flushEdits()
                let opened = try await store.selectCapture(id: id, captureID: captureID)
                guard jobID == job else { return }
                preview.clear()
                // The atomic selection has committed. Adopt it even if Cancel
                // arrived during that write; keep any newer editor values.
                apply(opened: opened, restoresEditor: true)
                finish(job)
                if !Task.isCancelled { onSelected() }
            }
            catch
            {
                if !(error is CancellationError)
                {
                    jobError = error.localizedDescription
                    jobFailureStatus = "Capture unavailable"
                }
            }
        }
    }

    /// Explicitly reopen recorded artifacts rather than retrying retained catalog
    /// values. Flush local edits first; refresh never starts network acquisition.
    func refresh(onRefreshed: @escaping @MainActor () -> Void)
    {
        guard !isBusy else { return }
        let job = begin(.refreshing)
        preview.clear()
        jobTask = Task
        { [weak self, store, id] in
            guard let self else { return }
            defer { finish(job) }
            do
            {
                if hasPendingEdits { savePendingEdits() }
                if let saveTask { await saveTask.value }
                guard !hasPendingEdits else { throw EarthAppFilesError.storage }
                let opened = try await store.open(id: id)
                try Task.checkCancellation()
                guard jobID == job else { throw CancellationError() }
                apply(opened: opened, restoresEditor: true)
                await refreshCaptureStatuses()
                try Task.checkCancellation()
                persistenceError = nil
                progressText = "Project refreshed"
                // Let the callback start an offline preparation/preview job.
                finish(job)
                onRefreshed()
            }
            catch
            {
                if !(error is CancellationError)
                {
                    jobError = error.localizedDescription
                    jobFailureStatus = "Refresh failed"
                }
            }
        }
    }

    func updateMap()
    {
        guard !isBusy else { return }
        let address = searchAddress
        let job = begin(.resolving)
        jobTask = Task
        { [weak self, captureService] in
            guard let self else { return }
            defer { finish(job) }
            do
            {
                try await flushEdits()
                let result = try await captureService.search(address: address)
                try Task.checkCancellation()
                guard jobID == job, searchAddress == address else { return }
                searchResult = result
                mapCenter = result.origin
                mapFocus = .init(center: result.origin)
            }
            catch
            {
                jobError = error is CancellationError ? nil : error.localizedDescription
                jobFailureStatus = "Address lookup failed"
            }
        }
    }

    func applyAreaAdjustment()
    {
        guard canApplyAreaAdjustment, let adjustment = areaAdjustment else { return }
        let job = begin(.editingLocation)
        jobTask = Task
        { [weak self, store, id] in
            guard let self else { return }
            defer { finish(job) }
            do
            {
                try await flushEdits()
                let record = try await store.applyAreaAdjustment(id: id, adjustment: adjustment)
                areaAdjustment = nil
                if record.captureLocation?.id == adjustment.locationID { preview.clear() }
                apply(opened: try await store.open(id: id), restoresEditor: true)
                await refreshCaptureStatuses()
            }
            catch { await failed(error, job: job) }
        }
    }

    func enqueueDownload(_ captureID: UUID)
    {
        guard canDownload(captureID), let variant = captures.first(where: { $0.id == captureID }),
              let archive = captureStatuses[captureID]?.archive else { return }
        let key = settings.apiKey
        let job = EarthDownloadJob(id: .init(projectID: id, variantID: captureID), generation: UUID(), locationID: variant.locationID, sourceID: variant.capture.id)
        let service = captureService
        let accepted = downloadQueue.enqueue(
            job: job,
            download: { [weak self] progress in
                guard let self else { throw CancellationError() }
                try await self.flushEdits()
                return try await service.download(variantID: captureID, archive: archive, apiKey: key, progress: progress)
            },
            prepare: { archive, progress in try await service.prepareModels(variantID: captureID, archive: archive, progress: progress) },
            onDownloaded: { [weak self] archive in self?.adoptDownloadedArchive(archive, job: job) },
            onFinished: { [weak self] in await self?.refreshDownloadResult(job) }
        )
        if accepted
        {
            captureStatusRevisions[captureID, default: 0] &+= 1
            if operationCaptureID == captureID { jobError = nil }
        }
    }

    private func adoptDownloadedArchive(_ archive: EarthSourceArchive, job: EarthDownloadJob)
    {
        guard downloadJob(job.id.variantID)?.generation == job.generation else { return }
        captureStatusRevisions[job.id.variantID, default: 0] &+= 1
        captureStatuses[job.id.variantID] = .init(archive: archive, errorMessage: nil)
        if selectedCaptureID == job.id.variantID
        {
            downloads.restore(archive)
            savedStatus = "Downloaded"
        }
    }

    private func refreshDownloadResult(_ job: EarthDownloadJob) async
    {
        let variantID = job.id.variantID
        guard downloadJob(variantID)?.generation == job.generation else { return }
        do
        {
            let opened = try await store.openVariant(id: id, variantID: variantID)
            let statuses = try await store.captureStatuses(id: id)
            guard downloadJob(variantID)?.generation == job.generation,
                  opened.variant.capture.id == job.sourceID,
                  let locationIndex = locations.firstIndex(where: { $0.id == opened.location.id }),
                  let variantIndex = locations[locationIndex].variants.firstIndex(where: { $0.id == variantID }) else { return }
            locations[locationIndex].variants[variantIndex] = opened.variant
            captureStatuses[variantID] = statuses[variantID]
            captureStatusRevisions[variantID, default: 0] &+= 1
            if selectedCaptureID == variantID
            {
                downloads.restore(opened.archive)
                prepared = opened.prepared
                savedStatus = opened.prepared?.state == .ready ? "Ready" : EarthProjectCaptureStatus(archive: opened.archive, errorMessage: opened.archive.interruptionReason).title
            }
        }
        catch
        {
            guard downloadJob(variantID)?.generation == job.generation else { return }
            captureStatuses[variantID] = .init(archive: nil, errorMessage: error.localizedDescription)
        }
    }

    func exportVariant(_ variantID: UUID)
    {
        guard !isBusy, downloadJob(variantID)?.phase.isActive != true, captureStatuses[variantID]?.archive?.state == .downloaded else { return }
        export.export(variantID: variantID, saveEdits: { [weak self] in
            guard let self else { throw CancellationError() }
            try await flushEdits()
        }, onFinished: { [weak self, store, id] in
            // Offline preparation may have committed even if export was cancelled.
            // Reload independently of the cancelled worker before enabling actions.
            let reload = Task { try await store.open(id: id) }
            do
            {
                let opened = try await reload.value
                guard let self else { return }
                apply(opened: opened, restoresEditor: !hasPendingEdits && persistenceError == nil)
                if opened.record.captures.first(where: { $0.id == variantID })?.preparation != nil
                { downloadQueue.forgetFinishedJob(.init(projectID: id, variantID: variantID)) }
            }
            catch { self?.persistenceError = error.localizedDescription }
        })
    }

    func preparePreview(onPrepared: @escaping @MainActor () -> Void)
    {
        guard !isBusy, selectedCaptureID.map({ downloadJob($0)?.phase.isActive != true }) == true,
              let archive = downloads.archive, archive.state == .downloaded else { return }
        let job = begin(.preparing, captureID: selectedCaptureID)
        jobTask = Task
        { [weak self] in
            guard let self else { return }
            defer { finish(job) }
            do { try await flushEdits(); try await prepare(archive: archive, job: job, onPrepared: onPrepared) }
            catch { await failed(error, job: job) }
        }
    }

    func pause()
    {
        guard phase != .deleting else { return }
        jobTask?.cancel()
        if phase != .idle { progressText = "Stopping…" }
        else if preview.isLoading { preview.cancel() }
        else if export.isLoading { export.cancel() }
    }

    private func begin(_ phase: EarthProjectJobPhase, captureID: UUID? = nil) -> UUID
    {
        let job = UUID()
        jobID = job
        self.phase = phase
        operationCaptureID = captureID
        jobError = nil
        progressText = phase.title
        return job
    }

    private func finish(_ job: UUID)
    {
        guard jobID == job else { return }
        phase = .idle
        jobTask = nil
    }

    private func prepare(archive: EarthSourceArchive, job: UUID, onPrepared: @MainActor () -> Void) async throws
    {
        phase = .preparing
        progressText = "Preparing downloaded models offline…"
        let result = try await captureService.prepareModels(archive: archive)
        { [weak self] progress in
            Task
            { @MainActor [weak self] in
                guard let self, jobID == job, phase == .preparing else { return }
                progressText = progress.phase == .inspecting ? "Reading source files: \(progress.processedPlacements.formatted()) / \(progress.totalPlacements.formatted())" : "Preparing models: \(progress.completedModels.formatted()) written"
            }
        }
        try Task.checkCancellation()
        guard jobID == job else { throw CancellationError() }
        let record = try await store.record(id: id)
        try Task.checkCancellation()
        guard record.currentCapture?.id.uuidString == archive.directoryURL.lastPathComponent,
              record.currentPreparation?.id.uuidString == result.directoryURL.lastPathComponent
        else { throw EarthProjectStoreError.sourceMismatch }
        adoptEditor(record)
        selectedCaptureID = record.selectedCaptureID
        prepared = result
        if result.state == .ready, let selectedCaptureID
        { downloadQueue.forgetFinishedJob(.init(projectID: id, variantID: selectedCaptureID)) }
        savedStatus = result.state == .ready ? "Ready" : "Preparation incomplete"
        progressText = "Ready"
        onPrepared()
    }

    private func apply(archive: EarthSourceArchive) async throws
    {
        let record = try await store.record(id: id)
        guard record.currentCapture?.id.uuidString == archive.directoryURL.lastPathComponent,
              record.currentCapture?.request == archive.request else { throw EarthProjectStoreError.sourceMismatch }
        adoptEditor(record)
        selectedCaptureID = record.selectedCaptureID
        downloads.restore(archive)
        savedStatus = EarthProjectCaptureStatus(archive: archive, errorMessage: archive.interruptionReason).title
        updateCaptureStatus()
    }

    private func apply(opened: EarthOpenedProject, restoresEditor: Bool)
    {
        adoptLocations(opened.record.locations)
        selectedCaptureID = opened.record.selectedCaptureID
        downloads.restore(opened.archive)
        prepared = opened.prepared
        savedStatus = opened.status
        updateCaptureStatus()
        export.reloadHistory()
        if restoresEditor { adoptEditor(opened.record) }
    }

    private func adoptEditor(_ record: EarthProjectRecord)
    {
        if let adjustment = areaAdjustment,
           record.locations.first(where: { $0.id == adjustment.locationID }).map({ adjustment.matches($0) }) != true
        { mapEdit.cancel(); areaAdjustment = nil }
        title = record.title
        searchAddress = record.searchAddress
        searchResult = record.searchResult
        adoptLocations(record.locations)
        editingLocationID = record.editingLocationID
        selectedCaptureID = record.selectedCaptureID
        refreshMapSelection()
    }

    private func adoptLocations(_ values: [EarthLocationRecord])
    {
        let previousIDs = Set(locations.map(\.id))
        let currentIDs = Set(values.map(\.id))
        expandedLocationIDs.formIntersection(currentIDs)
        expandedLocationIDs.formUnion(currentIDs.subtracting(previousIDs))
        locations = values
    }

    private func updateCaptureStatus()
    {
        if let selectedCaptureID, let archive = downloads.archive
        {
            captureStatusRevisions[selectedCaptureID, default: 0] &+= 1
            let historyAllowsDetailChange = selectedCapture?.previousCaptures.isEmpty == true || captureStatuses[selectedCaptureID]?.canChangeDetail == true
            let canChangeDetail = historyAllowsDetailChange && selectedCapture?.preparation == nil && EarthProjectCaptureStatus.isUnstarted(archive)
            let historyAllowsAreaChange = selectedCapture?.previousCaptures.isEmpty == true || captureStatuses[selectedCaptureID]?.canChangeArea == true
            let canChangeArea = historyAllowsAreaChange && selectedCapture?.preparation == nil && archive.state != .downloaded
            captureStatuses[selectedCaptureID] = .init(archive: archive, errorMessage: archive.interruptionReason, canChangeDetail: canChangeDetail, canChangeArea: canChangeArea)
        }
    }

    private func failed(_ error: any Error, job: UUID) async
    {
        guard jobID == job else { return }
        do
        {
            // The cancelled operation must still be able to read its durable
            // result; identity verification contains cancellation checkpoints.
            let reload = Task { [store, id] in try await store.open(id: id) }
            let reopened = try await reload.value
            apply(opened: reopened, restoresEditor: false)
        }
        catch
        {
            jobError = error.localizedDescription
            jobFailureStatus = "Project reload failed"
            return
        }
        if error is CancellationError
        {
            progressText = downloads.archive?.state == .downloaded ? "Preparation cancelled · download retained" : "Download paused"
        }
        else
        {
            let prefix = downloads.archive?.state == .downloaded ? "Download retained. " : ""
            jobError = prefix + error.localizedDescription
            jobFailureStatus = phase == .preparing ? "Preparation failed" : "Download failed"
            progressText = jobFailureStatus
        }
    }

    private func flushEdits() async throws
    {
        if let saveTask { await saveTask.value }
        guard persistenceError == nil, !hasPendingEdits else { throw EarthAppFilesError.storage }
        try Task.checkCancellation()
    }

    private func refreshMapSelection()
    {
        confirmation = nil
        mapInputError = nil
        guard let location = editingLocation else { return }
        do { confirmation = try EarthConfirmedSelection(location: location) }
        catch { mapInputError = error.localizedDescription }
    }

    private func savePendingEdits()
    {
        guard saveTask == nil, hasPendingEdits else { return }
        isSaving = true
        saveTask = Task
        { [weak self, store, id] in
            guard let self else { return }
            defer { saveTask = nil; isSaving = false }
            while hasPendingEdits
            {
                let searchValue = pendingSearch
                let locationValues = pendingLocations
                let titleValue = pendingTitle
                pendingSearch = nil
                pendingLocations = [:]
                pendingTitle = nil
                do
                {
                    let record = try await store.updateEditor(id: id, title: titleValue, searchAddress: searchValue, locations: locationValues)
                    for (locationID, submitted) in locationValues
                    {
                        guard let index = locations.firstIndex(where: { $0.id == locationID }), locations[index].edit == submitted,
                              let saved = record.locations.first(where: { $0.id == locationID }) else { continue }
                        locations[index].name = saved.name
                    }
                    persistenceError = nil
                }
                catch
                {
                    let hasNewEdits = hasPendingEdits
                    if pendingSearch == nil { pendingSearch = searchValue }
                    for (key, value) in locationValues where pendingLocations[key] == nil { pendingLocations[key] = value }
                    if pendingTitle == nil { pendingTitle = titleValue }
                    persistenceError = error.localizedDescription
                    if !hasNewEdits { return }
                }
            }
        }
    }
}

enum EarthProjectJobPhase: Equatable
{
    case idle, resolving, addingVariant, downloading, preparing, refreshing, selectingCapture, editingLocation, editingVariant, deleting
    var title: String
    {
        switch self
        {
            case .idle: ""
            case .resolving: "Finding address…"
            case .addingVariant: "Adding variant…"
            case .downloading: "Downloading"
            case .preparing: "Preparing"
            case .refreshing: "Refreshing project…"
            case .selectingCapture: "Opening capture…"
            case .editingLocation: "Updating location…"
            case .editingVariant: "Updating variant…"
            case .deleting: "Moving to Trash…"
        }
    }
}
