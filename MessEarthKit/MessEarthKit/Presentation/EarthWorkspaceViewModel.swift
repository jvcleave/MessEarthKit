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
    private(set) var apiKey = ""
    private(set) var hasSavedCapture = false
    private(set) var hasRecoverableDownload = false
    private(set) var incompleteCaptureMessage: String?

    @ObservationIgnored private(set) var renderer: EarthPreviewRenderer?
    @ObservationIgnored private let importer = EarthCaptureImporter()
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

    init()
    {
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
            guard let self, recoveryRootURL == nil else { return }
            recoveryRootURL = root
            hasRecoverableDownload = root != nil
        }
    }

    var canResolveAddress: Bool { !isLoading && !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var canCapture: Bool { !isLoading && !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !latitude.isEmpty && !longitude.isEmpty }

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
    func setDetailError(_ value: String) { detailError = value }
    func setMaximumRequests(_ value: String) { maximumRequests = value }
    func setAPIKey(_ value: String) { apiKey = value; didEditAPIKey = true }

    func resolveAddress()
    {
        guard canResolveAddress else { return }
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

    func captureRegion()
    {
        guard !isLoading else { return }
        do
        {
            guard let latitudeValue = Double(latitude), let longitudeValue = Double(longitude),
                  let width = Double(captureWidth), let depth = Double(captureDepth), let error = Double(detailError)
            else { throw EarthImportError.invalidContent("Enter valid coordinates, region dimensions, and detail error.") }
            guard let requestLimit = Int(maximumRequests.trimmingCharacters(in: .whitespacesAndNewlines))
            else { throw EarthImportError.invalidContent("Maximum Requests must be a positive whole number.") }
            let origin = try EarthGeographicOrigin(latitude: latitudeValue, longitude: longitudeValue)
            let request = try EarthCaptureRequest(center: origin, widthMeters: width, depthMeters: depth, maximumGeometricErrorMeters: error, maximumSourceRequests: requestLimit)
            let recoveryService = recoveryService
            let key = apiKey
            let jobID = UUID()
            activeJobID = jobID
            startLoad(title: resolvedLocationTitle ?? "Captured Region", accessURL: nil, refreshRecovery: true)
            { [weak self] in
                try await recoveryService.capture(request: request, apiKey: key)
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
        activeJobID = UUID()
        let importer = importer
        startLoad(title: fileURL.deletingPathExtension().lastPathComponent, accessURL: accessURL)
        {
            try await importer.importFile(fileURL: fileURL)
        }
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
                self?.recoveryRootURL = root
                self?.hasRecoverableDownload = root != nil
            }
            self?.isLoading = false
            self?.activeJobID = UUID()
            self?.importTask = nil
        }
    }
}
