import Foundation
@testable import MessEarthKit
import Testing

private func projectDeletionTestFiles(root: URL, rejectsTrash: Bool) throws -> (files: EarthAppFiles, trash: URL)
{
    let trash = root.appendingPathComponent("Trash", isDirectory: true)
    try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: false)
    let files = try EarthAppFiles(storageRootURL: root.appendingPathComponent("App", isDirectory: true), trash: { url in
        if rejectsTrash { throw EarthAppFilesError.storage }
        try FileManager.default.moveItem(at: url, to: trash.appendingPathComponent(url.lastPathComponent, isDirectory: true))
    })
    return (files, trash)
}

// Deletion risks: scope must stay inside the confirmed project, queued/late
// writes cannot recreate it, and a rejected Trash operation must retain access.
@Test(arguments: [false, true])
private func projectDeletionRetainsGlobalFilesAndPreventsResurrection(rejectsTrash: Bool) async throws
{
    let root = try projectStoreTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let context = try projectDeletionTestFiles(root: root, rejectsTrash: rejectsTrash)
    let files = context.files
    try await files.initialize()
    let store = EarthProjectStore(files: files)
    let project = try await store.create()
    let other = try await store.create()
    let settingsStore = EarthAppSettingsStore(files: files)
    try await settingsStore.save(settingsStore.load())
    let settings = try await files.readMetadata(.settings)
    let usageURL = try await files.requestUsageURL()
    let usage = Data("retained usage".utf8)
    try usage.write(to: usageURL)
    var directories: [URL] = []
    for kind in [EarthProjectArtifact.sources, .prepared, .output]
    {
        let url = try await files.newArtifactDirectory(projectID: project.id, kind: kind)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        try Data([1, 2, 3]).write(to: url.appendingPathComponent("fixture"))
        directories.append(url)
    }
    let projectURL = try await files.projectLocations(id: project.id).directoryURL
    let edit = Task { try await store.updateTitle(id: project.id, title: "Pending save") }
    let deletion = Task { try await store.deleteProject(id: project.id) }
    _ = await edit.result
    if rejectsTrash
    {
        await #expect(throws: EarthAppFilesError.storage) { try await deletion.value }
        #expect(directories.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        #expect(try await store.updateTitle(id: project.id, title: "Still editable").title == "Still editable")
    }
    else
    {
        try await deletion.value
        #expect(!FileManager.default.fileExists(atPath: projectURL.path))
        let trashed = context.trash.appendingPathComponent(project.id.uuidString)
        #expect(FileManager.default.fileExists(atPath: trashed.appendingPathComponent("project.json").path))
        for directory in directories
        {
            let relative = directory.pathComponents.dropFirst(projectURL.pathComponents.count).joined(separator: "/")
            #expect(try Data(contentsOf: trashed.appendingPathComponent(relative).appendingPathComponent("fixture")) == Data([1, 2, 3]))
        }
        await #expect(throws: EarthAppFilesError.missingFile) { try await store.updateTitle(id: project.id, title: "Late save") }
        await #expect(throws: EarthAppFilesError.missingFile) { try await EarthProjectStore(files: files).updateDraft(id: project.id, draft: .empty) }
        #expect(try await files.projectIDs() == [other.id])
    }
    #expect(try await store.record(id: other.id) == other)
    #expect(try await files.readMetadata(.settings) == settings)
    #expect(try Data(contentsOf: usageURL) == usage)
}

private enum VariantDeletionCase: CaseIterable, Sendable { case inactive, active, trashFailure, escapingSource }

