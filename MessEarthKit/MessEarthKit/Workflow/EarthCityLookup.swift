import CoreLocation
import Foundation
import MapKit
import MessEarthKit

/// Native geocoding requests and their cancellation stay on the main-actor
/// framework boundary. Only the city string crosses back to the store worker;
/// project loading and saving remain on that worker.
@MainActor
final class EarthCityLookup
{
    private var cancelRequest: (() -> Void)?

    func resolve(center: EarthGeographicOrigin) async throws -> String
    {
        try Task.checkCancellation()
        let location = CLLocation(latitude: center.latitude, longitude: center.longitude)
        defer { cancelRequest = nil }
        let city: String = try await withTaskCancellationHandler
        {
            try await withCheckedThrowingContinuation
            { continuation in
                if #available(macOS 26.0, *)
                {
                    guard let request = MKReverseGeocodingRequest(location: location)
                    else { continuation.resume(throwing: EarthLocationNamingError.cityUnavailable); return }
                    cancelRequest = { request.cancel() }
                    request.getMapItems
                    { items, error in
                        if let error { continuation.resume(throwing: error); return }
                        guard let city = items?.first?.addressRepresentations?.cityName?.trimmingCharacters(in: .whitespacesAndNewlines), !city.isEmpty
                        else { continuation.resume(throwing: EarthLocationNamingError.cityUnavailable); return }
                        continuation.resume(returning: city)
                    }
                }
                else
                {
                    let geocoder = CLGeocoder()
                    cancelRequest = { geocoder.cancelGeocode() }
                    geocoder.reverseGeocodeLocation(location, preferredLocale: nil)
                    { placemarks, error in
                        if let error { continuation.resume(throwing: error); return }
                        guard let city = placemarks?.first?.locality?.trimmingCharacters(in: .whitespacesAndNewlines), !city.isEmpty
                        else { continuation.resume(throwing: EarthLocationNamingError.cityUnavailable); return }
                        continuation.resume(returning: city)
                    }
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
