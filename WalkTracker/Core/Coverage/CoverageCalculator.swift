import Foundation

/// Turns stored coverage into the numbers the app actually shows.
public struct CoverageCalculator {

    public struct CityStats: Equatable, Sendable {
        public let cityID: String
        /// Metres of street walked, counting partial blocks proportionally.
        public let walkedMetres: Double
        /// Denominator: total walkable street in the city.
        public let totalMetres: Double
        /// Blocks walked past the completion threshold.
        public let completedBlocks: Int
        public let totalBlocks: Int

        public var fraction: Double {
            totalMetres > 0 ? min(1, walkedMetres / totalMetres) : 0
        }

        /// Percentage, floored rather than rounded below 100.
        ///
        /// Rounding 99.6% up to 100% tells someone they have finished a city
        /// when several streets are still missing, which is the one number in
        /// this app that must never lie.
        public var displayPercentage: Double {
            let raw = fraction * 100
            guard raw < 100 else { return 100 }
            return (raw * 10).rounded(.down) / 10
        }

        public var isComplete: Bool {
            totalBlocks > 0 && completedBlocks >= totalBlocks
        }
    }

    public struct DistrictStats: Identifiable, Equatable, Sendable {
        public let id: Int64
        public let name: String
        public let walkedMetres: Double
        public let totalMetres: Double
        public let completedBlocks: Int
        public let totalBlocks: Int

        public var fraction: Double {
            totalMetres > 0 ? min(1, walkedMetres / totalMetres) : 0
        }
    }

    private let packStore: CityPackStore
    private let coverageStore: CoverageStore

    public init(packStore: CityPackStore, coverageStore: CoverageStore) {
        self.packStore = packStore
        self.coverageStore = coverageStore
    }

    /// Headline stats for a city.
    ///
    /// - Parameter includeOptional: whether alleys, stairs and tracks count.
    ///   Off by default: including them makes a city look unfinishable and
    ///   punishes people for not walking every service road.
    public func cityStats(cityID: String, includeOptional: Bool = false) throws -> CityStats {
        let fractions = try coverageStore.fractions(forCity: cityID)
        let segments = packStore.segments(in: packStore.meta.bounds)

        var walked: Double = 0
        var completed = 0
        var total: Double = 0
        var totalBlocks = 0

        for segment in segments {
            guard includeOptional || !segment.wayClass.isOptionalByDefault else { continue }
            total += segment.length
            totalBlocks += 1

            guard let fraction = fractions[segment.id] else { continue }
            walked += fraction * segment.length
            if fraction >= SegmentCoverage.completionThreshold { completed += 1 }
        }

        return CityStats(
            cityID: cityID,
            walkedMetres: walked,
            totalMetres: total,
            completedBlocks: completed,
            totalBlocks: totalBlocks
        )
    }

    /// Per-neighbourhood breakdown, most complete first.
    public func districtStats(cityID: String, includeOptional: Bool = false) throws -> [DistrictStats] {
        let fractions = try coverageStore.fractions(forCity: cityID)
        let districts = packStore.districts()
        guard !districts.isEmpty else { return [] }

        var walked: [Int64: Double] = [:]
        var total: [Int64: Double] = [:]
        var completed: [Int64: Int] = [:]
        var blocks: [Int64: Int] = [:]

        for segment in packStore.segments(in: packStore.meta.bounds) {
            guard let districtID = segment.districtID else { continue }
            guard includeOptional || !segment.wayClass.isOptionalByDefault else { continue }

            total[districtID, default: 0] += segment.length
            blocks[districtID, default: 0] += 1

            guard let fraction = fractions[segment.id] else { continue }
            walked[districtID, default: 0] += fraction * segment.length
            if fraction >= SegmentCoverage.completionThreshold {
                completed[districtID, default: 0] += 1
            }
        }

        return districts.map { district in
            DistrictStats(
                id: district.id,
                name: district.name,
                walkedMetres: walked[district.id] ?? 0,
                totalMetres: total[district.id] ?? district.totalLengthMetres,
                completedBlocks: completed[district.id] ?? 0,
                totalBlocks: blocks[district.id] ?? district.segmentCount
            )
        }.sorted { $0.fraction > $1.fraction }
    }

    /// Unwalked blocks nearest to a coordinate, for a "what should I walk
    /// next" suggestion.
    public func nearestUnwalked(
        to coordinate: Coordinate,
        cityID: String,
        radiusMetres: Double = 1_500,
        limit: Int = 20
    ) throws -> [StreetSegment] {
        let fractions = try coverageStore.fractions(forCity: cityID)
        let box = BoundingBox(
            minLatitude: coordinate.latitude,
            minLongitude: coordinate.longitude,
            maxLatitude: coordinate.latitude,
            maxLongitude: coordinate.longitude
        ).expanded(byMetres: radiusMetres)

        return packStore.segments(in: box)
            .filter { !$0.wayClass.isOptionalByDefault }
            .filter { (fractions[$0.id] ?? 0) < SegmentCoverage.completionThreshold }
            .map { ($0, GeoMath.haversine(coordinate, $0.geometry.coordinate(atFraction: 0.5))) }
            .filter { $0.1 <= radiusMetres }
            .sorted { $0.1 < $1.1 }
            .prefix(limit)
            .map(\.0)
    }
}
