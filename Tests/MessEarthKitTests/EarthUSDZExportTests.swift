import Foundation
import ImageIO
@testable import MessEarthKit
import ModelIO
import simd
import Testing

@Test func usdzStoresBinaryGeometryIdentityAndPublishesWithoutChangingSources() async throws
{
    let parent = try preparationParent()
    defer { try? FileManager.default.removeItem(at: parent) }
    let raw = try preparationArchive(parent: parent, count: 2)
    let profile = try EarthPreparationProfile(maximumPlacementsPerModel: 1)
    let collection = try await EarthModelPreparer().prepare(archive: raw, directoryURL: parent.appendingPathComponent("prepared"), profile: profile)
    let exporter = EarthUSDZExporter()
    let identity = try EarthCaptureIdentity(locationName: "Export fixture", request: raw.request, detailName: "standard")
    let plan = try await exporter.preflight(collection: collection, destination: EarthPreparationProfile(), options: .untextured, identity: identity)
    #expect(plan.canExport)
    let first = try await collection.importModel(id: 1)
    let before = EarthGLBExporter.fingerprint(first)
    let result = try await exporter.export(plan: plan, fileURL: parent.appendingPathComponent("model.usdz"))
    #expect(result.triangleCount == 28)
    #expect(result.byteCount == (try Data(contentsOf: result.fileURL)).count)
    let info = try #require(await exporter.metadata(fileURL: result.fileURL))
    #expect(info.geographicOrigin == raw.request.center && info.captureIdentity == identity)
    #expect(info.options == .untextured && info.optimization == nil)
    #expect(try EarthGLBExporter.fingerprint(await collection.importModel(id: 1)) == before)
    try inspectUSDZ(result.fileURL)
    let asset = MDLAsset(url: result.fileURL)
    var triangles = 0
    func visit(_ object: MDLObject)
    {
        if let mesh = object as? MDLMesh, let parts = mesh.submeshes as? [MDLSubmesh]
        { for part in parts { triangles += part.indexCount / 3 } }
        for child in object.children.objects { visit(child) }
    }
    for index in 0 ..< asset.count { visit(asset.object(at: index)) }
    #expect(triangles == 28)
    let bytes = try Data(contentsOf: result.fileURL)
    var cursor = 0, members = 0, binary = 0
    while cursor + 30 <= bytes.count
    {
        func u32(_ offset: Int) -> UInt32 { bytes.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self)) } }
        func u16(_ offset: Int) -> UInt16 { bytes.withUnsafeBytes { UInt16(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt16.self)) } }
        if u32(cursor) != 0x04034B50 { break }
        let size = Int(u32(cursor + 18)), nameLength = Int(u16(cursor + 26)), extra = Int(u16(cursor + 28))
        let name = String(decoding: bytes[(cursor + 30) ..< (cursor + 30 + nameLength)], as: UTF8.self)
        let start = cursor + 30 + nameLength + extra
        #expect(start.isMultiple(of: 64) && u16(cursor + 8) == 0)
        if name.hasSuffix(".usdc") { #expect(String(decoding: bytes[start ..< start + 8], as: UTF8.self) == "PXR-USDC"); binary += 1 }
        members += 1; cursor = start + size
    }
    #expect(binary == 2 && members == 5)
    await #expect(throws: EarthUSDZExportError.invalidDestination) { try await exporter.export(plan: plan, fileURL: result.fileURL) }
}

