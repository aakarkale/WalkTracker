import Foundation
import CoreLocation

/// A plain latitude/longitude pair.
///
/// Deliberately independent of `CLLocationCoordinate2D` so that the matching
/// and coverage code stays pure, testable and free of CoreLocation, which
/// cannot be instantiated meaningfully outside a device context.
public struct Coordinate: Equatable, Hashable, Codable, Sendable {
    public var latitude: Double
    public var longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }

    public init(_ c: CLLocationCoordinate2D) {
        self.latitude = c.latitude
        self.longitude = c.longitude
    }

    public var clCoordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    /// Rejects NaN, out-of-range and the null-island sentinel that some
    /// hardware emits when it has no fix at all.
    public var isValid: Bool {
        guard latitude.isFinite, longitude.isFinite else { return false }
        guard latitude >= -90, latitude <= 90 else { return false }
        guard longitude >= -180, longitude <= 180 else { return false }
        if latitude == 0 && longitude == 0 { return false }
        return true
    }
}

/// An axis-aligned geographic bounding box.
public struct BoundingBox: Equatable, Hashable, Codable, Sendable {
    public var minLatitude: Double
    public var minLongitude: Double
    public var maxLatitude: Double
    public var maxLongitude: Double

    public init(minLatitude: Double, minLongitude: Double, maxLatitude: Double, maxLongitude: Double) {
        self.minLatitude = min(minLatitude, maxLatitude)
        self.minLongitude = min(minLongitude, maxLongitude)
        self.maxLatitude = max(minLatitude, maxLatitude)
        self.maxLongitude = max(minLongitude, maxLongitude)
    }

    public init?(containing coordinates: [Coordinate]) {
        guard let first = coordinates.first else { return nil }
        var minLat = first.latitude, maxLat = first.latitude
        var minLon = first.longitude, maxLon = first.longitude
        for c in coordinates.dropFirst() {
            minLat = min(minLat, c.latitude); maxLat = max(maxLat, c.latitude)
            minLon = min(minLon, c.longitude); maxLon = max(maxLon, c.longitude)
        }
        self.init(minLatitude: minLat, minLongitude: minLon, maxLatitude: maxLat, maxLongitude: maxLon)
    }

    public var center: Coordinate {
        Coordinate(
            latitude: (minLatitude + maxLatitude) / 2,
            longitude: (minLongitude + maxLongitude) / 2
        )
    }

    public func contains(_ c: Coordinate) -> Bool {
        c.latitude >= minLatitude && c.latitude <= maxLatitude &&
        c.longitude >= minLongitude && c.longitude <= maxLongitude
    }

    public func intersects(_ other: BoundingBox) -> Bool {
        !(other.minLatitude > maxLatitude || other.maxLatitude < minLatitude ||
          other.minLongitude > maxLongitude || other.maxLongitude < minLongitude)
    }

    /// Grows the box by `metres` on every side.
    public func expanded(byMetres metres: Double) -> BoundingBox {
        let dLat = metres / GeoMath.metresPerDegreeLatitude
        let lat = max(abs(minLatitude), abs(maxLatitude))
        let mpdLon = GeoMath.metresPerDegreeLongitude(atLatitude: lat)
        // Near the poles the longitude scale collapses; fall back to a full span.
        let dLon = mpdLon > 1 ? metres / mpdLon : 180
        return BoundingBox(
            minLatitude: max(-90, minLatitude - dLat),
            minLongitude: max(-180, minLongitude - dLon),
            maxLatitude: min(90, maxLatitude + dLat),
            maxLongitude: min(180, maxLongitude + dLon)
        )
    }
}
