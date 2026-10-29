import AppKit
import MessEarthKit
import Observation
import SwiftUI

@MainActor
@Observable
final class EarthSourceDownloadViewModel
{
    private(set) var archive: EarthSourceArchive?
    private(set) var isLoading = false
    private(set) var status = ""
    private(set) var summary = ""
    private(set) var selectionSummary = ""
    private(set) var errorMessage: String?
    @ObservationIgnored private let service: EarthSourceDownloadService
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()

    init(observer: EarthRequestObserver?, appFiles: EarthAppFiles, projectID: UUID)
    {
        service = EarthSourceDownloadService(appFiles: appFiles, projectID: projectID, observer: observer)
    }

    func start(request: EarthDownloadRequest, apiKey: String) { run(request: request, apiKey: apiKey, existing: nil) }

    func restore(_ archive: EarthSourceArchive?)
    {
        guard !isLoading else { return }
        apply(archive)
    }

    func resume(apiKey: String)
    {
        guard let archive, archive.state != .downloaded else { return }
        run(request: archive.request, apiKey: apiKey, existing: archive.directoryURL)
    }

    func pause() { task?.cancel(); if isLoading { status = "Pausing download…" } }
    func showFiles() { if let archive { Task { await service.showFiles(archive.directoryURL) } } }

    private func run(request: EarthDownloadRequest, apiKey: String, existing: URL?)
    {
        guard !isLoading else { return }
        task?.cancel()
        let job = UUID()
        generation = job
        isLoading = true
        if existing == nil { archive = nil }
        selectionSummary = describe(request)
        errorMessage = nil
        status = "Downloading sources…"
        summary = "Completed source files are kept if the download is interrupted."
        task = Task
        { [weak self, service] in
            var directory = existing
            do
            {
                if directory == nil { directory = try await service.newDirectory() }
                guard let directory else { throw EarthAcquisitionError.storage }
                let archive = try await service.download(request: request, apiKey: apiKey, directoryURL: directory, resuming: existing != nil)
                { [weak self] progress in
                    Task
                    { @MainActor [weak self] in
                        guard let self, generation == job, isLoading else { return }
                        summary = "\(progress.downloadedTiles.formatted()) GLB files · \(ByteCountFormatter.string(fromByteCount: Int64(progress.downloadedBytes), countStyle: .file)) · \(progress.sourceRequests.formatted()) requests"
                    }
                }
                guard let self, generation == job else { return }
                apply(archive)
            }
            catch
            {
                let snapshot: EarthSourceArchive?
                if let directory { snapshot = try? await EarthSourceArchive.open(directoryURL: directory) } else { snapshot = nil }
                guard let self, generation == job else { return }
                apply(snapshot)
                status = error is CancellationError ? "Download paused" : "Download interrupted"
                if !(error is CancellationError) { errorMessage = error.localizedDescription }
            }
            guard let self, generation == job else { return }
            isLoading = false
            task = nil
        }
    }

    private func apply(_ value: EarthSourceArchive?)
    {
        archive = value
        guard let value else { return }
        selectionSummary = describe(value.request)
        status = value.state == .downloaded ? "Downloaded" : "Download paused"
        errorMessage = value.interruptionReason
        summary = "\(value.completedPayloadCount.formatted()) GLB files · \(ByteCountFormatter.string(fromByteCount: Int64(value.downloadedBytes), countStyle: .file)) · \(value.selectedTileCount.formatted()) tile placements"
    }

    private func describe(_ request: EarthDownloadRequest) -> String
    {
        "\(request.widthMeters.formatted()) × \(request.depthMeters.formatted()) m · \(request.center.latitude.formatted()), \(request.center.longitude.formatted()) · \(request.maximumGeometricErrorMeters.formatted()) m detail error"
    }
}

struct EarthSourceDownloadView: View
{
    let viewModel: EarthWorkspaceViewModel

    var body: some View
    {
        let download = viewModel.downloads
        VStack(alignment: .leading, spacing: 8)
        {
            Text(download.status).font(.headline)
            Text(download.selectionSummary).foregroundStyle(.secondary)
            Text(download.summary).foregroundStyle(.secondary)
            if let error = download.errorMessage { Text(error).foregroundStyle(.orange).textSelection(.enabled) }
            if !download.isLoading, download.archive?.state == .downloaded
            {
                Text("Preparation runs offline. Original downloads are retained.").foregroundStyle(.secondary)
                Toggle("Create optimized copy", isOn: Binding(get: { viewModel.createsOptimizedCopy }, set: viewModel.setCreatesOptimizedCopy))
                    .disabled(viewModel.isLoading)
                if viewModel.createsOptimizedCopy
                {
                    Text("Allows changes to distant textures and smooth lighting where large textures need splitting. Full-resolution image detail and original downloads stay intact.")
                        .foregroundStyle(.orange)
                }
                else { Text("Preserve appearance. If a texture cannot be split faithfully, preparation stops and keeps the source.").foregroundStyle(.secondary) }
            }
            else if !download.isLoading, download.archive != nil
            { Text("Resume refreshes service access; completed files are reused.").foregroundStyle(.secondary) }
            if !viewModel.preparedModels.availabilitySummary.isEmpty
            { Text(viewModel.preparedModels.availabilitySummary).foregroundStyle(.secondary) }
            if let error = viewModel.preparedModels.availabilityError
            { Text(error).foregroundStyle(.orange).textSelection(.enabled) }
            HStack(spacing: 12)
            {
                if download.isLoading { Button("Pause Download", action: download.pause) }
                else if download.archive?.state == .downloaded
                {
                    if viewModel.preparedModels.availableCollection != nil
                    {
                        Button("Open Prepared Models", action: viewModel.openPreparedModels).disabled(viewModel.isLoading)
                        Button("Prepare Again", action: viewModel.prepareDownloadedModels).disabled(viewModel.isLoading)
                    }
                    else { Button("Prepare Models", action: viewModel.prepareDownloadedModels).disabled(viewModel.isLoading) }
                }
                else if download.archive != nil
                {
                    Button("Resume Download") { download.resume(apiKey: viewModel.apiKey) }
                        .disabled(viewModel.isLoading || viewModel.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            Button("Reveal in Finder", action: download.showFiles).disabled(download.archive == nil)
        }
        .font(.callout)
        .padding(12)
    }
}
