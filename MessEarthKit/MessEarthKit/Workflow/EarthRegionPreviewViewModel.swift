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
    @ObservationIgnored private(set) var renderer: EarthPreviewRenderer?
    @ObservationIgnored private let service: EarthRegionPreviewService
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var isVisible = false
    @ObservationIgnored private var isCancelling = false
    @ObservationIgnored private var displayedCollectionURL: URL?

    init(service: EarthRegionPreviewService) { self.service = service }

    func show(_ collection: EarthPreparedCollection)
    {
        guard !isLoading, !(hasPreview && displayedCollectionURL == collection.directoryURL) else { return }
        clear()
        let job = UUID()
        generation = job
        isLoading = true
        isCancelling = false
        status = "Checking the whole region…"
        let report: @Sendable (EarthRegionPreviewProgress) -> Void = { [weak self] progress in
            Task
            { @MainActor [weak self] in
                guard let self, generation == job, isLoading, !isCancelling else { return }
                let action = progress.phase == .checking ? "Checking region" : "Loading region"
                status = "\(action): \(progress.completed.formatted()) / \(progress.total.formatted())"
            }
        }
        let worker = Task.detached(priority: .userInitiated)
        { [service] in try await service.load(collection: collection, progress: report) }
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
                    let dimensions = result.scene.bounds.dimensions
                    summary = String(format: "Downloaded region · %.1f × %.1f × %.1f m", dimensions.x, dimensions.y, dimensions.z)
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
        renderer = nil
        hasPreview = false
        displayedCollectionURL = nil
    }
}
