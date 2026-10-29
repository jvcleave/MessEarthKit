import Foundation
import MessEarthKit
import Observation

/// Project-retained job ownership; navigation controls visibility, not lifetime.
@MainActor
@Observable
final class EarthRegionPreviewViewModel
{
    private(set) var isLoading = false
    private(set) var hasPreview = false
    private(set) var status = "Preview Unavailable"
    private(set) var summary = ""
    private(set) var attribution = ""
    private(set) var appearanceNotice: String?
    private(set) var errorMessage: String?
    private(set) var revision: UInt64 = 0
    private(set) var selectedPartOffset: Int?
    private(set) var displayMode = EarthPreviewDisplayMode.wireframe
    private(set) var usesAutomaticMemoryBudget = true
    private(set) var customMemoryBudgetGiB = "1"
    private(set) var memoryBudgetError: String?
    @ObservationIgnored private(set) var renderer: EarthPreviewRenderer?
    @ObservationIgnored private let service: EarthRegionPreviewService
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var isVisible = false
    @ObservationIgnored private var isCancelling = false
    @ObservationIgnored private var displayedCollectionURL: URL?
    @ObservationIgnored private var requestedCollectionURL: URL?
    @ObservationIgnored private var memoryLimit: EarthPreviewMemoryLimit = .automatic
    @ObservationIgnored private var displayedMemoryLimit: EarthPreviewMemoryLimit?
    @ObservationIgnored private var displayedMode: EarthPreviewDisplayMode?

    init(service: EarthRegionPreviewService) { self.service = service }

    func setDisplayMode(_ mode: EarthPreviewDisplayMode, collection: EarthPreparedCollection)
    {
        guard !isLoading, memoryBudgetError == nil, displayMode != mode else { return }
        displayMode = mode
        show(collection)
    }

    func setUsesAutomaticMemoryBudget(_ value: Bool)
    {
        guard !isLoading else { return }
        usesAutomaticMemoryBudget = value
        updateMemoryLimit()
    }

    func setCustomMemoryBudgetGiB(_ value: String)
    {
        guard !isLoading else { return }
        customMemoryBudgetGiB = value
        updateMemoryLimit()
    }

    private func updateMemoryLimit()
    {
        do
        {
            if usesAutomaticMemoryBudget { memoryLimit = .automatic }
            else { memoryLimit = try EarthPreviewMemoryLimit(gibibytes: customMemoryBudgetGiB) }
            memoryBudgetError = nil
        }
        catch { memoryBudgetError = error.localizedDescription }
    }

    func reload(_ collection: EarthPreparedCollection)
    {
        guard !isLoading, memoryBudgetError == nil else { return }
        clear()
        show(collection)
    }

    func show(_ collection: EarthPreparedCollection)
    {
        load(collection, partOffset: requestedCollectionURL == collection.directoryURL ? selectedPartOffset : nil)
    }

    func showEntireRegion(_ collection: EarthPreparedCollection) { load(collection, partOffset: nil) }

    func showPart(_ collection: EarthPreparedCollection, offset: Int)
    {
        guard offset >= 0, offset < collection.modelCount else { return }
        load(collection, partOffset: offset)
    }

    private func load(_ collection: EarthPreparedCollection, partOffset: Int?)
    {
        guard !isLoading, memoryBudgetError == nil,
              !(hasPreview && displayedCollectionURL == collection.directoryURL && selectedPartOffset == partOffset && displayedMemoryLimit == memoryLimit && displayedMode == displayMode)
        else { return }
        clear()
        requestedCollectionURL = collection.directoryURL
        selectedPartOffset = partOffset
        let requestedMemoryLimit = memoryLimit
        let requestedMode = displayMode
        let job = UUID()
        generation = job
        isLoading = true
        isCancelling = false
        status = partOffset == nil ? "Checking the whole region…" : "Checking model part…"
        let report: @Sendable (EarthRegionPreviewProgress) -> Void = { [weak self] progress in
            Task
            { @MainActor [weak self] in
                guard let self, generation == job, isLoading, !isCancelling else { return }
                let action = progress.phase == .checking ? "Checking models" : "Loading models"
                status = "\(action): \(progress.completed.formatted()) / \(progress.total.formatted())"
            }
        }
        let worker = Task.detached(priority: .userInitiated)
        { [service] in
            let modelID: Int?
            if let partOffset
            {
                let page = try await collection.models(offset: partOffset, limit: 1)
                guard let model = page.first else { throw EarthRegionPreviewError.sourceChanged }
                modelID = model.id
            }
            else { modelID = nil }
            return try await service.load(collection: collection, modelID: modelID, memoryLimit: requestedMemoryLimit, displayMode: requestedMode, progress: report)
        }
        task = Task
        { [weak self] in
            do
            {
                let result = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                try Task.checkCancellation()
                guard let self, generation == job else { return }
                if isVisible
                {
                    result.renderer.publish(scene: result.scene)
                    renderer = result.renderer
                    hasPreview = true
                    displayedCollectionURL = collection.directoryURL
                    displayedMemoryLimit = requestedMemoryLimit
                    displayedMode = requestedMode
                    let dimensions = result.scene.bounds.dimensions
                    let label = partOffset.map { "Part \($0 + 1) of \(collection.modelCount)" } ?? "Downloaded region"
                    summary = String(format: "\(label) · %.1f × %.1f × %.1f m", dimensions.x, dimensions.y, dimensions.z)
                    attribution = result.scene.attributions.joined(separator: "; ")
                    appearanceNotice = result.appearancePolicy == .optimizedCopy
                        ? "Optimized copy · Distant textures and lighting on split surfaces may differ."
                        : nil
                    revision &+= 1
                }
                status = "Ready"
            }
            catch is CancellationError { self?.status = "Preview cancelled · download retained" }
            catch
            {
                self?.errorMessage = error.localizedDescription
                self?.status = "Preview Unavailable"
            }
            guard let self, generation == job else { return }
            isLoading = false
            task = nil
        }
    }

    func setVisible(_ value: Bool)
    {
        isVisible = value
        if !value { releaseScene() }
    }

    func cancel()
    {
        guard isLoading else { return }
        isCancelling = true
        status = "Cancelling preview…"
        task?.cancel()
    }

    func clear()
    {
        guard !isLoading else { return }
        releaseScene()
        summary = ""
        attribution = ""
        appearanceNotice = nil
        errorMessage = nil
        status = "Preview Unavailable"
    }

    func resetCamera()
    {
        renderer?.resetCamera()
        revision &+= 1
    }

    private func releaseScene()
    {
        renderer?.clearScene()
        renderer = nil
        hasPreview = false
        displayedCollectionURL = nil
        displayedMemoryLimit = nil
        displayedMode = nil
    }
}
