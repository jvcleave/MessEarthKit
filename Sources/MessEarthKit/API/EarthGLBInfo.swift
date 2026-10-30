import Foundation

/// Optional delivery metadata. A GLB never depends on this companion to load.
public struct EarthGLBInfo: Codable, Sendable
{
    public static let maximumEncodedBytes = 1024 * 1024
    public let schemaVersion: Int
    public let name: String
    public let exportedAt: Date
    public let glb: Asset
    public let geometry: Geometry
    public let exportOptions: EarthGLBExportOptions
    public let attributions: [String]
    public let thumbnail: Thumbnail?

    public struct Asset: Codable, Sendable
    {
        public let fileName: String
        public let byteCount: Int
        public let sha256: String
    }

    public struct Geometry: Codable, Sendable
    {
        public let vertexCount: Int
        public let triangleCount: Int
        public let meshCount: Int
        public let materialCount: Int
        public let textureCount: Int
        /// Local meters: East +X, Up +Y, North -Z.
        public let minimum: [Float]
        public let maximum: [Float]
    }

    public struct Thumbnail: Codable, Sendable
    {
        public let mimeType: String
        public let width: Int
        public let height: Int
        public let data: Data

        public init(width: Int, height: Int, pngData: Data) throws
        {
            mimeType = "image/png"
            self.width = width
            self.height = height
            data = pngData
            try validate()
        }

        fileprivate func validate() throws
        {
            guard mimeType == "image/png", (1 ... 512).contains(width), (1 ... 512).contains(height),
                  data.count <= 768 * 1024, data.count >= 24,
                  data.prefix(8) == Data([137, 80, 78, 71, 13, 10, 26, 10]),
                  data[12 ..< 16] == Data("IHDR".utf8)
            else { throw EarthGLBInfoError.invalidInfo }
            let dimensions = data.withUnsafeBytes
            { bytes in
                (
                    Int(UInt32(bigEndian: bytes.loadUnaligned(fromByteOffset: 16, as: UInt32.self))),
                    Int(UInt32(bigEndian: bytes.loadUnaligned(fromByteOffset: 20, as: UInt32.self)))
                )
            }
            guard dimensions.0 == width, dimensions.1 == height else { throw EarthGLBInfoError.invalidInfo }
        }
    }

    private enum CodingKeys: String, CodingKey
    { case schemaVersion, name, exportedAt, glb, geometry, exportOptions, attributions, thumbnail }

    init(name: String, fileName: String, byteCount: Int, sha256: String, geometry: Geometry, options: EarthGLBExportOptions, attributions: [String], thumbnail: Thumbnail?)
    {
        schemaVersion = 1
        self.name = name
        exportedAt = Date()
        glb = Asset(fileName: fileName, byteCount: byteCount, sha256: sha256)
        self.geometry = geometry
        exportOptions = options
        self.attributions = attributions
        self.thumbnail = thumbnail
    }

    public init(from decoder: Decoder) throws
    {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
        name = try values.decode(String.self, forKey: .name)
        exportedAt = try values.decode(Date.self, forKey: .exportedAt)
        glb = try values.decode(Asset.self, forKey: .glb)
        geometry = try values.decode(Geometry.self, forKey: .geometry)
        exportOptions = try values.decode(EarthGLBExportOptions.self, forKey: .exportOptions)
        attributions = try values.decode([String].self, forKey: .attributions)
        thumbnail = try values.decode(Thumbnail?.self, forKey: .thumbnail)
        try validate()
    }

    public func encode(to encoder: Encoder) throws
    {
        try validate()
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(schemaVersion, forKey: .schemaVersion)
        try values.encode(name, forKey: .name)
        try values.encode(exportedAt, forKey: .exportedAt)
        try values.encode(glb, forKey: .glb)
        try values.encode(geometry, forKey: .geometry)
        try values.encode(exportOptions, forKey: .exportOptions)
        try values.encode(attributions, forKey: .attributions)
        try values.encode(thumbnail, forKey: .thumbnail)
    }

    public static func companionURL(_ glbURL: URL) -> URL
    { glbURL.appendingPathExtension("info.json") }

    public static func decode(_ data: Data) throws -> Self
    {
        guard data.count <= maximumEncodedBytes else { throw EarthGLBInfoError.invalidInfo }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Self.self, from: data)
    }

    public func encoded() throws -> Data
    {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(self)
        guard data.count <= Self.maximumEncodedBytes else { throw EarthGLBInfoError.invalidInfo }
        return data
    }

    private func validate() throws
    {
        guard schemaVersion == 1, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              name.utf8.count <= 4096, glb.byteCount > 0,
              glb.sha256.count == 64, glb.sha256.allSatisfy({ $0.isASCII && ($0.isNumber || ("a" ... "f").contains(String($0))) }),
              geometry.vertexCount > 0, geometry.triangleCount > 0, geometry.meshCount > 0,
              geometry.materialCount >= 0, geometry.textureCount >= 0,
              geometry.minimum.count == 3, geometry.maximum.count == 3,
              zip(geometry.minimum, geometry.maximum).allSatisfy({ pair in pair.0.isFinite && pair.1.isFinite && pair.0 <= pair.1 })
        else { throw EarthGLBInfoError.invalidInfo }
        try exportOptions.validate()
        try thumbnail?.validate()
    }
}

public enum EarthGLBInfoError: Error, Sendable, LocalizedError
{
    case invalidInfo
    public var errorDescription: String? { "The optional GLB information companion is invalid or unsupported." }
}

/// App-owned preview work consumes the exporter's current decoded part, then
/// releases its resources. No Metal or UI types cross the SDK boundary.
public struct EarthGLBExportPreview: Sendable
{
    let consume: @Sendable (EarthCapture) async throws -> Void
    let finish: @Sendable () async throws -> EarthGLBInfo.Thumbnail

    public init(consume: @escaping @Sendable (EarthCapture) async throws -> Void, finish: @escaping @Sendable () async throws -> EarthGLBInfo.Thumbnail)
    { self.consume = consume; self.finish = finish }
}

public struct EarthGLBExportDelivery: Sendable
{
    public let fileURL: URL
    public let infoURL: URL?
    public let infoWarning: String?
}
