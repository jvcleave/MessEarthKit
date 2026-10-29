import Foundation
import simd

struct EarthRegionSelection
{
    let center: EarthGeographicOrigin
    let widthMeters: Double
    let depthMeters: Double
    let maximumGeometricErrorMeters: Double

    init(request: EarthCaptureRequest)
    {
        center = request.center
        widthMeters = request.widthMeters
        depthMeters = request.depthMeters
        maximumGeometricErrorMeters = request.maximumGeometricErrorMeters
    }

    init(request: EarthDownloadRequest)
    {
        center = request.center
        widthMeters = request.widthMeters
        depthMeters = request.depthMeters
        maximumGeometricErrorMeters = request.maximumGeometricErrorMeters
    }

    func intersects(
        bounds: EarthTileset.BoundingVolume,
        transform: simd_double4x4
    ) throws -> Bool
    {
        if let region = bounds.region
        {
            return try intersectsRegion(region)
        }
        if widthMeters > 5000 || depthMeters > 5000
        { return try intersectsLargeFootprint(bounds: bounds, transform: transform) }
        let earthCenteredToLocal = center.earthCenteredToLocal
        let local = earthCenteredToLocal * transform
        // East/South projection alone also overlaps tiles on the far side of
        // Earth. Cull bounds wholly behind the plane through Earth's center;
        // bounds crossing it still survive, including globe-sized root tiles.
        let earthCenterUp = earthCenteredToLocal.columns.3.y
        if let box = bounds.box
        {
            guard box.count == 12, box.allSatisfy(\.isFinite)
            else { throw EarthImportError.invalidContent("Tile box bounds are invalid.") }
            let center = local * SIMD4(box[0], box[1], box[2], 1)
            var extents = SIMD3<Double>.zero
            for offset in stride(from: 3, through: 9, by: 3)
            {
                let axis = local * SIMD4(box[offset], box[offset + 1], box[offset + 2], 0)
                extents += SIMD3(abs(axis.x), abs(axis.y), abs(axis.z))
            }
            return center.y + extents.y >= earthCenterUp && abs(center.x) <= widthMeters / 2 + extents.x && abs(center.z) <= depthMeters / 2 + extents.z
        }
        if let sphere = bounds.sphere
        {
            guard sphere.count == 4, sphere.allSatisfy(\.isFinite), sphere[3] >= 0
            else { throw EarthImportError.invalidContent("Tile sphere bounds are invalid.") }
            let center = local * SIMD4(sphere[0], sphere[1], sphere[2], 1)
            let eastScale = simd_length(SIMD3(local.columns.0.x, local.columns.1.x, local.columns.2.x))
            let upScale = simd_length(SIMD3(local.columns.0.y, local.columns.1.y, local.columns.2.y))
            let southScale = simd_length(SIMD3(local.columns.0.z, local.columns.1.z, local.columns.2.z))
            return center.y + sphere[3] * upScale >= earthCenterUp && abs(center.x) <= widthMeters / 2 + sphere[3] * eastScale && abs(center.z) <= depthMeters / 2 + sphere[3] * southScale
        }
        throw EarthImportError.invalidContent("A tile needs supported bounding-volume data.")
    }

    private func intersectsRegion(_ region: [Double]) throws -> Bool
    {
        guard region.count == 6, region.allSatisfy(\.isFinite), region[1] <= region[3], region[4] <= region[5],
              abs(region[0]) <= .pi, abs(region[2]) <= .pi, abs(region[1]) <= .pi / 2, abs(region[3]) <= .pi / 2
        else { throw EarthImportError.invalidContent("Tile region bounds are invalid.") }
        let latitude = center.latitude * .pi / 180
        let longitude = center.longitude * .pi / 180
        // Conservative WGS84 surface envelope. Reaching either pole spans all
        // longitudes. Wrapping is explicit; dimensions are never clamped to 5 km.
        let latitudeRadius = depthMeters / 2 / 6300000 * 1.01
        guard latitude + latitudeRadius >= region[1], latitude - latitudeRadius <= region[3] else { return false }
        let maximumAbsoluteLatitude = min(.pi / 2, abs(latitude) + latitudeRadius)
        let longitudeRadius = maximumAbsoluteLatitude >= .pi / 2 ? .pi : min(.pi, widthMeters / 2 / (6300000 * max(1e-6, cos(maximumAbsoluteLatitude))) * 1.01)
        let east = region[2] < region[0] ? region[2] + 2 * .pi : region[2]
        for shift in [-2 * Double.pi, 0, 2 * Double.pi]
        {
            if longitude + shift + longitudeRadius >= region[0], longitude + shift - longitudeRadius <= east { return true }
        }
        return false
    }

