import Foundation
import MapKit
import MessEarthKit

struct EarthLocation: Sendable
{
    let title: String
    let latitude: Double
    let longitude: Double
}

/// App-owned address lookup; location data crosses into the package as values.
actor EarthLocationLookup
{
    func resolve(address: String) async throws -> EarthLocation
    {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = address
        request.resultTypes = .address
        let search = MKLocalSearch(request: request)
        let response = try await withTaskCancellationHandler
        {
            try await search.start()
        } onCancel: {
            search.cancel()
        }
        try Task.checkCancellation()
        guard response.mapItems.count == 1, let item = response.mapItems.first
        else { throw EarthImportError.invalidContent("Address lookup needs one clear match. Refine the address and update the map again.") }
        let coordinate = item.placemark.coordinate
        guard CLLocationCoordinate2DIsValid(coordinate)
        else { throw EarthImportError.invalidContent("Address lookup returned invalid coordinates.") }
        return EarthLocation(title: item.placemark.title ?? item.name ?? address, latitude: coordinate.latitude, longitude: coordinate.longitude)
    }
}