@Test func meshOptimizationReducesGridWithinErrorAndKeepsTransparentTriangleOrder() throws
{
    var vertices: [EarthVertex] = []
    var indices: [UInt32] = []
    let size = 8
    for y in 0 ... size { for x in 0 ... size { vertices.append(EarthVertex(position: SIMD3(Float(x), Float(y), 0), normal: SIMD3(0, 0, 1), textureCoordinate: SIMD2(Float(x) / 8, Float(y) / 8), color: SIMD4(repeating: 1))) } }
    for y in 0 ..< size { for x in 0 ..< size { let a = UInt32(y * (size + 1) + x); indices += [a, a + 1, a + UInt32(size + 1), a + 1, a + UInt32(size + 2), a + UInt32(size + 1)] } }
    let source = EarthMesh(id: 1, name: "Grid", vertices: vertices, triangleIndices: indices, materialIndex: 0)
    let profile = try EarthMeshOptimizationProfile(triangleFraction: 0.5, maximumErrorMeters: 0.1)
    for alpha in [EarthAlphaMode.opaque, .blend]
    {
        let material = EarthMaterial(name: "Grid", baseColor: SIMD4(repeating: 1), baseColorTexture: nil, metallic: 0, roughness: 1, isUnlit: true, isDoubleSided: false, alphaMode: alpha, alphaCutoff: 0.5)
        let result = try EarthMeshOptimization.optimize(source, material: material, options: .full, profile: profile)
        #expect(result.error <= 0.1)
        if alpha == .opaque
        {
            #expect(result.mesh.triangleIndices.count < indices.count)
            let border = Set(vertices.filter { $0.position.x == 0 || $0.position.y == 0 || $0.position.x == 8 || $0.position.y == 8 }.map(\.position))
            #expect(border.isSubset(of: Set(result.mesh.vertices.map(\.position))))
        }
        else
        {
            let before = indices.map { vertices[Int($0)].position }
            let after = result.mesh.triangleIndices.map { result.mesh.vertices[Int($0)].position }
            #expect(after == before)
        }
    }
}

private enum OptimizationChannel: CaseIterable
{
    case normals, textureCoordinates, vertexColors

    var keyPath: WritableKeyPath<EarthExportOptions, Bool>
    {
        switch self
        {
            case .normals: \.includeNormals
            case .textureCoordinates: \.includeTextureCoordinates
            case .vertexColors: \.includeVertexColors
        }
    }
}

@Test(arguments: OptimizationChannel.allCases)
private func meshOptimizationIgnoresOmittedChannelsAndProtectsSelectedSeams(channel: OptimizationChannel) throws
{
    var vertices: [EarthVertex] = []
    let size = 8
    for y in 0 ..< size
    { for x in 0 ..< size
        {
            let corners = [SIMD2(x, y), SIMD2(x + 1, y), SIMD2(x, y + 1), SIMD2(x + 1, y), SIMD2(x + 1, y + 1), SIMD2(x, y + 1)]
            for corner in corners
            {
                let face = vertices.count / 3
                let value = Float(face) / Float(size * size * 2)
                let normal = channel == .normals ? simd_normalize(SIMD3(value, 1, 1)) : SIMD3<Float>(0, 0, 1)
                let uv = SIMD2(Float(corner.x), Float(corner.y)) / Float(size)
                vertices.append(EarthVertex(
                    position: SIMD3(Float(corner.x), Float(corner.y), 0),
                    normal: normal,
                    textureCoordinate: channel == .textureCoordinates ? uv + SIMD2(Float(face), 0) : uv,
                    color: channel == .vertexColors ? SIMD4(value, 0.25, 0.5, 1) : SIMD4(repeating: 1)
                ))
            }
        }
    }
    let indices = vertices.indices.map { UInt32($0) }
    let mesh = EarthMesh(id: 1, name: "Attribute seams", vertices: vertices, triangleIndices: indices, materialIndex: 0)
    let material = EarthMaterial(name: "Opaque", baseColor: SIMD4(repeating: 1), baseColorTexture: nil, metallic: 0, roughness: 1, isUnlit: true, isDoubleSided: false, alphaMode: .opaque, alphaCutoff: 0.5)
    let profile = try EarthMeshOptimizationProfile(triangleFraction: 0.5, maximumErrorMeters: 0.1)
    var options = EarthExportOptions.untextured
    let selected = try EarthMeshOptimization.optimize(mesh, material: material, options: options, profile: profile)
    options[keyPath: channel.keyPath] = false
    let omitted = try EarthMeshOptimization.optimize(mesh, material: material, options: options, profile: profile)
    #expect(omitted.mesh.triangleIndices.count <= indices.count / 2)
    #expect(selected.mesh.triangleIndices.count > omitted.mesh.triangleIndices.count)
}