    /// Large footprints need surface bounds rather than an orthographic local
    /// projection, which folds distant content onto the same rectangle.
    private func intersectsLargeFootprint(bounds: EarthTileset.BoundingVolume, transform: simd_double4x4) throws -> Bool
    {
        let position: SIMD4<Double>
        let radius: Double
        if let sphere = bounds.sphere, sphere.count == 4, sphere.allSatisfy(\.isFinite), sphere[3] >= 0
        {
            position = transform * SIMD4(sphere[0], sphere[1], sphere[2], 1)
            radius = sphere[3] * errorScale(transform: transform)
        }
        else if let box = bounds.box, box.count == 12, box.allSatisfy(\.isFinite)
        {
            position = transform * SIMD4(box[0], box[1], box[2], 1)
            radius = stride(from: 3, through: 9, by: 3).reduce(0)
            { total, offset in
                let axis = transform * SIMD4(box[offset], box[offset + 1], box[offset + 2], 0)
                return total + simd_length(SIMD3(axis.x, axis.y, axis.z))
            }
        }
        else { throw EarthImportError.invalidContent("A tile needs supported bounding-volume data.") }
        let distance = simd_length(SIMD3(position.x, position.y, position.z))
        guard distance.isFinite, radius.isFinite else { throw EarthImportError.invalidContent("Non-finite transformed bounds.") }
        if distance <= radius { return true }
        let angle = asin(min(1, radius / distance))
        let geocentricLatitude = asin(max(-1, min(1, position.z / distance)))
        let latitude = try EarthGeographicOrigin.makeOrigin(earthCenteredPosition: SIMD3(position.x, position.y, position.z)).latitude * .pi / 180
        // Bound ellipsoid latitude variation rather than padding every tile by
        // the full geodetic/geocentric difference (which would overfetch km).
        let latitudeRadius = angle * 1.01 + 0.004 * radius / max(1, distance - radius)
        let longitude = atan2(position.y, position.x)
        let south = max(-.pi / 2, latitude - latitudeRadius)
        let north = min(.pi / 2, latitude + latitudeRadius)
        let longitudeRadius = abs(geocentricLatitude) + angle >= .pi / 2 ? .pi : asin(min(1, sin(angle) / cos(geocentricLatitude)))
        func wrap(_ value: Double) -> Double
        { value > .pi ? value - 2 * .pi : value < -.pi ? value + 2 * .pi : value }
        let west = longitudeRadius >= .pi ? -.pi : wrap(longitude - longitudeRadius)
        let east = longitudeRadius >= .pi ? .pi : wrap(longitude + longitudeRadius)
        return try intersectsRegion([west, south, east, north, 0, 0])
    }

    /// Upper bound for geometric error under an arbitrary affine linear transform.
    func errorScale(transform: simd_double4x4) -> Double
    {
        let first = SIMD3(transform.columns.0.x, transform.columns.0.y, transform.columns.0.z)
        let second = SIMD3(transform.columns.1.x, transform.columns.1.y, transform.columns.1.z)
        let third = SIMD3(transform.columns.2.x, transform.columns.2.y, transform.columns.2.z)
        // sqrt(||A||1 * ||A||infinity) bounds the spectral norm, including shear,
        // while returning exactly one for the common identity transform.
        let oneNorm = max(abs(first.x) + abs(first.y) + abs(first.z), max(abs(second.x) + abs(second.y) + abs(second.z), abs(third.x) + abs(third.y) + abs(third.z)))
        let infinityNorm = max(abs(first.x) + abs(second.x) + abs(third.x), max(abs(first.y) + abs(second.y) + abs(third.y), abs(first.z) + abs(second.z) + abs(third.z)))
        return sqrt(oneNorm * infinityNorm)
    }
}
