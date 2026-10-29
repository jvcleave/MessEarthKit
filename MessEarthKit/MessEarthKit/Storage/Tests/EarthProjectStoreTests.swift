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

// Persistence risks: UI drafts can be incomplete; suspended concurrent mutations
// must preserve separate fields and never attach another project's data.
@Test func projectDraftsKeepIdentityAndSerializeUnrelatedMutations() async throws
{
    let root = try projectStoreTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let files = try EarthAppFiles(storageRootURL: root)
    try await files.initialize()
    let store = EarthProjectStore(files: files)
    let first = try await store.create()
    let second = try await store.create()
    var draft = first.draft
    draft.address = "613 Race St, Cincinnati, Ohio"
    _ = try await store.updateDraft(id: first.id, draft: draft)
    draft.widthMeters = ""
    let pendingDraft = draft
    let location = EarthProjectLocation(address: draft.address, title: "613 Race", origin: try EarthGeographicOrigin(latitude: 39, longitude: -84))
    async let edit = store.updateDraft(id: first.id, draft: pendingDraft)
    async let resolve = store.recordLocation(id: first.id, location: location)
    async let rename = store.updateTitle(id: first.id, title: "Race study")
    _ = try await (edit, resolve, rename)
    let reopened = try await EarthProjectStore(files: files).open(id: first.id)
    #expect(reopened.record.id == first.id && reopened.record.draft == draft && reopened.record.resolvedLocation == location)
    #expect(reopened.status == "Draft" && reopened.record.createdAt == first.createdAt)
    #expect(reopened.record.title == "Race study")
    #expect(try await store.record(id: second.id).draft == .empty)
    draft.address = "Another Address"
    _ = try await store.updateDraft(id: first.id, draft: draft)
    #expect(try await store.record(id: first.id).resolvedLocation == nil)
    #expect(try await store.record(id: first.id).title == "Race study")
}

private enum InvalidProjectRecord: CaseIterable, Sendable { case version, missingNullable, folderIdentity }

