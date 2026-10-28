import AppKit
import Foundation
import MessEarthKit
import Metal
import Observation
import UniformTypeIdentifiers

@MainActor
@Observable
final class EarthWorkspaceViewModel
{
    private(set) var title = "MessEarthKit"
    private(set) var status = "Ready"
    private(set) var summary = ""
    private(set) var attribution = ""
    private(set) var isLoading = false
    private(set) var hasPreview = false
    private(set) var previewRevision: UInt64 = 0
    private(set) var errorMessage: String?
    private(set) var address = "613 Race St, Cincinnati, Ohio"
    private(set) var latitude = ""
    private(set) var longitude = ""
    private(set) var captureWidth = "200"
    private(set) var captureDepth = "200"
    private(set) var detailError = "4"
    private(set) var maximumRequests = "512"
    private(set) var maximumTiles = "256"
    private(set) var maximumVertices = "2000000"
    private(set) var maximumTexturesMiB = "256"
    private(set) var apiKey = ""
    private(set) var hasSavedCapture = false
    private(set) var hasRecoverableDownload = false
    private(set) var incompleteCaptureMessage: String?
    private(set) var precheckDisplay: EarthCapturePrecheckDisplay?
    private(set) var offlineEstimateDisplay: EarthOfflineEstimateDisplay?

    @ObservationIgnored private(set) var renderer: EarthPreviewRenderer?
    @ObservationIgnored private var importTask: Task<Void, Never>?
    @ObservationIgnored private var capture: EarthCapture?
    @ObservationIgnored private let locationLookup = EarthLocationLookup()
    @ObservationIgnored private let captureStore = EarthCaptureStore()
    @ObservationIgnored private var savedRootURL: URL?
    @ObservationIgnored private var activeJobID = UUID()
    @ObservationIgnored private var resolvedLocationTitle: String?
    @ObservationIgnored private let apiKeyStore = EarthAPIKeyStore()
    @ObservationIgnored private var credentialTask: Task<Void, Never>?
    @ObservationIgnored private var didEditAPIKey = false
    @ObservationIgnored private let recoveryService = EarthCaptureRecoveryService()
    @ObservationIgnored private var recoveryRootURL: URL?
    @ObservationIgnored private var recoveryTask: Task<Void, Never>?
    @ObservationIgnored private var precheckResult: EarthCapturePrecheck?
    @ObservationIgnored private var estimateHistory = EarthCaptureObservationHistory(observations: [], note: nil)

    init()
    {
        refreshOfflineEstimate()
        credentialTask = Task
        { [weak self, apiKeyStore] in
            defer { self?.credentialTask = nil }
            do
            {
                let savedKey = try await apiKeyStore.load()
                guard let self, !didEditAPIKey, !Task.isCancelled else { return }
                if let savedKey { apiKey = savedKey }
            }
            catch
            {
                guard let self, !didEditAPIKey else { return }
                errorMessage = error.localizedDescription
            }
        }
        recoveryTask = Task
        { [weak self, recoveryService] in
            defer { self?.recoveryTask = nil }
            let root = await recoveryService.mostRecentDownload()
            let history = await recoveryService.estimateHistory()
            guard let self else { return }
            if recoveryRootURL == nil { recoveryRootURL = root }
            hasRecoverableDownload = recoveryRootURL != nil
            estimateHistory = history
            refreshOfflineEstimate()
        }
    }

