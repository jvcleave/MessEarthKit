import AppKit
import Foundation
import MessEarthKit
import Observation
import SwiftUI

enum EarthDeletionTarget: Sendable
{
    case project(id: UUID, title: String)
    case location(projectID: UUID, locationID: UUID, title: String)
    case variant(projectID: UUID, captureID: UUID, title: String)

    var confirmationTitle: String
    {
        switch self
        {
            case .project: "Delete Project?"
            case .location: "Delete Location?"
            case .variant: "Delete Variant?"
        }
    }

    var message: String
    {
        switch self
        {
            case let .project(_, title): "“\(title)” and all of its locations, variants, downloaded tiles, prepared models and exports will be moved to Trash."
            case let .location(_, _, title): "“\(title)” and all of its variants, downloaded tiles and prepared models will be moved to Trash. Other locations will be kept."
            case let .variant(_, _, title): "The downloaded tiles and prepared models for “\(title)” will be moved to Trash. Other variants and the current capture settings will be kept."
        }
    }
}

@MainActor
@Observable
final class EarthProjectLibraryViewModel
{
    let navigation = EarthProjectNavigation()
    let exportViewer: EarthExportViewerViewModel
    let exportQueue: EarthExportQueue
    var path: [EarthAppRoute] { get { navigation.path } set { navigation.path = newValue } }
    let settings: EarthSettingsViewModel
    private(set) var projects: [EarthProjectViewModel] = []
    private(set) var failures: [EarthProjectLoadFailure] = []
    private(set) var isLoading = false
    private(set) var isCreating = false
    private(set) var errorMessage: String?
    private(set) var deletionTarget: EarthDeletionTarget?
    private(set) var isDeleting = false
    private(set) var isMovingStorage = false
    private(set) var isChoosingCollectionFolder = false
    private let downloadQueue = EarthDownloadQueue()
    private let preparationGate = EarthPreparationGate()
    @ObservationIgnored private let files: EarthAppFiles
    @ObservationIgnored private let store: EarthProjectStore
    @ObservationIgnored private var owners: [UUID: EarthProjectViewModel] = [:]
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var createTask: Task<Void, Never>?
    @ObservationIgnored private var deletionTask: Task<Void, Never>?

    init(files: EarthAppFiles, usageStore: EarthRequestUsageStore)
    {
        self.files = files
        exportViewer = EarthExportViewerViewModel(service: EarthExportViewerService(files: files))
        exportQueue = EarthExportQueue(files: files)
        store = EarthProjectStore(files: files)
        settings = EarthSettingsViewModel(files: files, usageStore: usageStore)
        reload()
    }

    func project(id: UUID) -> EarthProjectViewModel? { owners[id] }

    var canStartWork: Bool { !isDeleting && !isMovingStorage && !exportQueue.isRunning && !exportQueue.isCollecting && !isChoosingCollectionFolder }

    var canRunExportQueue: Bool
    {
        canStartWork && !isLoading && !isCreating
            && owners.values.allSatisfy { !$0.isBusy && !$0.export.isLoadingHistory }
    }

    var canMoveStorage: Bool
    {
        canRequestDeletion && settings.canMoveStorage && !exportViewer.isLoading && !exportQueue.isBusy
            && !downloadQueue.hasActiveWork
            && owners.values.allSatisfy(\.canMoveStorage)
    }

    func beginStorageMove() throws
    {
        guard canMoveStorage else { throw EarthStorageMoveError.busy }
        isMovingStorage = true
        exportViewer.close()
        for owner in owners.values { owner.preview.setVisible(false) }
    }

    func endStorageMove() { isMovingStorage = false }

    var canRequestDeletion: Bool { canStartWork && !isCreating && !isLoading }

    func canDeleteProject(_ id: UUID) -> Bool
    { canRequestDeletion && !(exportViewer.isLoading && exportViewer.request?.projectID == id) && owners[id]?.isBusy != true && owners[id]?.hasActiveDownloads != true && owners[id]?.isSaving != true }

    func canDeleteLocation(_ projectID: UUID, locationID: UUID) -> Bool
    { canRequestDeletion && owners[projectID]?.canDeleteLocation(locationID) == true }

    func canDeleteCapture(_ projectID: UUID, captureID: UUID) -> Bool
    { canRequestDeletion && owners[projectID]?.canDeleteCapture(captureID) == true }

