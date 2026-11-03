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

    func title(area: EarthLocationArea) -> String
    {
        switch self
        {
            case let .automatic(city):
                let coordinates = String(format: "%.2f, %.2f", locale: Locale(identifier: "en_US_POSIX"), area.center.latitude, area.center.longitude)
                let title = "\(city) (\(coordinates))"
                // Incomplete dimension edits retain the location label without
                // presenting an invalid or invented area.
                guard let request = try? area.request(detail: .standard) else { return title }
                let squareMeters = (request.widthMeters * request.depthMeters).rounded()
                let formattedArea = squareMeters.formatted(.number.locale(Locale(identifier: "en_US")).precision(.fractionLength(0)))
                return "\(title), \(formattedArea) m²"
            case let .custom(title): return title
        }
    }

    func exportName(request: EarthDownloadRequest) -> String
    {
        switch self
        {
            case let .automatic(city):
                let locale = Locale(identifier: "en_US_POSIX")
                let coordinates = String(format: "%.2f_%.2f", locale: locale, request.center.latitude, request.center.longitude)
                let squareMeters = String(format: "%.0f", locale: locale, (request.widthMeters * request.depthMeters).rounded())
                return "\(city)_\(coordinates)_\(squareMeters)m2"
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
