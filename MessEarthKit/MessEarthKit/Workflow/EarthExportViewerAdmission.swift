import Foundation
import MessEarthKit

/// Whole deliveries are larger than one capture/prepared part. Decode ceilings
/// follow this viewer's memory allowance; SDK capture defaults remain unchanged.
struct EarthExportViewerAdmission: Sendable
{
    let gpuBudget: EarthPreviewMemoryBudget
    let limits: EarthImportLimits

    init(recommendedWorkingSetSize: UInt64, allocatedBytes: Int, physicalMemory: UInt64) throws
    {
        let limit = try EarthPreviewMemoryLimit.automatic.resolvedBytes(recommendedWorkingSetSize: recommendedWorkingSetSize)
        gpuBudget = EarthPreviewMemoryBudget(limitBytes: limit, existingBytes: allocatedBytes)
        guard allocatedBytes >= 0, allocatedBytes < limit,
              gpuBudget.viewportReserveBytes < limit - allocatedBytes
        else
        {
            let required = max(0, allocatedBytes).addingReportingOverflow(gpuBudget.viewportReserveBytes)
            throw EarthExportViewerError.memory(requiredBytes: required.overflow ? Int.max : required.partialValue, allowedBytes: limit)
        }
        let available = limit - allocatedBytes - gpuBudget.viewportReserveBytes
        // Keep source/native/CPU headroom as well as one full upload inside the
        // GPU budget. This is admission, not a process peak-memory guarantee.
        let working = min(available / 2, Int(clamping: physicalMemory / 4))
        let geometry = working / 2
        let textures = working / 2
        let vertices = min(Int(UInt32.max) / 3, geometry / (MemoryLayout<EarthVertex>.stride + 3 * MemoryLayout<UInt32>.stride))
        let source = min(Int(UInt32.max) - 1, working / 4)
        guard vertices >= 3, source > 0, textures > 0 else { throw EarthExportViewerError.memory(requiredBytes: 64 * 1024 * 1024, allowedBytes: available) }
        limits = EarthImportLimits(maximumSourceBytes: source, maximumVertices: vertices, maximumTextureDimension: 16384, maximumDecodedTextureBytes: textures, maximumNodes: 100000)
    }

    func requireSource(_ bytes: Int) throws
    {
        guard bytes <= limits.maximumSourceBytes else { throw EarthExportViewerError.source(requiredBytes: bytes, allowedBytes: limits.maximumSourceBytes) }
    }

    func requireGPU(sceneBytes: Int) throws
    {
        do { try gpuBudget.admit(sceneBytes: sceneBytes, largestPartBytes: sceneBytes) }
        catch
        {
            let overhead = gpuBudget.existingBytes.addingReportingOverflow(gpuBudget.viewportReserveBytes)
            let required = sceneBytes.multipliedReportingOverflow(by: 2)
            let total = required.partialValue.addingReportingOverflow(overhead.partialValue)
            throw EarthExportViewerError.memory(requiredBytes: required.overflow || overhead.overflow || total.overflow ? Int.max : total.partialValue, allowedBytes: gpuBudget.limitBytes)
        }
    }
}

enum EarthExportViewerError: Error, LocalizedError, Sendable
{
    case source(requiredBytes: Int, allowedBytes: Int)
    case memory(requiredBytes: Int, allowedBytes: Int)
    case decoding(format: EarthExportFormat, reason: String, limits: EarthImportLimits)

    var errorDescription: String?
    {
        func size(_ bytes: Int) -> String { ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory) }
        switch self
        {
            case let .source(required, allowed):
                return "The exported file is \(size(required)); the viewer currently allows \(size(allowed)) of source data for this device."
            case let .memory(required, allowed):
                return "The exported model needs about \(size(required)) including current GPU allocations and upload space; the viewer's GPU budget is \(size(allowed))."
            case let .decoding(format, reason, limits):
                return "The exported \(format.rawValue) exceeded a viewer decode limit: \(reason) Viewer allowances: \(limits.maximumVertices.formatted()) vertices, \(size(limits.maximumDecodedTextureBytes)) decoded textures, \(size(limits.maximumSourceBytes)) source data."
        }
    }
}
