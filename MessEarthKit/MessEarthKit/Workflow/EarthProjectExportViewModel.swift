import Foundation
import MessEarthKit
import Observation

enum EarthProjectExportPreset: String, CaseIterable, Sendable
{
    case full = "Full", untextured = "Untextured", minimal = "Minimal"

    var options: EarthGLBExportOptions
    {
        switch self
        {
            case .full: .full
            case .untextured: .untextured
            case .minimal: .minimal
        }
    }
}

enum EarthProjectExportField: String, CaseIterable, Identifiable
{
    case normals = "Normals", vertexColors = "Vertex colors", textureCoordinates = "UV coordinates"
    case materials = "Materials", textures = "Textures"

    var id: Self { self }
    var keyPath: WritableKeyPath<EarthGLBExportOptions, Bool>
    {
        switch self
        {
            case .normals: \.includeNormals
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
    var isBusy: Bool { isLoading || isManagingHistory }
    private(set) var variantID: UUID?
    private(set) var status = ""
    private(set) var errorMessage: String?
    private(set) var historyError: String?
    private(set) var managementError: String?
    private(set) var history: [EarthProjectExportItem] = []
    private(set) var unrecordedExport: EarthProjectExportRecord?
    private var choices: [UUID: EarthGLBExportOptions] = [:]
    @ObservationIgnored private let service: EarthProjectExportService
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var jobID = UUID()
    @ObservationIgnored private var isCancelling = false

    init(service: EarthProjectExportService) { self.service = service }

    func options(for variantID: UUID) -> EarthGLBExportOptions { choices[variantID] ?? .full }

    func presetName(for variantID: UUID) -> String
    { EarthProjectExportPreset.allCases.first { $0.options == options(for: variantID) }?.rawValue ?? "Custom" }

    func setPreset(_ preset: EarthProjectExportPreset, variantID: UUID)
    {
        guard !isBusy else { return }
        choices[variantID] = preset.options
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
            case .normals, .vertexColors: break
        }
        choices[variantID] = value
    }

    func exports(for variantID: UUID) -> [EarthProjectExportItem] { history.filter { $0.record.variantID == variantID } }

    func reloadHistory()
    {
        guard !isBusy, !isLoadingHistory else { return }
        isLoadingHistory = true
        Task
        { [weak self, service] in
            defer { self?.isLoadingHistory = false }
            do { self?.history = try await service.exports(); self?.historyError = nil }
            catch { self?.historyError = error.localizedDescription }
        }
    }

    func rename(_ record: EarthProjectExportRecord, to name: String)
    { updateHistory { [service] in try await service.rename(record, to: name) } }

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
        let requestedPreset = presetName(for: variantID)
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
                let result = try await service.export(variantID: variantID, options: requestedOptions)
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
                status = result.infoWarning ?? "Exported \(requestedPreset.lowercased()) GLB"
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

    func cancel()
    {
        guard isLoading else { return }
        isCancelling = true
        status = "Cancelling export…"
        task?.cancel()
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
