import Foundation
import MessEarthKit
import Metal
import simd

struct EarthPreviewBounds: Sendable
{
    private(set) var minimum: SIMD3<Float>
    private(set) var maximum: SIMD3<Float>
    var center: SIMD3<Float> { minimum + (maximum - minimum) * 0.5 }
    var dimensions: SIMD3<Float> { maximum - minimum }

    init(_ bounds: EarthBounds)
    {
        minimum = bounds.minimum
        maximum = bounds.maximum
    }

    mutating func include(_ other: Self)
    {
        minimum = simd_min(minimum, other.minimum)
        maximum = simd_max(maximum, other.maximum)
    }
}

/// Shader values only. Retaining an EarthMaterial here also retains its encoded
/// source image, keeping CPU payloads alive for the entire region.
struct EarthPreviewMaterial: Sendable
{
    let baseColor: SIMD4<Float>
    let isUnlit: Bool
    let isDoubleSided: Bool
    let alphaMode: EarthAlphaMode
    let alphaCutoff: Float

    init(_ material: EarthMaterial)
    {
        baseColor = material.baseColor
        isUnlit = material.isUnlit
        isDoubleSided = material.isDoubleSided
        alphaMode = material.alphaMode
        alphaCutoff = material.alphaCutoff
    }
}

/// Immutable GPU resources after preparation; buffers/textures are never rewritten.
final class EarthPreparedPreview: @unchecked Sendable
{
    struct Mesh
    {
        let vertices: MTLBuffer
        let indices: MTLBuffer
        let indexCount: Int
        let material: EarthPreviewMaterial
        let texture: MTLTexture
        let sampler: MTLSamplerState
        let center: SIMD3<Float>
    }

    let meshes: [Mesh]
    let bounds: EarthPreviewBounds
    let modelCount: Int
    let attributions: [String]
    let allocatedBytes: Int

    init(meshes: [Mesh], bounds: EarthPreviewBounds, modelCount: Int, attributions: [String], allocatedBytes: Int)
    {
        self.meshes = meshes
        self.bounds = bounds
        self.modelCount = modelCount
        self.attributions = attributions
        self.allocatedBytes = allocatedBytes
    }
}

enum EarthRegionPreviewError: Error, Equatable, LocalizedError, Sendable
{
    case incompleteCollection, sourceChanged, workingSet, allocation
    case deviceWorkingSet(allocatedBytes: Int, allowedBytes: Int)

    var errorDescription: String?
    {
        switch self
        {
            case .incompleteCollection: "The complete downloaded region has not been prepared. Downloaded files are retained."
            case .sourceChanged: "The preview does not match the project's current source or prepared files. Refresh the project before retrying the preview. Downloaded files are retained."
            case .workingSet: "The entire region exceeds the supported preview memory budget. Downloaded and prepared files remain available for offline export."
            case .allocation: "Metal could not allocate the region's preview resources. Downloaded and prepared files are retained."
            case let .deviceWorkingSet(allocatedBytes, allowedBytes): "GPU allocations in this app reached \(ByteCountFormatter.string(fromByteCount: Int64(allocatedBytes), countStyle: .memory)); the preview allows \(ByteCountFormatter.string(fromByteCount: Int64(allowedBytes), countStyle: .memory)). Downloaded and prepared files are retained."
        }
    }
}

struct EarthPreviewMemoryCost: Sendable
{
    var geometryBytes = 0
    var textureBytes = 0
    var totalBytes: Int { get throws { try Self.sum(geometryBytes, textureBytes) } }

    mutating func include(_ other: Self) throws
    {
        geometryBytes = try Self.sum(geometryBytes, other.geometryBytes)
        textureBytes = try Self.sum(textureBytes, other.textureBytes)
    }

    static func sum(_ first: Int, _ second: Int) throws -> Int
    {
        let value = first.addingReportingOverflow(second)
        guard first >= 0, second >= 0, !value.overflow else { throw EarthRegionPreviewError.workingSet }
        return value.partialValue
    }

    static func product(_ first: Int, _ second: Int) throws -> Int
    {
        let value = first.multipliedReportingOverflow(by: second)
        guard first >= 0, second >= 0, !value.overflow else { throw EarthRegionPreviewError.workingSet }
        return value.partialValue
    }
}

/// Existing device allocations include any prior scene and frames still in
/// flight. Keep room for one part's upload/mipmap work and viewport attachments.
/// This is conservative admission, not process-memory or native-crash isolation.
struct EarthPreviewMemoryBudget: Sendable
{
    let limitBytes: Int
    let existingBytes: Int
    let viewportReserveBytes: Int

    init(limitBytes: Int, existingBytes: Int, viewportReserveBytes: Int = 64 * 1024 * 1024)
    {
        self.limitBytes = limitBytes
        self.existingBytes = existingBytes
        self.viewportReserveBytes = viewportReserveBytes
    }

    func admit(sceneBytes: Int, largestPartBytes: Int) throws
    {
        let total = try EarthPreviewMemoryCost.sum(
            EarthPreviewMemoryCost.sum(existingBytes, viewportReserveBytes),
            EarthPreviewMemoryCost.sum(sceneBytes, largestPartBytes)
        )
        guard total <= limitBytes else { throw EarthRegionPreviewError.workingSet }
    }

    func checkDeviceAllocation(_ allocatedBytes: Int) throws
    {
        let total = try EarthPreviewMemoryCost.sum(allocatedBytes, viewportReserveBytes)
        guard total <= limitBytes
        else
        { throw EarthRegionPreviewError.deviceWorkingSet(allocatedBytes: allocatedBytes, allowedBytes: max(0, limitBytes - viewportReserveBytes)) }
    }
}

/// Heap size queries forecast storage; standalone resources can consume more
/// due to driver allocation granularity. The budget, not the estimate, is the
/// ceiling. Keep all not-yet-uploaded parts and upload headroom in the projection.
struct EarthPreviewMemoryPlan: Sendable
{
    private(set) var sceneBytes: Int
    private(set) var largestPartBytes: Int

    init(sceneBytes: Int, largestPartBytes: Int)
    {
        self.sceneBytes = sceneBytes
        self.largestPartBytes = largestPartBytes
    }

    mutating func includeUpload(estimatedBytes: Int, allocatedBytes: Int, budget: EarthPreviewMemoryBudget) throws
    {
        guard estimatedBytes >= 0, allocatedBytes >= 0 else { throw EarthRegionPreviewError.workingSet }
        let extra = allocatedBytes > estimatedBytes ? allocatedBytes - estimatedBytes : 0
        sceneBytes = try EarthPreviewMemoryCost.sum(sceneBytes, extra)
        largestPartBytes = max(largestPartBytes, allocatedBytes)
        try budget.admit(sceneBytes: sceneBytes, largestPartBytes: largestPartBytes)
    }
}
