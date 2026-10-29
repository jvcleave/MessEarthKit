import Foundation
import MessEarthKit

enum EarthLocationNamingError: Error, LocalizedError, Sendable
{
    case cityUnavailable, invalidName

    var errorDescription: String?
    {
        switch self
        {
            case .cityUnavailable: "A city could not be resolved for this capture centre."
            case .invalidName: "The location name is invalid or too long."
        }
    }
}

/// One persistent name owner. Coordinates are display-only rounded values;
/// the location area retains its full-precision geographic centre.
enum EarthLocationName: Codable, Equatable, Sendable
{
    case automatic(city: String)
    case custom(String)

    func title(center: EarthGeographicOrigin) -> String
    {
        switch self
        {
            case let .automatic(city):
                let coordinates = String(format: "%.5f, %.5f", locale: Locale(identifier: "en_US_POSIX"), center.latitude, center.longitude)
                return "\(city) · \(coordinates)"
            case let .custom(title): return title
        }
    }

    func validate() throws
    {
        switch self
        {
            case let .automatic(city):
                guard !city.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, city.utf8.count <= 384
                else { throw EarthLocationNamingError.cityUnavailable }
            case let .custom(title):
                guard title.utf8.count <= 512 else { throw EarthLocationNamingError.invalidName }
        }
    }
}
