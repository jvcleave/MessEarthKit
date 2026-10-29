import Foundation
@testable import MessEarthKit
import simd
import Testing

@Test func compressedReferenceMatchesIndependentUncompressedBox() async throws
{
    let directory = try #require(Bundle.module.url(forResource: "Fixtures", withExtension: nil)).appendingPathComponent("DracoBox")
    let importer = EarthCaptureImporter()
    let compressed = try await importer.importFile(fileURL: directory.appendingPathComponent("BoxDraco.glb"))
    let reference = try await importer.importFile(fileURL: directory.appendingPathComponent("Box.glb"))
    #expect(compressed.triangleCount == reference.triangleCount)
    #expect(simd_distance(compressed.bounds.minimum, reference.bounds.minimum) < 0.002)
    #expect(simd_distance(compressed.bounds.maximum, reference.bounds.maximum) < 0.002)
    let normals = try #require(compressed.meshes.first).vertices.map(\.normal)
    #expect(normals.allSatisfy { abs(simd_length($0) - 1) < 0.0001 })
    let referenceNormals = try #require(reference.meshes.first).vertices.map(\.normal)
    // Draco quantizes directions. Compare against the independent reference
    // within an angular tolerance rather than requiring identical float bits.
    #expect(normals.allSatisfy { normal in referenceNormals.contains { simd_dot(normal, $0) > 0.9999 } })
    #expect(referenceNormals.allSatisfy { normal in normals.contains { simd_dot(normal, $0) > 0.9999 } })
}

@Test func encodedDracoAdmissionUsesTopologyRatherThanAccessorDeclarations() throws
{
    let url = try #require(Bundle.module.url(forResource: "Fixtures", withExtension: nil)).appendingPathComponent("DracoBox/BoxDraco.glb")
    let data = try Data(contentsOf: url)
    let json = try EarthGLBDecoder(limits: EarthImportLimits()).preflight(data: data)
    let mesh = try #require((json["meshes"] as? [[String: Any]])?.first)
    let primitive = try #require((mesh["primitives"] as? [[String: Any]])?.first)
    let ext = try #require((primitive["extensions"] as? [String: Any])?["KHR_draco_mesh_compression"] as? [String: Any])
    let viewIndex = try #require(ext["bufferView"] as? Int)
    let views = try #require(json["bufferViews"] as? [[String: Any]])
    let offset = try #require(views[viewIndex]["byteOffset"] as? Int)
    let length = try #require(views[viewIndex]["byteLength"] as? Int)
    let jsonLength = Int(data.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: 12, as: UInt32.self)) })
    let encoded = data.subdata(in: 28 + jsonLength + offset ..< 28 + jsonLength + offset + length)
    try EarthDracoAdmission.inspect(data: encoded)
    var withMetadata = encoded
    withMetadata[10] |= 128
    withMetadata.insert(contentsOf: [0, 0, 0], at: 11) // No attribute metadata; empty geometry metadata.
    try EarthDracoAdmission.inspect(data: withMetadata)
    #expect(throws: EarthImportError.self) { try EarthDracoAdmission.inspect(data: encoded, maximumPoints: 1) }
    #expect(throws: EarthImportError.self) { try EarthDracoAdmission.inspect(data: encoded, maximumFaces: 1) }
    // A topology prefix claiming >2M points is rejected before decoding any
    // connectivity/attribute data, regardless of a small glTF POSITION count.
    var hostile = Data("DRACO".utf8)
    hostile.append(contentsOf: [2, 2, 1, 0, 0, 0, 1]) // v2.2 sequential, one face
    var points: UInt32 = 2000001
    repeat
    {
        let next = UInt8(points & 127)
        points >>= 7
        hostile.append(next | (points == 0 ? 0 : 128))
    }
    while points != 0
    do
    {
        try EarthDracoAdmission.inspect(data: hostile)
        Issue.record("Oversized encoded topology was admitted.")
    }
    catch EarthImportError.limitExceeded {}
    #expect(throws: EarthImportError.self) { try EarthDracoAdmission.inspect(data: Data(encoded.prefix(8))) }
    var metadata = Data("DRACO".utf8)
    metadata.append(contentsOf: [2, 2, 1, 0, 0, 128, 255, 255, 255, 255, 15])
    #expect(throws: EarthImportError.self) { try EarthDracoAdmission.inspect(data: metadata) }
    // Even a small POSITION declaration cannot bypass the encoded-count gate
    // before GLTFKit2 loads this deliberately incomplete compressed payload.
    var changed = data
    let begin = 28 + jsonLength + offset
    changed.replaceSubrange(begin ..< begin + hostile.count, with: hostile)
    do
    {
        _ = try EarthGLBDecoder(limits: EarthImportLimits()).decode(data: changed, transform: matrix_identity_double4x4)
        Issue.record("The decoder reached an oversized bitstream.")
    }
    catch EarthImportError.limitExceeded {}
}
