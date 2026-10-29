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

private enum ProjectCaptureOutcome: CaseIterable, Sendable { case complete, paused, preparationFailure, replacedSource, noCoverage, detailUnavailable }
private enum ProjectFixtureFailure: Error { case preparation }

// Saved variants survive reopening without transport. Download must activate the
// chosen immutable snapshot without creating another variant or changing a draft.
@Test func projectSavedVariantsDownloadTheirOwnSnapshotAfterOfflineRegistration() async throws
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
        lookup: { _ in throw ProjectFixtureFailure.preparation },
        acquire: { archive, _, _ in
            _ = await counts.transferred()
            return try await projectSourceFixture(files: files, projectID: project.id, existing: archive)
        },
        prepare: { _, _, _ in throw ProjectFixtureFailure.preparation }
    )
    let added = try await store.addLocation(id: project.id, center: EarthGeographicOrigin(latitude: 0, longitude: 0), title: "Saved area")
    let location = try #require(added.editingLocation)
    let first = try await service.start(selection: EarthConfirmedSelection(location: location))
    let firstVariant = try #require(try await store.record(id: project.id).selectedCapture)
    let frozen = try #require(try await store.record(id: project.id).editingLocation)
    let originalSecond = try await service.start(selection: EarthConfirmedSelection(location: frozen))
    let secondVariant = try #require(try await store.record(id: project.id).selectedCapture)
    let originalJournal = originalSecond.directoryURL.appendingPathComponent("acquisition.sqlite")
    let originalBytes = try Data(contentsOf: originalJournal)
    let draft = try await store.addLocation(id: project.id, center: EarthGeographicOrigin(latitude: 40, longitude: -74), title: "Unrelated draft")
    _ = try await store.changeVariantDetail(id: project.id, captureID: secondVariant.id, detail: .preview)
    let changed = try await store.changeVariantDetail(id: project.id, captureID: secondVariant.id, detail: .high)
    let second = try #require(try await store.open(id: project.id).archive)
    #expect(changed.captures.first == firstVariant && changed.selectedCaptureID == secondVariant.id && changed.editingLocation == draft.editingLocation)
    #expect(changed.selectedCapture?.previousCaptures.first == secondVariant.capture)
    #expect(try Data(contentsOf: originalJournal) == originalBytes)
    let reopenedStore = EarthProjectStore(files: files)
    let reopened = try await reopenedStore.open(id: project.id)
    #expect(reopened.status == "Not downloaded" && reopened.record.captures.count == 2)
    #expect(await counts.transfers == 0)
    let statuses = try await reopenedStore.captureStatuses(id: project.id)
    #expect(statuses.values.allSatisfy { $0.title == "Not downloaded" && $0.archive?.sourceRequests == 0 && $0.canChangeDetail })
    #expect(first.request.maximumGeometricErrorMeters == 4 && second.request.maximumGeometricErrorMeters == 1)
    var resized = try #require(reopened.record.locations.first { $0.id == location.id }).edit
    resized.area.widthMeters = "500"
    await #expect(throws: EarthProjectStoreError.frozenLocation)
    { try await reopenedStore.updateEditor(id: project.id, locations: [location.id: resized]) }
    let completedSecond = try await service.download(archive: second, apiKey: "fixture", progress: { _ in })
    #expect(completedSecond.request.maximumGeometricErrorMeters == 1 && completedSecond.state == .downloaded)
    await #expect(throws: EarthProjectStoreError.sourceMismatch)
    { try await service.download(archive: first, apiKey: "fixture", progress: { _ in }) }
    let firstID = try #require(reopened.record.captures.first?.id)
    let selected = try await reopenedStore.selectCapture(id: project.id, captureID: firstID)
    let completed = try await service.download(archive: first, apiKey: "fixture", progress: { _ in })
    #expect(completed.state == .downloaded && completed.request == first.request)
    #expect(await counts.transfers == 2)
    #expect(try await reopenedStore.record(id: project.id) == selected.record)
    #expect(selected.record.editingLocation == draft.editingLocation)
}

