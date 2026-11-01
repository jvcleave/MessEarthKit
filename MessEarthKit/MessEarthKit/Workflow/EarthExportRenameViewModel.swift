import Foundation
import Observation

/// A rename draft never writes files. Late lookup results cannot replace edits
/// or a draft that has been dismissed.
@MainActor
@Observable
final class EarthExportRenameViewModel: Identifiable
{
    let id = UUID()
    let record: EarthProjectExportRecord
    private(set) var name: String
    private(set) var isResolving = false
    private(set) var errorMessage: String?
    @ObservationIgnored private let automaticName: @Sendable () async throws -> String
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()

    init(record: EarthProjectExportRecord, automaticName: @escaping @Sendable () async throws -> String)
    {
        self.record = record
        name = String(record.fileName.dropLast(4))
        self.automaticName = automaticName
    }

    func setName(_ value: String)
    {
        cancelLookup()
        name = value
        errorMessage = nil
    }

    func useAutomaticName()
    {
        cancelLookup()
        errorMessage = nil
        isResolving = true
        let job = generation
        task = Task
        { [weak self, automaticName] in
            do
            {
                let value = try await automaticName()
                guard let self, generation == job, !Task.isCancelled else { return }
                name = value.lowercased().hasSuffix(".glb") ? String(value.dropLast(4)) : value
                isResolving = false
                task = nil
            }
            catch
            {
                guard let self, generation == job, !Task.isCancelled else { return }
                errorMessage = error.localizedDescription
                isResolving = false
                task = nil
            }
        }
    }

    func cancelLookup()
    {
        generation = UUID()
        task?.cancel()
        task = nil
        isResolving = false
    }
}
