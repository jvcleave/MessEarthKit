import CryptoKit
import Foundation

/// Credentials stay in the active traversal only. Persisted identifiers are
/// hashes of the endpoint and non-access query, never service URLs or sessions.
struct EarthSourceAccess
{
    let apiKey: String

    func resourceURL(uri: String, parent: URL) throws -> URL
    {
        guard let url = URL(string: uri, relativeTo: parent)?.absoluteURL.standardized,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: true),
              components.scheme == "https", components.host == "tile.googleapis.com",
              components.port == nil || components.port == 443,
              components.user == nil, components.password == nil, components.fragment == nil,
              url.standardized.path.hasPrefix("/v1/3dtiles/"),
              !url.path.contains("\\"),
              !url.path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." })
        else { throw EarthImportError.unsupportedContent("Source URI is outside the Google 3D Tiles endpoint.") }
        var query = (components.queryItems ?? []).filter { $0.name != "key" }
        if !query.contains(where: { $0.name == "session" }),
           let session = URLComponents(url: parent, resolvingAgainstBaseURL: true)?.queryItems?.first(where: { $0.name == "session" })
        { query.append(session) }
        query.append(URLQueryItem(name: "key", value: apiKey))
        components.queryItems = query
        guard let authorized = components.url else { throw EarthImportError.invalidContent("Invalid source URI.") }
        return authorized
    }

    func identity(_ url: URL) -> String
    {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: true)!
        components.queryItems = components.queryItems?.filter { !["key", "session"].contains($0.name) }.sorted
        { ($0.name, $0.value ?? "") < ($1.name, $1.value ?? "") }
        if components.queryItems?.isEmpty == true { components.queryItems = nil }
        return Self.digest(Data(components.string!.utf8))
    }

    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}