@Test func meshOptimizationRemovesOnlyExactZeroAreaOutputAndRejectsEmptyGeometry() throws
{
    let positions: [SIMD3<Float>] = [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(2, 0, 0), SIMD3(0, 0, 1), SIMD3(1e-10, 0, 1), SIMD3(0, 1e-10, 1)]
    let vertices = positions.map { EarthVertex(position: $0, normal: SIMD3(0, 0, 1), textureCoordinate: .zero, color: SIMD4(repeating: 1)) }
    let mesh = EarthMesh(id: 1, name: "Collinear and tiny faces", vertices: vertices, triangleIndices: [0, 1, 2, 3, 4, 5], materialIndex: 0)
    let material = EarthMaterial(name: "Opaque", baseColor: SIMD4(repeating: 1), baseColorTexture: nil, metallic: 0, roughness: 1, isUnlit: true, isDoubleSided: false, alphaMode: .opaque, alphaCutoff: 0.5)
    let profile = try EarthMeshOptimizationProfile(triangleFraction: 0.5, maximumErrorMeters: 0.1)
    let result = try EarthMeshOptimization.optimize(mesh, material: material, options: .minimal, profile: profile)
    #expect(result.mesh.triangleIndices.map { result.mesh.vertices[Int($0)].position } == Array(positions.suffix(3)))
    let empty = EarthMesh(id: mesh.id, name: mesh.name, vertices: Array(vertices.prefix(3)), triangleIndices: [0, 1, 2], materialIndex: 0)
    #expect(throws: EarthMeshOptimizationError.failed)
    { try EarthMeshOptimization.optimize(empty, material: material, options: .minimal, profile: profile) }
}

// The optional workspace inspector exercises the separately built bundled
// OpenUSD importer. Ordinary standalone tests need no sibling checkout/tool.
private func inspectUSDZ(_ url: URL) throws
{
    if let executable = ProcessInfo.processInfo.environment["MESS_USDZ_INSPECTOR"]
    {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["--maps", url.path]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        #expect(process.terminationStatus == 0, "Independent USD import: \(text)")
    }
}

@Test func usdzPreservesTexturedVertexAlphaUnlitAndSampling() async throws
{
    let parent = try preparationParent()
    defer { try? FileManager.default.removeItem(at: parent) }
    let (varyingMesh, sourceMaterial) = try textureFixture(sampling: .mixedAxes)
    let mesh = EarthMesh(
        id: varyingMesh.id,
        name: varyingMesh.name,
        vertices: varyingMesh.vertices.map { EarthVertex(position: $0.position, normal: $0.normal, textureCoordinate: $0.textureCoordinate, color: SIMD4(0.25, 0.5, 0.5, 0.75)) },
        triangleIndices: varyingMesh.triangleIndices,
        materialIndex: 0
    )
    let material = EarthMaterial(name: "Map appearance", baseColor: sourceMaterial.baseColor, baseColorTexture: sourceMaterial.baseColorTexture, metallic: 0, roughness: 1, isUnlit: true, isDoubleSided: true, alphaMode: .blend, alphaCutoff: 0.5)
    let source = try EarthDerivativeGLB.encode(vertices: mesh.vertices, indices: mesh.triangleIndices, material: material, name: "Map appearance", attributions: ["Locally authored fixture"], sourceID: "authored")
    let raw = try preparationArchive(parent: parent, count: 1, sourceOverride: source)
    let profile = try EarthPreparationProfile()
    let collection = try await EarthModelPreparer().prepare(archive: raw, directoryURL: parent.appendingPathComponent("prepared"), profile: profile)
    let exporter = EarthUSDZExporter()
    for options in [EarthExportOptions.full, .untextured, .minimal]
    {
        let plan = try await exporter.preflight(collection: collection, destination: profile, options: options)
        #expect(plan.canExport)
        let url = parent.appendingPathComponent(options == .full ? "appearance.usdz" : options == .untextured ? "untextured.usdz" : "geometry.usdz")
        let result = try await exporter.export(plan: plan, fileURL: url)
        #expect(result.triangleCount == 2)
        try inspectUSDZ(url)
        let decoded = try await EarthUSDZExportReader().read(fileURL: url)
        #expect(decoded.triangleCount == 2)
        if options == .full
        {
            let restored = try #require(decoded.materials.first)
            #expect(restored.isUnlit && restored.alphaMode == .blend && restored.baseColor == material.baseColor)
            #expect(restored.baseColorTexture?.encodedImage == material.baseColorTexture?.encodedImage)
            #expect(restored.baseColorTexture?.wrapS == .repeatTexture && restored.baseColorTexture?.wrapT == .mirroredRepeat)
            #expect(decoded.meshes.allSatisfy { $0.vertices.allSatisfy { $0.color == SIMD4<Float>(0.25, 0.5, 0.5, 0.75) } })
            #expect(Set(decoded.meshes.flatMap { $0.vertices.map(\.textureCoordinate) }) == Set(mesh.vertices.map(\.textureCoordinate)))
        }
        if options == .full, let destination = ProcessInfo.processInfo.environment["MESS_USDZ_FIXTURE_OUTPUT"]
        { try FileManager.default.copyItem(at: url, to: URL(fileURLWithPath: destination)) }
    }
}