@Test(arguments: InvalidProjectRecord.allCases)
private func projectLibraryReportsInvalidCurrentFilesWithoutReplacingThem(scenario: InvalidProjectRecord) async throws
{
    let root = try projectStoreTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let files = try EarthAppFiles(storageRootURL: root)
    try await files.initialize()
    let store = EarthProjectStore(files: files)
    let good = try await store.create()
    let damaged = try await store.create()
    let bytes = try #require(try await files.readMetadata(.project(damaged.id)))
    var json = try #require(try JSONSerialization.jsonObject(with: bytes) as? [String: Any])
    switch scenario
    {
        case .version: json["version"] = 1
        case .missingNullable: json.removeValue(forKey: "selectedCaptureID")
        case .folderIdentity: json["id"] = good.id.uuidString
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
func projectSourceFixture(files: EarthAppFiles, projectID: UUID, existing: EarthSourceArchive? = nil, placements: Int = 1, mipmapped: Bool = false, origin: EarthGeographicOrigin? = nil) async throws -> EarthSourceArchive
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
    try index.finish(state: .downloaded)
    return try index.snapshot()
}

@Test func projectReopensOnlyItsRecordedCaptureAndRetainsFrozenRequest() async throws
{
    let root = try projectStoreTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let files = try EarthAppFiles(storageRootURL: root)
    try await files.initialize()
    let store = EarthProjectStore(files: files)
    let record = try await store.create()
    let raw = try await projectSourceFixture(files: files, projectID: record.id)
    let capture = try EarthProjectCapture(id: #require(UUID(uuidString: raw.directoryURL.lastPathComponent)), request: raw.request)
    _ = try await store.recordCapture(id: record.id, capture: capture)
    let preparedURL = try await files.newArtifactDirectory(projectID: record.id, kind: .prepared)
    let profile = try EarthPreparationProfile()
    let prepared = try await EarthModelPreparer().prepare(archive: raw, directoryURL: preparedURL, profile: profile)
    let preparation = try EarthProjectPreparation(id: #require(UUID(uuidString: preparedURL.lastPathComponent)), captureID: capture.id, profile: profile)
    _ = try await store.recordPreparation(id: record.id, preparation: preparation)
    var changedDraft = record.draft
    changedDraft.address = "A different draft selection"
    changedDraft.widthMeters = "500"
    _ = try await store.updateDraft(id: record.id, draft: changedDraft)
    let reopened = try await EarthProjectStore(files: files).open(id: record.id)
    #expect(reopened.record.draft == changedDraft && reopened.archive?.request == raw.request)
    #expect(reopened.prepared?.directoryURL == prepared.directoryURL && reopened.status == "Ready")
    #expect(try await reopened.prepared?.importModel(id: 1).triangleCount == 14)
    // A newer directory is not adopted when a saved reference disappears.
    _ = try await projectSourceFixture(files: files, projectID: record.id)
    try FileManager.default.moveItem(at: raw.directoryURL, to: root.appendingPathComponent("retained-source"))
    await #expect(throws: (any Error).self) { try await EarthProjectStore(files: files).open(id: record.id) }
    #expect(try await store.record(id: record.id).currentCapture == capture)
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

// Capture variants are acquisition choices, not internal model parts. Reuse the
// authored source/preparer; verify completed and paused variants retain identity,
// their own prepared references and the independent project title across reopen.
@Test(arguments: [false, true])
func projectRetainsNamedPreviewAndStandardVariants(secondPaused: Bool) async throws
{
    let root = try projectStoreTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let files = try EarthAppFiles(storageRootURL: root)
    try await files.initialize()
    let store = EarthProjectStore(files: files)
    let project = try await store.create()
    let origin = try EarthGeographicOrigin(latitude: 0, longitude: 0)
    let location = EarthProjectLocation(address: "613 Race", title: "613 Race", origin: origin)
    let profile = try EarthPreparationProfile(name: "Project preview")
    let previewDraft = EarthProjectDraft(address: location.address, detail: .preview, widthMeters: "200", heightMeters: "200")
    _ = try await store.updateEditor(id: project.id, title: "Race study", draft: previewDraft)
    _ = try await store.recordLocation(id: project.id, location: location)
    let previewURL = try await files.newArtifactDirectory(projectID: project.id, kind: .sources)
    let previewRequest = try EarthDownloadRequest(center: origin, maximumGeometricErrorMeters: 16)
    let previewSource = try await EarthSourceArchive.create(request: previewRequest, directoryURL: previewURL)
    let previewCapture = try EarthProjectCapture(id: #require(UUID(uuidString: previewURL.lastPathComponent)), request: previewRequest)
    _ = try await store.recordCapture(id: project.id, capture: previewCapture, expectedDraft: previewDraft)
    let preview = try await projectSourceFixture(files: files, projectID: project.id, existing: previewSource)
    let previewModelsURL = try await files.newArtifactDirectory(projectID: project.id, kind: .prepared)
    _ = try await EarthModelPreparer().prepare(archive: preview, directoryURL: previewModelsURL, profile: profile)
    let previewPreparation = try EarthProjectPreparation(id: #require(UUID(uuidString: previewModelsURL.lastPathComponent)), captureID: previewCapture.id, profile: profile)
    _ = try await store.recordPreparation(id: project.id, preparation: previewPreparation)
    let sourceIdentity = try await preview.sourceIdentifier()

    let standardDraft = EarthProjectDraft(address: location.address, detail: .standard, widthMeters: "300", heightMeters: "125")
    _ = try await store.updateDraft(id: project.id, draft: standardDraft)
    let standardURL = try await files.newArtifactDirectory(projectID: project.id, kind: .sources)
    let standardRequest = try EarthDownloadRequest(center: origin, widthMeters: 300, depthMeters: 125)
    let standard = try await EarthSourceArchive.create(request: standardRequest, directoryURL: standardURL)
    let standardCapture = try EarthProjectCapture(id: #require(UUID(uuidString: standardURL.lastPathComponent)), request: standardRequest)
    _ = try await store.recordCapture(id: project.id, capture: standardCapture, expectedDraft: standardDraft)
    var standardPreparation: EarthProjectPreparation?
    if !secondPaused
    {
        let completed = try await projectSourceFixture(files: files, projectID: project.id, existing: standard)
        let url = try await files.newArtifactDirectory(projectID: project.id, kind: .prepared)
        _ = try await EarthModelPreparer().prepare(archive: completed, directoryURL: url, profile: profile)
        let preparation = try EarthProjectPreparation(id: #require(UUID(uuidString: url.lastPathComponent)), captureID: standardCapture.id, profile: profile)
        _ = try await store.recordPreparation(id: project.id, preparation: preparation)
        standardPreparation = preparation
    }
    var editedDraft = standardDraft
    editedDraft.address = "Another draft address"
    _ = try await store.updateEditor(id: project.id, title: "Race site", draft: editedDraft)
    let editedLocation = EarthProjectLocation(address: editedDraft.address, title: editedDraft.address, origin: try EarthGeographicOrigin(latitude: 1, longitude: 1))
    _ = try await store.recordLocation(id: project.id, location: editedLocation)
    let reopenedStore = EarthProjectStore(files: files)
    let reopened = try await reopenedStore.open(id: project.id)
    #expect(reopened.record.captures.map(\.id) == [previewCapture.id, standardCapture.id])
    #expect(reopened.record.captures.map(\.draft) == [previewDraft, standardDraft])
    #expect(reopened.record.title == "Race site" && reopened.record.draft == editedDraft)
    #expect(reopened.archive?.state == (secondPaused ? .paused : .downloaded))
    // Card reads are journal-only and cannot mutate selection/editor metadata.
    let statuses = try await reopenedStore.captureStatuses(id: project.id)
    #expect(statuses[previewCapture.id]?.archive?.state == .downloaded)
    #expect(statuses[standardCapture.id]?.archive?.state == (secondPaused ? .paused : .downloaded))
    #expect(try await reopenedStore.record(id: project.id) == reopened.record)
    // Preview and Resume activate exact saved files without replacing the draft
    // or its separately resolved map location. Only Restore changes the editor.
    let openedPreview = try await reopenedStore.selectCapture(id: project.id, captureID: previewCapture.id, restoresEditor: false)
    #expect(openedPreview.prepared?.directoryURL == previewModelsURL)
    #expect(openedPreview.record.draft == editedDraft && openedPreview.record.resolvedLocation == editedLocation)
    #expect(openedPreview.record.title == "Race site")
    let openedStandard = try await reopenedStore.selectCapture(id: project.id, captureID: standardCapture.id, restoresEditor: false)
    #expect(openedStandard.record.draft == editedDraft && openedStandard.record.resolvedLocation == editedLocation)
    #expect(openedStandard.archive?.directoryURL == standardURL && openedStandard.record.currentPreparation == standardPreparation)
    let restoredCurrent = try await reopenedStore.selectCapture(id: project.id, captureID: standardCapture.id, restoresEditor: true)
    #expect(restoredCurrent.record.draft == standardDraft && restoredCurrent.record.title == "Race site")

    let selectedPreview = try await reopenedStore.selectCapture(id: project.id, captureID: previewCapture.id, restoresEditor: true)
    #expect(selectedPreview.record.draft == previewDraft && selectedPreview.record.resolvedLocation == location)
    #expect(selectedPreview.record.title == "Race site" && selectedPreview.prepared?.directoryURL == previewModelsURL)
    let selectedStandard = try await reopenedStore.selectCapture(id: project.id, captureID: standardCapture.id, restoresEditor: true)
    #expect(selectedStandard.record.draft == standardDraft && selectedStandard.record.currentPreparation == standardPreparation)
    #expect(selectedStandard.archive?.directoryURL == standardURL)
    #expect(try await preview.sourceIdentifier() == sourceIdentity)
    await #expect(throws: EarthProjectStoreError.sourceMismatch)
    { try await reopenedStore.recordPreparation(id: project.id, preparation: previewPreparation) }

    let service = EarthProjectCaptureService(
        id: project.id,
        files: files,
        store: reopenedStore,
        lookup: { _ in location },
        acquire: { archive, _, _ in Issue.record("Acquisition entered for an unselected variant."); return archive },
        prepare: { _, _, _ in throw EarthPreparationError.sourceChanged }
    )
    await #expect(throws: EarthProjectStoreError.sourceMismatch)
    { try await service.download(archive: preview, apiKey: "fixture", progress: { _ in }) }
    // A broken inactive variant cannot displace the valid selected capture.
    let before = try await reopenedStore.record(id: project.id)
    try FileManager.default.moveItem(at: previewURL, to: root.appendingPathComponent("retained-preview"))
    let unavailable = try await reopenedStore.captureStatuses(id: project.id)
    #expect(unavailable[previewCapture.id]?.archive == nil && unavailable[previewCapture.id]?.errorMessage != nil)
    #expect(unavailable[standardCapture.id]?.archive?.directoryURL == standardURL)
    await #expect(throws: (any Error).self)
    { try await reopenedStore.selectCapture(id: project.id, captureID: previewCapture.id, restoresEditor: false) }
    #expect(try await reopenedStore.record(id: project.id) == before)
    #expect(try await reopenedStore.open(id: project.id).archive?.directoryURL == standardURL)
}
