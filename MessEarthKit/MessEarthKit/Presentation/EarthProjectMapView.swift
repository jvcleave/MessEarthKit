import MapKit
import MessEarthKit
import SwiftUI

/// Always visible beside the capture editor. Camera motion changes only the
/// view; the current valid draft and resolved address define the footprint.
struct EarthProjectMapView: View
{
    let selection: EarthConfirmedSelection?
    let inputError: String?
    @State private var camera: MapCameraPosition = .automatic

    var body: some View
    {
        let footprint = selection.map { EarthProjectMapFootprint(request: $0.request) }
        VStack(alignment: .leading, spacing: 0)
        {
            VStack(alignment: .leading, spacing: 6)
            {
                if let selection, let footprint
                {
                    Text(selection.location.title).font(.headline)
                    Text("\(selection.request.widthMeters.formatted()) × \(selection.request.depthMeters.formatted()) m · \(selection.draft.detail.title) detail")
                    Text("Requested footprint. Downloaded edge tiles may extend beyond it.").font(.caption).foregroundStyle(.secondary)
                    if footprint.corners.isEmpty
                    { Text("This footprint extends beyond the map's display range. Its entered dimensions are retained for download.").foregroundStyle(.orange).font(.callout) }
                }
                else
                {
                    Text("Capture map").font(.headline)
                    Text(inputError ?? "Enter an address and choose Update Map to locate the capture area.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }.padding(16)
            Map(position: $camera)
            {
                if let selection, let footprint
                {
                    Marker(selection.location.title, coordinate: footprint.center)
                    if !footprint.corners.isEmpty
                    { MapPolygon(coordinates: footprint.corners).foregroundStyle(.blue.opacity(0.18)).stroke(.blue, lineWidth: 2) }
                }
            }
            .mapStyle(.standard(elevation: .flat))
            .mapControls { MapCompass(); MapScaleView() }
        }
        .onChange(of: selection?.request, initial: true)
        {
            if let footprint { camera = .region(footprint.cameraRegion) }
        }
    }
}

private struct EarthProjectMapFootprint
{
    let center: CLLocationCoordinate2D
    let corners: [CLLocationCoordinate2D]
    let cameraRegion: MKCoordinateRegion

    init(request: EarthDownloadRequest)
    {
        center = CLLocationCoordinate2D(latitude: request.center.latitude, longitude: request.center.longitude)
        let region = MKCoordinateRegion(center: center, latitudinalMeters: request.depthMeters, longitudinalMeters: request.widthMeters)
        let south = center.latitude - region.span.latitudeDelta / 2
        let north = center.latitude + region.span.latitudeDelta / 2
        let west = (center.longitude - region.span.longitudeDelta / 2 + 540).truncatingRemainder(dividingBy: 360) - 180
        let east = (center.longitude + region.span.longitudeDelta / 2 + 540).truncatingRemainder(dividingBy: 360) - 180
        // MapKit cannot display every polar/globe-sized footprint. Report its
        // display limitation without changing or capping the source request.
        if south > -85, north < 85, region.span.longitudeDelta < 180
        {
            corners = [CLLocationCoordinate2D(latitude: south, longitude: west),
                       CLLocationCoordinate2D(latitude: north, longitude: west),
                       CLLocationCoordinate2D(latitude: north, longitude: east),
                       CLLocationCoordinate2D(latitude: south, longitude: east)]
        }
        else { corners = [] }
        cameraRegion = MKCoordinateRegion(
            center: center,
            span: MKCoordinateSpan(
                latitudeDelta: min(170, max(0.002, region.span.latitudeDelta * 1.5)),
                longitudeDelta: min(360, max(0.002, region.span.longitudeDelta * 1.5))
            )
        )
    }
}
