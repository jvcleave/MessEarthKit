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

private enum ProjectCaptureOutcome: CaseIterable, Sendable { case complete, paused, preparationFailure, replacedSource }
private enum ProjectFixtureFailure: Error { case preparation }

// Wiring risks: map confirmation cannot enter Google transport; source identity
// must be durable before transport and survive pause; preparation is independent
// of successful acquisition. Reuse existing authored geometry and SDK workers.
@Test(arguments: ProjectCaptureOutcome.allCases)
private func projectMapConfirmationPinsSourceBeforeTransferAndPreparesOffline(outcome: ProjectCaptureOutcome) async throws
{
    let root = try projectStoreTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let files = try EarthAppFiles(storageRootURL: root)
    try await files.initialize()
    let store = EarthProjectStore(files: files)
    let project = try await store.create()
    var draft = project.draft
    draft.address = "613 Race"
    _ = try await store.updateDraft(id: project.id, draft: draft)
    let counts = ProjectOperationCounts()
    let service = EarthProjectCaptureService(
        id: project.id,
        files: files,
        store: store,
        lookup: { address in
            await counts.lookedUp()
            return try .init(address: address, title: address, origin: EarthGeographicOrigin(latitude: 0, longitude: 0))
        },
        acquire: { archive, _, _ in
            let attempt = await counts.transferred()
            let pinned = try await EarthProjectStore(files: files).open(id: project.id)
            #expect(pinned.archive?.directoryURL == archive.directoryURL)
            if attempt == 1 { #expect(pinned.archive?.state == .paused && pinned.archive?.sourceRequests == 0) }
            if outcome == .paused, attempt == 1 { throw CancellationError() }
            let completed = try await projectSourceFixture(files: files, projectID: project.id, existing: archive)
            if outcome == .replacedSource
            {
                let url = try await files.newArtifactDirectory(projectID: project.id, kind: .sources)
                let replacement = try await EarthSourceArchive.create(request: archive.request, directoryURL: url)
                _ = try await store.recordCapture(id: project.id, capture: .init(id: #require(UUID(uuidString: url.lastPathComponent)), request: replacement.request))
            }
            return completed
        },
        prepare: { archive, profile, progress in
            if outcome == .preparationFailure { throw ProjectFixtureFailure.preparation }
            let url = try await files.newArtifactDirectory(projectID: project.id, kind: .prepared)
            return try await EarthModelPreparer().prepare(archive: archive, directoryURL: url, profile: profile, progress: progress)
        }
    )
    let resolved = try await service.confirm(draft: draft)
    _ = try await service.confirm(draft: draft)
    // Editing dimensions/detail beside the map reuses the resolved address
    // immediately. Download must freeze the edited selection, not the old area.
    draft.widthMeters = "300"
    draft.heightMeters = "125"
    draft.detail = .high
    _ = try await store.updateDraft(id: project.id, draft: draft)
    let selection = try EarthConfirmedSelection(draft: draft, location: resolved.location)
    let lookups = await counts.lookups
    let transfers = await counts.transfers
    #expect(lookups == 1 && transfers == 0)
    #expect(try await store.record(id: project.id).currentCapture == nil)
    let archive = try await service.start(selection: selection)
    #expect(archive.request.widthMeters == 300 && archive.request.depthMeters == 125 && archive.request.maximumGeometricErrorMeters == 1)
    #expect(await counts.transfers == 0)
    if outcome == .paused
    {
        await #expect(throws: CancellationError.self) { try await service.download(archive: archive, apiKey: "fixture", progress: { _ in }) }
        #expect(try await store.open(id: project.id).archive?.state == .paused)
        // A card's Resume keeps its frozen High request even while the editor
        // holds a different capture draft.
        draft.detail = .preview
        draft.widthMeters = "500"
        _ = try await store.updateDraft(id: project.id, draft: draft)
    }
    if outcome == .replacedSource
    {
        await #expect(throws: EarthProjectStoreError.sourceMismatch) { try await service.download(archive: archive, apiKey: "fixture", progress: { _ in }) }
        #expect(try await store.open(id: project.id).archive?.directoryURL != archive.directoryURL)
        return
    }
    let completed = try await service.download(archive: archive, apiKey: "fixture", progress: { _ in })
    if outcome == .paused
    {
        #expect(completed.request == selection.request)
        #expect(try await store.record(id: project.id).draft == draft)
    }
    let attempts = await counts.transfers
    if outcome == .preparationFailure
    {
        await #expect(throws: ProjectFixtureFailure.self) { try await service.prepareModels(archive: completed, progress: { _ in }) }
        let retained = try await store.open(id: project.id)
        #expect(retained.archive?.state == .downloaded && retained.record.currentPreparation == nil)
    }
    else
    {
        let result = try await service.prepareModels(archive: completed, progress: { _ in })
        let reopened = try await EarthProjectStore(files: files).open(id: project.id)
        #expect(reopened.prepared?.directoryURL == result.directoryURL && reopened.status == "Ready")
    }
    #expect(await counts.transfers == attempts)
}

@Test func projectConfirmationRejectsInvalidOrChangedDraftBeforeSourceCreation() async throws
{
    let root = try projectStoreTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let files = try EarthAppFiles(storageRootURL: root)
    try await files.initialize()
    let store = EarthProjectStore(files: files)
    let project = try await store.create()
    var draft = project.draft
    draft.address = "613 Race"
    draft.widthMeters = ""
    _ = try await store.updateDraft(id: project.id, draft: draft)
    let counts = ProjectOperationCounts()
    let service = EarthProjectCaptureService(
        id: project.id,
        files: files,
        store: store,
        lookup: { address in
            await counts.lookedUp()
            // Simulate editing a field while this address request was suspended.
            var changed = try await store.record(id: project.id).draft
            changed.address = "Changed"
            _ = try await store.updateDraft(id: project.id, draft: changed)
            return try .init(address: address, title: address, origin: EarthGeographicOrigin(latitude: 0, longitude: 0))
        },
        acquire: { archive, _, _ in archive },
        prepare: { _, _, _ in throw ProjectFixtureFailure.preparation }
    )
    await #expect(throws: EarthProjectCaptureError.self) { try await service.confirm(draft: draft) }
    #expect(await counts.lookups == 0)
    draft.widthMeters = "200"
    _ = try await store.updateDraft(id: project.id, draft: draft)
    let previousLocation = try EarthProjectLocation(address: draft.address, title: draft.address, origin: EarthGeographicOrigin(latitude: 0, longitude: 0))
    var editedAddress = draft
    editedAddress.address = "A different address"
    #expect(throws: EarthProjectCaptureError.self) { try EarthConfirmedSelection(draft: editedAddress, location: previousLocation) }
    var incompleteDimensions = draft
    incompleteDimensions.widthMeters = ""
    #expect(throws: EarthProjectCaptureError.self) { try EarthConfirmedSelection(draft: incompleteDimensions, location: previousLocation) }
    await #expect(throws: EarthProjectCaptureError.self) { try await service.confirm(draft: draft) }
    #expect(try await store.record(id: project.id).resolvedLocation == nil)
    #expect(try await files.artifactDirectories(projectID: project.id, kind: .sources).isEmpty)
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
