import CoreLocation
import Foundation
import MapKit
import MessEarthKit

/// MapKit's callback and native objects stay on its main-actor boundary; only
/// the resolved city string crosses back to the store worker.
@MainActor
final class EarthCityLookup
{
    private var cancelRequest: (() -> Void)?

    func resolve(center: EarthGeographicOrigin) async throws -> String
    {
        guard #available(macOS 26.0, *) else { throw EarthLocationNamingError.unsupportedSystem }
        try Task.checkCancellation()
        let location = CLLocation(latitude: center.latitude, longitude: center.longitude)
        guard let request = MKReverseGeocodingRequest(location: location) else { throw EarthLocationNamingError.cityUnavailable }
        cancelRequest = { request.cancel() }
        defer { cancelRequest = nil }
        let city: String = try await withTaskCancellationHandler
        {
            try await withCheckedThrowingContinuation
            { continuation in
                request.getMapItems
                { items, error in
                    if let error { continuation.resume(throwing: error); return }
                    guard let city = items?.first?.addressRepresentations?.cityName?.trimmingCharacters(in: .whitespacesAndNewlines), !city.isEmpty
                    else { continuation.resume(throwing: EarthLocationNamingError.cityUnavailable); return }
                    continuation.resume(returning: city)
                }
            }
        } onCancel: {
            Task { @MainActor in self.cancelRequest?() }
        }
        try Task.checkCancellation()
        try EarthLocationName.automatic(city: city).validate()
        return city
    }
}
