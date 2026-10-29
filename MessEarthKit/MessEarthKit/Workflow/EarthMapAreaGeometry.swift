import Foundation
import MapKit
import MessEarthKit

enum EarthMapAreaHandle: CaseIterable, Identifiable, Sendable
{
    case northWest, north, northEast, east, southEast, south, southWest, west
    var id: Self { self }
    var west: Bool { self == .west || self == .northWest || self == .southWest }
    var east: Bool { self == .east || self == .northEast || self == .southEast }
    var north: Bool { self == .north || self == .northWest || self == .northEast }
    var south: Bool { self == .south || self == .southWest || self == .southEast }
}

enum EarthMapAreaDrag: Equatable, Sendable
{
    case move, resize(EarthMapAreaHandle), draw
}

enum EarthMapAreaError: Error, LocalizedError
{
    case displayRange, tooSmall, changed
    var errorDescription: String?
    {
        switch self
        {
            case .displayRange: "Map editing supports areas below 85° latitude that span less than half the world. Numeric dimensions are retained."
            case .tooSmall: "Draw an area at least 1 × 1 meter."
            case .changed: "The location changed during the map edit. Review its area and try again."
        }
    }
}

/// A north-up projected rectangle for interaction and display. Meter dimensions
/// use WGS84 local east/north scales at its center; source intersection is SDK-owned.
struct EarthMapAreaGeometry
{
    let rect: MKMapRect
    let ellipsoidHeight: Double
    private static let worldWidth = MKMapRect.world.size.width

    init(area: EarthLocationArea) throws
    {
        let request = try area.request(detail: .standard)
        let center = MKMapPoint(CLLocationCoordinate2D(latitude: area.center.latitude, longitude: area.center.longitude))
        let scale = Self.metersPerPoint(latitude: area.center.latitude)
        let width = request.widthMeters / scale.east
        let height = request.depthMeters / scale.north
        try self.init(rect: MKMapRect(x: center.x - width / 2, y: center.y - height / 2, width: width, height: height), ellipsoidHeight: area.center.ellipsoidHeight)
    }

    private init(rect: MKMapRect, ellipsoidHeight: Double) throws
    {
        guard [rect.minX, rect.minY, rect.size.width, rect.size.height].allSatisfy(\.isFinite),
              rect.size.width > 0, rect.size.height > 0, rect.size.width < Self.worldWidth / 2,
              Self.coordinate(x: rect.midX, y: rect.minY).latitude < 85,
              Self.coordinate(x: rect.midX, y: rect.maxY).latitude > -85
        else { throw EarthMapAreaError.displayRange }
        self.rect = rect
        self.ellipsoidHeight = ellipsoidHeight
    }

    var corners: [CLLocationCoordinate2D]
    {
        [EarthMapAreaHandle.northWest, .northEast, .southEast, .southWest].map { coordinate(for: $0) }
    }

    func coordinate(for handle: EarthMapAreaHandle) -> CLLocationCoordinate2D
    {
        Self.coordinate(
            x: handle.west ? rect.minX : handle.east ? rect.maxX : rect.midX,
            y: handle.north ? rect.minY : handle.south ? rect.maxY : rect.midY
        )
    }

    func moved(area: EarthLocationArea, from start: EarthGeographicOrigin, to end: EarthGeographicOrigin) throws -> EarthLocationArea
    {
        let first = Self.point(start)
        let last = Self.point(end, nearX: first.x)
        let center = Self.coordinate(x: rect.midX + last.x - first.x, y: rect.midY + last.y - first.y)
        var result = area
        result.center = try EarthGeographicOrigin(latitude: center.latitude, longitude: center.longitude, ellipsoidHeight: ellipsoidHeight)
        _ = try Self(area: result)
        return result
    }

    func resized(area: EarthLocationArea, handle: EarthMapAreaHandle, to coordinate: EarthGeographicOrigin) throws -> EarthLocationArea
    {
        let point = Self.point(coordinate, nearX: rect.midX)
        let scale = Self.metersPerPoint(latitude: area.center.latitude)
        let west = handle.west ? min(point.x, rect.maxX - 1 / scale.east) : rect.minX
        let east = handle.east ? max(point.x, rect.minX + 1 / scale.east) : rect.maxX
        let north = handle.north ? min(point.y, rect.maxY - 1 / scale.north) : rect.minY
        let south = handle.south ? max(point.y, rect.minY + 1 / scale.north) : rect.maxY
        let resized = try Self(rect: MKMapRect(x: west, y: north, width: east - west, height: south - north), ellipsoidHeight: ellipsoidHeight)
        var result = try resized.area()
        if !handle.west && !handle.east { result.widthMeters = area.widthMeters }
        if !handle.north && !handle.south { result.heightMeters = area.heightMeters }
        return result
    }

    static func drawn(from start: EarthGeographicOrigin, to end: EarthGeographicOrigin, ellipsoidHeight: Double) throws -> EarthLocationArea
    {
        let first = point(start)
        let last = point(end, nearX: first.x)
        guard first.x != last.x, first.y != last.y else { throw EarthMapAreaError.tooSmall }
        let geometry = try Self(rect: MKMapRect(x: min(first.x, last.x), y: min(first.y, last.y), width: abs(last.x - first.x), height: abs(last.y - first.y)), ellipsoidHeight: ellipsoidHeight)
        let scale = metersPerPoint(latitude: coordinate(x: geometry.rect.midX, y: geometry.rect.midY).latitude)
        guard geometry.rect.size.width * scale.east >= 1, geometry.rect.size.height * scale.north >= 1 else { throw EarthMapAreaError.tooSmall }
        return try geometry.area()
    }

    private func area() throws -> EarthLocationArea
    {
        let center = Self.coordinate(x: rect.midX, y: rect.midY)
        let scale = Self.metersPerPoint(latitude: center.latitude)
        let width = max(1, rect.size.width * scale.east)
        let height = max(1, rect.size.height * scale.north)
        return try EarthLocationArea(
            center: EarthGeographicOrigin(latitude: center.latitude, longitude: center.longitude, ellipsoidHeight: ellipsoidHeight),
            widthMeters: Self.meters(width),
            heightMeters: Self.meters(height)
        )
    }

    private static func meters(_ value: Double) -> String
    {
        var text = String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), value)
        while text.last == "0" { text.removeLast() }
        if text.last == "." { text.removeLast() }
        return text
    }

    private static func metersPerPoint(latitude: Double) -> (east: Double, north: Double)
    {
        let radians = latitude * .pi / 180
        let eccentricitySquared = 6.6943799901413165e-3
        let denominator = 1 - eccentricitySquared * pow(sin(radians), 2)
        let primeVerticalRadius = 6378137 / sqrt(denominator)
        let meridionalRadius = 6378137 * (1 - eccentricitySquared) / pow(denominator, 1.5)
        let radiansPerPoint = 2 * Double.pi * cos(radians) / worldWidth
        return (primeVerticalRadius * radiansPerPoint, meridionalRadius * radiansPerPoint)
    }

    private static func point(_ coordinate: EarthGeographicOrigin, nearX: Double? = nil) -> MKMapPoint
    {
        var point = MKMapPoint(CLLocationCoordinate2D(latitude: coordinate.latitude, longitude: coordinate.longitude))
        if let nearX { point.x += ((nearX - point.x) / worldWidth).rounded() * worldWidth }
        return point
    }

    private static func coordinate(x: Double, y: Double) -> CLLocationCoordinate2D
    {
        MKMapPoint(x: x - floor(x / worldWidth) * worldWidth, y: y).coordinate
    }
}
