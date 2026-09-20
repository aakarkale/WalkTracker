import Foundation
import CoreLocation

/// Geodesic helpers used across tracking, matching and coverage.
///
/// All city-scale work is done in a local tangent-plane ("ENU") projection
/// anchored at a reference coordinate. For the distances this app deals with
/// (street blocks of tens of metres, cities spanning tens of kilometres) the
/// equirectangular approximation is accurate to well under a metre, which is
/// an order of magnitude below GPS noise. Anything that needs true geodesic
/// accuracy uses `haversine`.
public enum GeoMath {

    /// IUGG mean Earth radius in metres.
    public static let earthRadius: Double = 6_371_008.8

    // MARK: - Geodesic

    /// Great-circle distance in metres between two coordinates.
    public static func haversine(_ a: Coordinate, _ b: Coordinate) -> Double {
        let phi1 = a.latitude * .pi / 180
        let phi2 = b.latitude * .pi / 180
        let dPhi = (b.latitude - a.latitude) * .pi / 180
        let dLambda = (b.longitude - a.longitude) * .pi / 180

        let sinDPhi = sin(dPhi / 2)
        let sinDLambda = sin(dLambda / 2)
        let h = sinDPhi * sinDPhi + cos(phi1) * cos(phi2) * sinDLambda * sinDLambda
        return 2 * earthRadius * asin(min(1, sqrt(max(0, h))))
    }

    /// Initial bearing in degrees (0 = north, clockwise) from `a` to `b`.
    public static func bearing(from a: Coordinate, to b: Coordinate) -> Double {
        let phi1 = a.latitude * .pi / 180
        let phi2 = b.latitude * .pi / 180
        let dLambda = (b.longitude - a.longitude) * .pi / 180

        let y = sin(dLambda) * cos(phi2)
        let x = cos(phi1) * sin(phi2) - sin(phi1) * cos(phi2) * cos(dLambda)
        let deg = atan2(y, x) * 180 / .pi
        return deg < 0 ? deg + 360 : deg
    }

    /// Smallest absolute difference between two bearings, in degrees (0...180).
    public static func bearingDelta(_ a: Double, _ b: Double) -> Double {
        var d = abs(a - b).truncatingRemainder(dividingBy: 360)
        if d > 180 { d = 360 - d }
        return d
    }

    // MARK: - Local projection

    /// Metres-per-degree of longitude at a given latitude.
    public static func metresPerDegreeLongitude(atLatitude lat: Double) -> Double {
        earthRadius * .pi / 180 * cos(lat * .pi / 180)
    }

    /// Metres-per-degree of latitude (constant under the spherical model).
    public static let metresPerDegreeLatitude: Double = earthRadius * .pi / 180

    /// Converts a coordinate into local east/north metres relative to `origin`.
    public static func project(_ c: Coordinate, origin: Coordinate) -> Point2D {
        Point2D(
            x: (c.longitude - origin.longitude) * metresPerDegreeLongitude(atLatitude: origin.latitude),
            y: (c.latitude - origin.latitude) * metresPerDegreeLatitude
        )
    }

    /// Inverse of `project`.
    public static func unproject(_ p: Point2D, origin: Coordinate) -> Coordinate {
        Coordinate(
            latitude: origin.latitude + p.y / metresPerDegreeLatitude,
            longitude: origin.longitude + p.x / metresPerDegreeLongitude(atLatitude: origin.latitude)
        )
    }

    // MARK: - Point / segment geometry

    /// Projects `p` onto the finite segment `a`->`b` in a planar space.
    ///
    /// - Returns: `t`, the clamped position along the segment in `0...1`, and
    ///   the perpendicular distance from `p` to that closest point.
    public static func projectOntoSegment(_ p: Point2D, _ a: Point2D, _ b: Point2D) -> (t: Double, distance: Double) {
        let vx = b.x - a.x
        let vy = b.y - a.y
        let lengthSquared = vx * vx + vy * vy

        guard lengthSquared > 1e-12 else {
            return (0, hypot(p.x - a.x, p.y - a.y))
        }

        let raw = ((p.x - a.x) * vx + (p.y - a.y) * vy) / lengthSquared
        let t = min(1, max(0, raw))
        let closest = Point2D(x: a.x + t * vx, y: a.y + t * vy)
        return (t, hypot(p.x - closest.x, p.y - closest.y))
    }
}

/// A point in a local tangent-plane projection, in metres.
public struct Point2D: Equatable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}
