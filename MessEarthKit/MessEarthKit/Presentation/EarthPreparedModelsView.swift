import MessEarthKit
import Observation
import SwiftUI

@MainActor
@Observable
final class EarthPreparedModelsViewModel
{
    private(set) var collection: EarthPreparedCollection?
    private(set) var items: [EarthModelSectionDisplayItem] = []
    private(set) var selection: EarthModelSelection = .only([])
    private(set) var selectedCount = 0
    private(set) var summary = ""
    private(set) var pageSummary = ""
    private(set) var isLoading = false
    private(set) var hasPrevious = false
    private(set) var hasNext = false
    private(set) var errorMessage: String?
    private(set) var availableCollection: EarthPreparedCollection?
    private(set) var availabilitySummary = ""
    private(set) var availabilityError: String?
    @ObservationIgnored private(set) var availableSourceRootURL: URL?
    @ObservationIgnored private var discoveryTask: Task<Void, Never>?
    @ObservationIgnored private var discoveryGeneration = UUID()
    @ObservationIgnored private var models: [EarthPreparedModel] = []
    @ObservationIgnored private var offset = 0
    @ObservationIgnored private var previewedID: Int?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    private let pageSize = 50

    func attach(_ value: EarthPreparedCollection?, previewedID: Int?, preservingSelection: Bool) async throws
    {
        if preservingSelection, value?.directoryURL == collection?.directoryURL
        {
            self.previewedID = previewedID
            refresh()
            return
        }
        task?.cancel()
        let job = UUID()
        generation = job
        guard let value
        else
        {
            collection = nil
            models = []
            selection = .only([])
            offset = 0
            self.previewedID = nil
            errorMessage = nil
            isLoading = false
            refresh()
            return
        }
        isLoading = true
        defer { if generation == job { isLoading = false } }
        let page = try await value.models(limit: pageSize)
        try Task.checkCancellation()
        guard generation == job else { return }
        collection = value
        selection = .all()
        offset = 0
        self.previewedID = previewedID
        errorMessage = nil
        models = page
        refresh()
    }

    func selectAll() { selection = .all(); refresh() }
    func selectNone() { selection = .only([]); refresh() }
    func include(_ id: Int, value: Bool)
    {
        guard models.contains(where: { $0.id == id }) else { return }
        switch selection
        {
            case var .all(excluding):
                if value { excluding.remove(id) } else { excluding.insert(id) }
                selection = .all(excluding: excluding)
            case var .only(ids):
                if value { ids.insert(id) } else { ids.remove(id) }
                selection = .only(ids)
        }
        refresh()
    }

    func previousPage() { loadPage(offset - pageSize) }
    func nextPage() { loadPage(offset + pageSize) }
    func cancel() { task?.cancel(); discoveryTask?.cancel() }

    func discover(archive: EarthSourceArchive?, service: EarthModelPreparationService)
    {
        discoveryTask?.cancel()
        let job = UUID()
        discoveryGeneration = job
        availableCollection = nil
        availableSourceRootURL = archive?.rootSourceURL
        availabilitySummary = ""
        availabilityError = nil
        guard let archive, archive.state == .downloaded else { return }
        availabilitySummary = "Looking for prepared models…"
        discoveryTask = Task
        { [weak self, service] in
            defer { if self?.discoveryGeneration == job { self?.discoveryTask = nil } }
            do
            {
                let catalog = try await service.latest(for: archive)
                try Task.checkCancellation()
                guard let self, discoveryGeneration == job else { return }
                availableCollection = catalog
                if let catalog
                {
                    let state = catalog.state == .ready ? "ready" : "partially prepared"
                    let noun = catalog.modelCount == 1 ? "model" : "models"
                    let appearance = catalog.profile.appearancePolicy == .optimizedCopy ? " · optimized copy" : ""
                    availabilitySummary = "\(catalog.modelCount.formatted()) \(noun) \(state) · \(catalog.profile.name)\(appearance)"
                }
                else { availabilitySummary = "" }
            }
            catch
            {
                guard let self, discoveryGeneration == job else { return }
                availabilitySummary = ""
                if !(error is CancellationError) { availabilityError = error.localizedDescription }
            }
        }
    }

    private func loadPage(_ target: Int)
    {
        guard !isLoading, let collection, target >= 0, target < collection.modelCount else { return }
        let job = UUID()
        generation = job
        isLoading = true
        errorMessage = nil
        task = Task
        { [weak self] in
            do
            {
                let page = try await collection.models(offset: target, limit: self?.pageSize ?? 50)
                try Task.checkCancellation()
                guard let self, generation == job else { return }
                models = page
                offset = target
                refresh()
            }
            catch
            {
                guard let self, generation == job else { return }
                if !(error is CancellationError) { errorMessage = error.localizedDescription }
            }
            guard let self, generation == job else { return }
            isLoading = false
            task = nil
        }
    }

    private func refresh()
    {
        let count = collection?.modelCount ?? 0
        selectedCount = (try? selection.count(modelCount: count)) ?? 0
        items = models.map { .init(id: $0.id, title: $0.name, isIncluded: selection.includes($0.id), isPreviewed: previewedID == $0.id) }
        let appearance = collection?.profile.appearancePolicy == .optimizedCopy ? " · optimized copy" : ""
        summary = "\(count.formatted()) models · \(selectedCount.formatted()) selected · \(collection?.profile.name ?? "")\(appearance)"
        pageSummary = count == 0 ? "" : "\(offset + 1)–\(min(offset + pageSize, count)) of \(count.formatted())"
        hasPrevious = offset > 0
        hasNext = offset + pageSize < count
    }
}

struct EarthPreparedModelsView: View
{
    let viewModel: EarthWorkspaceViewModel

    var body: some View
    {
        let models = viewModel.preparedModels
        VStack(alignment: .leading, spacing: 8)
        {
            Text(models.summary).font(.callout)
            HStack
            {
                Button("Select All", action: viewModel.selectAllPreparedModels)
                Button("Select None", action: viewModel.selectNoPreparedModels)
                Button("Show Models", action: viewModel.showPreparedModels)
            }
            if let reason = models.collection?.interruptionReason { EarthErrorMessage("Models incomplete: \(reason)", color: .orange).font(.callout) }
            if let error = models.errorMessage { EarthErrorMessage(error, color: .orange).font(.callout) }
            HStack
            {
                Button("Previous", action: models.previousPage).disabled(!models.hasPrevious)
                Text(models.pageSummary).font(.caption).foregroundStyle(.secondary)
                Button("Next", action: models.nextPage).disabled(!models.hasNext)
                Spacer()
            }
            LazyVStack(spacing: 10)
            {
                ForEach(models.items)
                {
                    item in
                    HStack(spacing: 12)
                    {
                        Toggle(item.title, isOn: Binding(get: { item.isIncluded }, set: { viewModel.setPreparedModelIncluded(item.id, included: $0) }))
                        Spacer()
                        Button(item.isPreviewed ? "Viewing" : "Preview") { viewModel.previewPreparedModel(item.id) }.disabled(item.isPreviewed)
                    }
                }
            }
        }
        .disabled(viewModel.isLoading)
        .padding(16)
    }
}
