import Foundation
import simd

public struct EarthGeographicOrigin: Codable, Equatable, Sendable
{
    public let latitude: Double
    public let longitude: Double
    public let ellipsoidHeight: Double

    public init(
        latitude: Double,
        longitude: Double,
        ellipsoidHeight: Double = 0
    ) throws
    {
        guard latitude.isFinite, longitude.isFinite, ellipsoidHeight.isFinite,
              (-90 ... 90).contains(latitude), (-180 ... 180).contains(longitude)
        else { throw EarthImportError.invalidContent("Geographic origin is outside its valid range.") }
        self.latitude = latitude
        self.longitude = longitude
        self.ellipsoidHeight = ellipsoidHeight
    }

    private enum CodingKeys: String, CodingKey { case latitude, longitude, ellipsoidHeight }

    public init(from decoder: any Decoder) throws
    {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(latitude: values.decode(Double.self, forKey: .latitude), longitude: values.decode(Double.self, forKey: .longitude), ellipsoidHeight: values.decode(Double.self, forKey: .ellipsoidHeight))
    }

    /// WGS84 Earth-centered coordinates to local East / Up / South, in meters.
    public var earthCenteredToLocal: simd_double4x4
    {
        let latitudeRadians = latitude * .pi / 180
        let longitudeRadians = longitude * .pi / 180
        let sineLatitude = sin(latitudeRadians)
        let cosineLatitude = cos(latitudeRadians)
        let sineLongitude = sin(longitudeRadians)
        let cosineLongitude = cos(longitudeRadians)
        let eccentricitySquared = 6.6943799901413165e-3
        let primeVerticalRadius = 6378137 / sqrt(1 - eccentricitySquared * sineLatitude * sineLatitude)
        let origin = SIMD3<Double>(
            (primeVerticalRadius + ellipsoidHeight) * cosineLatitude * cosineLongitude,
            (primeVerticalRadius + ellipsoidHeight) * cosineLatitude * sineLongitude,
            (primeVerticalRadius * (1 - eccentricitySquared) + ellipsoidHeight) * sineLatitude
        )
        let east = SIMD3<Double>(-sineLongitude, cosineLongitude, 0)
        let up = SIMD3<Double>(cosineLatitude * cosineLongitude, cosineLatitude * sineLongitude, sineLatitude)
        let south = SIMD3<Double>(sineLatitude * cosineLongitude, sineLatitude * sineLongitude, -cosineLatitude)
        return simd_double4x4(columns: (
            SIMD4(east.x, up.x, south.x, 0),
            SIMD4(east.y, up.y, south.y, 0),
            SIMD4(east.z, up.z, south.z, 0),
            SIMD4(-simd_dot(east, origin), -simd_dot(up, origin), -simd_dot(south, origin), 1)
        ))
    }

    static func makeOrigin(earthCenteredPosition: SIMD3<Double>) throws -> EarthGeographicOrigin
    {
        let equatorialRadius = 6378137.0
        let polarRadius = 6356752.314245179
        let eccentricitySquared = 6.6943799901413165e-3
        let secondEccentricitySquared = 6.739496742276434e-3
        let horizontalDistance = hypot(earthCenteredPosition.x, earthCenteredPosition.y)
        guard simd_length(earthCenteredPosition).isFinite,
              simd_length(earthCenteredPosition) > 1000000
        else { throw EarthImportError.invalidContent("Tileset bounds do not define an Earth-centered origin.") }
        let theta = atan2(earthCenteredPosition.z * equatorialRadius, horizontalDistance * polarRadius)
        let latitude = atan2(
            earthCenteredPosition.z + secondEccentricitySquared * polarRadius * pow(sin(theta), 3),
            horizontalDistance - eccentricitySquared * equatorialRadius * pow(cos(theta), 3)
        )
        let longitude = atan2(earthCenteredPosition.y, earthCenteredPosition.x)
        let primeVerticalRadius = equatorialRadius / sqrt(1 - eccentricitySquared * pow(sin(latitude), 2))
        let height: Double
        if horizontalDistance < 1e-6
        {
            height = abs(earthCenteredPosition.z) - polarRadius
        }
        else
        {
            height = horizontalDistance / cos(latitude) - primeVerticalRadius
        }
        return try EarthGeographicOrigin(latitude: latitude * 180 / .pi, longitude: longitude * 180 / .pi, ellipsoidHeight: height)
    }
}
