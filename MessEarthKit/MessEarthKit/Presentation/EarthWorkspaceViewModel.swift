import AppKit
import Foundation
import MessEarthKit
import Metal
import Observation
import UniformTypeIdentifiers

private struct EarthWorkspaceSource: Sendable
{
    let capture: EarthCapture
    let collection: EarthCaptureCollection?
    let sectionID: Int?
    var preparedCollection: EarthPreparedCollection? = nil
    var folderAccess: EarthFileAccess? = nil

    static func firstModel(_ collection: EarthCaptureCollection, limits: EarthImportLimits) async throws -> Self
    {
        guard let first = collection.sections.first else { throw EarthImportError.invalidContent("The capture has no model sections.") }
        return try await Self(capture: EarthCaptureImporter(limits: limits).importSection(first), collection: collection, sectionID: first.id)
    }

    static func firstPreparedModel(_ collection: EarthPreparedCollection) async throws -> Self
    {
        guard let first = try await collection.models(limit: 1).first else { throw EarthPreparationError.invalidCollection }
        return try await Self(capture: collection.importModel(id: first.id), collection: nil, sectionID: first.id, preparedCollection: collection)
    }
}

@MainActor
@Observable
final class EarthWorkspaceViewModel
{
    private(set) var title = "MessEarthKit"
    private(set) var status = "Ready"
    private(set) var summary = ""
    private(set) var attribution = ""
    private var isImporting = false
    var isLoading: Bool { isImporting || downloads.isLoading || preparedModels.isLoading || modelExport.isLoading }
    private(set) var hasPreview = false
    private(set) var previewRevision: UInt64 = 0
    private(set) var errorMessage: String?
    private(set) var address = "613 Race St, Cincinnati, Ohio"
    private(set) var latitude = ""
    private(set) var longitude = ""
    private(set) var captureWidth = "200"
    private(set) var captureDepth = "200"
    private(set) var detailError = "4"
    private(set) var maximumVertices = "2000000"
    private(set) var maximumTexturesMiB = "256"
    private(set) var hasSavedCapture = false
    private(set) var previewCoverageWarning: String?
    private(set) var previewAppearanceNotice: String?
    private(set) var createsOptimizedCopy = false
    private(set) var detail: EarthCaptureDetail = .standard
    private(set) var detailOptions: [EarthCaptureDetail] = [.preview, .standard, .high]
    private(set) var modelSectionItems: [EarthModelSectionDisplayItem] = []
    private(set) var modelSectionsSummary = ""
    private(set) var selectedSectionCount = 0
    let downloads: EarthSourceDownloadViewModel
    let preparedModels = EarthPreparedModelsViewModel()
    let modelExport = EarthModelExportViewModel()

    @ObservationIgnored private(set) var renderer: EarthPreviewRenderer?
    @ObservationIgnored private var importTask: Task<Void, Never>?
    @ObservationIgnored private var capture: EarthCapture?
    @ObservationIgnored private let locationLookup = EarthLocationLookup()
    @ObservationIgnored private let captureStore = EarthCaptureStore()
    @ObservationIgnored private var savedRootURL: URL?
    @ObservationIgnored private var activeJobID = UUID()
    @ObservationIgnored private var resolvedLocationTitle: String?
    @ObservationIgnored private var collection: EarthCaptureCollection?
    @ObservationIgnored private var selectedSectionIDs = Set<Int>()
    @ObservationIgnored private var previewedSectionID: Int?
    @ObservationIgnored private let preparationService: EarthModelPreparationService
    @ObservationIgnored private let appFiles: EarthAppFiles
    @ObservationIgnored private let settings: EarthSettingsViewModel
    @ObservationIgnored private var keepsPreviewResources = false

    var apiKey: String { settings.apiKey }
    @ObservationIgnored private var preparedFolderAccess: EarthFileAccess?

    init(appFiles: EarthAppFiles, settings: EarthSettingsViewModel, projectID: UUID)
    {
        self.appFiles = appFiles
        self.settings = settings
        downloads = EarthSourceDownloadViewModel(observer: settings.usage.requestObserver, appFiles: appFiles, projectID: projectID)
        preparationService = EarthModelPreparationService(appFiles: appFiles, projectID: projectID)
    }

    func openRecordedModels(_ catalog: EarthPreparedCollection)
    {
        guard !isLoading else { return }
        startLoad(title: "Downloaded Region", accessURL: catalog.directoryURL)
        { _ in try await EarthWorkspaceSource.firstPreparedModel(catalog) }
    }

