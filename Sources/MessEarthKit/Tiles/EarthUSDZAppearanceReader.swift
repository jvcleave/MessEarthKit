import Foundation
import simd

/// The writer-owned appearance dialect, not a general USD parser. Unknown
/// nodes/properties/connections fail before native geometry is opened.
struct EarthUSDZAppearanceReader
{
    struct Primvar
    {
        let values: Substring
        let components: Int
        var interpolation: String?
    }

    struct Node
    {
        let type: String
        var properties: [String: Substring] = [:]
        var primvars: [String: Primvar] = [:]
    }

    struct Surface
    {
        let material: EarthMaterial
        let texturePath: String?
        let textureScale: SIMD4<Float>?
        let vertexTint: SIMD4<Float>?
        let wrapS: EarthTextureWrap
        let wrapT: EarthTextureWrap
        let mipmap: EarthMipmapFilter
    }

    let nodes: [String: Node]

    init(text: String, geometryName: String) throws
    {
        var nodes: [String: Node] = [:]
        var stack: [String] = []
        var pending: (String, String)?
        var currentPrimvar: String?
        var rootFields: [String: Substring] = [:]
        for rawLine in text.split(separator: "\n")
        {
            try Task.checkCancellation()
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line == "#usda 1.0" { continue }
            if line.hasPrefix("def ") || line.hasPrefix("over ")
            {
                guard pending == nil, currentPrimvar == nil, let first = line.firstIndex(of: "\""),
                      let last = line.lastIndex(of: "\""), first < last
                else { throw Self.invalid() }
                let prefix = line[..<first].trimmingCharacters(in: .whitespaces)
                let name = String(line[line.index(after: first) ..< last])
                guard !name.isEmpty, name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }),
                      line[line.index(after: last)...].trimmingCharacters(in: .whitespaces) == "" || line.hasSuffix("(")
                else { throw Self.invalid() }
                pending = (name, prefix)
                continue
            }
            if line == "{"
            {
                guard let next = pending else { throw Self.invalid() }
                stack.append(next.0)
                let path = "/" + stack.joined(separator: "/")
                guard nodes[path] == nil else { throw Self.invalid() }
                nodes[path] = Node(type: next.1)
                pending = nil
                continue
            }
            if line == "}"
            {
                guard pending == nil, currentPrimvar == nil, !stack.isEmpty else { throw Self.invalid() }
                stack.removeLast()
                continue
            }
            if line == "(" || line == ")" { currentPrimvar = nil; continue }
            let path = "/" + stack.joined(separator: "/")
            if line.hasPrefix("interpolation = ")
            {
                guard let name = currentPrimvar, let value = Self.quoted(line.dropFirst("interpolation = ".count)), ["constant", "faceVarying"].contains(value)
                else { throw Self.invalid() }
                nodes[path]?.primvars[name]?.interpolation = value
                continue
            }
            // Metadata for the reference/inactive inherited material scope.
            if line.hasPrefix("prepend references = ")
            {
                guard pending?.0 == "Model", line == "prepend references = @\(geometryName)@" else { throw Self.invalid() }
                rootFields["reference"] = rawLine[rawLine.startIndex...]
                continue
            }
            if line == "active = false"
            { guard pending?.0 == "Materials" else { throw Self.invalid() }; continue }
            if stack.isEmpty, line == "defaultPrim = \"Model\"" { rootFields["default"] = rawLine[rawLine.startIndex...]; continue }
            guard pending == nil, nodes[path] != nil else { throw Self.invalid() }
            let pieces = rawLine.trimmingCharacters(in: .whitespaces).split(separator: "=", maxSplits: 1)
            guard let declarationText = pieces.first else { throw Self.invalid() }
            let declaration = declarationText.split(separator: " ")
            guard let key = declaration.last else { throw Self.invalid() }
            let value = pieces.count == 2 ? pieces[1].trimmingCharacters(in: .whitespaces)[...] : ""[...]
            if key.hasPrefix("primvars:")
            {
                let name = String(key.dropFirst("primvars:".count))
                let componentCount = ["float[]": 1, "float3[]": 3][String(declaration[0])]
                guard let componentCount, ["displayOpacity", "earthDiffuseColor", "earthOpacity"].contains(name),
                      nodes[path]?.primvars[name] == nil, value.hasSuffix(" (")
                else { throw Self.invalid() }
                let array = value.dropLast(2)
                guard array.first == "[", array.last == "]", array.allSatisfy({ "0123456789+-.,eE()[] \t".contains($0) }) else { throw Self.invalid() }
                nodes[path]?.primvars[name] = Primvar(values: array.dropFirst().dropLast(), components: componentCount)
                currentPrimvar = name
            }
            else
            {
                guard nodes[path]?.properties[String(key)] == nil else { throw Self.invalid() }
                nodes[path]?.properties[String(key)] = value
            }
        }
        guard stack.isEmpty, pending == nil, rootFields.count == 2, nodes["/Model"]?.type == "def Xform",
              nodes["/Model/Geom"]?.type == "over", nodes["/Model/Looks"]?.type == "def Scope"
        else { throw Self.invalid() }
        for (path, node) in nodes
        {
            let parts = path.split(separator: "/")
            switch parts.count
            {
                case 1: guard path == "/Model", node.properties.isEmpty else { throw Self.invalid() }
                case 2: guard ["/Model/Geom", "/Model/Looks", "/Model/Materials"].contains(path), node.properties.isEmpty else { throw Self.invalid() }
                case 3:
                    if parts[1] == "Geom"
                    {
                        guard parts[2].hasPrefix("Mesh"), Int(parts[2].dropFirst(4)) != nil, node.type == "over",
                              Set(node.properties.keys) == ["material:binding", "subdivisionScheme", "doubleSided"],
                              node.properties["subdivisionScheme"] == "\"none\""
                        else { throw Self.invalid() }
                    }
                    else
                    { guard parts[1] == "Looks", parts[2].hasPrefix("Material"), node.type == "def Material", Set(node.properties.keys) == ["outputs:surface.connect"] else { throw Self.invalid() } }
                case 4:
                    guard parts[1] == "Looks", node.type == "def Shader", ["Surface", "VertexColor", "VertexOpacity", "UV", "Texture"].contains(String(parts[3])), node.primvars.isEmpty
                    else { throw Self.invalid() }
                default: throw Self.invalid()
            }
        }
        self.nodes = nodes
    }

    func surface(mesh: Int, options: EarthExportOptions) throws -> Surface
    {
        let meshPath = "/Model/Geom/Mesh\(mesh)"
        guard let geometry = nodes[meshPath], let binding = geometry.properties["material:binding"], binding.first == "<", binding.last == ">" else { throw Self.invalid() }
        let path = String(binding.dropFirst().dropLast())
        guard path.hasPrefix("/Model/Looks/Material"), let material = nodes[path], let surface = nodes[path + "/Surface"],
              material.properties["outputs:surface.connect"] == "<\(path)/Surface.outputs:surface>"[...], surface.properties["info:id"] == "\"UsdPreviewSurface\""
        else { throw Self.invalid() }
        let fields = surface.properties
        let unlit = try Self.boolean(fields["messEarthKit:unlit"])
        let factor = try Self.vector(fields["messEarthKit:baseColorFactor"], count: 4)
        guard (0 ..< 4).allSatisfy({ factor[$0] >= 0 }), factor.w <= 1 else { throw Self.invalid() }
        let colorInput = unlit ? "emissiveColor" : "diffuseColor"
        let textured = fields["inputs:\(colorInput).connect"] == "<\(path)/Texture.outputs:rgb>"[...]
        var expected: Set<String> = ["info:id", "messEarthKit:unlit", "messEarthKit:baseColorFactor", "inputs:roughness", "outputs:surface"]
        if textured { guard options.includeTextures else { throw Self.invalid() }; expected.insert("inputs:\(colorInput).connect") }
        else if options.includeVertexColors
        {
            guard fields["inputs:\(colorInput).connect"] == "<\(path)/VertexColor.outputs:result>"[...] else { throw Self.invalid() }
            expected.insert("inputs:\(colorInput).connect")
        }
        else
        {
            let rgb = try Self.vector(fields["inputs:\(colorInput)"], count: 3)
            guard Self.close(rgb, factor, count: 3) else { throw Self.invalid() }
            expected.insert("inputs:\(colorInput)")
        }
        let metallic: Float
        if unlit
        {
            guard try Self.vector(fields["inputs:diffuseColor"], count: 3) == .zero,
                  try Self.vector(fields["inputs:specularColor"], count: 3) == .zero, fields["inputs:useSpecularWorkflow"] == "1"
            else { throw Self.invalid() }
            expected.formUnion(["inputs:diffuseColor", "inputs:specularColor", "inputs:useSpecularWorkflow"])
            metallic = 0
        }
        else { expected.insert("inputs:metallic"); metallic = try Self.scalar(fields["inputs:metallic"]) }
        let roughness = try Self.scalar(fields["inputs:roughness"])
        var alphaMode = EarthAlphaMode.opaque
        var cutoff: Float = 0.5
        if fields["inputs:opacity.connect"] != nil || fields["inputs:opacity"] != nil
        {
            alphaMode = .blend
            if let threshold = fields["inputs:opacityThreshold"]
            { cutoff = try Self.scalar(threshold); guard cutoff > 0 && cutoff <= 1 else { throw Self.invalid() }; alphaMode = .mask; expected.insert("inputs:opacityThreshold") }
            if textured
            { guard fields["inputs:opacity.connect"] == "<\(path)/Texture.outputs:a>"[...] else { throw Self.invalid() }; expected.insert("inputs:opacity.connect") }
            else if options.includeVertexColors
            { guard fields["inputs:opacity.connect"] == "<\(path)/VertexOpacity.outputs:result>"[...] else { throw Self.invalid() }; expected.insert("inputs:opacity.connect") }
            else
            { guard try Self.scalar(fields["inputs:opacity"]) == factor.w else { throw Self.invalid() }; expected.insert("inputs:opacity") }
        }
        guard Set(fields.keys) == expected, (0 ... 1).contains(metallic), (0 ... 1).contains(roughness) else { throw Self.invalid() }
        if options.includeVertexColors
        {
            try validateReader(path + "/VertexColor", type: "float3", variable: "earthDiffuseColor")
            try validateReader(path + "/VertexOpacity", type: "float", variable: "earthOpacity")
        }
        var texturePath: String?, scale: SIMD4<Float>?, tint: SIMD4<Float>?
        var wrapS = EarthTextureWrap.clampToEdge, wrapT = EarthTextureWrap.clampToEdge
        var mipmap = EarthMipmapFilter.none
        if textured
        {
            try validateReader(path + "/UV", type: "float2", variable: "st")
            guard let texture = nodes[path + "/Texture"]?.properties,
                  texture["info:id"] == "\"UsdUVTexture\"", texture["inputs:st.connect"] == "<\(path)/UV.outputs:result>"[...],
                  texture["inputs:sourceColorSpace"] == "\"sRGB\"", let asset = texture["inputs:file"], asset.first == "@", asset.last == "@"
            else { throw Self.invalid() }
            var textureFields: Set<String> = ["info:id", "inputs:file", "inputs:st.connect", "inputs:sourceColorSpace", "inputs:wrapS", "inputs:wrapT", "messEarthKit:mipmap", "inputs:scale", "outputs:rgb", "outputs:a"]
            if options.includeVertexColors { textureFields.insert("messEarthKit:vertexColorScale"); tint = try Self.vector(texture["messEarthKit:vertexColorScale"], count: 4) }
            guard Set(texture.keys) == textureFields else { throw Self.invalid() }
            scale = try Self.vector(texture["inputs:scale"], count: 4)
            guard let scale, Self.close(scale, factor * (tint ?? SIMD4(repeating: 1)), count: 4) else { throw Self.invalid() }
            texturePath = String(asset.dropFirst().dropLast())
            wrapS = try Self.wrap(texture["inputs:wrapS"])
            wrapT = try Self.wrap(texture["inputs:wrapT"])
            switch Self.quoted(texture["messEarthKit:mipmap"]) { case "none": mipmap = .none; case "linear": mipmap = .linear; default: throw Self.invalid() }
        }
        return Surface(
            material: EarthMaterial(name: "Material \(mesh)", baseColor: factor, baseColorTexture: nil, metallic: metallic, roughness: roughness, isUnlit: unlit, isDoubleSided: try Self.boolean(geometry.properties["doubleSided"]), alphaMode: alphaMode, alphaCutoff: cutoff),
            texturePath: texturePath,
            textureScale: scale,
            vertexTint: tint,
            wrapS: wrapS,
            wrapT: wrapT,
            mipmap: mipmap
        )
    }

    func validateColors(mesh: Int, vertices: [EarthVertex], indices: [UInt32], surface: Surface, options: EarthExportOptions) throws
    {
        guard let node = nodes["/Model/Geom/Mesh\(mesh)"] else { throw Self.invalid() }
        guard options.includeVertexColors else { guard node.primvars.isEmpty else { throw Self.invalid() }; return }
        for name in ["displayOpacity", "earthDiffuseColor", "earthOpacity"]
        {
            guard let primvar = node.primvars[name], let interpolation = primvar.interpolation else { throw Self.invalid() }
            var values = EarthUSDZNumberReader(text: primvar.values)
            var constant: SIMD4<Float>?
            if interpolation == "constant"
            {
                var value = SIMD4<Float>.zero
                for component in 0 ..< primvar.components { guard let next = try values.next() else { throw Self.invalid() }; value[component] = next }
                constant = value
            }
            for (corner, index) in indices.enumerated()
            {
                if corner.isMultiple(of: 4096) { try Task.checkCancellation() }
                let vertex = vertices[Int(index)]
                let expected = name == "displayOpacity" ? SIMD4(repeating: vertex.color.w) : name == "earthOpacity"
                    ? SIMD4(repeating: vertex.color.w * surface.material.baseColor.w) : vertex.color * surface.material.baseColor
                // The writer retains unused opacity primvars even for opaque
                // surfaces and zero-cutoff masks. They do not drive appearance.
                let unusedOpacity = name == "earthOpacity" && surface.material.alphaMode == .opaque
                for component in 0 ..< primvar.components
                {
                    let value: Float
                    if let constant { value = constant[component] }
                    else { guard let next = try values.next() else { throw Self.invalid() }; value = next }
                    guard unusedOpacity || abs(value - expected[component]) <= 0.00001 else { throw Self.invalid() }
                }
            }
            guard try values.next() == nil else { throw Self.invalid() }
        }

        if let tint = surface.vertexTint
        {
            for index in indices
            {
                let color = vertices[Int(index)].color
                guard Self.close(color, tint, count: 3), surface.material.alphaMode == .opaque || abs(color.w - tint.w) < 0.00001 else { throw Self.invalid() }
            }
        }
    }

    private func validateReader(_ path: String, type: String, variable: String) throws
    {
        guard let fields = nodes[path]?.properties, Set(fields.keys) == ["info:id", "inputs:varname", "outputs:result"],
              fields["info:id"] == "\"UsdPrimvarReader_\(type)\""[...], fields["inputs:varname"] == "\"\(variable)\""[...]
        else { throw Self.invalid() }
    }

    static func vector(_ text: Substring?, count: Int) throws -> SIMD4<Float>
    {
        guard let text else { throw invalid() }
        let tokens = text.split(whereSeparator: { "(), \t".contains($0) })
        guard tokens.count == count else { throw invalid() }
        var value = SIMD4<Float>.zero
        for index in tokens.indices { guard let number = Float(tokens[index]), number.isFinite else { throw invalid() }; value[index] = number }
        return value
    }

    static func scalar(_ text: Substring?) throws -> Float { try vector(text, count: 1).x }
    private static func boolean(_ text: Substring?) throws -> Bool
    { guard text == "true" || text == "false" else { throw invalid() }; return text == "true" }
    private static func quoted(_ text: Substring?) -> String?
    { guard let text, text.first == "\"", text.last == "\"" else { return nil }; return String(text.dropFirst().dropLast()) }
    private static func wrap(_ text: Substring?) throws -> EarthTextureWrap
    { switch quoted(text) { case "repeat": .repeatTexture; case "mirror": .mirroredRepeat; case "clamp": .clampToEdge; default: throw invalid() } }
    private static func close(_ a: SIMD4<Float>, _ b: SIMD4<Float>, count: Int) -> Bool
    { (0 ..< count).allSatisfy { abs(a[$0] - b[$0]) <= 0.00001 } }
    static func invalid() -> EarthImportError { .unsupportedContent("The USDZ appearance is outside the EarthKit export viewer contract.") }
}

/// Stream large face-varying arrays without allocating one substring per scalar.
private struct EarthUSDZNumberReader
{
    var text: Substring
    mutating func next() throws -> Float?
    {
        while let first = text.first, "(), \t".contains(first) { text.removeFirst() }
        guard !text.isEmpty else { return nil }
        let end = text.firstIndex(where: { "(), \t".contains($0) }) ?? text.endIndex
        guard let number = Float(text[..<end]), number.isFinite else { throw EarthUSDZAppearanceReader.invalid() }
        text = text[end...]
        return number
    }
}
