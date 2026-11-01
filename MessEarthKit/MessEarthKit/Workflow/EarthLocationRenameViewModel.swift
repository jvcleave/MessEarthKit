import Foundation
import Observation

/// A location-specific draft. Rename changes only the name and preserves the
/// selected map location, source attempts, and existing exported identities.
@MainActor
@Observable
final class EarthLocationRenameViewModel: Identifiable
{
    let id = UUID()
    private(set) var name: String
    private(set) var isResolving = false
    private(set) var isSaving = false
    private(set) var didSave = false
    private(set) var errorMessage: String?
    private var proposedName: EarthLocationName
    @ObservationIgnored private let projectID: UUID
    @ObservationIgnored private let location: EarthLocationRecord
    @ObservationIgnored private let store: EarthProjectStore
    @ObservationIgnored private let onSaved: @MainActor (EarthProjectRecord) -> Void
    @ObservationIgnored private var lookupTask: Task<Void, Never>?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()

    init(projectID: UUID, location: EarthLocationRecord, store: EarthProjectStore, onSaved: @escaping @MainActor (EarthProjectRecord) -> Void)
    {
        self.projectID = projectID
        self.location = location
        self.store = store
        self.onSaved = onSaved
        name = location.title
        proposedName = location.name
    }

    func setName(_ value: String)
    {
        guard !isSaving else { return }
        cancelLookup()
        name = value
        proposedName = .custom(value)
        errorMessage = nil
    }

    func useAutomaticName()
    {
        guard !isSaving else { return }
        cancelLookup()
        isResolving = true
        errorMessage = nil
        let job = generation
        lookupTask = Task
        { [weak self, store, location] in
            do
            {
                let value = try await store.automaticLocationName(center: location.area.center)
                guard let self, generation == job, !Task.isCancelled else { return }
                proposedName = value
                name = value.title(center: location.area.center)
                isResolving = false
                lookupTask = nil
            }
            catch
            {
                guard let self, generation == job, !Task.isCancelled else { return }
                errorMessage = error.localizedDescription
                isResolving = false
                lookupTask = nil
            }
        }
    }

    func save()
    {
        guard !isSaving, !isResolving, !didSave,
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        isSaving = true
        errorMessage = nil
        let value = proposedName
        saveTask = Task
        { [weak self, store, projectID, location] in
            do
            {
                let record = try await store.renameLocation(id: projectID, locationID: location.id, name: value, expectedName: location.name, expectedCenter: location.area.center)
                guard let self else { return }
                onSaved(record)
                didSave = true
                isSaving = false
                saveTask = nil
            }
            catch
            {
                guard let self else { return }
                errorMessage = error.localizedDescription
                isSaving = false
                saveTask = nil
            }
        }
    }

    func cancelLookup()
    {
        generation = UUID()
        lookupTask?.cancel()
        lookupTask = nil
        isResolving = false
    }
}