func optimizationGrid(size: Int, vertical: Bool = false) -> ([EarthVertex], [UInt32])
{
    var vertices: [EarthVertex] = [], indices: [UInt32] = []
    for north in 0 ... size
    { for east in 0 ... size
        {
            let position = vertical ? SIMD3(Float(east), Float(north), 0) : SIMD3(Float(east), 0, -Float(north))
            vertices.append(EarthVertex(position: position, normal: vertical ? SIMD3(0, 0, 1) : SIMD3(0, 1, 0), textureCoordinate: SIMD2(Float(east) / Float(size), Float(north) / Float(size)), color: SIMD4(repeating: 1)))
        }
    }
    for north in 0 ..< size
    { for east in 0 ..< size
        {
            let a = UInt32(north * (size + 1) + east), row = UInt32(size + 1)
            indices += [a, a + 1, a + row, a + 1, a + row + 1, a + row]
        }
    }
    return (vertices, indices)
}

@Test func optimizedUSDZReducesDeliveredBytesAndCancellationLeavesNoOutput() async throws
{
    let parent = try preparationParent()
    defer { try? FileManager.default.removeItem(at: parent) }
    let (vertices, indices) = optimizationGrid(size: 64)
    let material = EarthMaterial(name: "Map grid", baseColor: SIMD4(repeating: 1), baseColorTexture: nil, metallic: 0, roughness: 1, isUnlit: true, isDoubleSided: false, alphaMode: .opaque, alphaCutoff: 0.5)
    let source = try EarthDerivativeGLB.encode(vertices: vertices, indices: indices, material: material, name: "Grid", attributions: [], sourceID: "authored-grid")
    let raw = try preparationArchive(parent: parent, count: 2, sourceOverride: source)
    let profile = try EarthPreparationProfile(maximumPlacementsPerModel: 1)
    let collection = try await EarthModelPreparer().prepare(archive: raw, directoryURL: parent.appendingPathComponent("prepared"), profile: profile)
    let exporter = EarthUSDZExporter()
    let plan = try await exporter.preflight(collection: collection, destination: profile, options: .untextured)
    let original = try await exporter.export(plan: plan, fileURL: parent.appendingPathComponent("regular.usdz"))
    let optimization = try EarthUSDZOptimizationProfile(triangleFraction: 0.5, maximumErrorMeters: 0.1)
    let optimizedPlan = try await exporter.preflight(collection: collection, destination: profile, options: .untextured, optimization: optimization)
    let optimized = try await exporter.export(plan: optimizedPlan, fileURL: parent.appendingPathComponent("optimized.usdz"))
    #expect(optimized.triangleCount < original.triangleCount && optimized.byteCount < original.byteCount)
    #expect(optimized.maximumErrorMeters <= optimization.maximumErrorMeters)
    #expect(try await exporter.metadata(fileURL: optimized.fileURL)?.optimization == optimization)
    try inspectUSDZ(optimized.fileURL)
    print("Authored grid USDZ: \(original.triangleCount) triangles / \(original.byteCount) bytes; optimized: \(optimized.triangleCount) triangles / \(optimized.byteCount) bytes; error \(optimized.maximumErrorMeters) m")
    let target = parent.appendingPathComponent("cancelled.usdz")
    let task = Task
    {
        try await exporter.export(plan: optimizedPlan, fileURL: target)
        { value in if value.completedModels == 1 { withUnsafeCurrentTask { $0?.cancel() } } }
    }
    do { _ = try await task.value; Issue.record("Cancelled export must not publish") }
    catch is CancellationError {}
    #expect(!FileManager.default.fileExists(atPath: target.path))
    #expect(try FileManager.default.contentsOfDirectory(atPath: parent.path).allSatisfy { !$0.hasPrefix(".earth-usdz-") })
    #expect(try Data(contentsOf: optimized.fileURL).count == optimized.byteCount)
}

