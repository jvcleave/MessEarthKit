import Foundation
@testable import MessEarthKit
import simd
import Testing

func projectStoreTestRoot() throws -> URL
{
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    return root
}

// Concurrent editor operations keep search, per-location edits and title separate.
@Test func projectDraftsKeepIdentityAndSerializeUnrelatedMutations() async throws
{
    let root = try projectStoreTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let files = try EarthAppFiles(storageRootURL: root)
    try await files.initialize()
    let store = EarthProjectStore(files: files)
    let first = try await store.create()
    let second = try await store.create()
    let origin = try EarthGeographicOrigin(latitude: 39, longitude: -84)
    let added = try await store.addLocation(id: first.id, center: origin, title: "Race")
    let location = try #require(added.editingLocation)
    var edit = location.edit
    edit.area.widthMeters = ""
    let pending = edit
    async let areaEdit = store.updateEditor(id: first.id, locations: [location.id: pending])
    async let search = store.updateEditor(id: first.id, searchAddress: "New York")
    async let title = store.updateTitle(id: first.id, title: "Race study")
    _ = try await (areaEdit, search, title)
    let result = EarthMapSearchResult(address: "New York", title: "New York", origin: try EarthGeographicOrigin(latitude: 40.7, longitude: -74))
    _ = try await store.recordSearch(id: first.id, result: result)
    let reopened = try await EarthProjectStore(files: files).open(id: first.id)
    #expect(reopened.record.editingLocation?.edit == edit && reopened.record.editingLocation?.area.center == origin)
    #expect(reopened.record.title == "Race study" && reopened.record.searchResult == result)
    #expect(try await store.record(id: second.id).locations.isEmpty)
    _ = try await store.updateEditor(id: first.id, searchAddress: "Elsewhere")
    #expect(try await store.record(id: first.id).searchResult == nil)
    #expect(try await store.record(id: first.id).locations == reopened.record.locations)
}

private enum InvalidProjectRecord: CaseIterable, Sendable { case version, missingNullable, folderIdentity, missingFreeze, missingVariantID, missingAttemptHistory, missingName }