private enum VariantDetailLock: CaseIterable, Sendable { case downloading, paused, completed, previousAttempt }

// A current empty retry cannot unlock detail after an earlier acquisition.
// Rejection must preserve both project metadata and the source inventory.
@Test(arguments: VariantDetailLock.allCases)
private func variantDetailLocksWhenAnyAttemptStarts(scenario: VariantDetailLock) async throws
{
    let root = try projectStoreTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let files = try EarthAppFiles(storageRootURL: root)
    try await files.initialize()
    let store = EarthProjectStore(files: files)
    let project = try await store.create()
    let service = EarthProjectCaptureService(
        id: project.id,
        files: files,
        store: store,
        lookup: { _ in throw ProjectFixtureFailure.preparation },
        acquire: { _, _, _ in throw ProjectFixtureFailure.preparation },
        prepare: { _, _, _ in throw ProjectFixtureFailure.preparation }
    )
    let added = try await store.addLocation(id: project.id, center: EarthGeographicOrigin(latitude: 0, longitude: 0), title: "Area")
    let source = try await service.start(selection: EarthConfirmedSelection(location: #require(added.editingLocation)))
    let variant = try #require(try await store.record(id: project.id).selectedCapture)
    if scenario == .completed { _ = try await projectSourceFixture(files: files, projectID: project.id, existing: source) }
    else
    {
        let index = try EarthAcquisitionIndex(directoryURL: source.directoryURL, creating: nil)
        _ = try index.begin(request: source.request)
        if scenario != .downloading
        {
            try index.requestStarted()
            try index.finish(state: .paused, issue: "Fixture pause")
        }
    }
    if scenario == .previousAttempt
    {
        var adjustment = try await store.areaAdjustment(id: project.id, locationID: variant.locationID)
        adjustment.area.widthMeters = "500"
        _ = try await store.applyAreaAdjustment(id: project.id, adjustment: adjustment)
        let retry = try #require(try await store.open(id: project.id).archive)
        #expect(EarthProjectCaptureStatus.isUnstarted(retry))
    }
    let before = try await files.readMetadata(.project(project.id))
    let sourceCount = try await files.artifactDirectories(projectID: project.id, kind: .sources).count
    #expect(try await store.captureStatuses(id: project.id)[variant.id]?.canChangeDetail == false)
    await #expect(throws: EarthProjectStoreError.lockedVariantDetail)
    { try await store.changeVariantDetail(id: project.id, captureID: variant.id, detail: .high) }
    #expect(try await files.readMetadata(.project(project.id)) == before)
    #expect(try await files.artifactDirectories(projectID: project.id, kind: .sources).count == sourceCount)
}

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
            if outcome == .detailUnavailable { throw EarthCaptureError.detailUnavailable }
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
    if outcome == .noCoverage || outcome == .detailUnavailable
    {
        do
        {
            _ = try await service.download(archive: archive, apiKey: "fixture", progress: { _ in })
            Issue.record("Expected the incomplete acquisition to fail.")
        }
        catch let error as EarthCaptureError
        {
            switch error
            {
                case .noCoverage, .detailUnavailable: break
                default: throw error
            }
        }
        let failed = try await store.record(id: project.id)
        let captureID = try #require(failed.currentCapture?.id)
        let journal = archive.directoryURL.appendingPathComponent("acquisition.sqlite")
        let originalBytes = try Data(contentsOf: journal)
        var adjustment = try await store.areaAdjustment(id: project.id, locationID: location.id)
        adjustment.area.widthMeters = "600"
        adjustment.area.heightMeters = "250"
        #expect(try await store.record(id: project.id) == failed)
        _ = try await store.applyAreaAdjustment(id: project.id, adjustment: adjustment)
        let revised = try await EarthProjectStore(files: files).open(id: project.id)
        let retry = try #require(revised.archive)
        #expect(retry.request.widthMeters == 600 && retry.request.depthMeters == 250 && retry.request.maximumGeometricErrorMeters == 1)
        #expect(retry.directoryURL != archive.directoryURL && revised.record.locations.count == 1 && revised.record.captures.count == 1)
        #expect(revised.record.selectedCaptureID == captureID && revised.record.editingLocationID == location.id)
        #expect(revised.record.selectedCapture?.previousCaptures == [try #require(failed.currentCapture)])
        #expect(revised.archive?.request == retry.request && revised.record.currentCapture?.id != captureID)
        let original = try await EarthSourceArchive.open(directoryURL: archive.directoryURL)
        #expect(original.request == selection.request && original.state == .paused && original.downloadedBytes == 0)
        #expect(try Data(contentsOf: journal) == originalBytes)
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

// A shared area edit publishes every pending detail together, preserving
// partial downloads, stable identities and a separate completed location.
@Test func locationAreaAdjustmentUpdatesEveryPendingVariantAndRejectsStaleDrafts() async throws
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
        lookup: { _ in throw ProjectFixtureFailure.preparation },
        acquire: { archive, _, _ in
            _ = await counts.transferred()
            return try await projectSourceFixture(files: files, projectID: project.id, existing: archive)
        },
        prepare: { _, _, _ in throw ProjectFixtureFailure.preparation }
    )
    let added = try await store.addLocation(id: project.id, center: EarthGeographicOrigin(latitude: 0, longitude: 0), title: "Area")
    let initial = try EarthConfirmedSelection(location: #require(added.editingLocation))
    let source = try await service.start(selection: initial)
    _ = try await projectSourceFixture(files: files, projectID: project.id, existing: source, state: .paused)
    let journal = source.directoryURL.appendingPathComponent("acquisition.sqlite")
    let journalBytes = try Data(contentsOf: journal)
    let payload = try #require(FileManager.default.contentsOfDirectory(at: source.directoryURL.appendingPathComponent("tiles"), includingPropertiesForKeys: nil).first)
    let payloadBytes = try Data(contentsOf: payload)
    let location = try #require(try await store.record(id: project.id).editingLocation)
    _ = try await service.start(selection: EarthConfirmedSelection(location: location))
    let target = try #require(try await store.record(id: project.id).selectedCapture)
    _ = try await store.changeVariantDetail(id: project.id, captureID: target.id, detail: .high)
    let otherSource = try await projectSourceFixture(files: files, projectID: project.id, origin: EarthGeographicOrigin(latitude: 40, longitude: -74))
    let before = try await projectRegisterSource(files: files, store: store, projectID: project.id, source: otherSource)
    let expectedVariants = try #require(before.locations.first { $0.id == location.id }).variants
    var adjustment = try await store.areaAdjustment(id: project.id, locationID: location.id)
    adjustment.area.widthMeters = "600"
    adjustment.area.heightMeters = "250"
    adjustment.area.center = try EarthGeographicOrigin(latitude: 1, longitude: 2)
    #expect(try await store.record(id: project.id) == before)
    _ = try await store.applyAreaAdjustment(id: project.id, adjustment: adjustment)
    let revised = try await EarthProjectStore(files: files).open(id: project.id)
    let updated = try #require(revised.record.locations.first { $0.id == location.id })
    #expect(updated.area == adjustment.area && updated.variants.map(\.id) == expectedVariants.map(\.id))
    #expect(revised.record.locations.last == before.locations.last && revised.record.selectedCaptureID == before.selectedCaptureID && revised.record.editingLocationID == before.editingLocationID)
    for (variant, previous) in zip(updated.variants, expectedVariants)
    {
        #expect(variant.capture.request == (try adjustment.area.request(detail: previous.detail)))
        #expect(variant.previousCaptures == previous.previousCaptures + [previous.capture])
        let url = try await files.resolve(reference: variant.capture.reference, projectID: project.id)
        #expect(EarthProjectCaptureStatus.isUnstarted(try await EarthSourceArchive.open(directoryURL: url)))
    }
    #expect(try Data(contentsOf: journal) == journalBytes && Data(contentsOf: payload) == payloadBytes)
    #expect(await counts.transfers == 0)
    let staleMetadata = try await files.readMetadata(.project(project.id))
    let sourceCount = try await files.artifactDirectories(projectID: project.id, kind: .sources).count
    await #expect(throws: EarthProjectStoreError.changedLocation) { try await store.applyAreaAdjustment(id: project.id, adjustment: adjustment) }
    #expect(try await files.readMetadata(.project(project.id)) == staleMetadata)
    #expect(try await files.artifactDirectories(projectID: project.id, kind: .sources).count == sourceCount)
    // One correct sibling cannot make a mixed-area current record valid.
    var mixed = revised.record
    let index = try #require(mixed.locations.firstIndex { $0.id == location.id })
    let variant = updated.variants[0]
    mixed.locations[index].variants[0] = EarthProjectCaptureVariant(
        id: variant.id,
        capture: .init(id: variant.capture.id, request: initial.request),
        locationID: variant.locationID,
        detail: variant.detail,
        createdAt: variant.createdAt,
        previousCaptures: variant.previousCaptures
    )
    #expect(throws: EarthProjectStoreError.invalidRecord) { try mixed.validate(id: project.id) }
    let selected = try await store.selectCapture(id: project.id, captureID: target.id)
    let completed = try await service.download(archive: #require(selected.archive), apiKey: "fixture", progress: { _ in })
    #expect(completed.request == (try adjustment.area.request(detail: .high)))
    await #expect(throws: EarthProjectStoreError.capturedLocation) { try await store.areaAdjustment(id: project.id, locationID: location.id) }
}

private enum AreaCompletion: CaseIterable, Sendable { case current, historical }

@Test(arguments: AreaCompletion.allCases)
private func locationAreaAdjustmentRejectsCompletionAfterDraftBegan(scenario: AreaCompletion) async throws
{
    let root = try projectStoreTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let files = try EarthAppFiles(storageRootURL: root)
    try await files.initialize()
    let store = EarthProjectStore(files: files)
    let project = try await store.create()
    let added = try await store.addLocation(id: project.id, center: EarthGeographicOrigin(latitude: 0, longitude: 0), title: "Area")
    let location = try #require(added.editingLocation)
    let directory = try await files.newArtifactDirectory(projectID: project.id, kind: .sources)
    let source = try await EarthSourceArchive.create(request: location.area.request(detail: .standard), directoryURL: directory)
    _ = try await store.recordCapture(id: project.id, capture: .init(id: #require(UUID(uuidString: directory.lastPathComponent)), request: source.request), selection: EarthConfirmedSelection(location: location))
    var adjustment = try await store.areaAdjustment(id: project.id, locationID: location.id)
    adjustment.area.widthMeters = "600"
    if scenario == .historical
    {
        _ = try await store.applyAreaAdjustment(id: project.id, adjustment: adjustment)
        adjustment = try await store.areaAdjustment(id: project.id, locationID: location.id)
        adjustment.area.widthMeters = "800"
    }
    _ = try await projectSourceFixture(files: files, projectID: project.id, existing: source)
    let before = try await files.readMetadata(.project(project.id))
    let sourceCount = try await files.artifactDirectories(projectID: project.id, kind: .sources).count
    await #expect(throws: EarthProjectStoreError.capturedLocation) { try await store.applyAreaAdjustment(id: project.id, adjustment: adjustment) }
    #expect(try await files.readMetadata(.project(project.id)) == before)
    #expect(try await files.artifactDirectories(projectID: project.id, kind: .sources).count == sourceCount)
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
