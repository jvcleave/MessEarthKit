import Foundation
import MessEarthKit
import Testing

private func appFilesTestRoot() throws -> URL
{
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    return root
}

// Distinct risks: atomic replacement cannot destroy an existing manifest on
// admission failure; SDK destinations must not be precreated; IDs cannot cross
// project/kind boundaries. No decoder or SQLite implementation is repeated here.
@Test func appFilesMetadataAndArtifactPublicationBoundaries() async throws
{
    let root = try appFilesTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let files = try EarthAppFiles(storageRootURL: root.appendingPathComponent("managed"))
    try await files.initialize()
    let id = UUID()
    #expect(try await files.readMetadata(.settings) == nil)
    await #expect(throws: EarthAppFilesError.missingFile) { try await files.readMetadata(.project(id)) }
    let metadata = Data("{\"version\":1,\"name\":\"613 Race\"}".utf8)
    try await files.writeMetadata(metadata, location: .project(id))
    let reopened = try EarthAppFiles(storageRootURL: files.storageRootURL)
    #expect(try await reopened.readMetadata(.project(id)) == metadata)
    await #expect(throws: EarthAppFilesError.invalidMetadata)
    { try await files.writeMetadata(Data(repeating: 0, count: EarthAppFiles.maximumMetadataBytes + 1), location: .project(id)) }
    #expect(try await files.readMetadata(.project(id)) == metadata)
    let prepared = try await files.newArtifactDirectory(projectID: id, kind: .prepared)
    #expect(!FileManager.default.fileExists(atPath: prepared.path))
    #expect(FileManager.default.fileExists(atPath: prepared.deletingLastPathComponent().path))
    try await files.validateArtifactDirectory(prepared, projectID: id, kind: .prepared)
    await #expect(throws: EarthAppFilesError.invalidLocation) { try await files.accessForExport(prepared) }
    await #expect(throws: EarthAppFilesError.invalidLocation)
    { try await files.validateArtifactDirectory(prepared, projectID: UUID(), kind: .prepared) }
    await #expect(throws: EarthAppFilesError.invalidLocation)
    { try await files.validateArtifactDirectory(prepared, projectID: id, kind: .sources) }
    // Invalid existing metadata must be reported, never replaced by defaults.
    let manifest = try await files.projectLocations(id: id).manifestURL
    try Data().write(to: manifest)
    await #expect(throws: EarthAppFilesError.invalidMetadata) { try await files.readMetadata(.project(id)) }
    #expect(try Data(contentsOf: manifest).isEmpty)
}

