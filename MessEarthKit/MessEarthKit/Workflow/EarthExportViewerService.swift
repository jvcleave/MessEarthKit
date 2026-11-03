import Foundation
import MessEarthKit
import Metal

struct EarthExportViewerRequest: Equatable, Sendable
{
    let projectID: UUID
    let variantID: UUID
    let exportID: UUID
}

struct EarthExportViewerChoice: Identifiable, Sendable
{
    let id: UUID
    let title: String
    let isAvailable: Bool
}

enum EarthExportViewerProgress: Sendable { case reading, preparing }

struct EarthExportViewerModel: Sendable
{
    let renderer: EarthPreviewRenderer
    let scene: EarthPreparedPreview
    let fileName: String
    let format: EarthExportFormat
    let byteCount: Int
    let vertexCount: Int
    let triangleCount: Int
}

struct EarthExportViewerLoad: Sendable
{
    let model: EarthExportViewerModel
    let choices: [EarthExportViewerChoice]
}

/// Reads tracked delivery bytes, never the variant's capture/preparation. All
/// decode, validation and GPU construction runs on workers under one file lease.
actor EarthExportViewerService
{
    typealias Build = @Sendable (URL, EarthProjectExportRecord, Int, @escaping @Sendable (EarthExportViewerProgress) -> Void) async throws -> EarthExportViewerModel
    private let files: EarthAppFiles
    private let build: Build

    init(files: EarthAppFiles, build: @escaping Build = { try await EarthExportViewerService.buildScene($0, record: $1, byteCount: $2, progress: $3) })
    { self.files = files; self.build = build }

    func load(_ request: EarthExportViewerRequest, progress: @escaping @Sendable (EarthExportViewerProgress) -> Void) async throws -> EarthExportViewerLoad
    {
        try Task.checkCancellation()
        let records = try await EarthProjectExportHistoryStore(projectID: request.projectID, files: files).records()
        let variants = records.filter { $0.variantID == request.variantID }.sorted { $0.createdAt > $1.createdAt }
        guard let record = variants.first(where: { $0.id == request.exportID }) else { throw EarthAppFilesError.missingFile }
        var choices: [EarthExportViewerChoice] = []
        for record in variants
        {
            let available = try await files.exportFileIsAvailable(projectID: request.projectID, record: record)
            choices.append(.init(id: record.id, title: record.fileName, isAvailable: available))
        }
        let model = try await files.withExportRead(projectID: request.projectID, record: record)
        { [build] url, bytes in try await build(url, record, bytes, progress) }
        try Task.checkCancellation()
        return EarthExportViewerLoad(model: model, choices: choices)
    }

    nonisolated static func buildScene(_ url: URL, record: EarthProjectExportRecord, byteCount: Int, progress: @escaping @Sendable (EarthExportViewerProgress) -> Void, library: MTLLibrary? = nil) async throws -> EarthExportViewerModel
    {
        progress(.reading)
        guard let device = library?.device ?? MTLCreateSystemDefaultDevice() else { throw EarthRegionPreviewError.allocation }
        let admission = try EarthExportViewerAdmission(recommendedWorkingSetSize: device.recommendedMaxWorkingSetSize, allocatedBytes: device.currentAllocatedSize, physicalMemory: ProcessInfo.processInfo.physicalMemory)
        try admission.requireSource(byteCount)
        let limits = admission.limits
        let capture: EarthCapture
        let format: EarthExportFormat
        do
        {
            switch record.format
            {
                case .glb, .optimizedGLB:
                    capture = try await EarthCaptureImporter(limits: limits).importFile(fileURL: url)
                    format = try await EarthGLBExporter().exportedOptimization(fileURL: url) == nil ? .glb : .optimizedGLB
                case .usdz, .optimizedUSDZ:
                    capture = try await EarthUSDZExportReader(limits: limits).read(fileURL: url)
                    let metadata = try await EarthUSDZExporter().metadata(fileURL: url)
                    format = metadata?.optimization == nil ? .usdz : .optimizedUSDZ
            }
        }
        catch let EarthImportError.limitExceeded(reason)
        { throw EarthExportViewerError.decoding(format: record.format, reason: reason, limits: limits) }
        try Task.checkCancellation()
        progress(.preparing)
        let builder = try EarthPreviewSceneBuilder(device: device)
        let cost = try builder.memoryCost(capture: capture).totalBytes
        try admission.requireGPU(sceneBytes: cost)
        let scene = try autoreleasepool { try builder.prepare(capture: capture) }
        try Task.checkCancellation()
        try admission.gpuBudget.checkDeviceAllocation(device.currentAllocatedSize)
        return try EarthExportViewerModel(
            renderer: EarthPreviewRenderer(device: device, library: library),
            scene: scene,
            fileName: record.fileName,
            format: format,
            byteCount: byteCount,
            vertexCount: capture.vertexCount,
            triangleCount: capture.triangleCount
        )
    }
}
