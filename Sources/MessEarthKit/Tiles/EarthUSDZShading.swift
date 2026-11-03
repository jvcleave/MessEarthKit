import CryptoKit
import Foundation
import ImageIO
import simd
import UniformTypeIdentifiers

/// Small buffered text writes keep variable shading primvars file-backed too.
final class EarthUSDTextWriter
{
    private let output: FileHandle
    private var buffer = Data()

    init(_ fileURL: URL) throws
    {
        guard FileManager.default.createFile(atPath: fileURL.path, contents: nil) else { throw EarthUSDZExportError.storage }
        output = try FileHandle(forWritingTo: fileURL)
    }

    deinit { try? output.close() }

    func write(_ value: String) throws
    {
        buffer.append(contentsOf: value.utf8)
        if buffer.count >= 65536 { try flush() }
    }

    func finish() throws { try flush(); try output.synchronize(); try output.close() }
    private func flush() throws { try Task.checkCancellation(); try output.write(contentsOf: buffer); buffer.removeAll(keepingCapacity: true) }
}

enum EarthUSDZShading
{
    static func quoted(_ string: String) throws -> String
    {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        return String(decoding: try encoder.encode(string), as: UTF8.self)
    }

    static func write(
        meshes: [EarthMesh],
        materials: [EarthMaterial],
        geometryName: String,
        options: EarthExportOptions,
        optimization: EarthUSDZOptimizationProfile?,
        fileURL: URL,
        staging: URL,
        textures: inout [String: URL]
    ) throws
    {
        let text = try EarthUSDTextWriter(fileURL)
        try text.write("#usda 1.0\n(\n defaultPrim = \"Model\"\n)\ndef Xform \"Model\" (\n prepend references = @\(geometryName)@\n)\n{\n over \"Geom\"\n {\n")
        for (index, mesh) in meshes.enumerated()
        {
            try Task.checkCancellation()
            guard materials.indices.contains(mesh.materialIndex) else { throw EarthUSDZExportError.sourceChanged }
            let source = materials[mesh.materialIndex]
            let factor = options.includeMaterials ? source.baseColor : SIMD4<Float>(0.5, 0.5, 0.5, 1)
            let alphaMode = options.includeMaterials ? source.alphaMode : .opaque
            try text.write("  over \"Mesh\(index)\"\n  {\n   rel material:binding = </Model/Looks/Material\(index)>\n   uniform token subdivisionScheme = \"none\"\n   uniform bool doubleSided = \(source.isDoubleSided ? "true" : "false")\n")
            if options.includeVertexColors
            {
                try primvar(mesh: mesh, name: "displayOpacity", dimensions: 1, text: text) { SIMD4(repeating: $0.color.w) }
                try primvar(mesh: mesh, name: "earthDiffuseColor", dimensions: 3, text: text) { $0.color * factor }
                try primvar(mesh: mesh, name: "earthOpacity", dimensions: 1, text: text) { SIMD4(repeating: alphaMode == .opaque ? 1 : $0.color.w * factor.w) }
            }
            try text.write("  }\n")
        }
        try text.write(" }\n over \"Materials\" (\n  active = false\n )\n {\n }\n def Scope \"Looks\"\n {\n")
        for (index, mesh) in meshes.enumerated()
        {
            try Task.checkCancellation()
            let source = materials[mesh.materialIndex]
            let factor = options.includeMaterials ? source.baseColor : SIMD4<Float>(0.5, 0.5, 0.5, 1)
            let unlit = options.includeMaterials && source.isUnlit
            let alpha = options.includeMaterials ? source.alphaMode : .opaque
            let path = "/Model/Looks/Material\(index)"
            var texture: String?
            if options.includeTextures, let image = source.baseColorTexture
            { texture = try writeTexture(image, optimization: optimization, staging: staging, textures: &textures) }
            try text.write(
                "  def Material \"Material\(index)\"\n  {\n   token outputs:surface.connect = <\(path)/Surface.outputs:surface>\n   def Shader \"Surface\"\n   {\n    uniform token info:id = \"UsdPreviewSurface\"\n    custom bool messEarthKit:unlit = \(unlit ? "true" : "false")\n    custom color4f messEarthKit:baseColorFactor = \(tuple(factor, count: 4))\n"
            )
            let colorInput = unlit ? "emissiveColor" : "diffuseColor"
            if texture != nil
            { try text.write("    color3f inputs:\(colorInput).connect = <\(path)/Texture.outputs:rgb>\n") }
            else if options.includeVertexColors
            { try text.write("    color3f inputs:\(colorInput).connect = <\(path)/VertexColor.outputs:result>\n") }
            else { try text.write("    color3f inputs:\(colorInput) = \(tuple(factor, count: 3))\n") }
            if unlit
            { try text.write("    color3f inputs:diffuseColor = (0,0,0)\n    int inputs:useSpecularWorkflow = 1\n    color3f inputs:specularColor = (0,0,0)\n") }
            else { try text.write("    float inputs:metallic = \(options.includeMaterials ? source.metallic : 0)\n") }
            try text.write("    float inputs:roughness = \(options.includeMaterials ? source.roughness : 0.5)\n")
            if alpha == .blend || (alpha == .mask && source.alphaCutoff > 0)
            {
                if texture != nil { try text.write("    float inputs:opacity.connect = <\(path)/Texture.outputs:a>\n") }
                else if options.includeVertexColors { try text.write("    float inputs:opacity.connect = <\(path)/VertexOpacity.outputs:result>\n") }
                else { try text.write("    float inputs:opacity = \(factor.w)\n") }
                if alpha == .mask { try text.write("    float inputs:opacityThreshold = \(source.alphaCutoff)\n") }
            }
            try text.write("    token outputs:surface\n   }\n")
            if options.includeVertexColors
            {
                for (name, type, variable) in [("VertexColor", "float3", "earthDiffuseColor"), ("VertexOpacity", "float", "earthOpacity")]
                { try text.write("   def Shader \"\(name)\"\n   {\n    uniform token info:id = \"UsdPrimvarReader_\(type)\"\n    token inputs:varname = \"\(variable)\"\n    \(type) outputs:result\n   }\n") }
            }
            if let texture, let image = source.baseColorTexture
            {
                try text.write(
                    "   def Shader \"UV\"\n   {\n    uniform token info:id = \"UsdPrimvarReader_float2\"\n    token inputs:varname = \"st\"\n    float2 outputs:result\n   }\n   def Shader \"Texture\"\n   {\n    uniform token info:id = \"UsdUVTexture\"\n    asset inputs:file = @\(texture)@\n    float2 inputs:st.connect = <\(path)/UV.outputs:result>\n    token inputs:sourceColorSpace = \"sRGB\"\n    token inputs:wrapS = \"\(wrap(image.wrapS))\"\n    token inputs:wrapT = \"\(wrap(image.wrapT))\"\n    custom token messEarthKit:mipmap = \"\(image.mipmapFilter == .none ? "none" : "linear")\"\n"
                )
                let tint = options.includeVertexColors ? try uniformTextureTint(mesh, material: source) : SIMD4<Float>(repeating: 1)
                try text.write("    float4 inputs:scale = \(tuple(factor * tint, count: 4))\n")
                if options.includeVertexColors
                { try text.write("    custom float4 messEarthKit:vertexColorScale = \(tuple(tint, count: 4))\n") }
                try text.write("    float3 outputs:rgb\n    float outputs:a\n   }\n")
            }
            try text.write("  }\n")
        }
        try text.write(" }\n}\n")
        try text.finish()
    }

