import Foundation

/// Optional display identity, separate from payload budgets and immutable tiles.
/// The flat identity fields reuse the standalone GLB identity contract.
struct EarthPreparedCaptureInfo: Codable
{
    static let fileName = "capture.info.json"
    static let maximumBytes = 16 * 1024
    let identity: EarthCaptureIdentity
    let modelID: Int?

    init(identity: EarthCaptureIdentity, modelID: Int? = nil)
    {
        self.identity = identity
        self.modelID = modelID
    }

    private enum CodingKeys: String, CodingKey { case modelID }

    init(from decoder: any Decoder) throws
    {
        identity = try EarthCaptureIdentity(from: decoder)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        modelID = try values.decodeIfPresent(Int.self, forKey: .modelID)
        if let modelID, modelID <= 0 { throw EarthPreparationError.invalidCollection }
    }

    func encode(to encoder: any Encoder) throws
    {
        try identity.encode(to: encoder)
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encodeIfPresent(modelID, forKey: .modelID)
    }

    func encoded() throws -> Data
    {
        try identity.validate()
        if let modelID, modelID <= 0 { throw EarthPreparationError.invalidCollection }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(self)
        guard data.count <= Self.maximumBytes else { throw EarthPreparationError.invalidCollection }
        return data
    }

    static func read(files: EarthAcquisitionFiles, path: String = fileName) throws -> (info: Self, data: Data)?
    {
        let url = try files.checked(path)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        _ = try files.checked(path, regularFile: true)
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        let data = try input.read(upToCount: maximumBytes + 1) ?? Data()
        guard !data.isEmpty, data.count <= maximumBytes else { throw EarthPreparationError.invalidCollection }
        do { return (try JSONDecoder().decode(Self.self, from: data), data) }
        catch { throw EarthPreparationError.invalidCollection }
    }
}