    func canEditMap(_ id: UUID) -> Bool
    {
        guard canStartWork, let owner = owners[id], owner.phase == .idle, !owner.preview.isLoading, !owner.export.isBusy else { return false }
        return owner.canEditCurrentLocation
    }

    func canViewPreview(_ id: UUID, captureID: UUID) -> Bool
    {
        guard canStartWork, let owner = owners[id], owner.downloadJob(captureID)?.phase.isActive != true else { return false }
        return !owner.isBusy || (owner.selectedCaptureID == captureID && (owner.phase == .preparing || owner.preview.isLoading))
    }

    func navigationChanged()
    {
        for (id, owner) in owners { owner.preview.setVisible(path.last == .preview(id)) }
    }

    func reload()
    {
        guard canStartWork, loadTask == nil, !isCreating else { return }
        isLoading = true
        loadTask = Task
        { [weak self, store] in
            guard let self else { return }
            defer { loadTask = nil; isLoading = false }
            do
            {
                let library = try await store.library()
                var values: [EarthProjectViewModel] = []
                for opened in library.projects
                {
                    let owner = owners[opened.record.id] ?? EarthProjectViewModel(opened: opened, store: store, appFiles: files, settings: settings, downloadQueue: downloadQueue, preparationGate: preparationGate)
                    owners[owner.id] = owner
                    values.append(owner)
                }
                projects = values
                failures = library.failures
                errorMessage = nil
            }
            catch { errorMessage = error.localizedDescription }
        }
    }

    func newProject()
    {
        guard canStartWork, !isCreating, !isLoading else { return }
        isCreating = true
        createTask = Task
        { [weak self, store] in
            guard let self else { return }
            defer { createTask = nil; isCreating = false }
            do
            {
                let record = try await store.create()
                let owner = EarthProjectViewModel(opened: .init(record: record, archive: nil, prepared: nil), store: store, appFiles: files, settings: settings, downloadQueue: downloadQueue, preparationGate: preparationGate)
                owners[owner.id] = owner
                projects.insert(owner, at: 0)
                errorMessage = nil
                path.append(.project(owner.id))
            }
            catch { errorMessage = error.localizedDescription }
        }
    }

    func openProject(_ id: UUID)
    {
        guard !isDeleting, owners[id] != nil else { return }
        path.append(.project(id))
    }

    func showSettings() { path.append(.settings) }

    func showExportQueue() { path.append(.exportQueue) }

    func isExportQueued(_ projectID: UUID, variantID: UUID) -> Bool
    {
        guard let owner = owners[projectID], let variant = owner.captures.first(where: { $0.id == variantID }),
              let location = owner.locations.first(where: { $0.id == variant.locationID }),
              let profile = try? variant.preparation?.profile ?? EarthPreparationProfile(name: "Project preview")
        else { return false }
        let request = EarthQueuedExportRequest(
            projectID: projectID,
            projectTitle: owner.displayTitle,
            locationID: location.id,
            locationName: location.name,
            locationTitle: location.title,
            variantID: variantID,
            detail: variant.detail,
            source: variant.capture,
            preparationProfile: profile,
            options: owner.export.options(for: variantID),
            format: owner.export.format(for: variantID),
            optimization: owner.export.optimization(for: variantID)
        )
        return exportQueue.containsPending(request)
    }

    func addExportToQueue(_ projectID: UUID, variantID: UUID)
    {
        guard canStartWork else { return }
        owners[projectID]?.addExportToQueue(variantID, queue: exportQueue)
    }

    func startExportQueue()
    {
        guard canRunExportQueue else { return }
        exportQueue.start
        { [weak self] entry, progress in
            guard let self, !isDeleting, !isMovingStorage,
                  let owner = owners[entry.request.projectID] else { throw EarthAppFilesError.missingFile }
            return try await owner.exportQueued(entry, cancel: { [weak self] in self?.exportQueue.cancel() }, progress: progress)
        }
    }

    func chooseExportCollectionFolder()
    {
        guard canRunExportQueue, exportQueue.canCollect else { return }
        isChoosingCollectionFolder = true
        Task
        { [self] in
            defer { isChoosingCollectionFolder = false }
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.allowsMultipleSelection = false
            panel.canCreateDirectories = true
            panel.prompt = "Collect"
            guard await panel.begin() == .OK, let destination = panel.url else { return }
            exportQueue.collect(to: destination)
        }
    }

