import Foundation
import MessEarthKit

enum EarthProjectExportProgress: Sendable
{
    case preparing(EarthPreparationProgress)
    case exporting(EarthGLBExportProgress)
}

struct EarthProjectExportResult: Sendable
{
    let output: EarthProjectExportRecord
    let fileURL: URL
    let infoWarning: String?
}

enum EarthProjectExportError: Error, LocalizedError, Sendable
{
    case historyNotSaved(record: EarthProjectExportRecord, reason: String)

    var errorDescription: String?
    {
        switch self
        {
            case let .historyNotSaved(_, reason): "The export was saved, but its export history could not be recorded. The file is retained. \(reason)"
        }
    }
}

/// Explicit variant identity and access leases survive navigation and selection.
actor EarthProjectExportService
{
    nonisolated let projectID: UUID
    private let files: EarthAppFiles
    private let store: EarthProjectStore
    private let history: EarthProjectExportHistoryStore
    private let prepare: EarthProjectCaptureService.Prepare
    private let cityLookup: EarthProjectStore.CityLookup
    private enum DeliveryPlan
    {
        case glb(EarthGLBExportPlan)
        case usdz(EarthUSDZExportPlan)
    }

    private let exporter = EarthGLBExporter()
    private let usdzExporter = EarthUSDZExporter()
    private let captureStore = EarthCaptureStore()
    private var isWorking = false

    init(projectID: UUID, files: EarthAppFiles, store: EarthProjectStore, prepare: @escaping EarthProjectCaptureService.Prepare, cityLookup: @escaping EarthProjectStore.CityLookup = { try await EarthCityLookup().resolve(center: $0) })
    {
        self.projectID = projectID
        self.files = files
        self.store = store
        history = EarthProjectExportHistoryStore(projectID: projectID, files: files)
        self.prepare = prepare
        self.cityLookup = cityLookup
    }

    func export(
        variantID: UUID,
        options: EarthExportOptions,
        format: EarthExportFormat = .glb,
        optimization: EarthExportOptimizationSettings = .init(),
        progress: @escaping @Sendable (EarthProjectExportProgress) -> Void
    ) async throws -> EarthProjectExportResult
    {
        guard !isWorking else { throw EarthProjectCaptureError.workInProgress }
        isWorking = true
        defer { isWorking = false }
        try Task.checkCancellation()
        _ = try await history.records()
        var source = try await store.openVariant(id: projectID, variantID: variantID)
        guard source.archive.state == .downloaded else { throw EarthGLBExportError.sourceChanged }
        let sourceAccess = try await files.accessForReading(source.archive.directoryURL)
        defer { withExtendedLifetime(sourceAccess) {} }
        if source.prepared?.state != .ready || source.prepared?.coversEntireSource != true
        {
            let profile: EarthPreparationProfile
            if let preparation = source.variant.preparation { profile = preparation.profile }
            else { profile = try EarthPreparationProfile(name: "Project preview") }
            let prepared = try await prepare(source.archive, profile) { progress(.preparing($0)) }
            try Task.checkCancellation()
            guard let id = UUID(uuidString: prepared.directoryURL.lastPathComponent) else { throw EarthAppFilesError.invalidLocation }
            _ = try await store.recordPreparation(id: projectID, variantID: variantID, preparation: .init(
                id: id,
                captureID: source.variant.capture.id,
                profile: prepared.profile
            ))
            source = try await store.openVariant(id: projectID, variantID: variantID)
        }
        guard let collection = source.prepared, let preparation = source.variant.preparation,
              collection.state == .ready, collection.coversEntireSource
        else { throw EarthGLBExportError.sourceChanged }
        let preparedAccess = try await files.accessForReading(collection.directoryURL)
        defer { withExtendedLifetime(preparedAccess) {} }
        let identity = try EarthCaptureIdentity(locationName: source.location.title, request: source.variant.capture.request, detailName: source.variant.detail.rawValue)
        let preparedIdentity = try EarthCaptureIdentity(locationName: source.location.title, request: source.variant.capture.request, detailName: source.variant.title)
        try await captureStore.recordIdentity(preparedIdentity, collection: collection)
        let destination = try EarthPreparationProfile(
            name: "Standalone delivery",
            maximumVerticesPerModel: Int(UInt32.max) / 3,
            maximumIndicesPerModel: Int(UInt32.max),
            maximumDecodedTextureBytesPerModel: Int.max,
            maximumTextureDimension: Int.max,
            maximumSourceBytesPerModel: Int(UInt32.max),
            maximumNodesPerPayload: 1000000,
            appearancePolicy: collection.profile.appearancePolicy
        )
        let plan: DeliveryPlan
        switch format
        {
            case .glb, .optimizedGLB:
                let profile = format == .optimizedGLB ? try optimization.meshProfile() : nil
                let value = try await exporter.preflight(collection: collection, destination: destination, options: options, optimization: profile, identity: identity, progress: { progress(.exporting($0)) })
                guard value.canExport else { throw EarthGLBExportError.requirements(value.issues) }
                plan = .glb(value)
            case .usdz, .optimizedUSDZ:
                let profile = format == .optimizedUSDZ ? try optimization.profile() : nil
                let value = try await usdzExporter.preflight(collection: collection, destination: destination, options: options, optimization: profile, identity: identity, progress: { progress(.exporting($0)) })
                guard value.canExport else { throw EarthUSDZExportError.requirements(value.issues) }
                plan = .usdz(value)
        }
        try Task.checkCancellation()
        let current = try await store.record(id: projectID)
        guard current.captures.first(where: { $0.id == variantID }) == source.variant,
              current.locations.first(where: { $0.id == source.location.id })?.name == source.location.name
        else { throw EarthGLBExportError.sourceChanged }
        let name = source.location.name.exportName(request: source.variant.capture.request)
        let output = try await files.newExportDestination(projectID: projectID, name: name, detail: source.variant.detail, options: options, format: format)
        let fileURL: URL
        var infoWarning: String?
        do
        {
            let access = try await files.accessForExport(output.fileURL)
            defer { withExtendedLifetime(access) {} }
            switch plan
            {
                case let .glb(value):
                    var preview: EarthGLBExportPreview?
                    do
                    {
                        let renderer = try EarthGLBThumbnailRenderer(geometry: value.informationGeometry(), options: value.options)
                        preview = EarthGLBExportPreview(consume: { try await renderer.consume($0) }, finish: { try await renderer.finish() })
                    }
                    catch { infoWarning = "The GLB information companion has no thumbnail because preview rendering is unavailable." }
                    let delivery = try await exporter.exportWithInfo(plan: value, fileURL: output.fileURL, preview: preview, progress: { progress(.exporting($0)) })
                    fileURL = delivery.fileURL
                    infoWarning = delivery.infoWarning ?? infoWarning
                case let .usdz(value):
                    let delivery = try await usdzExporter.export(plan: value, fileURL: output.fileURL, progress: { progress(.exporting($0)) })
                    fileURL = delivery.fileURL
            }
        }
        catch
        {
            try? await files.discardEmptyExportDirectory(containing: output.fileURL, projectID: projectID)
            throw error
        }
        let record = EarthProjectExportRecord(
            id: output.id,
            variantID: variantID,
            source: source.variant.capture,
            preparation: preparation,
            locationName: identity.locationName,
            detail: source.variant.detail,
            includeTextures: options.includeTextures,
            fileName: fileURL.lastPathComponent,
            createdAt: Date()
        )
        // Atomic output publication wins a simultaneous Cancel. Persist its history
        // even if the caller is now cancelled; never delete a completed output.
        do { _ = try await history.append(record) }
        catch { throw EarthProjectExportError.historyNotSaved(record: record, reason: error.localizedDescription) }
        return .init(output: record, fileURL: fileURL, infoWarning: infoWarning)
    }

    func exports() async throws -> [EarthProjectExportItem]
    {
        let records = try await history.records()
        var items: [EarthProjectExportItem] = []
        for record in records
        {
            let byteCount = try await files.exportFileByteCount(projectID: projectID, record: record)
            let available = byteCount != nil
            var options: EarthGLBExportOptions?
            var contentsError: String?
            var usdzMetadata: EarthUSDZExportMetadata?
            var glbOptimization: EarthMeshOptimizationResult?
            if available
            {
                do
                {
                    let url = try await files.exportFileURL(projectID: projectID, record: record)
                    let access = try await files.accessForReading(url)
                    defer { withExtendedLifetime(access) {} }
                    if record.format.isGLB
                    {
                        options = try await exporter.exportedOptions(fileURL: url)
                        glbOptimization = try await exporter.exportedOptimization(fileURL: url)
                    }
                    else
                    {
                        usdzMetadata = try await usdzExporter.metadata(fileURL: url)
                        options = usdzMetadata?.options
                    }
                }
                catch { contentsError = error.localizedDescription }
            }
            items.append(.init(record: record, fileIsAvailable: available, exportedOptions: options, contentsError: contentsError, usdzMetadata: usdzMetadata, glbOptimization: glbOptimization, byteCount: byteCount))
        }
        return items.sorted
        {
            if $0.record.createdAt == $1.record.createdAt { return $0.id.uuidString > $1.id.uuidString }
            return $0.record.createdAt > $1.record.createdAt
        }
    }

    func rename(_ record: EarthProjectExportRecord, to name: String) async throws -> [EarthProjectExportItem]
    {
        guard !isWorking else { throw EarthProjectCaptureError.workInProgress }
        isWorking = true
        defer { isWorking = false }
        _ = try await history.rename(record, to: name)
        return try await exports()
    }

    func automaticName(for record: EarthProjectExportRecord) async throws -> String
    {
        guard try await history.records().contains(record) else { throw EarthAppFilesError.invalidMetadata }
        let url = try await files.exportFileURL(projectID: projectID, record: record)
        let access = try await files.accessForReading(url)
        defer { withExtendedLifetime(access) {} }
        let options: EarthExportOptions?
        let format: EarthExportFormat
        if record.format.isGLB
        {
            options = try await exporter.exportedOptions(fileURL: url)
            format = try await exporter.exportedOptimization(fileURL: url) == nil ? .glb : .optimizedGLB
        }
        else
        {
            let info = try await usdzExporter.metadata(fileURL: url)
            options = info?.options
            format = info?.optimization == nil ? .usdz : .optimizedUSDZ
        }
        let center = record.source.request.center
        let name = EarthLocationName.automatic(city: try await cityLookup(center))
        try Task.checkCancellation()
        try name.validate()
        return try await files.exportFileName(name: name.exportName(request: record.source.request), detail: record.detail, options: options, format: format)
    }

    func delete(_ record: EarthProjectExportRecord) async throws -> [EarthProjectExportItem]
    {
        guard !isWorking else { throw EarthProjectCaptureError.workInProgress }
        isWorking = true
        defer { isWorking = false }
        _ = try await history.delete(record)
        return try await exports()
    }

    func reveal(_ record: EarthProjectExportRecord) async throws
    {
        guard try await files.exportFileIsAvailable(projectID: projectID, record: record) else { throw EarthAppFilesError.missingFile }
        let url = try await files.exportFileURL(projectID: projectID, record: record)
        await files.reveal(url)
    }
}
