import Darwin
import Foundation
import MessEarthKit

do
{
    let capture: EarthCapture
    var savedRoot: URL?
    if CommandLine.arguments.dropFirst().first == "--capture"
    {
        let arguments = CommandLine.arguments
        guard arguments.count == 8,
              let latitude = Double(arguments[2]), let longitude = Double(arguments[3]),
              let width = Double(arguments[4]), let depth = Double(arguments[5]), let error = Double(arguments[6])
        else { throw EarthImportError.invalidContent("Usage: --capture latitude longitude width depth error new-folder; supply the API key on stdin.") }
        let keyData = FileHandle.standardInput.readDataToEndOfFile()
        guard keyData.count <= 4096, let key = String(data: keyData, encoding: .utf8)
        else { throw EarthCaptureError.missingAPIKey }
        let request = try EarthCaptureRequest(center: EarthGeographicOrigin(latitude: latitude, longitude: longitude), widthMeters: width, depthMeters: depth, maximumGeometricErrorMeters: error)
        let destination = URL(fileURLWithPath: arguments[7])
        capture = try await EarthCaptureSession(apiKey: key).capture(request: request, recoveryDirectoryURL: destination)
        { progress in
            let line = "Capture: \(progress.sourceRequests)/\(request.maximumSourceRequests) requests; \(progress.visitedTiles) tiles checked; \(progress.downloadedTiles) downloaded; \(progress.downloadedBytes) bytes\n"
            FileHandle.standardError.write(Data(line.utf8))
        }
        let root = destination.appendingPathComponent("tileset.json")
        let reopened = try await EarthCaptureImporter().importFile(fileURL: root)
        guard reopened.triangleCount == capture.triangleCount,
              reopened.bounds.minimum == capture.bounds.minimum, reopened.bounds.maximum == capture.bounds.maximum
        else { throw EarthImportError.invalidContent("Saved capture did not reproduce its original geometry/bounds.") }
        savedRoot = root
    }
    else
    {
        let sourceURL: URL
        if let path = CommandLine.arguments.dropFirst().first
        {
            sourceURL = URL(fileURLWithPath: path)
        }
        else
        {
            guard let fixtures = Bundle.module.url(forResource: "Fixtures", withExtension: nil)
            else { throw EarthImportError.inaccessibleSource("Bundled reference capture.") }
            sourceURL = fixtures.appendingPathComponent("Orientation/tileset.json")
        }
        capture = try await EarthCaptureImporter().importFile(fileURL: sourceURL)
    }
    var report: [String: Any] = [
        "source": capture.name,
        "meshCount": capture.meshes.count,
        "vertexCount": capture.vertexCount,
        "triangleCount": capture.triangleCount,
        "sourceFileCount": capture.sourceFiles.count,
        "sourceBytes": capture.sourceByteCount,
        "boundsMinimum": [capture.bounds.minimum.x, capture.bounds.minimum.y, capture.bounds.minimum.z],
        "boundsMaximum": [capture.bounds.maximum.x, capture.bounds.maximum.y, capture.bounds.maximum.z],
        "attributions": capture.attributions,
        "isPartial": capture.incompleteReason != nil,
    ]
    if let reason = capture.incompleteReason { report["incompleteReason"] = reason }
    if let savedRoot { report["savedRoot"] = savedRoot.path; report["reopened"] = true }
    let output = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
    print(String(decoding: output, as: UTF8.self))
}
catch
{
    FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
    if CommandLine.arguments.count == 8, CommandLine.arguments[1] == "--capture"
    {
        let root = URL(fileURLWithPath: CommandLine.arguments[7]).appendingPathComponent("tileset.json")
        if FileManager.default.fileExists(atPath: root.path)
        {
            FileHandle.standardError.write(Data("Downloaded sources remain at \(root.path)\n".utf8))
        }
    }
    exit(1)
}
