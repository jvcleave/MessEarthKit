import Foundation
@testable import MessEarthKit
import Testing

private actor ProjectOperationCounts
{
    var lookups = 0
    var transfers = 0
    func lookedUp() { lookups += 1 }
    func transferred() -> Int { transfers += 1; return transfers }
}

private enum ProjectCaptureOutcome: CaseIterable, Sendable { case complete, paused, preparationFailure, replacedSource, noCoverage }
private enum ProjectFixtureFailure: Error { case preparation }

// Search never acquires; the first exact area freezes before transport and
// remains frozen across pause/failure. Reuse SDK sources and preparation.
@Test(arguments: ProjectCaptureOutcome.allCases)
private func projectLocationFreezesBeforeTransferAndPreparesOffline(outcome: ProjectCaptureOutcome) async throws
{
    let root = try projectStoreTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let files = try EarthAppFiles(storageRootURL: root)
    try await files.initialize()
    let store = EarthProjectStore(files: files)
    let project = try await store.create()
    let counts = ProjectOperationCounts()
    let service = EarthProjectCaptureService(
        id: project.id,
        files: files,
        store: store,
        lookup: { address in
            await counts.lookedUp()
            return .init(address: address, title: address, origin: try EarthGeographicOrigin(latitude: 0, longitude: 0))
        },
        acquire: { archive, _, _ in
            let attempt = await counts.transferred()
            let pinned = try await EarthProjectStore(files: files).open(id: project.id)
            #expect(pinned.archive?.directoryURL == archive.directoryURL && pinned.record.captureLocation?.isFrozen == true)
            if attempt == 1 { #expect(pinned.archive?.state == .paused && pinned.archive?.sourceRequests == 0) }
            if outcome == .paused, attempt == 1 { throw CancellationError() }
            if outcome == .noCoverage { throw EarthCaptureError.noCoverage }
            let completed = try await projectSourceFixture(files: files, projectID: project.id, existing: archive)
            if outcome == .replacedSource
            {
                let url = try await files.newArtifactDirectory(projectID: project.id, kind: .sources)
                let replacement = try await EarthSourceArchive.create(request: archive.request, directoryURL: url)
                _ = try await projectRegisterSource(files: files, store: store, projectID: project.id, source: replacement)
            }
            return completed
        },
        prepare: { archive, profile, progress in
            if outcome == .preparationFailure { throw ProjectFixtureFailure.preparation }
            let url = try await files.newArtifactDirectory(projectID: project.id, kind: .prepared)
            return try await EarthModelPreparer().prepare(archive: archive, directoryURL: url, profile: profile, progress: progress)
        }
    )
    _ = try await store.updateEditor(id: project.id, searchAddress: "613 Race")
    let resolved = try await service.search(address: "613 Race")
    _ = try await service.search(address: "613 Race")
    let lookups = await counts.lookups
    let transfers = await counts.transfers
    #expect(lookups == 1 && transfers == 0)
    #expect(try await store.record(id: project.id).locations.isEmpty)
    let added = try await store.addLocation(id: project.id, center: resolved.origin, title: "Race")
    let location = try #require(added.editingLocation)
    var edit = location.edit
    edit.area.widthMeters = "300"
    edit.area.heightMeters = "125"
    edit.variantDetail = .high
    let updated = try await store.updateEditor(id: project.id, locations: [location.id: edit])
    let selection = try EarthConfirmedSelection(location: #require(updated.editingLocation))
    let archive = try await service.start(selection: selection)
    #expect(archive.request.widthMeters == 300 && archive.request.depthMeters == 125 && archive.request.maximumGeometricErrorMeters == 1)
    #expect(await counts.transfers == 0)
    #expect(try await store.record(id: project.id).locations[0].frozenAt != nil)
    if outcome == .noCoverage
    {
        do
        {
            _ = try await service.download(archive: archive, apiKey: "fixture", progress: { _ in })
            Issue.record("Expected the no-coverage acquisition to fail.")
        }
        catch EarthCaptureError.noCoverage { }
        let failed = try await store.record(id: project.id)
        let captureID = try #require(failed.currentCapture?.id)
        let copied = try await store.copyLocation(id: project.id, locationID: location.id, captureID: captureID)
        let copy = try #require(copied.editingLocation)
        var retryEdit = copy.edit
        retryEdit.area.widthMeters = "600"
        retryEdit.area.heightMeters = "250"
        let edited = try await store.updateEditor(id: project.id, locations: [copy.id: retryEdit])
        let retrySelection = try EarthConfirmedSelection(location: #require(edited.editingLocation))
        let retry = try await service.start(selection: retrySelection)
        #expect(retry.request.widthMeters == 600 && retry.request.depthMeters == 250 && retry.request.maximumGeometricErrorMeters == 1)
        #expect(retry.directoryURL != archive.directoryURL && copied.locations[0] == failed.locations[0])
        #expect(copy.area == selection.area && !copy.isFrozen && copy.variants.isEmpty)
        let original = try await EarthSourceArchive.open(directoryURL: archive.directoryURL)
        #expect(original.request == selection.request && original.state == .paused && original.downloadedBytes == 0)
        #expect(await counts.transfers == 1)
        return
    }
    if outcome == .paused
    {
        await #expect(throws: CancellationError.self) { try await service.download(archive: archive, apiKey: "fixture", progress: { _ in }) }
        // Search and a new location cannot alter the frozen resume request.
        _ = try await store.updateEditor(id: project.id, searchAddress: "New York")
        _ = try await store.addLocation(id: project.id, center: EarthGeographicOrigin(latitude: 40, longitude: -74), title: "New York")
    }
    if outcome == .replacedSource
    {
        await #expect(throws: EarthProjectStoreError.sourceMismatch) { try await service.download(archive: archive, apiKey: "fixture", progress: { _ in }) }
        return
    }
    let completed = try await service.download(archive: archive, apiKey: "fixture", progress: { _ in })
    #expect(completed.request == selection.request)
    if outcome == .preparationFailure
    {
        await #expect(throws: ProjectFixtureFailure.self) { try await service.prepareModels(archive: completed, progress: { _ in }) }
        #expect(try await store.open(id: project.id).archive?.state == .downloaded)
    }
    else
    {
        let result = try await service.prepareModels(archive: completed, progress: { _ in })
        #expect(try await store.open(id: project.id).prepared?.directoryURL == result.directoryURL)
    }
    #expect(try await store.record(id: project.id).locations[0].area == selection.area)
}

@Test func projectRejectsStaleSearchAndChangedLocationBeforeSourceRegistration() async throws
{
    let root = try projectStoreTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let files = try EarthAppFiles(storageRootURL: root)
    try await files.initialize()
    let store = EarthProjectStore(files: files)
    let project = try await store.create()
    let counts = ProjectOperationCounts()
    let origin = try EarthGeographicOrigin(latitude: 0, longitude: 0)
    let service = EarthProjectCaptureService(
        id: project.id,
        files: files,
        store: store,
        lookup: { address in
            await counts.lookedUp()
            _ = try await store.updateEditor(id: project.id, searchAddress: "Changed")
            return .init(address: address, title: address, origin: origin)
        },
        acquire: { archive, _, _ in Issue.record("Unexpected acquisition"); return archive },
        prepare: { _, _, _ in throw ProjectFixtureFailure.preparation }
    )
    _ = try await store.updateEditor(id: project.id, searchAddress: "Original")
    await #expect(throws: EarthProjectStoreError.changedLocation) { try await service.search(address: "Original") }
    let record = try await store.addLocation(id: project.id, center: origin, title: "Draft")
    let location = try #require(record.editingLocation)
    let selection = try EarthConfirmedSelection(location: location)
    var edit = location.edit
    edit.area.widthMeters = ""
    let invalid = try await store.updateEditor(id: project.id, locations: [location.id: edit])
    #expect(throws: EarthProjectCaptureError.invalidInput) { try EarthConfirmedSelection(location: #require(invalid.editingLocation)) }
    await #expect(throws: EarthProjectStoreError.changedLocation) { try await service.start(selection: selection) }
    #expect(try await files.artifactDirectories(projectID: project.id, kind: .sources).isEmpty)
    #expect(try await store.record(id: project.id).locations[0].frozenAt == nil)
    #expect(await counts.transfers == 0)
}

private enum ProjectNavigationChange: CaseIterable, Sendable { case none, back, backThenReturn, otherProject }

@Test(arguments: ProjectNavigationChange.allCases)
@MainActor private func projectCompletionCannotStealNavigation(change: ProjectNavigationChange) throws
{
    let projectID = UUID()
    let navigation = EarthProjectNavigation()
    navigation.path = [.project(projectID)]
    let ticket = try #require(navigation.ticket(route: .project(projectID)))
    switch change
    {
        case .none: break
        case .back: navigation.path.removeLast()
        case .backThenReturn:
            navigation.path.removeLast()
            navigation.path.append(.project(projectID))
        case .otherProject: navigation.path = [.project(UUID())]
    }
    let before = navigation.path
    let advanced = navigation.advance(ticket, to: .preview(projectID))
    #expect(advanced == (change == .none))
    if change != .none { #expect(navigation.path == before) }
}