    /// UsdUVTexture.scale is interfaceOnly: it cannot consume a varying
    /// primvar. A constant per-mesh tint is exact; varying tint needs another
    /// delivery format or an explicit future baking operation.
    static func uniformTextureTint(_ mesh: EarthMesh, material: EarthMaterial) throws -> SIMD4<Float>
    {
        guard let first = mesh.triangleIndices.first else { throw EarthUSDZExportError.sourceChanged }
        let usesAlpha = material.alphaMode == .blend || (material.alphaMode == .mask && material.alphaCutoff > 0)
        func tint(_ vertex: EarthVertex) -> SIMD4<Float>
        { SIMD4(vertex.color.x, vertex.color.y, vertex.color.z, usesAlpha ? vertex.color.w : 1) }
        let color = tint(mesh.vertices[Int(first)])
        guard mesh.triangleIndices.allSatisfy({ tint(mesh.vertices[Int($0)]) == color })
        else { throw EarthUSDZExportError.unsupportedAppearance("Textured meshes with varying vertex colors require GLB. Standard USD texture scale accepts only a constant tint.") }
        return color
    }

    private static func primvar(mesh: EarthMesh, name: String, dimensions: Int, text: EarthUSDTextWriter, value: (EarthVertex) -> SIMD4<Float>) throws
    {
        guard let firstIndex = mesh.triangleIndices.first else { throw EarthUSDZExportError.sourceChanged }
        let first = value(mesh.vertices[Int(firstIndex)])
        let constant = mesh.vertices.allSatisfy { value($0) == first }
        let type = dimensions == 1 ? "float" : "float\(dimensions)"
        try text.write("   \(type)[] primvars:\(name) = [")
        if constant { try text.write(tuple(first, count: dimensions)) }
        else
        {
            for (index, vertex) in mesh.triangleIndices.enumerated()
            {
                if index.isMultiple(of: 4096) { try Task.checkCancellation() }
                if index > 0 { try text.write(",") }
                try text.write(tuple(value(mesh.vertices[Int(vertex)]), count: dimensions))
            }
        }
        try text.write("] (\n    interpolation = \"\(constant ? "constant" : "faceVarying")\"\n   )\n")
    }

