import Foundation
import MessEarthKit

struct EarthProjectExportRecord: Codable, Equatable, Identifiable, Sendable
{
    let id: UUID
    let variantID: UUID
    let source: EarthProjectCapture
    let preparation: EarthProjectPreparation
    let locationName: String
    let detail: EarthProjectDetail
    let includeTextures: Bool
    let fileName: String
    let createdAt: Date
    var reference: String { "output/\(id.uuidString)/\(fileName)" }

    func validate() throws
    {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_"))
        guard preparation.captureID == source.id, detail.errorMeters == source.request.maximumGeometricErrorMeters,
              createdAt.timeIntervalSince1970.isFinite, !fileName.isEmpty, fileName.utf8.count <= 255,
              fileName.hasSuffix(".glb"), fileName.unicodeScalars.allSatisfy({ allowed.contains($0) })
        else { throw EarthAppFilesError.invalidMetadata }
        _ = try EarthCaptureIdentity(locationName: locationName, request: source.request, detailName: detail.rawValue)
    }
}

struct EarthProjectExportItem: Identifiable, Sendable
{
    let record: EarthProjectExportRecord
    let fileIsAvailable: Bool
    var id: UUID { record.id }
}

/// Independent metadata: no history file exists until the first tracked export.
/// Existing untracked output folders are never scanned or assigned to a variant.
actor EarthProjectExportHistoryStore
{
    private struct History: Codable
    {
        let version: Int
        let projectID: UUID
        var exports: [EarthProjectExportRecord]

        func validate(projectID expectedID: UUID) throws
        {
            guard version == 1, projectID == expectedID, Set(exports.map(\.id)).count == exports.count
            else { throw EarthAppFilesError.invalidMetadata }
            for record in exports { try record.validate() }
        }
    }

    private let projectID: UUID
    private let files: EarthAppFiles
    private var mutation: (id: UUID, task: Task<[EarthProjectExportRecord], Error>)?

    init(projectID: UUID, files: EarthAppFiles)
    {
        self.projectID = projectID
        self.files = files
    }

    func records() async throws -> [EarthProjectExportRecord]
    {
        if let mutation { return try await mutation.task.value }
        return try await Self.read(projectID: projectID, files: files)
    }

    func append(_ record: EarthProjectExportRecord) async throws -> [EarthProjectExportRecord]
    {
        try record.validate()
        let previous = mutation?.task
        let token = UUID()
        let task = Task
        { [projectID, files] in
            var records: [EarthProjectExportRecord]
            if let previous { records = try await previous.value }
            else { records = try await Self.read(projectID: projectID, files: files) }
            guard !records.contains(where: { $0.id == record.id }) else { throw EarthAppFilesError.invalidMetadata }
            records.append(record)
            let history = History(version: 1, projectID: projectID, exports: records)
            try history.validate(projectID: projectID)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try await files.writeMetadata(encoder.encode(history), location: .exports(projectID))
            return records
        }
        mutation = (token, task)
        defer { if mutation?.id == token { mutation = nil } }
        return try await task.value
    }

    private static func read(projectID: UUID, files: EarthAppFiles) async throws -> [EarthProjectExportRecord]
    {
        guard let data = try await files.readMetadata(.exports(projectID)) else { return [] }
        do
        {
            let history = try JSONDecoder().decode(History.self, from: data)
            try history.validate(projectID: projectID)
            return history.exports
        }
        catch { throw EarthAppFilesError.invalidMetadata }
    }
}