    func requestProjectDeletion(_ id: UUID)
    {
        guard canDeleteProject(id),
              owners[id] != nil || failures.contains(where: { $0.id == id }) else { return }
        deletionTarget = .project(id: id, title: owners[id]?.displayTitle ?? "Project \(id.uuidString.prefix(8))")
    }

    func requestCaptureDeletion(_ projectID: UUID, captureID: UUID)
    {
        guard canDeleteCapture(projectID, captureID: captureID), let owner = owners[projectID],
              let variant = owner.captures.first(where: { $0.id == captureID }) else { return }
        deletionTarget = .variant(projectID: projectID, captureID: captureID, title: variant.title)
    }

    func requestLocationDeletion(_ projectID: UUID, locationID: UUID)
    {
        guard canDeleteLocation(projectID, locationID: locationID), let owner = owners[projectID],
              let location = owner.locations.first(where: { $0.id == locationID }) else { return }
        deletionTarget = .location(projectID: projectID, locationID: locationID, title: location.displayTitle)
    }

    func cancelDeletion() { deletionTarget = nil }

    func confirmDeletion(_ target: EarthDeletionTarget)
    {
        deletionTarget = nil
        guard canRequestDeletion else { return }
        isDeleting = true
        deletionTask = Task
        { [weak self, store] in
            guard let self else { return }
            defer { isDeleting = false; deletionTask = nil }
            do
            {
                switch target
                {
                    case let .project(id, _):
                        if let owner = owners[id] { try await owner.deleteProject() }
                        else { try await store.deleteProject(id: id) }
                        owners[id] = nil
                        projects.removeAll { $0.id == id }
                        failures.removeAll { $0.id == id }
                        path.removeAll
                        { route in
                            switch route
                            {
                                case let .project(projectID), let .preview(projectID): projectID == id
                                case .settings, .exportQueue: false
                            }
                        }
                        errorMessage = nil
                    case let .variant(projectID, captureID, _):
                        guard let owner = owners[projectID] else { throw EarthAppFilesError.missingFile }
                        try await owner.deleteCapture(captureID)
                    case let .location(projectID, locationID, _):
                        guard let owner = owners[projectID] else { throw EarthAppFilesError.missingFile }
                        try await owner.deleteLocation(locationID)
                }
            }
            catch
            {
                if case .project = target { errorMessage = "Could not delete the project. " + error.localizedDescription }
            }
        }
    }

    func updateMap(_ id: UUID)
    {
        guard canStartWork, let owner = owners[id] else { return }
        owner.updateMap()
    }

    func download(_ id: UUID, captureID: UUID)
    {
        guard canStartWork, let owner = owners[id], owner.areaAdjustment == nil else { return }
        owner.enqueueDownload(captureID)
    }

    func showPreview(_ id: UUID, captureID: UUID)
    {
        guard canViewPreview(id, captureID: captureID), let owner = owners[id] else { return }
        if owner.selectedCaptureID == captureID, owner.downloads.archive?.state == .downloaded
        {
            path.append(.preview(id))
            // An active preparation owns the next result. Re-enter its screen
            // without starting another load from the retained catalog.
            if owner.phase == .idle { prepareOrRenderIfVisible(id) }
            return
        }
        let ticket = navigation.ticket(route: .project(id))
        owner.selectCapture(captureID)
        { [weak self, weak owner] in
            guard let self, owner?.downloads.archive?.state == .downloaded,
                  navigation.advance(ticket, to: .preview(id)) else { return }
            prepareOrRenderIfVisible(id)
        }
    }

    func refreshProject(_ id: UUID)
    {
        guard canStartWork, let owner = owners[id] else { return }
        owner.refresh { [weak self] in self?.prepareOrRenderIfVisible(id) }
    }

    private func prepareOrRenderIfVisible(_ id: UUID)
    {
        guard path.last == .preview(id), let owner = owners[id], owner.downloads.archive?.state == .downloaded else { return }
        if let prepared = owner.prepared, prepared.state == .ready, prepared.coversEntireSource
        { renderIfVisible(id) }
        else if !owner.isBusy { owner.preparePreview { [weak self] in self?.renderIfVisible(id) } }
    }

    private func renderIfVisible(_ id: UUID)
    {
        guard path.last == .preview(id), let owner = owners[id], let prepared = owner.prepared else { return }
        owner.preview.setVisible(true)
        owner.preview.show(prepared)
    }
}

struct EarthProjectLibraryView: View
{
    @Bindable var viewModel: EarthProjectLibraryViewModel