    private static func tuple(_ value: SIMD4<Float>, count: Int) -> String
    {
        if count == 1 { return String(value.x) }
        return "(" + (0 ..< count).map { String(value[$0]) }.joined(separator: ",") + ")"
    }

    private static func wrap(_ value: EarthTextureWrap) -> String
    { switch value { case .repeatTexture: "repeat"; case .mirroredRepeat: "mirror"; case .clampToEdge: "clamp" } }

    private static func writeTexture(_ source: EarthTexture, optimization: EarthUSDZOptimizationProfile?, staging: URL, textures: inout [String: URL]) throws -> String
    {
        guard !source.usesNearestMagnification, !source.usesNearestMinification, source.mipmapFilter != .nearest
        else { throw EarthUSDZExportError.unsupportedAppearance("Nearest texture filtering is not a standard USD Preview Surface sampling contract; retain GLB for that source.") }
        var bytes = source.encodedImage
        var suffix: String
        switch source.mimeType { case "image/png": suffix = "png"; case "image/jpeg": suffix = "jpg"; default: throw EarthUSDZExportError.unsupportedAppearance("The texture encoding is not supported by USDZ.") }
        if let maximum = optimization?.maximumTextureDimension, max(source.width, source.height) > maximum
        {
            guard let input = CGImageSourceCreateWithData(bytes as CFData, nil),
                  let image = CGImageSourceCreateThumbnailAtIndex(input, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: maximum, kCGImageSourceShouldCacheImmediately: false] as CFDictionary)
            else { throw EarthUSDZExportError.storage }
            let output = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else { throw EarthUSDZExportError.storage }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else { throw EarthUSDZExportError.storage }
            bytes = output as Data
            suffix = "png"
        }
        let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let name = "textures/\(hash).\(suffix)"
        if textures[name] == nil
        {
            let destination = staging.appendingPathComponent(name)
            try bytes.write(to: destination, options: .atomic)
            textures[name] = destination
        }
        return name
    }
}
