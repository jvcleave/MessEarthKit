import Foundation
import MessEarthKit
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
