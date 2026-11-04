import Foundation
import MessEarthKit
import Observation

/// Library-retained export scheduling. The view only sends semantic actions;
/// queued requests and completed results survive both navigation and relaunch.
@MainActor
@Observable
final class EarthExportQueue
{
    typealias Export = @MainActor (EarthExportQueueEntry, @escaping @Sendable (EarthProjectExportProgress) -> Void) async throws -> EarthProjectExportResult

    private(set) var entries: [EarthExportQueueEntry] = []
    private(set) var isLoading = false
    private(set) var isSaving = false
    private(set) var isRunning = false
    private(set) var isCollecting = false
    private(set) var isCancelling = false
    private(set) var activeID: UUID?
    private(set) var status = ""
    private(set) var activeProgress = ""
    private(set) var loadError: String?
    private(set) var persistenceError: String?
    private(set) var operationError: String?
    private(set) var lastCollectionURL: URL?
    private var hasLoaded = false
    @ObservationIgnored private let files: EarthAppFiles
    @ObservationIgnored private let store: EarthExportQueueStore
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var saveTask: Task<Void, Error>?
    @ObservationIgnored private var saveID = UUID()
    @ObservationIgnored private var runID = UUID()

    init(files: EarthAppFiles)
    {
        self.files = files
        store = EarthExportQueueStore(files: files)
        reload()
    }

    var canEdit: Bool { hasLoaded && !isLoading && !isCollecting && loadError == nil }
    var isBusy: Bool { isLoading || isSaving || isRunning || isCollecting }
    var selectedPendingCount: Int { entries.filter { $0.isIncluded && $0.phase == .pending }.count }
    var selectedCompleteCount: Int { entries.filter { $0.isIncluded && $0.phase == .complete }.count }
    var canStart: Bool { canEdit && !isRunning && !isSaving && persistenceError == nil && selectedPendingCount > 0 }
    var canCollect: Bool { canEdit && !isRunning && !isSaving && persistenceError == nil && selectedCompleteCount > 0 }
    var pendingCount: Int { entries.filter { $0.phase == .pending }.count }
    var buttonTitle: String
    {
        if isRunning || isCollecting { return "QUEUE MANAGER - " + status }
        return entries.isEmpty ? "QUEUE MANAGER" : "QUEUE MANAGER (\(entries.count))"
    }

    func reload()
    {
        guard !isBusy else { return }
        isLoading = true
        loadError = nil
        task = Task
        { [self] in
            defer { isLoading = false; task = nil }
            do
            {
                var restored = try await store.load()
                var changed = false
                for index in restored.indices where restored[index].phase == .running
                {
                    let entry = restored[index]
                    do
                    {
                        let history = try await EarthProjectExportHistoryStore(projectID: entry.request.projectID, files: files).records()
                        if let result = history.first(where: { $0.id == entry.exportID })
                        {
                            restored[index].result = result
                            restored[index].phase = .complete
                        }
                        else { restored[index].phase = .cancelled }
                    }
                    catch
                    {
                        restored[index].phase = .failed
                        restored[index].message = error.localizedDescription
                    }
                    changed = true
                }
                if changed { try await store.save(restored) }
                entries = restored
                hasLoaded = true
                persistenceError = nil
            }
            catch { loadError = error.localizedDescription }
        }
    }

    func containsPending(_ request: EarthQueuedExportRequest) -> Bool
    { entries.contains { ($0.phase == .pending || $0.phase == .running) && $0.request.hasSameExport(as: request) } }

    @discardableResult
    func enqueue(_ request: EarthQueuedExportRequest) -> Bool
    {
        guard canEdit, !containsPending(request) else { return false }
        do { try request.validate() }
        catch { operationError = error.localizedDescription; return false }
        entries.append(.init(request: request))
        persist()
        return true
    }