// Reuse the authored source/preparer to verify source/prepared ownership,
// retained editor/location, active/last selection and metadata/file rollback.
@Test(arguments: VariantDeletionCase.allCases)
private func variantDeletionKeepsOtherCapturesAndRollsBackFailure(scenario: VariantDeletionCase) async throws
{
    let root = try projectStoreTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let context = try projectDeletionTestFiles(root: root, rejectsTrash: scenario == .trashFailure)
    let files = context.files
    try await files.initialize()
    let store = EarthProjectStore(files: files)
    let project = try await store.create()
    let origin = try EarthGeographicOrigin(latitude: 0, longitude: 0)
    let location = EarthProjectLocation(address: "Fixture address", title: "Fixture", origin: origin)
    let profile = try EarthPreparationProfile(name: "Project preview")
    for detail in [EarthProjectDetail.preview, .high]
    {
        let draft = EarthProjectDraft(address: location.address, detail: detail, widthMeters: "200", heightMeters: "200")
        _ = try await store.updateEditor(id: project.id, title: "Deletion study", draft: draft)
        _ = try await store.recordLocation(id: project.id, location: location)
        let url = try await files.newArtifactDirectory(projectID: project.id, kind: .sources)
        let source = try await EarthSourceArchive.create(request: EarthDownloadRequest(center: origin, maximumGeometricErrorMeters: detail.errorMeters), directoryURL: url)
        let capture = try EarthProjectCapture(id: #require(UUID(uuidString: url.lastPathComponent)), request: source.request)
        _ = try await store.recordCapture(id: project.id, capture: capture)
        let completed = try await projectSourceFixture(files: files, projectID: project.id, existing: source)
        let preparedURL = try await files.newArtifactDirectory(projectID: project.id, kind: .prepared)
        _ = try await EarthModelPreparer().prepare(archive: completed, directoryURL: preparedURL, profile: profile)
        let preparation = try EarthProjectPreparation(id: #require(UUID(uuidString: preparedURL.lastPathComponent)), captureID: capture.id, profile: profile)
        _ = try await store.recordPreparation(id: project.id, preparation: preparation)
    }
    var edited = try await store.record(id: project.id).draft
    edited.widthMeters = "500"
    _ = try await store.updateDraft(id: project.id, draft: edited)
    let before = try await store.record(id: project.id)
    let metadata = try await files.readMetadata(.project(project.id))
    let removesInactive = scenario == .inactive || scenario == .escapingSource
    let removed = before.captures[removesInactive ? 0 : 1]
    let retained = before.captures[removesInactive ? 1 : 0]
    let sourceURL = try await files.resolve(reference: removed.capture.reference, projectID: project.id)
    let preparedURL = try await files.resolve(reference: #require(removed.preparation?.reference), projectID: project.id)
    if scenario == .escapingSource
    {
        let external = root.appendingPathComponent("Retained source")
        try FileManager.default.moveItem(at: sourceURL, to: external)
        try FileManager.default.createSymbolicLink(at: sourceURL, withDestinationURL: external)
        await #expect(throws: EarthAppFilesError.invalidLocation) { try await store.deleteCapture(id: project.id, captureID: removed.id) }
        #expect(try await files.readMetadata(.project(project.id)) == metadata)
        #expect(FileManager.default.fileExists(atPath: external.appendingPathComponent("tileset.json").path))
        #expect(FileManager.default.fileExists(atPath: preparedURL.path))
    }
    else if scenario == .trashFailure
    {
        await #expect(throws: EarthAppFilesError.storage) { try await store.deleteCapture(id: project.id, captureID: removed.id) }
        #expect(try await files.readMetadata(.project(project.id)) == metadata)
        #expect(try await store.record(id: project.id) == before)
        #expect(FileManager.default.fileExists(atPath: sourceURL.path) && FileManager.default.fileExists(atPath: preparedURL.path))
        #expect(try await store.open(id: project.id).status == "Ready")
    }
    else
    {
        let updated = try await store.deleteCapture(id: project.id, captureID: removed.id)
        #expect(updated.captures == [retained] && updated.selectedCaptureID == retained.id)
        #expect(updated.title == before.title && updated.draft == before.draft && updated.resolvedLocation == before.resolvedLocation)
        #expect(!FileManager.default.fileExists(atPath: sourceURL.path) && !FileManager.default.fileExists(atPath: preparedURL.path))
        let bundles = try FileManager.default.contentsOfDirectory(at: context.trash, includingPropertiesForKeys: nil)
        let bundle = try #require(bundles.first)
        #expect(FileManager.default.fileExists(atPath: bundle.appendingPathComponent("sources-\(removed.id.uuidString)").path))
        #expect(FileManager.default.fileExists(atPath: bundle.appendingPathComponent("prepared-\(try #require(removed.preparation?.id).uuidString)").path))
        let reopened = try await EarthProjectStore(files: files).open(id: project.id)
        #expect(reopened.record.currentPreparation == retained.preparation && reopened.status == "Ready")
        if scenario == .active
        {
            _ = try await store.deleteCapture(id: project.id, captureID: retained.id)
            let empty = try await EarthProjectStore(files: files).open(id: project.id)
            #expect(empty.record.captures.isEmpty && empty.record.selectedCaptureID == nil && empty.status == "Draft")
            #expect(empty.record.draft == edited && empty.record.title == before.title)
        }
    }
}