    var body: some View
    {
        NavigationStack(path: $viewModel.path)
        {
            projectsList
                .navigationTitle("Projects")
                .toolbar
                {
                    ToolbarItem(placement: .primaryAction) { Button("New", systemImage: "plus", action: viewModel.newProject).disabled(!viewModel.canStartWork || viewModel.isCreating || viewModel.isLoading) }
                    ToolbarItem { Button("Settings", systemImage: "gearshape", action: viewModel.showSettings) }
                }
                .navigationDestination(for: EarthAppRoute.self)
                { route in
                    switch route
                    {
                        case let .project(id):
                            if let project = viewModel.project(id: id)
                            { EarthProjectDetailView(project: project, library: viewModel) }
                        case let .preview(id):
                            if let project = viewModel.project(id: id)
                            {
                                EarthProjectPreviewView(project: project, library: viewModel)
                                    .navigationTitle(project.displayTitle)
                                    .navigationSubtitle(project.selectedCapture?.title ?? "")
                            }
                        case .settings: EarthSettingsView(viewModel: viewModel.settings)
                        case .exportQueue: EarthExportQueueView(queue: viewModel.exportQueue, library: viewModel)
                    }
                }
        }
        .onChange(of: viewModel.path) { viewModel.navigationChanged() }
        .alert(
            viewModel.deletionTarget?.confirmationTitle ?? "Delete?",
            isPresented: Binding(get: { viewModel.deletionTarget != nil }, set: { if !$0 { viewModel.cancelDeletion() } }),
            presenting: viewModel.deletionTarget
        )
        { target in
            Button("Move to Trash", role: .destructive) { viewModel.confirmDeletion(target) }
            Button("Cancel", role: .cancel, action: viewModel.cancelDeletion)
        } message: { target in Text(target.message) }
        .frame(minWidth: 720, minHeight: 600)
    }

    private var projectsList: some View
    {
        VStack(spacing: 0)
        {
            if viewModel.isLoading { ProgressView().padding() }
            if let error = viewModel.errorMessage
            {
                EarthErrorMessage(error).padding()
                Button("Retry", action: viewModel.reload)
            }
            if !viewModel.failures.isEmpty
            {
                VStack(alignment: .leading)
                {
                    ForEach(viewModel.failures)
                    { failure in
                        HStack
                        {
                            EarthErrorMessage("Project \(failure.id.uuidString.prefix(8)): \(failure.message)")
                            Spacer()
                            Button(role: .destructive) { viewModel.requestProjectDeletion(failure.id) } label: { Image(systemName: "trash") }
                                .buttonStyle(.borderless).help("Delete Project").accessibilityLabel("Delete Project")
                                .disabled(!viewModel.canRequestDeletion)
                        }
                    }
                    Button("Reload Projects", action: viewModel.reload)
                }.padding()
            }
            if viewModel.projects.isEmpty, !viewModel.isLoading, viewModel.errorMessage == nil, viewModel.failures.isEmpty
            {
                ContentUnavailableView
                {
                    Label("No Projects", systemImage: "folder")
                } actions: {
                    Button("New Project", action: viewModel.newProject).buttonStyle(.borderedProminent).disabled(!viewModel.canStartWork || viewModel.isCreating)
                }
            }
            else
            {
                List(viewModel.projects)
                { project in
                    HStack
                    {
                        Button { viewModel.openProject(project.id) } label: {
                            HStack
                            {
                                VStack(alignment: .leading, spacing: 4)
                                {
                                    Text(project.displayTitle).font(.headline)
                                    if !project.searchAddress.isEmpty { Text(project.searchAddress).font(.caption).foregroundStyle(.secondary) }
                                }
                                Spacer()
                                Text(project.status).foregroundStyle(.secondary)
                                Image(systemName: "chevron.right").foregroundStyle(.secondary)
                            }.padding(.vertical, 8).contentShape(Rectangle())
                        }.buttonStyle(.plain).disabled(viewModel.isDeleting)
                        Button(role: .destructive) { viewModel.requestProjectDeletion(project.id) } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless).help("Delete Project").accessibilityLabel("Delete \(project.displayTitle)")
                            .disabled(!viewModel.canDeleteProject(project.id))
                    }
                }
            }
            Divider()
            Button(viewModel.exportQueue.buttonTitle, action: viewModel.showExportQueue)
                .buttonStyle(.bordered)
                .padding()
        }
    }
}
