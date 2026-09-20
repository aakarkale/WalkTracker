import Foundation

/// An ordered run of coordinates with precomputed cumulative lengths.
///
/// A `Polyline` is the geometry of one street segment (a single block between
/// two intersections). Cumulative lengths are computed once at construction so
/// the matcher can convert between "metres along the block" and "fraction of
/// the block" without re-walking the vertex list on every GPS fix.
public struct Polyline: Equatable, Sendable {

    public let coordinates: [Coordinate]

    /// `cumulative[i]` is the distance in metres from the start to vertex `i`.
    /// Always has the same count as `coordinates`, starting at 0.
    public let cumulative: [Double]

    /// Total length in metres.
    public var length: Double { cumulative.last ?? 0 }

    /// Local projection origin. Kept stable so repeated projections agree.
    public let origin: Coordinate

    private let projected: [Point2D]

    public init(coordinates: [Coordinate]) {
        precondition(!coordinates.isEmpty, "Polyline requires at least one coordinate")
        self.coordinates = coordinates
        self.origin = coordinates[0]

        var projected: [Point2D] = []
        projected.reserveCapacity(coordinates.count)
        for c in coordinates {
            projected.append(GeoMath.project(c, origin: coordinates[0]))
        }
        self.projected = projected

        var cumulative: [Double] = [0]
        cumulative.reserveCapacity(coordinates.count)
        var total: Double = 0
        for i in 1..<max(1, projected.count) {
            total += hypot(projected[i].x - projected[i - 1].x, projected[i].y - projected[i - 1].y)
            cumulative.append(total)
        }
        self.cumulative = cumulative
    }

    // MARK: - Projection

    public struct Projection: Equatable, Sendable {
        /// Position along the polyline as a fraction of total length, 0...1.
        public let fraction: Double
        /// Distance from the queried point to the polyline, in metres.
        public let distance: Double
        /// Distance along the polyline in metres.
        public let offset: Double
        /// Bearing of the polyline at the projected point, degrees.
        public let bearing: Double
    }

    /// Finds the closest point on the polyline to `c`.
    ///
    /// Runs a linear scan over vertices. Segments are single city blocks, so
    /// vertex counts are small (typically under 20) and a scan beats any index.
    public func project(_ c: Coordinate) -> Projection {
        guard coordinates.count > 1 else {
            return Projection(
                fraction: 0,
                distance: GeoMath.haversine(c, coordinates[0]),
                offset: 0,
                bearing: 0
            )
        }

        let p = GeoMath.project(c, origin: origin)
        var bestDistance = Double.greatestFiniteMagnitude
        var bestOffset: Double = 0
        var bestIndex = 1

        for i in 1..<projected.count {
            let a = projected[i - 1]
            let b = projected[i]
            let hit = GeoMath.projectOntoSegment(p, a, b)
            if hit.distance < bestDistance {
                bestDistance = hit.distance
                bestIndex = i
                bestOffset = cumulative[i - 1] + hit.t * (cumulative[i] - cumulative[i - 1])
            }
        }

        let total = length
        let bearing = GeoMath.bearing(from: coordinates[bestIndex - 1], to: coordinates[bestIndex])

        return Projection(
            fraction: total > 0 ? min(1, max(0, bestOffset / total)) : 0,
            distance: bestDistance,
            offset: bestOffset,
            bearing: bearing
        )
    }

    /// Returns the coordinate at `fraction` (0...1) along the polyline.
    public func coordinate(atFraction fraction: Double) -> Coordinate {
        guard coordinates.count > 1 else { return coordinates[0] }
        let target = min(1, max(0, fraction)) * length
        guard target > 0 else { return coordinates[0] }
        guard target < length else { return coordinates[coordinates.count - 1] }

        // `cumulative` is sorted ascending, so binary search the containing span.
        var low = 1
        var high = cumulative.count - 1
        while low < high {
            let mid = (low + high) / 2
            if cumulative[mid] < target { low = mid + 1 } else { high = mid }
        }

        let span = cumulative[low] - cumulative[low - 1]
        let t = span > 1e-9 ? (target - cumulative[low - 1]) / span : 0
        let a = projected[low - 1]
        let b = projected[low]
        return GeoMath.unproject(Point2D(x: a.x + t * (b.x - a.x), y: a.y + t * (b.y - a.y)), origin: origin)
    }

    /// Returns the sub-polyline covering `from...to` expressed as fractions.
    public func slice(from: Double, to: Double) -> [Coordinate] {
        let lo = min(1, max(0, min(from, to)))
        let hi = min(1, max(0, max(from, to)))
        guard hi > lo, length > 0 else { return [] }

        let loOffset = lo * length
        let hiOffset = hi * length

        var result: [Coordinate] = [coordinate(atFraction: lo)]
        for i in 0..<coordinates.count {
            let offset = cumulative[i]
            if offset > loOffset && offset < hiOffset {
                result.append(coordinates[i])
            }
        }
        result.append(coordinate(atFraction: hi))
        return result
    }

    public var boundingBox: BoundingBox {
        // Safe to force-unwrap: the initializer rejects empty coordinate lists.
        BoundingBox(containing: coordinates)!
    }
}
