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
    var fileName: String
    let createdAt: Date
    var reference: String { "output/\(id.uuidString)/\(fileName)" }

    func validate() throws
    {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " .-_"))
        guard preparation.captureID == source.id, detail.errorMeters == source.request.maximumGeometricErrorMeters,
              createdAt.timeIntervalSince1970.isFinite, !fileName.isEmpty, fileName.utf8.count <= 255,
              fileName.hasSuffix(".glb"), fileName.unicodeScalars.allSatisfy({ allowed.contains($0) })
        else { throw EarthAppFilesError.invalidMetadata }
        _ = try EarthCaptureIdentity(locationName: locationName, request: source.request, detailName: detail.rawValue)
    }

    func renamed(to name: String) throws -> Self
    {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let stem = name.lowercased().hasSuffix(".glb") ? String(name.dropLast(4)) : name
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " .-_"))
        let fileName = stem + ".glb"
        guard !stem.trimmingCharacters(in: CharacterSet(charactersIn: " .")).isEmpty,
              fileName.utf8.count <= 245, fileName.unicodeScalars.allSatisfy({ allowed.contains($0) })
        else { throw EarthAppFilesError.invalidExportName }
        var result = self
        result.fileName = fileName
        try result.validate()
        return result
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
    private enum Mutation: Sendable
    {
        case append(EarthProjectExportRecord)
        case rename(EarthProjectExportRecord, String)
        case delete(EarthProjectExportRecord)
    }

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
        return try await mutate(.append(record))
    }

    func rename(_ record: EarthProjectExportRecord, to name: String) async throws -> [EarthProjectExportRecord]
    { try await mutate(.rename(record, name)) }

    func delete(_ record: EarthProjectExportRecord) async throws -> [EarthProjectExportRecord]
    { try await mutate(.delete(record)) }

    private func mutate(_ change: Mutation) async throws -> [EarthProjectExportRecord]
    {
        let previous = mutation?.task
        let token = UUID()
        let task = Task
        { [projectID, files] in
            // A failed mutation must not poison later queued actions. Reread the
            // persisted state after it settles, including any rollback.
            if let previous { _ = await previous.result }
            let originalMetadata = try await files.readMetadata(.exports(projectID))
            var records = try Self.decode(originalMetadata, projectID: projectID)
            switch change
            {
                case let .append(record):
                    guard !records.contains(where: { $0.id == record.id }) else { throw EarthAppFilesError.invalidMetadata }
                    records.append(record)
                case let .rename(record, name):
                    guard let index = records.firstIndex(of: record) else { throw EarthAppFilesError.invalidMetadata }
                    records[index] = try record.renamed(to: name)
                case let .delete(record):
                    guard let index = records.firstIndex(of: record) else { throw EarthAppFilesError.invalidMetadata }
                    records.remove(at: index)
            }
            let history = History(version: 1, projectID: projectID, exports: records)
            try history.validate(projectID: projectID)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let updatedMetadata = try encoder.encode(history)
            switch change
            {
                case .append:
                    try await files.writeMetadata(updatedMetadata, location: .exports(projectID))
                case let .rename(record, name):
                    guard let originalMetadata else { throw EarthAppFilesError.invalidMetadata }
                    try await files.renameExport(projectID: projectID, record: record, name: name, originalMetadata: originalMetadata, updatedMetadata: updatedMetadata)
                case let .delete(record):
                    guard let originalMetadata else { throw EarthAppFilesError.invalidMetadata }
                    try await files.trashExport(projectID: projectID, record: record, originalMetadata: originalMetadata, updatedMetadata: updatedMetadata)
            }
            return records
        }
        mutation = (token, task)
        defer { if mutation?.id == token { mutation = nil } }
        return try await task.value
    }

    private static func read(projectID: UUID, files: EarthAppFiles) async throws -> [EarthProjectExportRecord]
    {
        let data = try await files.readMetadata(.exports(projectID))
        return try decode(data, projectID: projectID)
    }

    private static func decode(_ data: Data?, projectID: UUID) throws -> [EarthProjectExportRecord]
    {
        guard let data else { return [] }
        do
        {
            let history = try JSONDecoder().decode(History.self, from: data)
            try history.validate(projectID: projectID)
            return history.exports
        }
        catch { throw EarthAppFilesError.invalidMetadata }
    }
}
