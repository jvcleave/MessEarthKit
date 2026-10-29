import Foundation

/// Authored delivery identity, independent of the rounded display/file name.
/// The request retains the exact capture centre, dimensions and detail error.
public struct EarthCaptureIdentity: Codable, Equatable, Sendable
{
    public let formatVersion: Int
    public let locationName: String
    public let request: EarthDownloadRequest
    public let detailName: String

    public init(locationName: String, request: EarthDownloadRequest, detailName: String) throws
    {
        formatVersion = 1
        self.locationName = locationName
        self.request = request
        self.detailName = detailName
        try validate()
    }

    func validate() throws
    {
        guard formatVersion == 1,
              !locationName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, locationName.utf8.count <= 512,
              !detailName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, detailName.utf8.count <= 64
        else { throw EarthImportError.invalidContent("Invalid capture identity metadata.") }
    }

    private enum CodingKeys: String, CodingKey { case formatVersion, locationName, request, detailName }

    public init(from decoder: any Decoder) throws
    {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try values.decode(Int.self, forKey: .formatVersion)
        locationName = try values.decode(String.self, forKey: .locationName)
        request = try values.decode(EarthDownloadRequest.self, forKey: .request)
        detailName = try values.decode(String.self, forKey: .detailName)
        try validate()
    }

    static func readMetadata(json: [String: Any]) throws -> Self?
    {
        guard let value = (json["extras"] as? [String: Any])?["messEarthKitCaptureIdentity"] else { return nil }
        do
        {
            let identity = try JSONDecoder().decode(Self.self, from: JSONSerialization.data(withJSONObject: value))
            try identity.validate()
            return identity
        }
        catch { throw EarthImportError.invalidContent("Invalid capture identity metadata.") }
    }
}
