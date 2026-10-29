import Foundation
@testable import MessEarthKit
import Testing

private actor NamingCities
{
    var centres: [EarthGeographicOrigin] = []

    func resolve(_ center: EarthGeographicOrigin) -> String
    {
        centres.append(center)
        return center.latitude < 42 ? "Chicago" : "Other City"
    }
}

@Test func automaticLocationNamesUseActualCentresAndPreserveManualNames() async throws
{
    let root = try projectStoreTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let files = try EarthAppFiles(storageRootURL: root)
    try await files.initialize()
    let cities = NamingCities()
    let store = EarthProjectStore(files: files, cityLookup: { await cities.resolve($0) })
    let project = try await store.create()
    let center = try EarthGeographicOrigin(latitude: 41.87811347, longitude: -87.62980539)
    let added = try await store.addLocation(id: project.id, center: center)
    let location = try #require(added.editingLocation)
    #expect(location.title == "Chicago · 41.87811, -87.62981")
    var edit = location.edit
    let moved = try EarthGeographicOrigin(latitude: 43.12345678, longitude: -86.12345678)
    edit.area.center = moved
    let updated = try await store.updateEditor(id: project.id, locations: [location.id: edit])
    let named = try #require(updated.editingLocation)
    #expect(named.title == "Other City · 43.12346, -86.12346" && named.area.center == moved)
    // A later queued dimension edit may still carry the previous resolved city.
    // The store owns automatic city updates and must retain the current result.
    var queued = edit
    queued.area.widthMeters = "300"
    let dimensionEdit = try await store.updateEditor(id: project.id, locations: [location.id: queued])
    #expect(dimensionEdit.editingLocation?.title == named.title)
    var custom = named.edit
    custom.title = "My capture"
    _ = try await store.updateEditor(id: project.id, locations: [location.id: custom])
    custom.area.center = center
    _ = try await store.updateEditor(id: project.id, locations: [location.id: custom])
    let reopened = try await EarthProjectStore(files: files).open(id: project.id)
    #expect(reopened.record.editingLocation?.title == "My capture")
    #expect(await cities.centres == [center, moved])
    // Copying an automatic location retains automatic ownership, independently
    // of a copied custom title or another location's future area.
    let automatic = try await store.addLocation(id: project.id, center: center)
    let original = try #require(automatic.editingLocation)
    let copied = try await store.copyLocation(id: project.id, locationID: original.id)
    var copy = try #require(copied.editingLocation).edit
    copy.area.center = moved
    let copyID = try #require(copied.editingLocationID)
    let renamed = try await store.updateEditor(id: project.id, locations: [copyID: copy])
    #expect(renamed.editingLocation?.title == "Other City · 43.12346, -86.12346")
    #expect(renamed.locations.first { $0.id == original.id } == original)
}

private actor NamingSuspension
{
    private var result: CheckedContinuation<String, Never>?
    private var arrival: CheckedContinuation<Void, Never>?

    func resolve() async -> String
    {
        await withCheckedContinuation
        { continuation in
            result = continuation
            arrival?.resume()
            arrival = nil
        }
    }

    func waitForLookup() async
    {
        if result != nil { return }
        await withCheckedContinuation { arrival = $0 }
    }

    func finish()
    {
        result?.resume(returning: "Moved city")
        result = nil
    }
}

@Test func delayedCityLookupCannotOverwriteAManualName() async throws
{
    let root = try projectStoreTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let files = try EarthAppFiles(storageRootURL: root)
    try await files.initialize()
    let gate = NamingSuspension()
    let center = try EarthGeographicOrigin(latitude: 41, longitude: -87)
    let store = EarthProjectStore(files: files, cityLookup: { point in point == center ? "First city" : await gate.resolve() })
    let project = try await store.create()
    let added = try await store.addLocation(id: project.id, center: center)
    let location = try #require(added.editingLocation)
    var moved = location.edit
    moved.area.center = try EarthGeographicOrigin(latitude: 43, longitude: -86)
    let edit = moved
    let moving = Task { try await store.updateEditor(id: project.id, locations: [location.id: edit]) }
    await gate.waitForLookup()
    var manual = location.edit
    manual.title = "Hand edited"
    _ = try await store.updateEditor(id: project.id, locations: [location.id: manual])
    await gate.finish()
    await #expect(throws: EarthProjectStoreError.changedLocation) { try await moving.value }
    #expect(try await store.record(id: project.id).editingLocation?.title == "Hand edited")
}

@Test func cityLookupFailureDoesNotCreateAnInventedLocationName() async throws
{
    let root = try projectStoreTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let files = try EarthAppFiles(storageRootURL: root)
    try await files.initialize()
    let store = EarthProjectStore(files: files, cityLookup: { _ in throw EarthLocationNamingError.cityUnavailable })
    let project = try await store.create()
    await #expect(throws: EarthLocationNamingError.self)
    { try await store.addLocation(id: project.id, center: EarthGeographicOrigin(latitude: 0, longitude: 0)) }
    #expect(try await store.record(id: project.id).locations.isEmpty)
}

@Test(arguments: [false, true])
func sharedAreaChangesRefreshAutomaticNamesAndRetainCustomNames(customName: Bool) async throws
{
    let root = try projectStoreTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let files = try EarthAppFiles(storageRootURL: root)
    try await files.initialize()
    let cities = NamingCities()
    let store = EarthProjectStore(files: files, cityLookup: { await cities.resolve($0) })
    let project = try await store.create()
    let center = try EarthGeographicOrigin(latitude: 41.87811347, longitude: -87.62980539)
    var added = try await store.addLocation(id: project.id, center: center)
    let locationID = try #require(added.editingLocationID)
    if customName
    {
        var edit = try #require(added.editingLocation).edit
        edit.title = "My area"
        added = try await store.updateEditor(id: project.id, locations: [locationID: edit])
    }
    let selection = try EarthConfirmedSelection(location: #require(added.editingLocation))
    let directory = try await files.newArtifactDirectory(projectID: project.id, kind: .sources)
    let source = try await EarthSourceArchive.create(request: selection.request, directoryURL: directory)
    _ = try await store.recordCapture(id: project.id, capture: .init(id: #require(UUID(uuidString: directory.lastPathComponent)), request: source.request), selection: selection)
    var adjustment = try await store.areaAdjustment(id: project.id, locationID: locationID)
    adjustment.area.center = try EarthGeographicOrigin(latitude: 43.12345678, longitude: -86.12345678)
    _ = try await store.applyAreaAdjustment(id: project.id, adjustment: adjustment)
    let reopened = try await EarthProjectStore(files: files).open(id: project.id)
    #expect(reopened.record.editingLocation?.title == (customName ? "My area" : "Other City · 43.12346, -86.12346"))
    #expect(await cities.centres.count == (customName ? 1 : 2))
}
