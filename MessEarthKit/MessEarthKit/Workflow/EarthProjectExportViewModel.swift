import Foundation
import MessEarthKit
import Observation

enum EarthProjectExportField: String, CaseIterable, Identifiable
{
    case vertexColors = "Vertex colors", textureCoordinates = "UV coordinates"
    case materials = "Materials", textures = "Textures"

    var id: Self { self }
    var keyPath: WritableKeyPath<EarthGLBExportOptions, Bool>
    {
        switch self
        {
            case .vertexColors: \.includeVertexColors
            case .textureCoordinates: \.includeTextureCoordinates
            case .materials: \.includeMaterials
            case .textures: \.includeTextures
        }
    }
}

/// Project-retained worker with variant-scoped controls and durable results.
@MainActor
@Observable
final class EarthProjectExportViewModel
{
    private(set) var isLoading = false
    private(set) var isLoadingHistory = false
    private(set) var isManagingHistory = false
    private(set) var isAddingToQueue = false
    var isBusy: Bool { isLoading || isManagingHistory || isAddingToQueue }
    private(set) var variantID: UUID?
    private(set) var status = ""
    private(set) var errorMessage: String?
    private(set) var historyError: String?
    private(set) var managementError: String?
    private(set) var history: [EarthProjectExportItem] = []
    private(set) var unrecordedExport: EarthProjectExportRecord?
    private var formats: [UUID: EarthExportFormat] = [:]
    private var optimizationChoices: [UUID: EarthExportOptimizationSettings] = [:]
    private var choices: [UUID: EarthGLBExportOptions] = [:]
    @ObservationIgnored private let service: EarthProjectExportService
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var historyTask: Task<Void, Never>?
    @ObservationIgnored private var jobID = UUID()
    @ObservationIgnored private var isCancelling = false
    @ObservationIgnored private var cancelQueued: (@MainActor () -> Void)?

    init(service: EarthProjectExportService) { self.service = service }

    var projectID: UUID { service.projectID }

    // Map delivery omits generated normals; SDK callers retain their own choice.
    func options(for variantID: UUID) -> EarthGLBExportOptions { choices[variantID] ?? EarthGLBExportOptions(includeNormals: false) }

    func format(for variantID: UUID) -> EarthExportFormat { formats[variantID] ?? .glb }
    func optimization(for variantID: UUID) -> EarthExportOptimizationSettings { optimizationChoices[variantID] ?? .init() }

    func setFormat(_ format: EarthExportFormat, variantID: UUID)
    {
        guard !isBusy else { return }
        formats[variantID] = format
    }

    func setOptimization(_ settings: EarthExportOptimizationSettings, variantID: UUID)
    {
        guard !isBusy else { return }
        optimizationChoices[variantID] = settings
    }

    func setOption(_ field: EarthProjectExportField, included: Bool, variantID: UUID)
    {
        guard !isBusy else { return }
        var value = options(for: variantID)
        value[keyPath: field.keyPath] = included
        switch field
        {
            case .textures:
                if included { value.includeTextureCoordinates = true; value.includeMaterials = true }
            case .textureCoordinates, .materials:
                if !included { value.includeTextures = false }
            case .vertexColors: break
        }
        choices[variantID] = value
    }

    func exports(for variantID: UUID) -> [EarthProjectExportItem] { history.filter { $0.record.variantID == variantID } }

    func reloadHistory()
    {
        guard !isBusy, !isLoadingHistory else { return }
        isLoadingHistory = true
        historyTask = Task
        { [weak self, service] in
            defer { self?.isLoadingHistory = false; self?.historyTask = nil }
            do { self?.history = try await service.exports(); self?.historyError = nil }
            catch { self?.historyError = error.localizedDescription }
        }
    }

    func rename(_ record: EarthProjectExportRecord, to name: String)
    { updateHistory { [service] in try await service.rename(record, to: name) } }

    func renameDraft(for record: EarthProjectExportRecord) -> EarthExportRenameViewModel
    { EarthExportRenameViewModel(record: record, automaticName: { [service] in try await service.automaticName(for: record) }) }

    func delete(_ record: EarthProjectExportRecord)
    { updateHistory { [service] in try await service.delete(record) } }

    private func updateHistory(_ operation: @escaping @Sendable () async throws -> [EarthProjectExportItem])
    {
        guard !isBusy, !isLoadingHistory else { return }
        isManagingHistory = true
        managementError = nil
        Task
        {
            defer { isManagingHistory = false }
            do { history = try await operation(); historyError = nil }
            catch
            {
                managementError = error.localizedDescription
                do { history = try await service.exports(); historyError = nil }
                catch { historyError = error.localizedDescription }
            }
        }
    }

