import CryptoKit
import Foundation

/// An offline preflight bound to the selected files, not just their catalog
/// estimates. A blocked plan explains the destination constraints without
/// creating output. The host retains folder authorization until export finishes.
public struct EarthGLBExportPlan: Sendable
{
    public let selectedModelCount: Int
    public let estimate: EarthCaptureGeometryEstimate
    public let outputByteCount: Int?
    public let coversEntireSource: Bool
    public let options: EarthGLBExportOptions
    public var includesTextures: Bool { options.includeTextures }
    public let issues: [String]
    public var canExport: Bool { issues.isEmpty && json != nil }
    let collection: EarthPreparedCollection
    let json: Data?
    let binaryByteCount: Int
    let models: [EarthGLBExportModel]
}

struct EarthGLBExportModel: Sendable
{
    let id: Int
    let fingerprint: String
}

public struct EarthGLBExportProgress: Sendable
{
    public enum Phase: Sendable { case checking, writing }
    public let phase: Phase
    public let completedModels: Int
    public let totalModels: Int
}

public enum EarthGLBExportError: Error, Equatable, LocalizedError, Sendable
{
    case requirements([String])
    case sourceChanged
    case invalidDestination
    case invalidOptions
    case storage

    public var errorDescription: String?
    {
        switch self
        {
            case let .requirements(issues): "Combined GLB cannot fit this destination. " + issues.joined(separator: " ") + " Export separate models or change the destination requirements."
            case .sourceChanged: "The prepared models changed after preflight. Check the selection again; source files are retained."
            case .invalidDestination: "Choose a new .glb file outside the prepared collection. Existing files are not replaced."
            case .invalidOptions: "Texture export requires UV coordinates and materials."
            case .storage: "The combined GLB could not be written. Check disk space and folder access. Source models are retained."
        }
    }
}

