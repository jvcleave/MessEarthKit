import Foundation
import Observation

/// One app-owned viewer window. A replacement waits for cancelled native work;
/// generation checks prevent stale results from replacing the selected export.
@MainActor @Observable
final class EarthExportViewerViewModel
{
    private(set) var request: EarthExportViewerRequest?
    private(set) var choices: [EarthExportViewerChoice] = []
    private(set) var isLoading = false
    private(set) var isOpen = false
    private(set) var status = "Choose VIEW beside an exported file."
    private(set) var errorMessage: String?
    private(set) var fileName = "Exported Model"
    private(set) var summary = ""
    private(set) var attribution = ""
    private(set) var revision: UInt64 = 0
    @ObservationIgnored private(set) var renderer: EarthPreviewRenderer?
    @ObservationIgnored private let service: EarthExportViewerService
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var comparisonCamera: EarthPreviewCameraState?

    init(service: EarthExportViewerService) { self.service = service }

    func open(_ request: EarthExportViewerRequest, title: String? = nil)
    {
        if isOpen, self.request == request, renderer != nil { return }
        isOpen = true
        if self.request?.projectID != request.projectID || self.request?.variantID != request.variantID
        { choices = []; comparisonCamera = nil }
        else { comparisonCamera = renderer?.cameraState ?? comparisonCamera }
        self.request = request
        fileName = title ?? choices.first(where: { $0.id == request.exportID })?.title ?? "Exported Model"
        if !choices.contains(where: { $0.id == request.exportID })
        { choices.append(.init(id: request.exportID, title: fileName, isAvailable: true)) }
        let previous = task
        previous?.cancel()
        releaseScene()
        let job = UUID()
        generation = job
        isLoading = true
        errorMessage = nil
        status = "Reading exported model…"
        task = Task
        { [weak self, service] in
            if let previous { await previous.value }
            do
            {
                try Task.checkCancellation()
                let result = try await service.load(request)
                { [weak self] phase in
                    Task
                    { @MainActor [weak self] in
                        guard let self, generation == job, isLoading else { return }
                        status = phase == .reading ? "Reading exported model…" : "Preparing viewer…"
                    }
                }
                try Task.checkCancellation()
                guard let self, generation == job, isOpen else { return }
                result.model.renderer.publish(scene: result.model.scene, camera: comparisonCamera)
                renderer = result.model.renderer
                choices = result.choices
                fileName = result.model.fileName
                let model = result.model
                let size = ByteCountFormatter.string(fromByteCount: Int64(model.byteCount), countStyle: .file)
                summary = "\(model.format.rawValue) - \(size) - \(model.vertexCount.formatted()) vertices - \(model.triangleCount.formatted()) triangles"
                attribution = result.model.scene.attributions.joined(separator: "; ")
                revision &+= 1
                status = "Ready"
            }
            catch is CancellationError
            {
                if let self, generation == job { status = "Viewer load cancelled" }
            }
            catch
            {
                if let self, generation == job { errorMessage = error.localizedDescription; status = "Viewer unavailable" }
            }
            guard let self, generation == job else { return }
            isLoading = false
            task = nil
        }
    }

    func selectExport(_ id: UUID)
    {
        guard let request, let choice = choices.first(where: { $0.id == id }), choice.isAvailable, id != request.exportID else { return }
        open(.init(projectID: request.projectID, variantID: request.variantID, exportID: id))
    }

    func retry() { if let request { open(request) } }
    func cancel() { task?.cancel() }
    func frameAll() { renderer?.resetCamera(); revision &+= 1 }

    func close()
    {
        isOpen = false
        generation = UUID()
        task?.cancel()
        // Retain the task until native work settles, so a quick reopen queues.
        isLoading = false
        releaseScene()
        choices = []
        comparisonCamera = nil
        request = nil
        fileName = "Exported Model"
        status = "Choose VIEW beside an exported file."
        errorMessage = nil
    }

    /// Storage replacement must wait for cancelled native reads as well as
    /// clearing presentation. A newer open keeps ownership of its own task.
    func closeAndWait() async
    {
        close()
        let closing = generation
        if let task { await task.value }
        if generation == closing { task = nil }
    }

    private func releaseScene()
    {
        renderer?.clearScene()
        renderer = nil
        summary = ""
        attribution = ""
    }
}
