import Foundation
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