    func export(
        variantID: UUID,
        saveEdits: @escaping @MainActor () async throws -> Void,
        onFinished: @escaping @MainActor () async -> Void
    )
    {
        guard !isBusy, !isLoadingHistory else { return }
        let requestedOptions = options(for: variantID)
        let requestedFormat = format(for: variantID)
        let requestedOptimization = optimization(for: variantID)
        let job = UUID()
        jobID = job
        self.variantID = variantID
        isLoading = true
        isCancelling = false
        errorMessage = nil
        unrecordedExport = nil
        status = "Preparing export…"
        task = Task
        { [weak self, service] in
            defer { self?.isLoading = false; self?.task = nil }
            do
            {
                try await saveEdits()
                try Task.checkCancellation()
                let result = try await service.export(variantID: variantID, options: requestedOptions, format: requestedFormat, optimization: requestedOptimization)
                { [weak self] progress in
                    Task
                    { @MainActor [weak self] in
                        guard let self, jobID == job, isLoading, !isCancelling else { return }
                        switch progress
                        {
                            case let .preparing(value):
                                status = value.phase == .inspecting
                                    ? "Preparing models: reading \(value.processedPlacements.formatted()) / \(value.totalPlacements.formatted())"
                                    : "Preparing models: \(value.completedModels.formatted()) written"
                            case let .exporting(value):
                                let action = value.phase == .checking ? "Checking models" : "Writing models"
                                status = "\(action): \(value.completedModels.formatted()) / \(value.totalModels.formatted())"
                        }
                    }
                }
                guard let self else { return }
                // A completed publication is durable even after a simultaneous Cancel.
                status = result.infoWarning ?? "Exported \(requestedFormat.rawValue)"
                do { history = try await service.exports(); historyError = nil }
                catch { historyError = error.localizedDescription }
            }
            catch
            {
                guard let self else { return }
                if error is CancellationError { status = "Export cancelled" }
                else
                {
                    status = "Export failed"
                    errorMessage = error.localizedDescription
                    if case let EarthProjectExportError.historyNotSaved(record, _) = error { unrecordedExport = record }
                }
            }
            await onFinished()
        }
    }

    func addToQueue(variantID: UUID, queue: EarthExportQueue, saveEdits: @escaping @MainActor () async throws -> Void)
    {
        guard !isBusy, !isLoadingHistory, queue.canEdit else { return }
        let requestedOptions = options(for: variantID)
        let requestedFormat = format(for: variantID)
        let requestedOptimization = optimization(for: variantID)
        self.variantID = variantID
        isAddingToQueue = true
        errorMessage = nil
        status = "Adding to queue…"
        task = Task
        { [self, service] in
            defer { isAddingToQueue = false; task = nil }
            do
            {
                try await saveEdits()
                let request = try await service.queuedRequest(variantID: variantID, options: requestedOptions, format: requestedFormat, optimization: requestedOptimization)
                guard queue.canEdit else { throw EarthProjectCaptureError.workInProgress }
                if queue.containsPending(request) { status = "Already queued" }
                else if queue.enqueue(request) { status = "Added to queue" }
                else { status = "Could not add to queue"; errorMessage = queue.operationError }
            }
            catch { status = "Could not add to queue"; errorMessage = error.localizedDescription }
        }
    }

    func exportQueued(_ entry: EarthExportQueueEntry, cancel: @escaping @MainActor () -> Void, progress: @escaping @Sendable (EarthProjectExportProgress) -> Void) async throws -> EarthProjectExportResult
    {
        guard !isBusy, let exportID = entry.exportID else { throw EarthProjectCaptureError.workInProgress }
        variantID = entry.request.variantID
        isLoading = true
        isCancelling = false
        errorMessage = nil
        unrecordedExport = nil
        cancelQueued = cancel
        status = "Exporting queued variant…"
        defer { isLoading = false; cancelQueued = nil }
        do
        {
            // A project refresh may still own a history read between queue
            // entries. Join that read before starting the next export.
            if let historyTask { await historyTask.value }
            try Task.checkCancellation()
            let request = entry.request
            let result = try await service.export(variantID: request.variantID, options: request.options, format: request.format, optimization: request.optimization, queuedRequest: request, exportID: exportID, progress: progress)
            status = result.infoWarning ?? "Exported \(request.format.rawValue)"
            do { history = try await service.exports(); historyError = nil }
            catch { historyError = error.localizedDescription }
            return result
        }
        catch
        {
            status = error is CancellationError ? "Export cancelled" : "Export failed"
            errorMessage = error is CancellationError ? nil : error.localizedDescription
            if case let EarthProjectExportError.historyNotSaved(record, _) = error { unrecordedExport = record }
            throw error
        }
    }

    func cancel()
    {
        guard isLoading else { return }
        isCancelling = true
        status = "Cancelling export…"
        if let cancelQueued { cancelQueued() }
        else { task?.cancel() }
    }

    func reveal(_ record: EarthProjectExportRecord)
    {
        Task
        { [weak self, service] in
            do { try await service.reveal(record) }
            catch { self?.historyError = error.localizedDescription; self?.reloadHistory() }
        }
    }
}
