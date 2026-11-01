import Foundation
import MessEarthKit
import Observation

struct EarthDownloadJobID: Hashable, Sendable
{
    let projectID: UUID
    let variantID: UUID
}

enum EarthDownloadJobPhase: Sendable
{
    case queued, downloading, waitingForPreparation, preparing, stopping, paused, failed, complete

    var isActive: Bool
    {
        switch self
        {
            case .queued, .downloading, .waitingForPreparation, .preparing, .stopping: true
            case .paused, .failed, .complete: false
        }
    }

    var title: String
    {
        switch self
        {
            case .queued: "Queued for download"
            case .downloading: "Downloading…"
            case .waitingForPreparation: "Waiting to prepare models…"
            case .preparing: "Preparing models…"
            case .stopping: "Stopping…"
            case .paused: "Paused"
            case .failed: "Operation failed"
            case .complete: "Ready"
        }
    }
}

struct EarthDownloadJob: Sendable
{
    let id: EarthDownloadJobID
    let generation: UUID
    let locationID: UUID
    let sourceID: UUID
    var phase: EarthDownloadJobPhase = .queued
    var progressText = EarthDownloadJobPhase.queued.title
    var errorMessage: String?
}

/// App-owned FIFO admission. Tasks outlive views and cancellation releases a slot
/// only after the corresponding worker has actually stopped.
@MainActor
@Observable
final class EarthDownloadQueue
{
    typealias Download = @Sendable (@escaping @Sendable (EarthCaptureProgress) -> Void) async throws -> EarthSourceArchive
    typealias Prepare = @Sendable (EarthSourceArchive, @escaping @Sendable (EarthPreparationProgress) -> Void) async throws -> EarthPreparedCollection

    private(set) var jobs: [EarthDownloadJobID: EarthDownloadJob] = [:]
    @ObservationIgnored private var work: [EarthDownloadJobID: Work] = [:]
    @ObservationIgnored private var downloadOrder: [EarthDownloadJobID] = []
    @ObservationIgnored private var preparationOrder: [EarthDownloadJobID] = []
    @ObservationIgnored private var downloading: [EarthDownloadJobID: Task<Void, Never>] = [:]
    @ObservationIgnored private var preparing: [EarthDownloadJobID: Task<Void, Never>] = [:]

    private struct Work
    {
        let download: Download
        let prepare: Prepare
        let onDownloaded: @MainActor (EarthSourceArchive) -> Void
        let onFinished: @MainActor () async -> Void
        var archive: EarthSourceArchive?
    }

    @discardableResult
    func enqueue(
        job: EarthDownloadJob,
        download: @escaping Download,
        prepare: @escaping Prepare,
        onDownloaded: @escaping @MainActor (EarthSourceArchive) -> Void,
        onFinished: @escaping @MainActor () async -> Void
    ) -> Bool
    {
        guard jobs[job.id]?.phase.isActive != true, work[job.id] == nil else { return false }
        jobs[job.id] = job
        work[job.id] = Work(download: download, prepare: prepare, onDownloaded: onDownloaded, onFinished: onFinished)
        downloadOrder.append(job.id)
        startDownloads()
        return true
    }

    func pause(_ id: EarthDownloadJobID)
    {
        guard jobs[id]?.phase.isActive == true else { return }
        if let task = downloading[id] ?? preparing[id]
        {
            jobs[id]?.phase = .stopping
            jobs[id]?.progressText = EarthDownloadJobPhase.stopping.title
            task.cancel()
        }
        else
        {
            jobs[id]?.phase = .stopping
            jobs[id]?.progressText = EarthDownloadJobPhase.stopping.title
            downloadOrder.removeAll { $0 == id }
            preparationOrder.removeAll { $0 == id }
            guard let job = jobs[id] else { return }
            Task { await self.finish(job, error: CancellationError()) }
        }
    }

    func forgetFinishedJob(_ id: EarthDownloadJobID)
    {
        guard jobs[id]?.phase.isActive != true, work[id] == nil else { return }
        jobs[id] = nil
    }

    private func startDownloads()
    {
        while downloading.count < 2, !downloadOrder.isEmpty
        {
            let id = downloadOrder.removeFirst()
            guard let job = jobs[id], let operation = work[id] else { continue }
            jobs[id]?.phase = .downloading
            jobs[id]?.progressText = EarthDownloadJobPhase.downloading.title
            downloading[id] = Task
            { [self] in
                do
                {
                    let archive = try await operation.download
                    { [weak self] progress in
                        Task { @MainActor [weak self] in self?.downloadProgress(progress, job: job) }
                    }
                    // Atomic source completion wins cancellation; retain it for
                    // export even if the user no longer wants preparation.
                    operation.onDownloaded(archive)
                    try Task.checkCancellation()
                    work[id]?.archive = archive
                    jobs[id]?.phase = .waitingForPreparation
                    jobs[id]?.progressText = EarthDownloadJobPhase.waitingForPreparation.title
                    preparationOrder.append(id)
                    downloading[id] = nil
                    startDownloads()
                    startPreparation()
                }
                catch { await finish(job, error: error) }
            }
        }
    }

    private func startPreparation()
    {
        guard preparing.isEmpty, !preparationOrder.isEmpty else { return }
        let id = preparationOrder.removeFirst()
        guard let job = jobs[id], let operation = work[id], let archive = operation.archive else { return }
        jobs[id]?.phase = .preparing
        jobs[id]?.progressText = EarthDownloadJobPhase.preparing.title
        preparing[id] = Task
        { [self] in
            do
            {
                _ = try await operation.prepare(archive)
                { [weak self] progress in
                    Task { @MainActor [weak self] in self?.preparationProgress(progress, job: job) }
                }
                await finish(job, error: nil)
            }
            catch { await finish(job, error: error) }
        }
    }

    private func downloadProgress(_ progress: EarthCaptureProgress, job: EarthDownloadJob)
    {
        guard jobs[job.id]?.generation == job.generation, jobs[job.id]?.phase == .downloading else { return }
        jobs[job.id]?.progressText = "\(progress.downloadedTiles.formatted()) files · \(ByteCountFormatter.string(fromByteCount: Int64(progress.downloadedBytes), countStyle: .file))"
    }

    private func preparationProgress(_ progress: EarthPreparationProgress, job: EarthDownloadJob)
    {
        guard jobs[job.id]?.generation == job.generation, jobs[job.id]?.phase == .preparing else { return }
        jobs[job.id]?.progressText = progress.phase == .inspecting ? "Reading source files: \(progress.processedPlacements.formatted()) / \(progress.totalPlacements.formatted())" : "Preparing models: \(progress.completedModels.formatted()) written"
    }

    private func finish(_ job: EarthDownloadJob, error: (any Error)?) async
    {
        guard jobs[job.id]?.generation == job.generation, let operation = work.removeValue(forKey: job.id) else { return }
        downloading[job.id] = nil
        preparing[job.id] = nil
        if let error
        {
            jobs[job.id]?.phase = error is CancellationError ? .paused : .failed
            jobs[job.id]?.errorMessage = error is CancellationError ? nil : error.localizedDescription
        }
        else { jobs[job.id]?.phase = .complete }
        let title: String
        if let error, !(error is CancellationError)
        { title = operation.archive == nil ? "Download failed" : "Preparation failed · download retained" }
        else { title = jobs[job.id]?.phase.title ?? "" }
        jobs[job.id]?.progressText = title
        startDownloads()
        startPreparation()
        // Reopening durable checkpoints must not inherit the cancelled worker.
        let completion = Task { await operation.onFinished() }
        await completion.value
    }
}