@Test(arguments: InvalidProjectRecord.allCases)
private func projectLibraryReportsInvalidCurrentFilesWithoutReplacingThem(scenario: InvalidProjectRecord) async throws
{
    let root = try projectStoreTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let files = try EarthAppFiles(storageRootURL: root)
    try await files.initialize()
    let store = EarthProjectStore(files: files)
    let good = try await store.create()
    let empty = try await store.create()
    var damaged = try await store.addLocation(id: empty.id, center: EarthGeographicOrigin(latitude: 0, longitude: 0), title: "Draft")
    if scenario == .missingVariantID || scenario == .missingAttemptHistory
    {
        let selection = try EarthConfirmedSelection(location: #require(damaged.editingLocation))
        let url = try await files.newArtifactDirectory(projectID: empty.id, kind: .sources)
        let source = try await EarthSourceArchive.create(request: selection.request, directoryURL: url)
        damaged = try await store.recordCapture(id: empty.id, capture: .init(id: #require(UUID(uuidString: url.lastPathComponent)), request: source.request), selection: selection)
    }
    let bytes = try #require(try await files.readMetadata(.project(damaged.id)))
    var json = try #require(try JSONSerialization.jsonObject(with: bytes) as? [String: Any])
    switch scenario
    {
        case .version: json["version"] = 4
        case .missingNullable: json.removeValue(forKey: "selectedCaptureID")
        case .folderIdentity: json["id"] = good.id.uuidString
        case .missingFreeze:
            var locations = try #require(json["locations"] as? [[String: Any]])
            locations[0].removeValue(forKey: "frozenAt")
            json["locations"] = locations
        case .missingName:
            var locations = try #require(json["locations"] as? [[String: Any]])
            locations[0].removeValue(forKey: "name")
            json["locations"] = locations
        case .missingVariantID, .missingAttemptHistory:
            var locations = try #require(json["locations"] as? [[String: Any]])
            var variants = try #require(locations[0]["variants"] as? [[String: Any]])
            variants[0].removeValue(forKey: scenario == .missingVariantID ? "id" : "previousCaptures")
            locations[0]["variants"] = variants
            json["locations"] = locations
    }
    let invalid = try JSONSerialization.data(withJSONObject: json)
    try await files.writeMetadata(invalid, location: .project(damaged.id))
    let library = try await EarthProjectStore(files: files).library()
    #expect(library.projects.map(\.record.id) == [good.id])
    #expect(library.failures.map(\.id) == [damaged.id])
    #expect(try await files.readMetadata(.project(damaged.id)) == invalid)
}

/// Reuse the existing independent orientation GLB. SDK journal/preparer APIs
/// construct a real current artifact; no app test reimplements their codecs.
func projectSourceFixture(files: EarthAppFiles, projectID: UUID, existing: EarthSourceArchive? = nil, placements: Int = 1, mipmapped: Bool = false, origin: EarthGeographicOrigin? = nil, state: EarthSourceArchive.State = .downloaded) async throws -> EarthSourceArchive
{
    let directory: URL
    let request: EarthDownloadRequest
    if let existing { directory = existing.directoryURL; request = existing.request }
    else
    {
        directory = try await files.newArtifactDirectory(projectID: projectID, kind: .sources)
        request = try EarthDownloadRequest(center: origin ?? EarthGeographicOrigin(latitude: 0, longitude: 0))
    }
    let index = try EarthAcquisitionIndex(directoryURL: directory, creating: existing == nil ? request : nil)
    let run = try index.begin(request: request)
    var repository = URL(fileURLWithPath: #filePath)
    for _ in 0 ..< 5 { repository.deleteLastPathComponent() }
    var bytes = try Data(contentsOf: repository.appendingPathComponent("Tools/IntegrationProbe/Fixtures/Orientation/block.glb"))
    if mipmapped
    {
        // Only change the sampler's standard glTF minification enum. Preserve
        // the authored pixels/geometry and the GLB's existing chunk lengths.
        let range = try #require(bytes.range(of: Data("\"minFilter\":9728".utf8)))
        bytes.replaceSubrange(range, with: Data("\"minFilter\":9987".utf8))
    }
    let assetID = EarthSourceAccess.digest(Data("project-fixture".utf8))
    let file = try index.files.checked("tiles/\(assetID).glb")
    try bytes.write(to: file)
    let integrity = try index.files.integrity(file)
    try index.pending(assetID)
    try index.stage(assetID, bytes: integrity.bytes, hash: integrity.hash)
    try index.complete(assetID, run: run)
    for ordinal in 0 ..< placements
    {
        var placement = matrix_identity_double4x4
        placement.columns.3.x = Double(ordinal) * 10
        let transform = simd_inverse(request.center.earthCenteredToLocal) * placement
        let columns = [transform.columns.0, transform.columns.1, transform.columns.2, transform.columns.3]
        let tile = EarthTileset.Tile(boundingVolume: .init(box: nil, sphere: [2, 2, 1, 6], region: nil), geometricError: 0, transform: columns.flatMap { [$0.x, $0.y, $0.z, $0.w] }, refine: "REPLACE", content: .init(uri: "tiles/\(assetID).glb"), contents: nil, children: nil, implicitTiling: nil)
        try index.place(tile: tile, run: run, ordinal: ordinal)
    }
    try EarthSourceMetadata.publishManifest(index: index, request: request)
    try index.finish(state: state)
    return try index.snapshot()
}

/// Register a local authored fixture through the real location lifecycle.
@discardableResult
func projectRegisterSource(files: EarthAppFiles, store: EarthProjectStore, projectID: UUID, source: EarthSourceArchive, locationID: UUID? = nil) async throws -> EarthProjectRecord
{
    var record: EarthProjectRecord
    if let locationID { record = try await store.editLocation(id: projectID, locationID: locationID) }
    else { record = try await store.addLocation(id: projectID, center: source.request.center, title: "Fixture") }
    let location = try #require(record.editingLocation)
    var edit = location.edit
    edit.area.widthMeters = String(source.request.widthMeters)
    edit.area.heightMeters = String(source.request.depthMeters)
    guard let detail = EarthProjectDetail.allCases.first(where: { $0.errorMeters == source.request.maximumGeometricErrorMeters })
    else { throw EarthProjectStoreError.invalidRecord }
    edit.variantDetail = detail
    record = try await store.updateEditor(id: projectID, locations: [location.id: edit])
    let selection = try EarthConfirmedSelection(location: #require(record.editingLocation))
    return try await store.recordCapture(id: projectID, capture: .init(id: #require(UUID(uuidString: source.directoryURL.lastPathComponent)), request: source.request), selection: selection)
}

@Test func projectReopensOnlyItsRecordedCaptureAndRetainsFrozenRequest() async throws
{
    let root = try projectStoreTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let files = try EarthAppFiles(storageRootURL: root)
    try await files.initialize()
    let store = EarthProjectStore(files: files)
    let project = try await store.create()
    let raw = try await projectSourceFixture(files: files, projectID: project.id)
    let registered = try await projectRegisterSource(files: files, store: store, projectID: project.id, source: raw)
    let capture = try #require(registered.currentCapture)
    let url = try await files.newArtifactDirectory(projectID: project.id, kind: .prepared)
    let profile = try EarthPreparationProfile()
    _ = try await EarthModelPreparer().prepare(archive: raw, directoryURL: url, profile: profile)
    _ = try await store.recordPreparation(id: project.id, variantID: #require(registered.selectedCaptureID), preparation: .init(id: #require(UUID(uuidString: url.lastPathComponent)), captureID: capture.id, profile: profile))
    let searchResult = EarthMapSearchResult(address: "New York", title: "New York", origin: try EarthGeographicOrigin(latitude: 40, longitude: -74))
    _ = try await store.updateEditor(id: project.id, searchAddress: searchResult.address)
    _ = try await store.recordSearch(id: project.id, result: searchResult)
    let reopened = try await EarthProjectStore(files: files).open(id: project.id)
    #expect(reopened.archive?.request == raw.request && reopened.record.locations[0].isFrozen)
    #expect(reopened.prepared?.directoryURL == url && reopened.status == "Ready")
    _ = try await projectSourceFixture(files: files, projectID: project.id)
    try FileManager.default.moveItem(at: raw.directoryURL, to: root.appendingPathComponent("retained-source"))
    await #expect(throws: (any Error).self) { try await store.open(id: project.id) }
    #expect(try await store.record(id: project.id).currentCapture == capture)
}

@Test func appSettingsDoNotResetOrMigrateUnsupportedExistingData() async throws
{
    let root = try projectStoreTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let files = try EarthAppFiles(storageRootURL: root)
    try await files.initialize()
    let store = EarthAppSettingsStore(files: files)
    var settings = try await store.load()
    settings.showsUsageDetails = true
    try await store.save(settings)
    #expect(try await EarthAppSettingsStore(files: files).load() == settings)
    let invalid = Data("{\"version\":99,\"showsUsageDetails\":false}".utf8)
    try await files.writeMetadata(invalid, location: .settings)
    await #expect(throws: EarthAppSettingsError.unsupportedVersion) { try await store.load() }
    #expect(try await files.readMetadata(.settings) == invalid)
}

// Detail variants share one immutable area; copies are independent editable
// drafts. Reopen/selection cannot replace search or the actively edited location.
@Test(arguments: [false, true])
func projectLocationVariantsRetainGeometryAndPreparation(secondPaused: Bool) async throws
{
    let root = try projectStoreTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let files = try EarthAppFiles(storageRootURL: root)
    try await files.initialize()
    let store = EarthProjectStore(files: files)
    let project = try await store.create()
    let origin = try EarthGeographicOrigin(latitude: 0, longitude: 0)
    let initial = try await store.addLocation(id: project.id, center: origin, title: "Race")
    let locationID = try #require(initial.editingLocationID)
    let profile = try EarthPreparationProfile(name: "Project preview")
    var preparedURLs: [URL] = []
    for detail in [EarthProjectDetail.preview, .high]
    {
        var location = try #require(try await store.record(id: project.id).editingLocation)
        var edit = location.edit
        edit.variantDetail = detail
        _ = try await store.updateEditor(id: project.id, title: "Race study", locations: [locationID: edit])
        location = try #require(try await store.record(id: project.id).editingLocation)
        let selection = try EarthConfirmedSelection(location: location)
        let sourceURL = try await files.newArtifactDirectory(projectID: project.id, kind: .sources)
        let source = try await EarthSourceArchive.create(request: selection.request, directoryURL: sourceURL)
        _ = try await store.recordCapture(id: project.id, capture: .init(id: #require(UUID(uuidString: sourceURL.lastPathComponent)), request: source.request), selection: selection)
        if secondPaused && detail == .high { continue }
        let completed = try await projectSourceFixture(files: files, projectID: project.id, existing: source)
        let url = try await files.newArtifactDirectory(projectID: project.id, kind: .prepared)
        _ = try await EarthModelPreparer().prepare(archive: completed, directoryURL: url, profile: profile)
        _ = try await store.recordPreparation(id: project.id, variantID: #require(try await store.record(id: project.id).selectedCaptureID), preparation: .init(id: #require(UUID(uuidString: url.lastPathComponent)), captureID: #require(UUID(uuidString: sourceURL.lastPathComponent)), profile: profile))
        preparedURLs.append(url)
    }
    let frozen = try #require(try await store.record(id: project.id).editingLocation)
    // A current-format file cannot relabel acquired data with a different area.
    var corrupted = try await store.record(id: project.id)
    corrupted.locations[0].area.widthMeters = "250"
    let corruptBytes = try JSONEncoder().encode(corrupted)
    #expect(throws: (any Error).self) { try JSONDecoder().decode(EarthProjectRecord.self, from: corruptBytes) }
    var invalidEdit = frozen.edit
    invalidEdit.area.widthMeters = "500"
    await #expect(throws: EarthProjectStoreError.frozenLocation) { try await store.updateEditor(id: project.id, locations: [locationID: invalidEdit]) }
    // Adjusting an earlier attempt must copy its Preview detail, even though
    // High is the latest variant on that location.
    let copied = try await store.copyLocation(id: project.id, locationID: locationID, captureID: frozen.variants[0].id)
    let copy = try #require(copied.editingLocation)
    #expect(copy.id != frozen.id && !copy.isFrozen && copy.variants.isEmpty && copy.area == frozen.area)
    #expect(copy.variantDetail == .preview)
    var copyEdit = copy.edit
    copyEdit.area.widthMeters = "500"
    copyEdit.area.center = try EarthGeographicOrigin(latitude: 1, longitude: 1)
    _ = try await store.updateEditor(id: project.id, searchAddress: "New York", locations: [copy.id: copyEdit])
    let before = try await store.record(id: project.id)
    let statuses = try await store.captureStatuses(id: project.id)
    #expect(statuses[frozen.variants[0].id]?.archive?.state == .downloaded)
    #expect(statuses[frozen.variants[1].id]?.archive?.state == (secondPaused ? .paused : .downloaded))
    #expect(try await store.record(id: project.id) == before)
    let reopenedStore = EarthProjectStore(files: files)
    let selected = try await reopenedStore.selectCapture(id: project.id, captureID: frozen.variants[0].id)
    #expect(selected.record.editingLocationID == copy.id && selected.record.editingLocation?.edit == copyEdit && selected.record.searchAddress == "New York")
    #expect(selected.prepared?.directoryURL == preparedURLs[0])
    let last = try await reopenedStore.selectCapture(id: project.id, captureID: frozen.variants[1].id)
    #expect(last.archive?.state == (secondPaused ? .paused : .downloaded))
    #expect(last.record.locations[0] == frozen)
    let originalURL = try await files.resolve(reference: frozen.variants[0].capture.reference, projectID: project.id)
    try FileManager.default.moveItem(at: originalURL, to: root.appendingPathComponent("retained-preview"))
    let unavailable = try await store.captureStatuses(id: project.id)
    #expect(unavailable[frozen.variants[0].id]?.errorMessage != nil)
    await #expect(throws: (any Error).self) { try await reopenedStore.selectCapture(id: project.id, captureID: frozen.variants[0].id) }
    #expect(try await reopenedStore.record(id: project.id) == last.record)
}