    func setIncluded(_ included: Bool, id: UUID)
    {
        guard canEdit, id != activeID, let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].isIncluded = included
        persist()
    }

    func setAllIncluded(_ included: Bool)
    {
        guard canEdit else { return }
        for index in entries.indices where entries[index].id != activeID { entries[index].isIncluded = included }
        persist()
    }

    func remove(_ id: UUID)
    {
        guard canEdit, id != activeID else { return }
        entries.removeAll { $0.id == id }
        persist()
    }

    func removeIncluded()
    {
        guard canEdit else { return }
        entries.removeAll { $0.isIncluded && $0.id != activeID }
        persist()
    }

    func move(_ id: UUID, by offset: Int)
    {
        guard canEdit, !isRunning, let index = entries.firstIndex(where: { $0.id == id }), entries.indices.contains(index + offset) else { return }
        entries.swapAt(index, index + offset)
        persist()
    }

    func retry(_ id: UUID)
    {
        guard canEdit, let index = entries.firstIndex(where: { $0.id == id }),
              entries[index].phase == .failed || entries[index].phase == .cancelled,
              !containsPending(entries[index].request)
        else { return }
        entries[index].phase = .pending
        entries[index].exportID = nil
        entries[index].message = nil
        entries[index].isIncluded = true
        persist()
    }

    func retrySave()
    {
        guard canEdit else { return }
        persist()
    }

    func start(export: @escaping Export)
    {
        guard canStart else { return }
        let selected = entries.filter { $0.isIncluded && $0.phase == .pending }.map(\.id)
        let run = UUID()
        runID = run
        isRunning = true
        isCancelling = false
        operationError = nil
        lastCollectionURL = nil
        status = "Exporting 0 of \(selected.count)"
        task = Task
        { [self] in
            defer
            {
                activeID = nil
                activeProgress = ""
                isRunning = false
                isCancelling = false
                task = nil
            }
            var finished = 0
            for id in selected
            {
                if Task.isCancelled { break }
                guard let index = entries.firstIndex(where: { $0.id == id }), entries[index].isIncluded,
                      entries[index].phase == .pending else { continue }
                activeID = id
                entries[index].phase = .running
                entries[index].exportID = UUID()
                entries[index].message = nil
                let entry = entries[index]
                status = "Exporting \(finished + 1) of \(selected.count)"
                activeProgress = "Preparing export…"
                do
                {
                    // Persist the attempt identity before the exporter can publish.
                    try await persist().value
                    try Task.checkCancellation()
                    let result = try await export(entry)
                    { [weak self] progress in
                        Task { @MainActor [weak self] in self?.updateProgress(progress, id: id, run: run) }
                    }
                    complete(id, record: result.output, warning: result.infoWarning)
                }
                catch let EarthProjectExportError.historyNotSaved(record, reason)
                { complete(id, record: record, warning: reason, isUnrecorded: true) }
                catch
                {
                    if let current = entries.firstIndex(where: { $0.id == id })
                    {
                        entries[current].phase = error is CancellationError ? .cancelled : .failed
                        entries[current].message = error is CancellationError ? nil : error.localizedDescription
                    }
                }
                do { try await persist().value }
                catch { status = "Queue stopped"; return }
                activeID = nil
                finished += 1
            }
            status = Task.isCancelled ? "Queue stopped" : "Queue finished"
        }
    }

    func cancel()
    {
        guard isRunning || isCollecting else { return }
        isCancelling = true
        status = "Stopping…"
        task?.cancel()
    }

    func collect(to parent: URL)
    {
        guard canCollect else { return }
        let selected = entries.filter { $0.isIncluded && $0.phase == .complete }
        let run = UUID()
        runID = run
        isCollecting = true
        isCancelling = false
        operationError = nil
        status = "Collecting exports…"
        task = Task
        { [self] in
            defer { isCollecting = false; isCancelling = false; task = nil }
            do
            {
                lastCollectionURL = try await files.collectExports(selected, to: parent)
                { [weak self] completed, total in
                    Task
                    { @MainActor [weak self] in
                        guard let self, runID == run, isCollecting, !isCancelling else { return }
                        status = "Collecting files: \(completed) / \(total)"
                    }
                }
                status = "Collected \(selected.count) exports"
            }
            catch
            {
                status = error is CancellationError ? "Collection cancelled" : "Collection failed"
                operationError = error is CancellationError ? nil : error.localizedDescription
            }
        }
    }

    func reveal(_ id: UUID)
    {
        guard let entry = entries.first(where: { $0.id == id }), entry.phase == .complete else { return }
        operationError = nil
        Task
        { [weak self, files] in
            do
            {
                let url = try await files.queuedExportFileURL(entry)
                await files.reveal(url)
            }
            catch { self?.operationError = error.localizedDescription }
        }
    }

    func revealCollection()
    {
        guard let lastCollectionURL else { return }
        Task { await files.reveal(lastCollectionURL) }
    }

    private func complete(_ id: UUID, record: EarthProjectExportRecord, warning: String?, isUnrecorded: Bool = false)
    {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].phase = .complete
        entries[index].result = record
        entries[index].message = warning
        entries[index].isUnrecorded = isUnrecorded
    }

    private func updateProgress(_ progress: EarthProjectExportProgress, id: UUID, run: UUID)
    {
        guard runID == run, activeID == id, isRunning, !isCancelling else { return }
        switch progress
        {
            case let .preparing(value):
                activeProgress = value.phase == .inspecting
                    ? "Preparing models: reading \(value.processedPlacements.formatted()) / \(value.totalPlacements.formatted())"
                    : "Preparing models: \(value.completedModels.formatted()) written"
            case let .exporting(value):
                let action = value.phase == .checking ? "Checking models" : "Writing models"
                activeProgress = "\(action): \(value.completedModels.formatted()) / \(value.totalModels.formatted())"
        }
    }

    /// Every snapshot waits for its predecessor. A newer edit can recover a
    /// failed save, but no export starts before its own attempt is durable.
    @discardableResult
    private func persist() -> Task<Void, Error>
    {
        let previous = saveTask
        let snapshot = entries
        let generation = UUID()
        saveID = generation
        isSaving = true
        let saving = Task
        { [store] in
            if let previous { _ = await previous.result }
            try await store.save(snapshot)
        }
        saveTask = saving
        Task
        { [weak self] in
            let result = await saving.result
            guard let self, saveID == generation else { return }
            isSaving = false
            switch result
            {
                case .success: persistenceError = nil
                case let .failure(error): persistenceError = error.localizedDescription
            }
        }
        return saving
    }
}