private func usdzTextureBytes(_ url: URL) throws -> Data
{
    let bytes = try Data(contentsOf: url)
    var cursor = 0
    func u32(_ offset: Int) -> UInt32 { bytes.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self)) } }
    func u16(_ offset: Int) -> UInt16 { bytes.withUnsafeBytes { UInt16(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt16.self)) } }
    while cursor + 30 <= bytes.count, u32(cursor) == 0x04034B50
    {
        let size = Int(u32(cursor + 18)), nameLength = Int(u16(cursor + 26)), extra = Int(u16(cursor + 28))
        let start = cursor + 30 + nameLength + extra
        let name = String(decoding: bytes[(cursor + 30) ..< (cursor + 30 + nameLength)], as: UTF8.self)
        if name.hasPrefix("textures/") { return bytes.subdata(in: start ..< start + size) }
        cursor = start + size
    }
    throw EarthUSDZExportError.sourceChanged
}

@Test func usdzTextureReductionIsExplicitAndNearestSamplingIsRejected() async throws
{
    let parent = try preparationParent()
    defer { try? FileManager.default.removeItem(at: parent) }
    for (ordinal, sampling) in [TextureSamplingCase.linearClamp, .nearestClamp].enumerated()
    {
        let directory = parent.appendingPathComponent("case\(ordinal)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let (mesh, material) = try textureFixture(sampling: sampling)
        let source = try EarthDerivativeGLB.encode(vertices: mesh.vertices, indices: mesh.triangleIndices, material: material, name: "Pixels", attributions: [], sourceID: "authored-pixels")
        let raw = try preparationArchive(parent: directory, count: 1, sourceOverride: source)
        let profile = try EarthPreparationProfile()
        let collection = try await EarthModelPreparer().prepare(archive: raw, directoryURL: directory.appendingPathComponent("prepared"), profile: profile)
        let exporter = EarthUSDZExporter()
        let plan = try await exporter.preflight(collection: collection, destination: profile, options: EarthExportOptions(includeVertexColors: false))
        if sampling == .nearestClamp
        {
            #expect(plan.canExport == false && plan.issues.contains { $0.contains("Nearest") })
            let withoutPixels = try await exporter.preflight(collection: collection, destination: profile, options: .untextured)
            #expect(withoutPixels.canExport)
            continue
        }
        let varying = try await exporter.preflight(collection: collection, destination: profile)
        #expect(!varying.canExport && varying.issues.contains { $0.contains("varying vertex colors") })
        let colorOnly = try await exporter.preflight(collection: collection, destination: profile, options: .untextured)
        let colorDelivery = try await exporter.export(plan: colorOnly, fileURL: directory.appendingPathComponent("varying-color.usdz"))
        try inspectUSDZ(colorDelivery.fileURL)
        let before = try EarthGLBExporter.fingerprint(await collection.importModel(id: 1))
        let regular = try await exporter.export(plan: plan, fileURL: directory.appendingPathComponent("regular.usdz"))
        #expect(try usdzTextureBytes(regular.fileURL) == material.baseColorTexture?.encodedImage)
        let optimization = try EarthUSDZOptimizationProfile(maximumTextureDimension: 3)
        let optimizedPlan = try await exporter.preflight(collection: collection, destination: profile, options: EarthExportOptions(includeVertexColors: false), optimization: optimization)
        let optimized = try await exporter.export(plan: optimizedPlan, fileURL: directory.appendingPathComponent("optimized.usdz"))
        let image = try #require(CGImageSourceCreateWithData(try usdzTextureBytes(optimized.fileURL) as CFData, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any])
        #expect(properties[kCGImagePropertyPixelWidth] as? Int == 3 && properties[kCGImagePropertyPixelHeight] as? Int == 2)
        #expect(try EarthGLBExporter.fingerprint(await collection.importModel(id: 1)) == before)
        try inspectUSDZ(optimized.fileURL)
    }
}

// Read the published bytes, without consulting the original prepared collection.
@Test func exportedUSDZReaderPreservesActualGeometryChannelsAndMaterials() async throws
{
    let parent = try preparationParent()
    defer { try? FileManager.default.removeItem(at: parent) }
    let raw = try preparationArchive(parent: parent, count: 2)
    let collection = try await EarthModelPreparer().prepare(archive: raw, directoryURL: parent.appendingPathComponent("prepared"), profile: EarthPreparationProfile(maximumPlacementsPerModel: 1))
    let exporter = EarthUSDZExporter()
    for options in [EarthExportOptions.untextured, .minimal, .full]
    {
        let plan = try await exporter.preflight(collection: collection, destination: EarthPreparationProfile(), options: options)
        if !plan.canExport { continue } // The authored input uses nearest filtering.
        let target = parent.appendingPathComponent("\(options == .minimal ? "minimal" : options == .full ? "full" : "untextured").usdz")
        let result = try await exporter.export(plan: plan, fileURL: target)
        let bytes = try Data(contentsOf: target)
        let restored = try await EarthUSDZExportReader().read(fileURL: target)
        #expect(restored.triangleCount == result.triangleCount)
        #expect(restored.geographicOrigin == raw.request.center)
        #expect(restored.sourceFiles.first?.data == bytes)
        #expect(restored.materials.allSatisfy { ($0.baseColorTexture != nil) == options.includeTextures })
        #expect(options.includeVertexColors || restored.meshes.allSatisfy { $0.vertices.allSatisfy { $0.color == SIMD4(repeating: 1) } })
        #expect(try Data(contentsOf: target) == bytes)
    }
}

@Test func exportedUSDZReaderReconstructsOmittedNormalsAtCreasesAndSmallScales() async throws
{
    let parent = try preparationParent()
    defer { try? FileManager.default.removeItem(at: parent) }
    let positions: [SIMD3<Float>] = [.zero, SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, 0, 1), .zero, SIMD3(-1e-12, 0, 0), SIMD3(0, -1e-12, 0)]
    let vertices = positions.enumerated().map
    { index, position in
        EarthVertex(position: position, normal: SIMD3(0, 0, 1), textureCoordinate: SIMD2(Float(index) / 8, 0.25), color: SIMD4(Float(index) / 8, 0.5, 0.25, 1))
    }
    let indices: [UInt32] = [0, 1, 2, 0, 3, 1, 4, 5, 6]
    let material = EarthMaterial(name: "Creased geometry", baseColor: SIMD4(repeating: 1), baseColorTexture: nil, metallic: 0, roughness: 1, isUnlit: false, isDoubleSided: true, alphaMode: .opaque, alphaCutoff: 0.5)
    let source = try EarthDerivativeGLB.encode(vertices: vertices, indices: indices, material: material, name: "Omitted normals", attributions: [], sourceID: "authored")
    // Anchor at exactly zero local translation so Float output preserves tiny edges.
    let tileToGLTF = simd_double4x4(columns: (SIMD4(1, 0, 0, 0), SIMD4(0, 0, -1, 0), SIMD4(0, 1, 0, 0), SIMD4(0, 0, 0, 1)))
    let placement = try EarthGeographicOrigin(latitude: 0, longitude: 0).earthCenteredToLocal.inverse * tileToGLTF
    let raw = try preparationArchive(parent: parent, count: 1, sourceOverride: source, transformOverride: placement)
    let collection = try await EarthModelPreparer().prepare(archive: raw, directoryURL: parent.appendingPathComponent("prepared"), profile: EarthPreparationProfile())
    let exporter = EarthUSDZExporter()
    let options = EarthExportOptions(includeNormals: false, includeTextures: false)
    let plan = try await exporter.preflight(collection: collection, destination: EarthPreparationProfile(), options: options)
    let result = try await exporter.export(plan: plan, fileURL: parent.appendingPathComponent("omitted-normals.usdz"))
    let bytes = try Data(contentsOf: result.fileURL)
    let restored = try await EarthUSDZExportReader().read(fileURL: result.fileURL)
    #expect(restored.triangleCount == 3 && restored.vertexCount == 9)
    let mesh = try #require(restored.meshes.first)
    let expectedNormals: [SIMD3<Float>] = [SIMD3(0, 0, 1), SIMD3(0, 1, 0), SIMD3(0, 0, 1)]
    for (corner, index) in mesh.triangleIndices.enumerated()
    {
        let actual = mesh.vertices[Int(index)], expected = vertices[Int(indices[corner])]
        #expect(actual.position == expected.position && actual.color == expected.color)
        #expect(simd_distance(actual.textureCoordinate, expected.textureCoordinate) < 0.00001)
        #expect(simd_distance(actual.normal, expectedNormals[corner / 3]) < 0.00001)
    }
    #expect(restored.sourceFiles.first?.data == bytes)
    await #expect(throws: EarthImportError.self) { try await EarthUSDZExportReader(limits: EarthImportLimits(maximumVertices: 8)).read(fileURL: result.fileURL) }
    #expect(try Data(contentsOf: result.fileURL) == bytes)
}