@Test func appFilesRejectEscapesLinksAndUnusableRoot() async throws
{
    let root = try appFilesTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let files = try EarthAppFiles(storageRootURL: root.appendingPathComponent("managed"))
    let id = UUID()
    try await files.initialize()
    for reference in ["../other/project.json", "/outside/project.json", "sources/../../escape", "sources//part", "sources/./part"]
    {
        await #expect(throws: EarthAppFilesError.invalidLocation) { try await files.resolve(reference: reference, projectID: id) }
    }
    try await files.writeMetadata(Data("{}".utf8), location: .project(id))
    let outside = root.appendingPathComponent("outside", isDirectory: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
    let project = try await files.projectLocations(id: id)
    try FileManager.default.createSymbolicLink(at: project.sourcesURL, withDestinationURL: outside)
    await #expect(throws: EarthAppFilesError.invalidLocation) { try await files.newArtifactDirectory(projectID: id, kind: .sources) }
    #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
    let database = try await files.requestUsageURL()
    let sidecar = URL(fileURLWithPath: database.path + "-wal")
    try FileManager.default.createSymbolicLink(at: sidecar, withDestinationURL: outside)
    await #expect(throws: EarthAppFilesError.invalidLocation) { try await files.requestUsageURL() }
    let invalidRoot = root.appendingPathComponent("file")
    try Data([1]).write(to: invalidRoot)
    let blocked = try EarthAppFiles(storageRootURL: invalidRoot)
    await #expect(throws: EarthAppFilesError.invalidLocation) { try await blocked.initialize() }
}

@Test func appFilesAccessIsLimitedToTheAuthorizedLocation() async throws
{
    let root = try appFilesTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let files = try EarthAppFiles(storageRootURL: root.appendingPathComponent("managed"))
    try await files.initialize()
    let external = root.appendingPathComponent("external", isDirectory: true)
    try FileManager.default.createDirectory(at: external, withIntermediateDirectories: false)
    let marker = external.appendingPathComponent("preparation.sqlite")
    try Data([1]).write(to: marker)
    let access = try await files.accessForReading(external)
    #expect(try await files.isPreparedCollection(directoryURL: external, access: access))
    await #expect(throws: EarthAppFilesError.invalidLocation)
    { try await files.isPreparedCollection(directoryURL: root, access: access) }
    let fileAccess = try await files.accessForReading(marker)
    #expect(try await !files.isPreparedCollection(directoryURL: marker, access: fileAccess))
    // An external directory lease cannot follow a marker out of its tree.
    try FileManager.default.removeItem(at: marker)
    let other = root.appendingPathComponent("other.sqlite")
    try Data([2]).write(to: other)
    try FileManager.default.createSymbolicLink(at: marker, withDestinationURL: other)
    await #expect(throws: EarthAppFilesError.invalidLocation)
    { try await files.isPreparedCollection(directoryURL: external, access: access) }
    let output = external.appendingPathComponent("new.glb")
    let exportAccess = try await files.accessForExport(output)
    #expect(exportAccess.url == output && !FileManager.default.fileExists(atPath: output.path))
    await #expect(throws: EarthAppFilesError.invalidLocation) { try await files.accessForExport(other) }
    #expect(try Data(contentsOf: other) == Data([2]))
}

// Relocation must preserve arbitrary payload bytes and database state, reopen
// through the saved bookmark, and keep originals on failure/cancellation.
@Test(arguments: [false, true]) func appFilesMovesLibraryAndReopensSelectedStorage(cancelAfterCommit: Bool) async throws
{
    let parent = try appFilesTestRoot()
    defer { try? FileManager.default.removeItem(at: parent) }
    let original = parent.appendingPathComponent("original"), destination = parent.appendingPathComponent("destination")
    let selection = parent.appendingPathComponent("preferences/location.json")
    let files = try EarthAppFiles(storageRootURL: original)
    try await files.initialize()
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
    let store = EarthProjectStore(files: files)
    let projectID = try await store.create().id
    let raw = try await projectSourceFixture(files: files, projectID: projectID)
    let registered = try await projectRegisterSource(files: files, store: store, projectID: projectID, source: raw)
    let variantID = try #require(registered.selectedCaptureID)
    let service = EarthProjectExportService(projectID: projectID, files: files, store: store, prepare: { archive, profile, progress in
        try await EarthModelPreparer().prepare(archive: archive, directoryURL: files.newArtifactDirectory(projectID: projectID, kind: .prepared), profile: profile, progress: progress)
    })
    let delivered = try await service.export(variantID: variantID, options: .init(includeNormals: false), progress: { _ in })
    let deliveredBytes = try Data(contentsOf: delivered.fileURL)
    let metadata = try #require(try await files.readMetadata(.project(projectID)))
    let settingsData = try JSONEncoder().encode(EarthAppSettings.initial)
    try await files.writeMetadata(settingsData, location: .settings)
    let queueData = Data("{\"version\":1,\"entries\":[]}".utf8)
    try await files.writeMetadata(queueData, location: .exportQueue)
    let payload = Data((0 ..< 4096).map { UInt8($0 % 251) })
    let export = try await files.newArtifactDirectory(projectID: projectID, kind: .output)
    try FileManager.default.createDirectory(at: export, withIntermediateDirectories: false)
    try payload.write(to: export.appendingPathComponent("model.glb"))
    let usage = EarthRequestUsageStore(fileURL: try await files.requestUsageURL())
    await usage.record(.started(id: UUID(), kind: .tile, at: Date()))
    await usage.close()
    let move = Task
    {
        try await files.moveStorage(to: destination, selectionFile: selection, progress: { status in
            if cancelAfterCommit, status == "Removing previous storage copies…" { withUnsafeCurrentTask { $0?.cancel() } }
        })
    }
    let moved = try await move.value
    #expect(moved.oldCopiesRemain == cancelAfterCommit)
    #expect(FileManager.default.fileExists(atPath: original.appendingPathComponent("projects").path) == cancelAfterCommit)
    await #expect(throws: EarthStorageMoveError.self) { try await files.writeMetadata(metadata, location: .settings) }
    let reopened = try await EarthAppFiles.openStorage(defaultRoot: original, selectionFile: selection)
    #expect(reopened.storageRootURL.resolvingSymlinksInPath() == destination.resolvingSymlinksInPath())
    #expect(try await reopened.readMetadata(.project(projectID)) == metadata)
    #expect(try await reopened.readMetadata(.settings) == settingsData)
    #expect(try await reopened.readMetadata(.exportQueue) == queueData)
    let output = try await reopened.artifactDirectories(projectID: projectID, kind: .output)
    let retained = try #require(output.first { $0.url.lastPathComponent == export.lastPathComponent })
    #expect(try Data(contentsOf: retained.url.appendingPathComponent("model.glb")) == payload)
    let opened = try await EarthProjectStore(files: reopened).openVariant(id: projectID, variantID: variantID)
    #expect(opened.archive.request == raw.request && opened.prepared?.state == .ready)
    let prepared = try #require(opened.prepared)
    #expect(try await prepared.importModel(id: 1).triangleCount == 14)
    let history = try await EarthProjectExportHistoryStore(projectID: projectID, files: reopened).records()
    #expect(history == [delivered.output])
    let movedExport = try await reopened.exportFileURL(projectID: projectID, record: delivered.output)
    #expect(try Data(contentsOf: movedExport) == deliveredBytes)
    let restoredUsage = EarthRequestUsageStore(fileURL: try await reopened.requestUsageURL())
    #expect(await restoredUsage.snapshot().tileRequests == 1)
    await restoredUsage.close()
    try FileManager.default.removeItem(at: destination)
    await #expect(throws: (any Error).self) { try await EarthAppFiles.openStorage(defaultRoot: original, selectionFile: selection) }
    #expect(FileManager.default.fileExists(atPath: original.appendingPathComponent("projects").path) == cancelAfterCommit)
}

@Test(arguments: [false, true]) func appFilesFailedOrCancelledMoveKeepsOriginals(cancel: Bool) async throws
{
    let parent = try appFilesTestRoot()
    defer { try? FileManager.default.removeItem(at: parent) }
    let files = try EarthAppFiles(storageRootURL: parent.appendingPathComponent("original"))
    try await files.initialize()
    let metadata = Data("{\"retained\":true}".utf8)
    try await files.writeMetadata(metadata, location: .settings)
    let destination = parent.appendingPathComponent("destination")
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
    // A file cannot be the parent of a preferences file: fail after copy/verify.
    let blocked = parent.appendingPathComponent("blocked")
    try Data([1]).write(to: blocked)
    let task = Task
    {
        try await files.moveStorage(to: destination, selectionFile: blocked.appendingPathComponent("location.json"), progress: { _ in
            if cancel { withUnsafeCurrentTask { $0?.cancel() } }
        })
    }
    await #expect(throws: (any Error).self) { try await task.value }
    #expect(try await files.readMetadata(.settings) == metadata)
    #expect(try FileManager.default.contentsOfDirectory(at: destination, includingPropertiesForKeys: nil).isEmpty)
    #expect(try Data(contentsOf: blocked) == Data([1]))
}

@Test func appFilesRejectsStorageOverlapOccupiedFoldersAndLinkedPayloads() async throws
{
    let parent = try appFilesTestRoot()
    defer { try? FileManager.default.removeItem(at: parent) }
    let files = try EarthAppFiles(storageRootURL: parent.appendingPathComponent("original"))
    try await files.initialize()
    let selection = parent.appendingPathComponent("location.json")
    let nested = files.storageRootURL.appendingPathComponent("nested")
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: false)
    await #expect(throws: EarthStorageMoveError.self) { try await files.moveStorage(to: nested, selectionFile: selection, progress: { _ in }) }
    let destination = parent.appendingPathComponent("destination")
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
    let marker = destination.appendingPathComponent("existing")
    try Data([2]).write(to: marker)
    await #expect(throws: EarthStorageMoveError.self) { try await files.moveStorage(to: destination, selectionFile: selection, progress: { _ in }) }
    #expect(try Data(contentsOf: marker) == Data([2]))
    try FileManager.default.removeItem(at: marker)
    let project = try await files.projectLocations(id: UUID())
    try FileManager.default.createSymbolicLink(at: project.directoryURL, withDestinationURL: parent)
    await #expect(throws: EarthStorageMoveError.self) { try await files.moveStorage(to: destination, selectionFile: selection, progress: { _ in }) }
    #expect(!FileManager.default.fileExists(atPath: selection.path))
    #expect(try FileManager.default.contentsOfDirectory(at: destination, includingPropertiesForKeys: nil).isEmpty)
}

@Test func appFilesRejectsInvalidStorageSelectionWithoutDefaultFallback() async throws
{
    let parent = try appFilesTestRoot()
    defer { try? FileManager.default.removeItem(at: parent) }
    let selection = parent.appendingPathComponent("location.json"), unused = parent.appendingPathComponent("unused-default")
    try Data("{".utf8).write(to: selection)
    await #expect(throws: (any Error).self) { try await EarthAppFiles.openStorage(defaultRoot: unused, selectionFile: selection) }
    #expect(!FileManager.default.fileExists(atPath: unused.path))
    try FileManager.default.removeItem(at: selection)
    try FileManager.default.createSymbolicLink(at: selection, withDestinationURL: parent.appendingPathComponent("missing"))
    await #expect(throws: (any Error).self) { try await EarthAppFiles.openStorage(defaultRoot: unused, selectionFile: selection) }
    #expect(!FileManager.default.fileExists(atPath: unused.path))
}