    func setPreviewVisible(_ value: Bool)
    {
        keepsPreviewResources = value
        if !value { releaseHiddenPreview() }
    }

    private func releaseHiddenPreview()
    {
        guard !keepsPreviewResources, !isImporting else { return }
        capture = nil
        renderer = nil
        hasPreview = false
    }

    var canResolveAddress: Bool { !isLoading && !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var canDownload: Bool { !isLoading && !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !latitude.isEmpty && !longitude.isEmpty }
    var canSaveCapture: Bool { !isLoading && hasPreview && (preparedModels.collection != nil ? preparedModels.selectedCount > 0 && (modelExport.mode == .separate || modelExport.canExportCombined) : (collection == nil || selectedSectionCount > 0)) }
    var saveButtonTitle: String { preparedModels.collection != nil && modelExport.mode == .combinedGLB ? "Save GLB…" : "Save Models…" }

    func setAddress(_ value: String)
    {
        guard address != value else { return }
        address = value
        latitude = ""
        longitude = ""
        resolvedLocationTitle = nil
    }

    func setLatitude(_ value: String) { latitude = value; resolvedLocationTitle = nil }
    func setLongitude(_ value: String) { longitude = value; resolvedLocationTitle = nil }
    func setCaptureWidth(_ value: String) { captureWidth = value }
    func setCaptureDepth(_ value: String) { captureDepth = value }
    func setDetailError(_ value: String)
    {
        detailError = value
        detail = EarthCaptureDetail.allCases.first { $0.errorMeters == value } ?? .custom
        detailOptions = detail == .custom ? EarthCaptureDetail.allCases : [.preview, .standard, .high]
    }

    func setDetail(_ value: EarthCaptureDetail)
    {
        detail = value
        if let error = value.errorMeters { detailError = error; detailOptions = [.preview, .standard, .high] }
    }

    func setMaximumVertices(_ value: String) { maximumVertices = value; modelExport.invalidate() }
    func setMaximumTexturesMiB(_ value: String) { maximumTexturesMiB = value; modelExport.invalidate() }
    func setCreatesOptimizedCopy(_ value: Bool)
    {
        guard !isLoading else { return }
        createsOptimizedCopy = value
        modelExport.invalidate()
    }

    func resolveAddress()
    {
        guard canResolveAddress else { return }
        activeJobID = UUID()
        isImporting = true
        errorMessage = nil
        status = "Resolving address…"
        let query = address
        importTask = Task
        { [weak self, locationLookup] in
            do
            {
                let location = try await locationLookup.resolve(address: query)
                try Task.checkCancellation()
                self?.latitude = String(format: "%.8f", location.latitude)
                self?.longitude = String(format: "%.8f", location.longitude)
                self?.resolvedLocationTitle = location.title
                self?.status = location.title
            }
            catch is CancellationError { self?.status = "Lookup cancelled" }
            catch
            {
                self?.errorMessage = error.localizedDescription
                self?.status = "Address lookup failed"
            }
            self?.isImporting = false
            self?.importTask = nil
        }
    }

    func downloadRegion()
    {
        guard !isLoading else { return }
        do
        {
            errorMessage = nil
            downloads.start(request: try makeDownloadRequest(), apiKey: apiKey)
        }
        catch { errorMessage = error.localizedDescription }
    }

    func prepareDownloadedModels()
    {
        guard !isLoading, let archive = downloads.archive, archive.state == .downloaded else { return }
        do
        {
            let profile = try makePreparationProfile(name: "Example preview")
            let service = preparationService
            let job = UUID()
            activeJobID = job
            startLoad(title: "Downloaded Region", accessURL: archive.directoryURL, refreshPreparedModels: true, failureStatus: "Model preparation failed · source download retained")
            { [weak self] _ in
                let catalog = try await service.prepare(archive: archive, profile: profile)
                { [weak self] progress in
                    Task
                    { @MainActor [weak self] in
                        guard let self, activeJobID == job, isImporting else { return }
                        status = progress.phase == .inspecting ? "Inspecting source tiles: \(progress.processedPlacements.formatted()) / \(progress.totalPlacements.formatted())" : "Preparing models: \(progress.completedModels.formatted()) written"
                    }
                }
                return try await EarthWorkspaceSource.firstPreparedModel(catalog)
            }
        }
        catch { errorMessage = error.localizedDescription }
    }

    func refreshPreparedAvailability()
    {
        preparedModels.discover(archive: downloads.archive, service: preparationService)
    }

    func openPreparedModels()
    {
        guard !isLoading, preparedModels.availableSourceRootURL == downloads.archive?.rootSourceURL,
              let catalog = preparedModels.availableCollection else { return }
        startLoad(title: "Downloaded Region", accessURL: catalog.directoryURL)
        { _ in try await EarthWorkspaceSource.firstPreparedModel(catalog) }
    }

    func previewPreparedModel(_ id: Int)
    {
        guard !isLoading, let catalog = preparedModels.collection else { return }
        startLoad(title: title, accessURL: nil, preservesSectionSelection: true)
        { _ in try await EarthWorkspaceSource(capture: catalog.importModel(id: id), collection: nil, sectionID: id, preparedCollection: catalog) }
    }

    func showPreparedModels()
    {
        if let folder = preparedModels.collection?.directoryURL { Task { await appFiles.reveal(folder) } }
    }

    func selectAllPreparedModels() { preparedModels.selectAll(); modelExport.invalidate() }
    func selectNoPreparedModels() { preparedModels.selectNone(); modelExport.invalidate() }
    func setPreparedModelIncluded(_ id: Int, included: Bool) { preparedModels.include(id, value: included); modelExport.invalidate() }

    func setExportMode(_ mode: EarthModelExportMode)
    {
        guard !isLoading else { return }
        modelExport.setMode(mode)
        if mode == .combinedGLB { checkCombinedExport() }
    }

    func checkCombinedExport()
    {
        guard !isLoading, let catalog = preparedModels.collection else { return }
        do { modelExport.check(collection: catalog, selection: preparedModels.selection, destination: try makePreparationProfile(name: "Combined asset")) }
        catch { errorMessage = error.localizedDescription }
    }

    func saveCapture()
    {
        guard canSaveCapture, let capture else { return }
        let prepared = preparedModels.collection
        let modelSelection = preparedModels.selection
        let combinesModels = prepared != nil && modelExport.mode == .combinedGLB
        let selected: EarthCaptureCollection?
        do { selected = prepared == nil ? try collection?.selecting(selectedSectionIDs) : nil }
        catch { errorMessage = error.localizedDescription; return }
        let panel = NSSavePanel()
        panel.title = combinesModels ? "Save Combined GLB" : "Save Models Folder"
        panel.nameFieldStringValue = combinesModels ? "Earth Models.glb" : "Earth Models"
        if combinesModels { panel.allowedContentTypes = [UTType(filenameExtension: "glb") ?? .data] }
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        let job = UUID()
        activeJobID = job
        isImporting = true
        errorMessage = nil
        status = combinesModels ? "Saving combined GLB…" : "Saving capture…"
        importTask = Task
        { [weak self, captureStore, appFiles] in
            do
            {
                let access = try await appFiles.accessForExport(destination)
                defer { withExtendedLifetime(access) {} }
                let root: URL
                if combinesModels
                {
                    guard let self else { throw CancellationError() }
                    root = try await modelExport.saveCombined(to: destination)
                    { [weak self] progress in
                        Task
                        { @MainActor [weak self] in
                            guard let self, activeJobID == job, isImporting else { return }
                            status = "Writing combined GLB: \(progress.completedModels.formatted()) / \(progress.totalModels.formatted()) models"
                        }
                    }
                }
                else if let prepared { root = try await captureStore.save(collection: prepared, selection: modelSelection, directoryURL: destination) }
                else if let selected { root = try await captureStore.save(collection: selected, directoryURL: destination) }
                else { root = try await captureStore.save(capture: capture, directoryURL: destination) }
                self?.savedRootURL = root
                self?.hasSavedCapture = true
                self?.status = prepared?.state == .partial ? "Partial models saved" : (combinesModels ? "Combined GLB saved" : (capture.incompleteReason == nil ? "Capture saved" : "Partial capture saved"))
            }
            catch is CancellationError { self?.status = "Save cancelled" }
            catch
            {
                self?.errorMessage = error.localizedDescription
                self?.status = "Save failed"
            }
            self?.isImporting = false
            self?.importTask = nil
        }
    }

    func showSavedCapture()
    {
        if let savedRootURL { Task { await appFiles.reveal(savedRootURL) } }
    }

    func chooseGLB()
    {
        let panel = NSOpenPanel()
        panel.title = "Open GLB"
        panel.allowedContentTypes = [UTType(filenameExtension: "glb") ?? .data]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { load(fileURL: url, accessURL: url) }
    }

    func chooseTilesetFolder()
    {
        let panel = NSOpenPanel()
        panel.title = "Open Folder Containing tileset.json"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url
        {
            load(fileURL: url.appendingPathComponent("tileset.json"), accessURL: url)
        }
    }

    func cancelImport()
    {
        downloads.pause()
        preparedModels.cancel()
        modelExport.cancel()
        importTask?.cancel()
        activeJobID = UUID()
        if isImporting { status = "Cancelling…" }
    }

    func resetView()
    {
        renderer?.resetCamera()
        previewRevision &+= 1
    }

    private func load(fileURL: URL, accessURL: URL)
    {
        guard !isLoading else { return }
        let limits = try? makeImportLimits()
        activeJobID = UUID()
        startLoad(title: fileURL.deletingPathExtension().lastPathComponent, accessURL: accessURL)
        { [appFiles] access in
            guard let access else { throw EarthAppFilesError.invalidLocation }
            if try await appFiles.isPreparedCollection(directoryURL: accessURL, access: access)
            { return try await EarthWorkspaceSource.firstPreparedModel(EarthPreparedCollection.open(directoryURL: accessURL)) }
            guard let limits else { throw EarthImportError.invalidContent("Set valid Advanced limits for the local import.") }
            let importer = EarthCaptureImporter(limits: limits)
            if fileURL.pathExtension.lowercased() == "json"
            { return try await EarthWorkspaceSource.firstModel(importer.prepareCollection(fileURL: fileURL), limits: limits) }
            return try await EarthWorkspaceSource(capture: importer.importFile(fileURL: fileURL), collection: nil, sectionID: nil)
        }
    }

    func selectAllSections() { selectedSectionIDs = Set(modelSectionItems.map(\.id)); refreshModelSections() }
    func selectNoSections() { selectedSectionIDs = []; refreshModelSections() }
    func setSectionIncluded(_ id: Int, included: Bool)
    {
        if included { selectedSectionIDs.insert(id) } else { selectedSectionIDs.remove(id) }
        refreshModelSections()
    }

    func previewSection(_ id: Int)
    {
        guard !isLoading, let collection, let section = collection.sections.first(where: { $0.id == id }) else { return }
        do
        {
            let importer = EarthCaptureImporter(limits: try makeImportLimits())
            startLoad(title: title, accessURL: nil, preservesSectionSelection: true)
            { _ in try await EarthWorkspaceSource(capture: importer.importSection(section), collection: collection, sectionID: id) }
        }
        catch { errorMessage = error.localizedDescription }
    }

    private func refreshModelSections()
    {
        modelSectionItems = collection?.sections.map { EarthModelSectionDisplayItem(id: $0.id, title: $0.name, isIncluded: selectedSectionIDs.contains($0.id), isPreviewed: $0.id == previewedSectionID) } ?? []
        selectedSectionCount = selectedSectionIDs.count
        modelSectionsSummary = "\(modelSectionItems.count) model sections · \(selectedSectionCount) selected for saving"
    }

    private func makeDownloadRequest() throws -> EarthDownloadRequest
    {
        guard let latitudeValue = Double(latitude), let longitudeValue = Double(longitude),
              let width = Double(captureWidth), let depth = Double(captureDepth), let error = Double(detailError)
        else { throw EarthImportError.invalidContent("Enter valid coordinates, region dimensions, and detail error.") }
        return try EarthDownloadRequest(center: EarthGeographicOrigin(latitude: latitudeValue, longitude: longitudeValue), widthMeters: width, depthMeters: depth, maximumGeometricErrorMeters: error)
    }

    private func makeImportLimits() throws -> EarthImportLimits
    {
        guard let vertexLimit = Int(maximumVertices.trimmingCharacters(in: .whitespacesAndNewlines)),
              vertexLimit > 0, vertexLimit <= Int(UInt32.max) / 3
        else { throw EarthImportError.invalidContent("Maximum Vertices must be a positive whole number no greater than \(Int(UInt32.max) / 3).") }
        let maximumMiB = Int.max / (1024 * 1024)
        guard let textureMiB = Int(maximumTexturesMiB.trimmingCharacters(in: .whitespacesAndNewlines)),
              textureMiB > 0, textureMiB <= maximumMiB
        else { throw EarthImportError.invalidContent("Maximum Textures (MiB) must be a positive whole number no greater than \(maximumMiB).") }
        return EarthImportLimits(maximumVertices: vertexLimit, maximumDecodedTextureBytes: textureMiB * 1024 * 1024)
    }

    private func makePreparationProfile(name: String) throws -> EarthPreparationProfile
    {
        let limits = try makeImportLimits()
        return try EarthPreparationProfile(
            name: name,
            maximumVerticesPerModel: limits.maximumVertices,
            maximumIndicesPerModel: limits.maximumVertices * 3,
            maximumDecodedTextureBytesPerModel: limits.maximumDecodedTextureBytes,
            maximumTextureDimension: limits.maximumTextureDimension,
            maximumSourceBytesPerModel: limits.maximumSourceBytes,
            maximumNodesPerPayload: limits.maximumNodes,
            appearancePolicy: createsOptimizedCopy ? .optimizedCopy : .preserveAppearance
        )
    }

    private func startLoad(
        title: String,
        accessURL: URL?,
        refreshPreparedModels: Bool = false,
        preservesSectionSelection: Bool = false,
        failureStatus: String = "Import failed",
        operation: @escaping @Sendable (EarthFileAccess?) async throws -> EarthWorkspaceSource
    )
    {
        guard !isLoading else { return }
        isImporting = true
        errorMessage = nil
        status = "Preparing \(title)…"
        let existingRenderer = renderer
        let appFiles = appFiles
        let existingFolderAccess = preparedFolderAccess
        let worker = Task.detached(priority: .userInitiated)
        {
            let access: EarthFileAccess?
            if let accessURL { access = try await appFiles.accessForReading(accessURL) }
            else { access = existingFolderAccess }
            defer { withExtendedLifetime(access) {} }
            var source = try await operation(access)
            if source.preparedCollection != nil { source.folderAccess = access ?? existingFolderAccess }

            let capture = source.capture
            try Task.checkCancellation()
            let renderer: EarthPreviewRenderer
            if let existingRenderer
            {
                renderer = existingRenderer
            }
            else
            {
                guard let device = MTLCreateSystemDefaultDevice()
                else { throw EarthImportError.unsupportedContent("A Metal device is unavailable.") }
                renderer = try EarthPreviewRenderer(device: device)
            }
            let prepared = try renderer.prepare(capture: capture)
            try Task.checkCancellation()
            return (source, renderer, prepared)
        }
        importTask = Task
        { [weak self] in
            do
            {
                let result = try await withTaskCancellationHandler
                {
                    try await worker.value
                } onCancel: {
                    worker.cancel()
                }
                try Task.checkCancellation()
                guard let self else { return }
                try await preparedModels.attach(result.0.preparedCollection, previewedID: result.0.sectionID, preservingSelection: preservesSectionSelection)
                try Task.checkCancellation()
                if !preservesSectionSelection { modelExport.invalidate() }
                capture = result.0.capture
                preparedFolderAccess = result.0.folderAccess
                collection = result.0.collection
                previewedSectionID = result.0.sectionID
                if !preservesSectionSelection { selectedSectionIDs = Set(collection?.sections.map(\.id) ?? []) }
                refreshModelSections()
                renderer = result.1
                result.1.publish(scene: result.2)
                self.title = title
                let dimensions = result.0.capture.bounds.dimensions
                summary = result.0.preparedCollection.map { "\($0.modelCount.formatted()) prepared models · previewing one model" } ?? collection.map { "\($0.sections.count) model sections · previewing one model" } ?? String(format: "%.1f × %.1f × %.1f m", dimensions.x, dimensions.y, dimensions.z)
                attribution = result.0.capture.attributions.joined(separator: "; ")
                previewCoverageWarning = result.0.capture.incompleteReason.map
                { "Preview coverage: \($0) Full region coverage is unverified. Downloaded files are retained." }
                previewAppearanceNotice = result.0.capture.preparationProfile?.appearancePolicy == .optimizedCopy
                    ? "Optimized copy · Cropped textures may look different at a distance, and lighting on split surfaces may differ."
                    : nil
                hasPreview = true
                hasSavedCapture = false
                savedRootURL = nil
                previewRevision &+= 1
                status = result.0.preparedCollection?.state == .partial ? "Models partially prepared" : (result.0.capture.incompleteReason == nil ? "Ready" : "Preview · coverage unverified")
            }
            catch is CancellationError
            {
                self?.status = refreshPreparedModels ? "Model preparation cancelled · source download retained" : "Import cancelled"
            }
            catch
            {
                self?.errorMessage = error.localizedDescription
                self?.status = failureStatus
            }
            self?.isImporting = false
            self?.activeJobID = UUID()
            self?.importTask = nil
            // Preparation can commit models before failing or being cancelled.
            // Refresh after the worker settles so those files can be reopened.
            if refreshPreparedModels { self?.refreshPreparedAvailability() }
            self?.releaseHiddenPreview()
        }
    }
}
