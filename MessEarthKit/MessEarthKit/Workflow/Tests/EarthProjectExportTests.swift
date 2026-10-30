import Foundation
@testable import MessEarthKit
import Testing

private func projectExportService(files: EarthAppFiles, store: EarthProjectStore, projectID: UUID) -> EarthProjectExportService
{
    EarthProjectExportService(projectID: projectID, files: files, store: store, prepare: { archive, profile, progress in
        let directory = try await files.newArtifactDirectory(projectID: projectID, kind: .prepared)
        return try await EarthModelPreparer().prepare(archive: archive, directoryURL: directory, profile: profile, progress: progress)
    })
}

@MainActor private func settleExport(_ export: EarthProjectExportViewModel) async throws
{
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(10))
    while export.isBusy || export.isLoadingHistory, clock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
    try #require(!export.isBusy && !export.isLoadingHistory)
}

private enum ProjectExportChoice: CaseIterable, Sendable
{
    case full, untextured, minimal, custom
}

// Existing authored fixture covers naming, exact identity and shared placement.
// Exercise preset/dependency choices through the real job and immutable output;
// changing controls mid-job and cancellation cannot alter the published export.
@Test(arguments: ProjectExportChoice.allCases)
@MainActor private func projectExportPreservesNamedCaptureAndOptions(choice: ProjectExportChoice) async throws
{
    let root = try projectStoreTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let files = try EarthAppFiles(storageRootURL: root)
    try await files.initialize()
    let store = EarthProjectStore(files: files)
    let project = try await store.create()
    let center = try EarthGeographicOrigin(latitude: 41.87811347, longitude: -87.62980539, ellipsoidHeight: 123.456789)
    let raw = try await projectSourceFixture(files: files, projectID: project.id, placements: 3, origin: center)
    let registered = try await projectRegisterSource(files: files, store: store, projectID: project.id, source: raw)
    let variantID = try #require(registered.selectedCaptureID)
    let capture = try #require(registered.currentCapture)
    let locationID = try #require(registered.editingLocationID)
    var edit = try #require(registered.editingLocation).edit
    edit.title = "Chicago / Downtown · 41.87811, -87.62981"
    _ = try await store.updateEditor(id: project.id, locations: [locationID: edit])
    let directory = try await files.newArtifactDirectory(projectID: project.id, kind: .prepared)
    let profile = try EarthPreparationProfile(maximumPlacementsPerModel: 1)
    let collection = try await EarthModelPreparer().prepare(archive: raw, directoryURL: directory, profile: profile)
    _ = try await store.recordPreparation(id: project.id, variantID: variantID, preparation: .init(
        id: #require(UUID(uuidString: directory.lastPathComponent)),
        captureID: capture.id,
        profile: profile
    ))
    let other = try await projectSourceFixture(files: files, projectID: project.id)
    let record = try await projectRegisterSource(files: files, store: store, projectID: project.id, source: other)
    let otherID = try #require(record.selectedCaptureID)
    let original = try Data(contentsOf: #require(collection.rootSourceURL))
    let service = projectExportService(files: files, store: store, projectID: project.id)
    let export = EarthProjectExportViewModel(service: service)
    switch choice
    {
        case .full: export.setPreset(.full, variantID: variantID)
        case .untextured: export.setPreset(.untextured, variantID: variantID)
        case .minimal: export.setPreset(.minimal, variantID: variantID)
        case .custom:
            export.setPreset(.minimal, variantID: variantID)
            export.setOption(.textures, included: true, variantID: variantID)
            export.setOption(.materials, included: false, variantID: variantID)
            #expect(!export.options(for: variantID).includeTextures)
            export.setOption(.textures, included: true, variantID: variantID)
            export.setOption(.textureCoordinates, included: false, variantID: variantID)
            #expect(!export.options(for: variantID).includeTextures)
            export.setOption(.textures, included: true, variantID: variantID)
    }
    let options: EarthGLBExportOptions
    switch choice
    {
        case .full: options = .full
        case .untextured: options = .untextured
        case .minimal: options = .minimal
        case .custom: options = .init(includeNormals: false, includeVertexColors: false)
    }
    #expect(export.options(for: otherID) == .full)
    export.export(variantID: variantID, saveEdits: {}, onFinished: {})
    export.setOption(.normals, included: !options.includeNormals, variantID: variantID)
    #expect(export.isLoading && export.options(for: variantID) == options)
    try await settleExport(export)
    try #require(export.errorMessage == nil && export.historyError == nil)
    let item = try #require(export.exports(for: variantID).first)
    let saved = item.record
    let target = try await files.exportFileURL(projectID: project.id, record: saved)
    #expect(item.fileIsAvailable && saved.source == capture && saved.includeTextures == options.includeTextures)
    #expect(export.exports(for: otherID).isEmpty)
    let suffix: String
    switch choice
    {
        case .full: suffix = "_geom_norm_vcol_uv_mat_tex"
        case .untextured: suffix = "_geom_norm_vcol_uv_mat"
        case .minimal: suffix = "_geom"
        case .custom: suffix = "_geom_uv_mat_tex"
    }
    #expect(target.lastPathComponent == "Chicago_Downtown_41.87811_-87.62981_Standard\(suffix).glb")
    let info = try EarthGLBInfo.decode(Data(contentsOf: EarthGLBInfo.companionURL(target)))
    #expect(info.name == edit.title && info.geometry.triangleCount == 42 && info.exportOptions == options)
    let output = try await files.projectLocations(id: project.id).outputURL
    #expect(target.deletingLastPathComponent().deletingLastPathComponent() == output)
    let imported = try await EarthCaptureImporter().importFile(fileURL: target)
    #expect(imported.name == edit.title && imported.triangleCount == 42)
    if options.includeTextures { #expect(imported.materials.contains { $0.baseColorTexture != nil }) }
    else { #expect(imported.materials.allSatisfy { $0.baseColorTexture == nil }) }
    #expect(imported.identity == (try EarthCaptureIdentity(locationName: edit.title, request: raw.request, detailName: "standard")))
    let json = try EarthGLBDecoder(limits: EarthImportLimits()).preflight(data: Data(contentsOf: target))
    let extras = try #require(json["extras"] as? [String: Any])
    let recordedOptions = try JSONSerialization.data(withJSONObject: #require(extras["messEarthKitExportOptions"]))
    #expect(try JSONDecoder().decode(EarthGLBExportOptions.self, from: recordedOptions) == options)
    let scenes = try #require(json["scenes"] as? [[String: Any]])
    let roots = try #require(scenes[0]["nodes"] as? [Int])
    let nodes = try #require(json["nodes"] as? [[String: Any]])
    #expect(scenes[0]["name"] as? String == edit.title && nodes[roots[0]]["name"] as? String == edit.title)
    #expect(abs(imported.bounds.maximum.x - 25) < 0.001)
    let publishedBytes = try Data(contentsOf: target)
    let cancelled = Task
    {
        try await service.export(variantID: variantID, options: .untextured)
        { progress in
            if case let .exporting(value) = progress, value.phase == .writing, value.completedModels == 1
            { withUnsafeCurrentTask { $0?.cancel() } }
        }
    }
    await #expect(throws: CancellationError.self) { try await cancelled.value }
    let retained = try await files.artifactDirectories(projectID: project.id, kind: .output)
    #expect(retained.map { $0.url.resolvingSymlinksInPath() } == [target.deletingLastPathComponent().resolvingSymlinksInPath()])
    let reopened = projectExportService(files: files, store: EarthProjectStore(files: files), projectID: project.id)
    #expect(try await reopened.exports().map(\.record) == [saved])
    #expect(try Data(contentsOf: target) == publishedBytes)
    #expect(try await store.record(id: project.id) == record)
    #expect(try Data(contentsOf: #require(collection.rootSourceURL)) == original)
}

// Missing preparation must be recorded on the requested variant without moving
// selection. Repeated exports remain separate and missing files retain provenance.
@Test @MainActor func projectExportPreparesVariantOfflineAndRestoresSeparateHistories() async throws
{
    let root = try projectStoreTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let files = try EarthAppFiles(storageRootURL: root)
    try await files.initialize()
    let store = EarthProjectStore(files: files)
    let project = try await store.create()
    let rawA = try await projectSourceFixture(files: files, projectID: project.id)
    let first = try await projectRegisterSource(files: files, store: store, projectID: project.id, source: rawA)
    let a = try #require(first.selectedCaptureID)
    let rawB = try await projectSourceFixture(files: files, projectID: project.id)
    let before = try await projectRegisterSource(files: files, store: store, projectID: project.id, source: rawB)
    let b = try #require(before.selectedCaptureID)
    let service = projectExportService(files: files, store: store, projectID: project.id)
    #expect(try await files.readMetadata(.exports(project.id)) == nil)
    let initial = try await service.export(variantID: a, options: .full, progress: { _ in })
    let prepared = try await store.record(id: project.id)
    #expect(prepared.selectedCaptureID == b && prepared.editingLocationID == before.editingLocationID)
    #expect(prepared.captures.first { $0.id == a }?.preparation == initial.output.preparation)
    #expect(prepared.captures.first { $0.id == b }?.preparation == nil)
    let again = try await service.export(variantID: a, options: .untextured, progress: { _ in })
    #expect(again.output.id != initial.output.id && again.output.preparation == initial.output.preparation)
    #expect(try await store.record(id: project.id) == prepared)
    let other = try await service.export(variantID: b, options: .untextured, progress: { _ in })
    let restored = EarthProjectExportViewModel(service: projectExportService(files: files, store: EarthProjectStore(files: files), projectID: project.id))
    restored.reloadHistory()
    try await settleExport(restored)
    #expect(restored.historyError == nil && Set(restored.exports(for: a).map(\.id)) == [initial.output.id, again.output.id])
    #expect(restored.exports(for: b).map(\.id) == [other.output.id])
    try FileManager.default.removeItem(at: initial.fileURL)
    restored.reloadHistory()
    try await settleExport(restored)
    #expect(restored.history.count == 3 && restored.history.first { $0.id == initial.output.id }?.fileIsAvailable == false)
    #expect(restored.history.filter(\.fileIsAvailable).count == 2)
}

private enum ExportHistoryCorruption: CaseIterable, Sendable { case malformed, version, project }

// Pending names/areas must save before any source lookup or output publication.
@Test @MainActor func projectExportStopsWhenPendingEditsCannotBeSaved() async throws
{
    let root = try projectStoreTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let files = try EarthAppFiles(storageRootURL: root)
    try await files.initialize()
    let store = EarthProjectStore(files: files)
    let project = try await store.create()
    let export = EarthProjectExportViewModel(service: projectExportService(files: files, store: store, projectID: project.id))
    var finished = false
    export.export(variantID: UUID(), saveEdits: { throw EarthAppFilesError.storage }, onFinished: { finished = true })
    try await settleExport(export)
    #expect(finished && export.errorMessage == EarthAppFilesError.storage.localizedDescription)
    #expect(try await files.readMetadata(.exports(project.id)) == nil)
    #expect(try await files.artifactDirectories(projectID: project.id, kind: .output).isEmpty)
}

// Independent history must reject corruption without erasing it or adopting
// untracked output folders; a bad history blocks export before file publication.
@Test(arguments: ExportHistoryCorruption.allCases)
private func projectExportRejectsInvalidHistoryWithoutReplacement(corruption: ExportHistoryCorruption) async throws
{
    let root = try projectStoreTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let files = try EarthAppFiles(storageRootURL: root)
    try await files.initialize()
    let store = EarthProjectStore(files: files)
    let project = try await store.create()
    let data: Data
    switch corruption
    {
        case .malformed: data = Data("{".utf8)
        case .version: data = try JSONSerialization.data(withJSONObject: ["version": 2, "projectID": project.id.uuidString, "exports": []])
        case .project: data = try JSONSerialization.data(withJSONObject: ["version": 1, "projectID": UUID().uuidString, "exports": []])
    }
    try await files.writeMetadata(data, location: .exports(project.id))
    let service = projectExportService(files: files, store: store, projectID: project.id)
    await #expect(throws: EarthAppFilesError.invalidMetadata) { try await service.exports() }
    await #expect(throws: EarthAppFilesError.invalidMetadata) { try await service.export(variantID: UUID(), options: .full, progress: { _ in }) }
    #expect(try await files.readMetadata(.exports(project.id)) == data)
    #expect(try await files.artifactDirectories(projectID: project.id, kind: .output).isEmpty)
}

// Publication and metadata are separate atomic writes. A late metadata failure
// must retain the completed GLB and report it explicitly rather than claim success.
@Test private func projectExportRetainsPublishedFileWhenHistoryCannotBeSaved() async throws
{
    let root = try projectStoreTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let files = try EarthAppFiles(storageRootURL: root)
    try await files.initialize()
    let store = EarthProjectStore(files: files)
    let project = try await store.create()
    let raw = try await projectSourceFixture(files: files, projectID: project.id)
    let registered = try await projectRegisterSource(files: files, store: store, projectID: project.id, source: raw)
    let variantID = try #require(registered.selectedCaptureID)
    let metadataURL = try await files.projectLocations(id: project.id).directoryURL.appendingPathComponent("exports.json")
    let damaged = Data("{".utf8)
    let service = projectExportService(files: files, store: store, projectID: project.id)
    do
    {
        _ = try await service.export(variantID: variantID, options: .untextured)
        { progress in
            if case let .exporting(value) = progress, value.phase == .writing, value.completedModels == 1
            {
                do { try damaged.write(to: metadataURL) }
                catch { Issue.record("Could not install the local metadata-failure fixture.") }
            }
        }
        Issue.record("Expected explicit history-persistence failure.")
    }
    catch let EarthProjectExportError.historyNotSaved(record, _)
    {
        let url = try await files.exportFileURL(projectID: project.id, record: record)
        #expect(try await files.exportFileIsAvailable(projectID: project.id, record: record))
        let imported = try await EarthCaptureImporter().importFile(fileURL: url)
        #expect(imported.identity?.request == raw.request)
        #expect(try await files.readMetadata(.exports(project.id)) == damaged)
    }
}

// Renaming preserves immutable bytes/provenance and survives reopening. Reject
// traversal/collisions and roll back both files when history cannot be written.
@Test @MainActor private func projectExportRenamePreservesCompanionAndRollsBackFailure() async throws
{
    let root = try projectStoreTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let files = try EarthAppFiles(storageRootURL: root)
    try await files.initialize()
    let store = EarthProjectStore(files: files)
    let project = try await store.create()
    let raw = try await projectSourceFixture(files: files, projectID: project.id)
    let registered = try await projectRegisterSource(files: files, store: store, projectID: project.id, source: raw)
    let service = projectExportService(files: files, store: store, projectID: project.id)
    let result = try await service.export(variantID: #require(registered.selectedCaptureID), options: .untextured, progress: { _ in })
    let before = try await store.record(id: project.id)
    let metadata = try #require(try await files.readMetadata(.exports(project.id)))
    let bytes = try Data(contentsOf: result.fileURL)
    let infoBytes = try Data(contentsOf: EarthGLBInfo.companionURL(result.fileURL))
    await #expect(throws: EarthAppFilesError.invalidExportName)
    { try await service.rename(result.output, to: "../Escaping") }
    let collision = result.fileURL.deletingLastPathComponent().appendingPathComponent("Existing.glb.info.json")
    try infoBytes.write(to: collision)
    await #expect(throws: EarthAppFilesError.invalidLocation)
    { try await service.rename(result.output, to: "Existing") }
    #expect(try Data(contentsOf: collision) == infoBytes)
    await #expect(throws: EarthAppFilesError.invalidMetadata)
    {
        try await files.renameExport(projectID: project.id, record: result.output, name: "Rolled back", originalMetadata: metadata, updatedMetadata: Data())
    }
    #expect(try await files.readMetadata(.exports(project.id)) == metadata)
    #expect(try Data(contentsOf: result.fileURL) == bytes)
    #expect(try Data(contentsOf: EarthGLBInfo.companionURL(result.fileURL)) == infoBytes)
    let export = EarthProjectExportViewModel(service: service)
    export.rename(result.output, to: "City Model.GLB")
    #expect(export.isBusy && export.isManagingHistory)
    // A second action cannot act on stale history while the first is pending.
    export.delete(result.output)
    try await settleExport(export)
    try #require(export.managementError == nil && export.historyError == nil)
    let renamed = try #require(export.history.first?.record)
    var expected = result.output
    expected.fileName = "City Model.glb"
    #expect(renamed == expected)
    #expect(!FileManager.default.fileExists(atPath: result.fileURL.path))
    let finalItems = try await service.rename(renamed, to: "city model")
    let final = try #require(finalItems.first?.record)
    let target = try await files.exportFileURL(projectID: project.id, record: final)
    #expect(final.fileName == "city model.glb")
    #expect(try FileManager.default.contentsOfDirectory(atPath: target.deletingLastPathComponent().path).contains(final.fileName))
    #expect(try Data(contentsOf: target) == bytes)
    #expect(try Data(contentsOf: EarthGLBInfo.companionURL(target)) == infoBytes)
    try FileManager.default.removeItem(at: EarthGLBInfo.companionURL(target))
    let withoutCompanion = try #require(try await service.rename(final, to: "Without companion").first?.record)
    let withoutCompanionURL = try await files.exportFileURL(projectID: project.id, record: withoutCompanion)
    #expect(try Data(contentsOf: withoutCompanionURL) == bytes)
    #expect(!FileManager.default.fileExists(atPath: EarthGLBInfo.companionURL(withoutCompanionURL).path))
    let reopened = projectExportService(files: files, store: EarthProjectStore(files: files), projectID: project.id)
    #expect(try await reopened.exports().map(\.record) == [withoutCompanion])
    #expect(try await store.record(id: project.id) == before)
}

private enum ExportDeletionCase: CaseIterable, Sendable { case available, missing, trashFailure, escapingOutput }

// Use an injected Trash destination, never the user's Trash. Scope is one
// output folder; failure restores history, and missing folders stay absent.
@Test(arguments: ExportDeletionCase.allCases)
@MainActor private func projectExportDeletionPreservesVariantAndOtherExports(scenario: ExportDeletionCase) async throws
{
    let root = try projectStoreTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let trash = root.appendingPathComponent("Trash", isDirectory: true)
    let files = try EarthAppFiles(storageRootURL: root.appendingPathComponent("App", isDirectory: true), trash: { url in
        if scenario == .trashFailure { throw EarthAppFilesError.storage }
        try FileManager.default.moveItem(at: url, to: trash)
    })
    try await files.initialize()
    let store = EarthProjectStore(files: files)
    let project = try await store.create()
    let raw = try await projectSourceFixture(files: files, projectID: project.id)
    let registered = try await projectRegisterSource(files: files, store: store, projectID: project.id, source: raw)
    let service = projectExportService(files: files, store: store, projectID: project.id)
    let variantID = try #require(registered.selectedCaptureID)
    let removed = try await service.export(variantID: variantID, options: .untextured, progress: { _ in })
    let retained = try await service.export(variantID: variantID, options: .minimal, progress: { _ in })
    let before = try await store.record(id: project.id)
    let sourceBytes = try Data(contentsOf: #require(raw.rootSourceURL))
    let retainedBytes = try Data(contentsOf: retained.fileURL)
    let removedBytes = try Data(contentsOf: removed.fileURL)
    let infoBytes = try Data(contentsOf: EarthGLBInfo.companionURL(removed.fileURL))
    let metadata = try await files.readMetadata(.exports(project.id))
    let folder = removed.fileURL.deletingLastPathComponent()
    if scenario == .missing { try FileManager.default.removeItem(at: folder) }
    if scenario == .escapingOutput
    {
        let external = root.appendingPathComponent("External")
        try FileManager.default.moveItem(at: folder, to: external)
        try FileManager.default.createSymbolicLink(at: folder, withDestinationURL: external)
        await #expect(throws: EarthAppFilesError.invalidLocation) { try await service.delete(removed.output) }
        #expect(try await files.readMetadata(.exports(project.id)) == metadata)
        #expect(try Data(contentsOf: external.appendingPathComponent(removed.output.fileName)) == removedBytes)
    }
    else
    {
        let export = EarthProjectExportViewModel(service: service)
        export.delete(removed.output)
        #expect(export.isBusy)
        try await settleExport(export)
        if scenario == .trashFailure
        {
            #expect(export.managementError == EarthAppFilesError.storage.localizedDescription)
            #expect(try await files.readMetadata(.exports(project.id)) == metadata)
            #expect(try Data(contentsOf: removed.fileURL) == removedBytes)
            #expect(try Data(contentsOf: EarthGLBInfo.companionURL(removed.fileURL)) == infoBytes)
        }
        else
        {
            #expect(export.managementError == nil && export.history.map(\.record) == [retained.output])
            #expect(!FileManager.default.fileExists(atPath: folder.path))
            let reopened = projectExportService(files: files, store: EarthProjectStore(files: files), projectID: project.id)
            #expect(try await reopened.exports().map(\.record) == [retained.output])
            if scenario == .available
            {
                #expect(try Data(contentsOf: trash.appendingPathComponent(removed.output.fileName)) == removedBytes)
                #expect(try Data(contentsOf: EarthGLBInfo.companionURL(trash.appendingPathComponent(removed.output.fileName))) == infoBytes)
            }
        }
    }
    #expect(try Data(contentsOf: retained.fileURL) == retainedBytes)
    #expect(try Data(contentsOf: #require(raw.rootSourceURL)) == sourceBytes)
    #expect(try await store.record(id: project.id) == before)
}