@Test func exportedUSDZReaderRejectsChangedAppearanceCapacityAndCancellation() async throws
{
    let parent = try preparationParent()
    defer { try? FileManager.default.removeItem(at: parent) }
    let raw = try preparationArchive(parent: parent, count: 1)
    let collection = try await EarthModelPreparer().prepare(archive: raw, directoryURL: parent.appendingPathComponent("prepared"), profile: EarthPreparationProfile())
    let exporter = EarthUSDZExporter()
    let plan = try await exporter.preflight(collection: collection, destination: EarthPreparationProfile(), options: .untextured)
    let original = try await exporter.export(plan: plan, fileURL: parent.appendingPathComponent("original.usdz"))
    let bytes = try Data(contentsOf: original.fileURL)
    await #expect(throws: EarthImportError.self) { try await EarthUSDZExportReader(limits: EarthImportLimits(maximumSourceBytes: 10)).read(fileURL: original.fileURL) }
    await #expect(throws: EarthImportError.self) { try await EarthUSDZExportReader(limits: EarthImportLimits(maximumVertices: 3)).read(fileURL: original.fileURL) }
    let cancelled = Task
    {
        withUnsafeCurrentTask { $0?.cancel() }
        return try await EarthUSDZExportReader().read(fileURL: original.fileURL)
    }
    await #expect(throws: CancellationError.self) { try await cancelled.value }
    let archive = try EarthUSDZArchiveReader(original.fileURL, maximumBytes: 1024 * 1024)
    let corrupt = parent.appendingPathComponent("changed-appearance.usdz")
    let writer = try EarthUSDZArchive(fileURL: corrupt)
    let ordered = ["scene.usda"] + archive.members.keys.filter { $0 != "scene.usda" }.sorted()
    for (ordinal, name) in ordered.enumerated()
    {
        var data = try archive.data(name, maximumBytes: 1024 * 1024)
        if name == "model1.usda"
        {
            var text = String(decoding: data, as: UTF8.self)
            text = text.replacingOccurrences(of: "uniform token info:id = \"UsdPreviewSurface\"", with: "uniform token info:id = \"UnsupportedSurface\"")
            data = Data(text.utf8)
        }
        let file = parent.appendingPathComponent("member\(ordinal)")
        try data.write(to: file)
        try writer.append(file, name: name)
    }
    _ = try writer.finish()
    // CRCs/package layout are valid. The changed graph itself must fail.
    await #expect(throws: EarthImportError.self) { try await EarthUSDZExportReader().read(fileURL: corrupt) }
    #expect(try Data(contentsOf: original.fileURL) == bytes)
}
