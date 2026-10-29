import Foundation
import MessEarthKit
import Metal

struct EarthRegionPreviewProgress: Sendable
{
    enum Phase: Sendable { case checking, uploading }
    let phase: Phase
    let completed: Int
    let total: Int
}

/// Two bounded passes: inspect one decoded part at a time, then upload one part
/// at a time after aggregate admission. No combined GLB or aggregate CPU capture.
struct EarthRegionPreviewLoader
{
    let device: MTLDevice

    func load(
        collection: EarthPreparedCollection,
        modelID: Int? = nil,
        memoryLimit: EarthPreviewMemoryLimit = .automatic,
        displayMode: EarthPreviewDisplayMode = .wireframe,
        budget suppliedBudget: EarthPreviewMemoryBudget? = nil,
        progress: @Sendable (EarthRegionPreviewProgress) -> Void,
        validateSource: @Sendable () async throws -> Void
    ) async throws -> EarthPreparedPreview
    {
        guard collection.state == .ready, collection.coversEntireSource, collection.modelCount > 0
        else { throw EarthRegionPreviewError.incompleteCollection }
        let selectedCount = modelID == nil ? collection.modelCount : 1
        let limitBytes = try memoryLimit.resolvedBytes(recommendedWorkingSetSize: device.recommendedMaxWorkingSetSize)
        let budget = suppliedBudget ?? EarthPreviewMemoryBudget(
            limitBytes: limitBytes,
            existingBytes: device.currentAllocatedSize
        )
        let builder = try EarthPreviewSceneBuilder(device: device, displayMode: displayMode)
        var planned = EarthPreviewMemoryCost(textureBytes: builder.constantTextureBytes)
        var largestPartBytes = 0
        var offset = 0
        var checkedCount = 0
        try await validateCollection(collection)
        while offset < collection.modelCount
        {
            try Task.checkCancellation()
            try await validateSource()
            let page = try await collection.models(offset: offset, limit: 128)
            guard !page.isEmpty, page.count <= collection.modelCount - offset else { throw EarthRegionPreviewError.sourceChanged }
            for model in page
            {
                try Task.checkCancellation()
                offset += 1
                guard modelID == nil || model.id == modelID else { continue }
                let cost = try await inspect(model: model, collection: collection, builder: builder)
                try planned.include(cost)
                largestPartBytes = max(largestPartBytes, try cost.totalBytes)
                try budget.admit(sceneBytes: planned.totalBytes, largestPartBytes: largestPartBytes)
                checkedCount += 1
                progress(.init(phase: .checking, completed: checkedCount, total: selectedCount))
            }
        }
        guard checkedCount == selectedCount else { throw EarthRegionPreviewError.sourceChanged }
        try Task.checkCancellation()
        try await validateSource()
        try await validateCollection(collection)
        var memoryPlan = try EarthPreviewMemoryPlan(sceneBytes: planned.totalBytes, largestPartBytes: largestPartBytes)
        var meshes: [EarthPreparedPreview.Mesh] = []
        var bounds: EarthPreviewBounds?
        var attributions = Set<String>()
        var allocatedBytes = builder.constantTextureBytes
        offset = 0
        var uploadedCount = 0
        while offset < collection.modelCount
        {
            try Task.checkCancellation()
            try await validateSource()
            let page = try await collection.models(offset: offset, limit: 128)
            guard !page.isEmpty, page.count <= collection.modelCount - offset else { throw EarthRegionPreviewError.sourceChanged }
            for model in page
            {
                try Task.checkCancellation()
                offset += 1
                guard modelID == nil || model.id == modelID else { continue }
                let uploaded = try await upload(model: model, collection: collection, builder: builder)
                let part = uploaded.scene
                allocatedBytes = try EarthPreviewMemoryCost.sum(allocatedBytes, part.allocatedBytes)
                // Re-admit measured costs, including estimates for remaining
                // parts. An underestimated allocation is not a budget failure.
                try memoryPlan.includeUpload(estimatedBytes: uploaded.estimatedBytes, allocatedBytes: part.allocatedBytes, budget: budget)
                try budget.checkDeviceAllocation(device.currentAllocatedSize)
                meshes.append(contentsOf: part.meshes)
                if bounds == nil { bounds = part.bounds } else { bounds?.include(part.bounds) }
                attributions.formUnion(part.attributions)
                uploadedCount += 1
                progress(.init(phase: .uploading, completed: uploadedCount, total: selectedCount))
            }
        }
        try Task.checkCancellation()
        try await validateSource()
        try await validateCollection(collection)
        guard let bounds, !meshes.isEmpty, uploadedCount == selectedCount else { throw EarthRegionPreviewError.incompleteCollection }
        return EarthPreparedPreview(meshes: meshes, bounds: bounds, modelCount: uploadedCount, attributions: attributions.sorted(), allocatedBytes: allocatedBytes, displayMode: displayMode)
    }

    private func inspect(model: EarthPreparedModel, collection: EarthPreparedCollection, builder: EarthPreviewSceneBuilder) async throws -> EarthPreviewMemoryCost
    {
        let capture = try await collection.importModel(id: model.id)
        try validate(capture: capture, collection: collection)
        return try autoreleasepool { try builder.memoryCost(capture: capture) }
    }

    private func upload(model: EarthPreparedModel, collection: EarthPreparedCollection, builder: EarthPreviewSceneBuilder) async throws -> (scene: EarthPreparedPreview, estimatedBytes: Int)
    {
        let capture = try await collection.importModel(id: model.id)
        try validate(capture: capture, collection: collection)
        return try autoreleasepool
        {
            let estimate = try builder.memoryCost(capture: capture).totalBytes
            return (try builder.prepare(capture: capture), estimate)
        }
    }

    private func validate(capture: EarthCapture, collection: EarthPreparedCollection) throws
    {
        try Task.checkCancellation()
        guard capture.incompleteReason == nil, capture.geographicOrigin == collection.geographicOrigin,
              capture.preparationProfile == collection.profile
        else { throw EarthRegionPreviewError.sourceChanged }
    }

    private func validateCollection(_ collection: EarthPreparedCollection) async throws
    {
        let current = try await EarthPreparedCollection.open(directoryURL: collection.directoryURL)
        guard current.state == .ready, current.coversEntireSource,
              current.modelCount == collection.modelCount, current.sourceIdentifier == collection.sourceIdentifier,
              current.geographicOrigin == collection.geographicOrigin, current.profile == collection.profile
        else { throw EarthRegionPreviewError.sourceChanged }
    }
}