    var canResolveAddress: Bool { !isLoading && !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var canPrecheck: Bool { !isLoading && !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !latitude.isEmpty && !longitude.isEmpty }
    var canCapture: Bool { !isLoading && (!apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || precheckResult?.hasReusableSources == true) && !latitude.isEmpty && !longitude.isEmpty && precheckDisplay?.allowsCapture != false }

    func setAddress(_ value: String)
    {
        guard address != value else { return }
        address = value
        latitude = ""
        longitude = ""
        resolvedLocationTitle = nil
        invalidatePrecheck()
    }

    func setLatitude(_ value: String) { latitude = value; resolvedLocationTitle = nil; invalidatePrecheck() }
    func setLongitude(_ value: String) { longitude = value; resolvedLocationTitle = nil; invalidatePrecheck() }
    func setCaptureWidth(_ value: String) { captureWidth = value; invalidatePrecheck() }
    func setCaptureDepth(_ value: String) { captureDepth = value; invalidatePrecheck() }
    func setDetailError(_ value: String) { detailError = value; invalidatePrecheck() }
    func setMaximumRequests(_ value: String) { maximumRequests = value; refreshPrecheckDisplay() }
    func setMaximumTiles(_ value: String) { maximumTiles = value; refreshPrecheckDisplay() }
    func setMaximumVertices(_ value: String) { maximumVertices = value; refreshPrecheckDisplay() }
    func setMaximumTexturesMiB(_ value: String) { maximumTexturesMiB = value; refreshPrecheckDisplay() }
    func setAPIKey(_ value: String) { apiKey = value; didEditAPIKey = true }

    func resolveAddress()
    {
        guard canResolveAddress else { return }
        invalidatePrecheck()
        activeJobID = UUID()
        isLoading = true
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
                self?.refreshOfflineEstimate()
                self?.status = location.title
            }
            catch is CancellationError { self?.status = "Lookup cancelled" }
            catch
            {
                self?.errorMessage = error.localizedDescription
                self?.status = "Address lookup failed"
            }
            self?.isLoading = false
            self?.importTask = nil
        }
    }

    func precheckRegion()
    {
        guard !isLoading else { return }
        do
        {
            let request = try makeCaptureRequest()
            let limits = try makeImportLimits()
            let key = apiKey
            let jobID = UUID()
            activeJobID = jobID
            isLoading = true
            errorMessage = nil
            invalidatePrecheck()
            status = "Inspecting selection via API…"
            importTask = Task
            { [weak self, recoveryService] in
                do
                {
                    let result = try await recoveryService.precheck(request: request, apiKey: key, limits: limits)
                    { [weak self] progress in
                        Task
                        { @MainActor [weak self] in
                            guard let self, activeJobID == jobID, isLoading else { return }
                            status = "API inspection: \(progress.sourceRequests)/\(request.maximumSourceRequests) requests · \(progress.downloadedTiles) GLBs read"
                        }
                    }
                    try Task.checkCancellation()
                    guard self?.activeJobID == jobID else { throw CancellationError() }
                    self?.precheckResult = result
                    self?.refreshPrecheckDisplay()
                }
                catch is CancellationError { self?.status = "API inspection cancelled" }
                catch
                {
                    self?.errorMessage = error.localizedDescription
                    self?.status = "API inspection failed"
                }
                let root = await recoveryService.mostRecentDownload()
                let history = await recoveryService.estimateHistory()
                self?.estimateHistory = history
                self?.refreshOfflineEstimate()
                self?.recoveryRootURL = root
                self?.hasRecoverableDownload = root != nil
                self?.isLoading = false
                self?.activeJobID = UUID()
                self?.importTask = nil
            }
        }
        catch { errorMessage = error.localizedDescription }
    }

    func captureRegion()
    {
        guard !isLoading else { return }
        do
        {
            let request = try makeCaptureRequest()
            let limits = try makeImportLimits()
            if let precheckResult, precheckResult.matchesSelection(request)
            {
                guard precheckDisplay?.allowsCapture != false else { throw EarthImportError.limitExceeded("API inspection is incomplete or exceeds the current limits. Adjust limits and inspect again if needed.") }
                if precheckResult.hasReusableSources
                {
                    let importer = EarthCaptureImporter(limits: limits)
                    activeJobID = UUID()
                    startLoad(title: resolvedLocationTitle ?? "Captured Region", accessURL: nil, refreshRecovery: true)
                    { try await importer.importPrechecked(precheck: precheckResult) }
                    return
                }
            }
            let recoveryService = recoveryService
            let key = apiKey
            let jobID = UUID()
            activeJobID = jobID
            startLoad(title: resolvedLocationTitle ?? "Captured Region", accessURL: nil, refreshRecovery: true)
            { [weak self] in
                try await recoveryService.capture(request: request, apiKey: key, limits: limits)
                { [weak self] progress in
                    Task
                    { @MainActor [weak self] in
                        guard let self, activeJobID == jobID, isLoading else { return }
                        status = "\(progress.sourceRequests)/\(request.maximumSourceRequests) requests · \(progress.downloadedTiles) tiles downloaded · \(String(format: "%.1f MiB", Double(progress.downloadedBytes) / 1048576))"
                    }
                }
            }
        }
        catch { errorMessage = error.localizedDescription }
    }

    func saveCapture()
    {
        guard !isLoading, let capture else { return }
        let panel = NSSavePanel()
        panel.title = "Save Capture Folder"
        panel.nameFieldStringValue = "Earth Capture"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        activeJobID = UUID()
        isLoading = true
        errorMessage = nil
        status = "Saving capture…"
        importTask = Task
        { [weak self, captureStore] in
            let scoped = destination.startAccessingSecurityScopedResource()
            defer { if scoped { destination.stopAccessingSecurityScopedResource() } }
            do
            {
                let root = try await captureStore.save(capture: capture, directoryURL: destination)
                self?.savedRootURL = root
                self?.hasSavedCapture = true
                self?.status = capture.incompleteReason == nil ? "Capture saved" : "Partial capture saved"
            }
            catch is CancellationError { self?.status = "Save cancelled" }
            catch
            {
                self?.errorMessage = error.localizedDescription
                self?.status = "Save failed"
            }
            self?.isLoading = false
            self?.importTask = nil
        }
    }

    func showSavedCapture()
    {
        if let savedRootURL { NSWorkspace.shared.activateFileViewerSelecting([savedRootURL]) }
    }

    func openLastDownload()
    {
        guard !isLoading, let recoveryRootURL else { return }
        load(fileURL: recoveryRootURL, accessURL: recoveryRootURL.deletingLastPathComponent())
    }

    func showDownloads()
    {
        if let recoveryRootURL { NSWorkspace.shared.activateFileViewerSelecting([recoveryRootURL]) }
    }

    func loadReference()
    {
        guard let fixtures = Bundle.main.url(forResource: "Fixtures", withExtension: nil)
        else
        {
            errorMessage = "The bundled reference capture is missing."
            return
        }
        load(fileURL: fixtures.appendingPathComponent("Orientation/tileset.json"), accessURL: fixtures)
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
        importTask?.cancel()
        activeJobID = UUID()
        if isLoading { status = "Cancelling…" }
    }

    func resetView()
    {
        renderer?.resetCamera()
        previewRevision &+= 1
    }

    private func load(fileURL: URL, accessURL: URL)
    {
        guard !isLoading else { return }
        do
        {
            let importer = EarthCaptureImporter(limits: try makeImportLimits())
            activeJobID = UUID()
            startLoad(title: fileURL.deletingPathExtension().lastPathComponent, accessURL: accessURL)
            {
                try await importer.importFile(fileURL: fileURL)
            }
        }
        catch { errorMessage = error.localizedDescription }
    }

    private func invalidatePrecheck()
    {
        precheckResult = nil
        precheckDisplay = nil
        refreshOfflineEstimate()
    }

    private func refreshPrecheckDisplay()
    {
        refreshOfflineEstimate()
        guard let precheckResult else { precheckDisplay = nil; return }
        do
        {
            let request = try makeCaptureRequest()
            guard precheckResult.matchesSelection(request) else { invalidatePrecheck(); status = "Selection changed; inspect again if needed"; return }
            precheckDisplay = try EarthCapturePrecheckDisplay(precheck: precheckResult, request: request, limits: makeImportLimits())
        }
        catch { precheckDisplay = EarthCapturePrecheckDisplay(invalidLimits: error.localizedDescription) }
        status = precheckDisplay?.allowsCapture == true ? "API inspection ready" : "API inspection needs attention"
    }

    private func refreshOfflineEstimate()
    {
        let width = Double(captureWidth)
        let depth = Double(captureDepth)
        let area = width.flatMap { width in depth.map { width * $0 } }
        offlineEstimateDisplay = EarthOfflineEstimateDisplay(areaSquareMeters: area, limits: try? makeImportLimits(), request: try? makeCaptureRequest(), history: estimateHistory)
    }

    private func makeCaptureRequest() throws -> EarthCaptureRequest
    {
        guard let latitudeValue = Double(latitude), let longitudeValue = Double(longitude),
              let width = Double(captureWidth), let depth = Double(captureDepth), let error = Double(detailError)
        else { throw EarthImportError.invalidContent("Enter valid coordinates, region dimensions, and detail error.") }
        guard let requestLimit = Int(maximumRequests.trimmingCharacters(in: .whitespacesAndNewlines))
        else { throw EarthImportError.invalidContent("Maximum Requests must be a positive whole number.") }
        guard let tileLimit = Int(maximumTiles.trimmingCharacters(in: .whitespacesAndNewlines))
        else { throw EarthImportError.invalidContent("Maximum Tiles must be a positive whole number.") }
        return try EarthCaptureRequest(center: EarthGeographicOrigin(latitude: latitudeValue, longitude: longitudeValue), widthMeters: width, depthMeters: depth, maximumGeometricErrorMeters: error, maximumSourceRequests: requestLimit, maximumSelectedTiles: tileLimit)
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

    private func startLoad(
        title: String,
        accessURL: URL?,
        refreshRecovery: Bool = false,
        operation: @escaping @Sendable () async throws -> EarthCapture
    )
    {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        status = "Preparing \(title)…"
        let existingRenderer = renderer
        let worker = Task.detached(priority: .userInitiated)
        {
            let scoped = accessURL?.startAccessingSecurityScopedResource() == true
            defer { if scoped { accessURL?.stopAccessingSecurityScopedResource() } }
            let capture = try await operation()
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
            return (capture, renderer, prepared)
        }
        let recoveryService = recoveryService
        importTask = Task
        { [weak self, recoveryService] in
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
                capture = result.0
                renderer = result.1
                result.1.publish(scene: result.2)
                self.title = title
                let dimensions = result.0.bounds.dimensions
                summary = String(format: "%d meshes · %d triangles · %.1f × %.1f × %.1f m", result.0.meshes.count, result.0.triangleCount, dimensions.x, dimensions.y, dimensions.z)
                attribution = result.0.attributions.joined(separator: "; ")
                incompleteCaptureMessage = result.0.incompleteReason
                hasPreview = true
                hasSavedCapture = false
                savedRootURL = nil
                previewRevision &+= 1
                status = result.0.incompleteReason == nil ? "Ready" : "Partial capture recovered"
            }
            catch is CancellationError
            {
                self?.status = refreshRecovery ? "Capture cancelled" : "Import cancelled"
            }
            catch
            {
                self?.errorMessage = error.localizedDescription
                self?.status = "Import failed"
            }
            if refreshRecovery
            {
                let root = await recoveryService.mostRecentDownload()
                let history = await recoveryService.estimateHistory()
                self?.estimateHistory = history
                self?.refreshOfflineEstimate()
                self?.recoveryRootURL = root
                self?.hasRecoverableDownload = root != nil
            }
            self?.isLoading = false
            self?.activeJobID = UUID()
            self?.importTask = nil
        }
    }
}