/// Keeps one bounded prepared model, a bounded JSON document and small I/O
/// buffers in memory. Meshes remain independent; there is no welding or texture
/// resampling. The selected source files are fingerprinted before output.
public actor EarthGLBExporter
{
    private var isWorking = false

    public init() {}

    /// Options select the exported vertex attributes, materials and images.
    /// Source model loading retains its original limits and data. Texture export
    /// requires UV coordinates and materials; inconsistent options fail explicitly.
    public func preflight(
        collection: EarthPreparedCollection,
        selection: EarthModelSelection = .all(),
        destination: EarthPreparationProfile,
        options: EarthGLBExportOptions = .full,
        identity: EarthCaptureIdentity? = nil,
        progress: @escaping @Sendable (EarthGLBExportProgress) -> Void = { _ in }
    ) async throws -> EarthGLBExportPlan
    {
        guard !isWorking else { throw EarthCaptureError.alreadyCapturing }
        isWorking = true
        defer { isWorking = false }
        try Task.checkCancellation()
        try options.validate()
        let (snapshot, count, estimate) = try Self.inspect(collection: collection, selection: selection, includeTextures: options.includeTextures)
        if let identity
        {
            try identity.validate()
            guard identity.request.center == snapshot.geographicOrigin
            else { throw EarthImportError.invalidContent("Export identity does not match the prepared capture origin.") }
        }
        let entire = snapshot.coversEntireSource && count == snapshot.modelCount
        let estimatedIssues = Self.requirementIssues(estimate, profile: destination)
        if !estimatedIssues.isEmpty
        {
            return EarthGLBExportPlan(selectedModelCount: count, estimate: estimate, outputByteCount: nil, coversEntireSource: entire, options: options, issues: estimatedIssues, collection: snapshot, json: nil, binaryByteCount: 0, models: [])
        }
        let builder = try EarthCombinedGLB(profile: destination, options: options, identity: identity)
        var models: [EarthGLBExportModel] = []
        var offset = 0
        var lastProgress = ContinuousClock.now
        do
        {
            while offset < snapshot.modelCount
            {
                try Task.checkCancellation()
                let page = try await snapshot.models(offset: offset)
                guard !page.isEmpty else { throw EarthGLBExportError.sourceChanged }
                for model in page where selection.includes(model.id)
                {
                    try Task.checkCancellation()
                    let capture = try await snapshot.importModel(id: model.id)
                    try autoreleasepool
                    {
                        try builder.append(capture, modelID: model.id)
                        models.append(EarthGLBExportModel(id: model.id, fingerprint: Self.fingerprint(capture)))
                    }
                    if models.count == 1 || models.count == count || lastProgress.duration(to: .now) >= .milliseconds(200)
                    {
                        progress(.init(phase: .checking, completedModels: models.count, totalModels: count))
                        lastProgress = .now
                    }
                }
                offset += page.count
            }
            guard models.count == count else { throw EarthGLBExportError.sourceChanged }
            let json = try builder.finish(collection: snapshot, modelIDs: models.map(\.id), coversEntireSource: entire)
            let total = try EarthCaptureGeometryEstimate.sum(28, EarthCaptureGeometryEstimate.sum(json.count, builder.binaryByteCount))
            var issues = Self.requirementIssues(builder.estimate, profile: destination)
            if total > destination.maximumSourceBytesPerModel
            { issues.append("The file needs \(total.formatted()) bytes; this destination allows \(destination.maximumSourceBytesPerModel.formatted()).") }
            if total > Int(UInt32.max)
            { issues.append("The file exceeds GLB's 32-bit container length.") }
            return EarthGLBExportPlan(selectedModelCount: count, estimate: builder.estimate, outputByteCount: total, coversEntireSource: entire, options: options, issues: issues, collection: snapshot, json: issues.isEmpty ? json : nil, binaryByteCount: builder.binaryByteCount, models: models)
        }
        catch let EarthGLBExportError.requirements(issues)
        {
            return EarthGLBExportPlan(selectedModelCount: count, estimate: estimate, outputByteCount: nil, coversEntireSource: entire, options: options, issues: issues, collection: snapshot, json: nil, binaryByteCount: 0, models: [])
        }
    }

    @discardableResult
    public func export(
        plan: EarthGLBExportPlan,
        fileURL: URL,
        progress: @escaping @Sendable (EarthGLBExportProgress) -> Void = { _ in }
    ) async throws -> URL
    {
        guard !isWorking else { throw EarthCaptureError.alreadyCapturing }
        isWorking = true
        defer { isWorking = false }
        try Task.checkCancellation()
        guard plan.canExport, let json = plan.json, let total = plan.outputByteCount
        else { throw EarthGLBExportError.requirements(plan.issues) }
        let source = plan.collection.directoryURL.standardizedFileURL.resolvingSymlinksInPath().path
        let destination = fileURL.standardizedFileURL.resolvingSymlinksInPath().path
        guard fileURL.isFileURL, fileURL.pathExtension.lowercased() == "glb",
              destination != source, !destination.hasPrefix(source + "/"),
              !FileManager.default.fileExists(atPath: fileURL.path)
        else { throw EarthGLBExportError.invalidDestination }
        var ancestor = fileURL.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath()
        while ancestor.path != "/"
        {
            guard !FileManager.default.fileExists(atPath: ancestor.appendingPathComponent("acquisition.sqlite").path),
                  !FileManager.default.fileExists(atPath: ancestor.appendingPathComponent("preparation.sqlite").path)
            else { throw EarthGLBExportError.invalidDestination }
            ancestor.deleteLastPathComponent()
        }
        let current = try await EarthPreparedCollection.open(directoryURL: plan.collection.directoryURL)
        guard current.sourceIdentifier == plan.collection.sourceIdentifier, current.profile == plan.collection.profile,
              current.modelCount == plan.collection.modelCount, current.state == plan.collection.state,
              current.coversEntireSource == plan.collection.coversEntireSource
        else { throw EarthGLBExportError.sourceChanged }
        let staging = fileURL.deletingLastPathComponent().appendingPathComponent(".mess-earth-\(UUID().uuidString).partial")
        guard FileManager.default.createFile(atPath: staging.path, contents: nil) else { throw EarthGLBExportError.storage }
        defer { try? FileManager.default.removeItem(at: staging) }
        do
        {
            let output = try FileHandle(forWritingTo: staging)
            defer { try? output.close() }
            try EarthCombinedGLB.writeWords([0x46546C67, 2, UInt32(total), UInt32(json.count), 0x4E4F534A], to: output)
            try output.write(contentsOf: json)
            try EarthCombinedGLB.writeWords([UInt32(plan.binaryByteCount), 0x004E4942], to: output)
            let binaryStart = try output.offset()
            var lastProgress = ContinuousClock.now
            for (ordinal, model) in plan.models.enumerated()
            {
                try Task.checkCancellation()
                let capture = try await current.importModel(id: model.id)
                guard Self.fingerprint(capture) == model.fingerprint else { throw EarthGLBExportError.sourceChanged }
                try autoreleasepool { try EarthCombinedGLB.writeBinary(capture, options: plan.options, to: output) }
                if ordinal == 0 || ordinal + 1 == plan.selectedModelCount || lastProgress.duration(to: .now) >= .milliseconds(200)
                {
                    progress(.init(phase: .writing, completedModels: ordinal + 1, totalModels: plan.selectedModelCount))
                    lastProgress = .now
                }
            }
            try Task.checkCancellation()
            guard try output.offset() - binaryStart == UInt64(plan.binaryByteCount),
                  try output.offset() == UInt64(total) else { throw EarthGLBExportError.sourceChanged }
            try output.synchronize()
            try output.close()
            // A hard link publishes atomically without overwriting a destination
            // that appeared during the export; staging is in the same directory.
            try FileManager.default.linkItem(at: staging, to: fileURL)
            return fileURL
        }
        catch is CancellationError { throw CancellationError() }
        catch let error as EarthGLBExportError { throw error }
        catch let error as EarthImportError { throw error }
        catch let error as EarthPreparationError { throw error }
        catch { throw EarthGLBExportError.storage }
    }

    private static func inspect(collection: EarthPreparedCollection, selection: EarthModelSelection, includeTextures: Bool) throws -> (EarthPreparedCollection, Int, EarthCaptureGeometryEstimate)
    {
        let index = try EarthPreparationIndex(directoryURL: collection.directoryURL)
        let snapshot = try index.snapshot()
        guard snapshot.sourceIdentifier == collection.sourceIdentifier, snapshot.profile == collection.profile else { throw EarthGLBExportError.sourceChanged }
        let count = try index.validate(selection)
        guard count > 0 else { throw EarthGLBExportError.requirements(["Select at least one model."]) }
        var estimate = try EarthCaptureGeometryEstimate()
        try index.forEachModel
        { model in
            try Task.checkCancellation()
            if selection.includes(model.id)
            {
                let cost = includeTextures ? model.estimate : try EarthCaptureGeometryEstimate(vertices: model.estimate.vertexCount, indices: model.estimate.indexCount)
                estimate = try estimate.adding(cost)
            }
        }
        return (snapshot, count, estimate)
    }

    private static func requirementIssues(_ estimate: EarthCaptureGeometryEstimate, profile: EarthPreparationProfile) -> [String]
    {
        var issues: [String] = []
        if estimate.vertexCount > profile.maximumVerticesPerModel { issues.append("The selection needs \(estimate.vertexCount.formatted()) vertices; the destination allows \(profile.maximumVerticesPerModel.formatted()).") }
        if estimate.indexCount > profile.maximumIndicesPerModel { issues.append("The selection exceeds the destination's triangle/index budget.") }
        if estimate.decodedTextureBytes > profile.maximumDecodedTextureBytesPerModel { issues.append("The selection exceeds the destination's decoded-texture budget.") }
        if estimate.largestTextureDimension > profile.maximumTextureDimension { issues.append("A texture exceeds the destination's maximum image dimensions.") }
        return issues
    }

    private static func fingerprint(_ capture: EarthCapture) -> String
    {
        var hash = SHA256()
        for file in capture.sourceFiles
        {
            // Include framing so path/data boundaries cannot be ambiguous.
            hash.update(data: Data("\(file.relativePath.utf8.count):\(file.relativePath):\(file.data.count):".utf8))
            hash.update(data: file.data)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
