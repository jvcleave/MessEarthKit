import Foundation
import MessEarthKit

/// A queue entry owns its export choices and source identity independently of
/// selection, later control edits and location/project renaming.
struct EarthQueuedExportRequest: Codable, Equatable, Sendable
{
    let projectID: UUID
    let projectTitle: String
    let locationID: UUID
    let locationName: EarthLocationName
    let locationTitle: String
    let variantID: UUID
    let detail: EarthProjectDetail
    let source: EarthProjectCapture
    let preparationProfile: EarthPreparationProfile
    let options: EarthExportOptions
    let format: EarthExportFormat
    let optimization: EarthExportOptimizationSettings

    var settingsSummary: String
    {
        var contents = ["Geometry"]
        if options.includeNormals { contents.append("Normals") }
        if options.includeVertexColors { contents.append("Vertex colors") }
        if options.includeTextureCoordinates { contents.append("UV coordinates") }
        if options.includeMaterials { contents.append("Materials") }
        if options.includeTextures { contents.append("Textures") }
        if format.isOptimized
        {
            contents.append("\((optimization.triangleFraction * 100).formatted())% triangles")
            contents.append("\(optimization.maximumErrorMeters.formatted()) m maximum error")
            if format == .optimizedUSDZ, let dimension = optimization.maximumTextureDimension
            { contents.append("\(dimension) px textures") }
        }
        return contents.joined(separator: ", ")
    }

    func validate() throws
    {
        guard projectTitle.utf8.count <= 512, locationTitle.utf8.count <= 1024,
              detail.errorMeters == source.request.maximumGeometricErrorMeters,
              !options.includeTextures || (options.includeTextureCoordinates && options.includeMaterials)
        else { throw EarthAppFilesError.invalidMetadata }
        try locationName.validate()
        _ = try EarthCaptureIdentity(locationName: locationTitle, request: source.request, detailName: detail.rawValue)
        if format == .optimizedGLB { _ = try optimization.meshProfile() }
        if format == .optimizedUSDZ { _ = try optimization.profile() }
    }

    func hasSameExport(as other: Self) -> Bool
    {
        projectID == other.projectID && variantID == other.variantID && source == other.source
            && locationName == other.locationName && preparationProfile == other.preparationProfile
            && options == other.options && format == other.format
            && (!format.isOptimized || optimization == other.optimization)
    }
}

enum EarthExportQueuePhase: String, Codable, Sendable
{
    case pending, running, cancelled, failed, complete

    var title: String
    {
        switch self
        {
            case .pending: "Pending"
            case .running: "Exporting"
            case .cancelled: "Cancelled"
            case .failed: "Failed"
            case .complete: "Complete"
        }
    }
}

struct EarthExportQueueEntry: Codable, Equatable, Identifiable, Sendable
{
    let id: UUID
    let request: EarthQueuedExportRequest
    var isIncluded = true
    var phase = EarthExportQueuePhase.pending
    var exportID: UUID?
    var result: EarthProjectExportRecord?
    var isUnrecorded = false
    var message: String?

    init(id: UUID = UUID(), request: EarthQueuedExportRequest)
    {
        self.id = id
        self.request = request
    }

    func validate() throws
    {
        try request.validate()
        guard message.map({ $0.utf8.count <= 4096 }) ?? true,
              phase != .running || exportID != nil,
              (phase == .complete) == (result != nil), !isUnrecorded || result != nil
        else { throw EarthAppFilesError.invalidMetadata }
        if let result
        {
            try result.validate()
            guard result.id == exportID, result.variantID == request.variantID,
                  result.source == request.source, result.detail == request.detail,
                  result.locationName == request.locationTitle,
                  result.preparation.profile == request.preparationProfile,
                  result.format.fileExtension == request.format.fileExtension,
                  result.includeTextures == request.options.includeTextures
            else { throw EarthAppFilesError.invalidMetadata }
        }
    }
}

/// One app-wide queue owner writes immutable snapshots through the file owner.
/// Missing metadata initializes an empty queue; invalid data is never replaced.
actor EarthExportQueueStore
{
    private struct Queue: Codable
    {
        let version: Int
        let entries: [EarthExportQueueEntry]

        func validate() throws
        {
            guard version == 1, Set(entries.map(\.id)).count == entries.count else { throw EarthAppFilesError.invalidMetadata }
            for entry in entries { try entry.validate() }
        }
    }

    private let files: EarthAppFiles

    init(files: EarthAppFiles) { self.files = files }

    func load() async throws -> [EarthExportQueueEntry]
    {
        guard let data = try await files.readMetadata(.exportQueue) else { return [] }
        do
        {
            let queue = try JSONDecoder().decode(Queue.self, from: data)
            try queue.validate()
            return queue.entries
        }
        catch { throw EarthAppFilesError.invalidMetadata }
    }

    func save(_ entries: [EarthExportQueueEntry]) async throws
    {
        let queue = Queue(version: 1, entries: entries)
        try queue.validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try await files.writeMetadata(encoder.encode(queue), location: .exportQueue)
    }
}
