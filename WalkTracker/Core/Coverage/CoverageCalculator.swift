import Foundation

/// Turns stored coverage into the numbers the app actually shows.
///
/// The denominators come from SQL aggregates over the pack, and the numerators
/// from the much smaller set of blocks the user has actually touched. Nothing
/// here loads a whole city: a large one runs to tens of thousands of blocks,
/// and summing them in memory would decode every geometry blob to use a single
/// number from each row.
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
        /// Rounding 99.96% up to 100% tells someone they have finished a city
        /// while streets are still missing. That is the one number in this app
        /// that must never overstate.
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
    /// - Parameter includeOptional: whether alleys, stairs and service roads
    ///   count. Off by default: including them makes a city look unfinishable
    ///   and penalises people for not walking every service road.
    public func cityStats(cityID: String, includeOptional: Bool = false) throws -> CityStats {
        let totals = packStore.totals(includeOptional: includeOptional)
        let fractions = try coverageStore.fractions(forCity: cityID)

        guard !fractions.isEmpty else {
            return CityStats(
                cityID: cityID,
                walkedMetres: 0,
                totalMetres: totals.lengthMetres,
                completedBlocks: 0,
                totalBlocks: totals.blockCount
            )
        }

        let summaries = packStore.summaries(ids: Array(fractions.keys))
        var walked: Double = 0
        var completed = 0

        for (segmentID, fraction) in fractions {
            // A coverage row with no matching block means the pack was
            // replaced without a rebuild. Skipping it keeps the percentage
            // honest until the rebuild runs.
            guard let summary = summaries[segmentID] else { continue }
            guard includeOptional || !summary.wayClass.isOptionalByDefault else { continue }

            walked += fraction * summary.lengthMetres
            if fraction >= SegmentCoverage.completionThreshold { completed += 1 }
        }

        return CityStats(
            cityID: cityID,
            walkedMetres: min(walked, totals.lengthMetres),
            totalMetres: totals.lengthMetres,
            completedBlocks: completed,
            totalBlocks: totals.blockCount
        )
    }

    /// Per-neighbourhood breakdown, most complete first.
    public func districtStats(cityID: String, includeOptional: Bool = false) throws -> [DistrictStats] {
        let districts = packStore.districts()
        guard !districts.isEmpty else { return [] }

        let totals = packStore.districtTotals(includeOptional: includeOptional)
        let fractions = try coverageStore.fractions(forCity: cityID)
        let summaries = fractions.isEmpty ? [:] : packStore.summaries(ids: Array(fractions.keys))

        var walked: [Int64: Double] = [:]
        var completed: [Int64: Int] = [:]

        for (segmentID, fraction) in fractions {
            guard let summary = summaries[segmentID], let districtID = summary.districtID else { continue }
            guard includeOptional || !summary.wayClass.isOptionalByDefault else { continue }

            walked[districtID, default: 0] += fraction * summary.lengthMetres
            if fraction >= SegmentCoverage.completionThreshold {
                completed[districtID, default: 0] += 1
            }
        }

        return districts.map { district in
            let total = totals[district.id]
            let totalMetres = total?.lengthMetres ?? district.totalLengthMetres
            return DistrictStats(
                id: district.id,
                name: district.name,
                walkedMetres: min(walked[district.id] ?? 0, totalMetres),
                totalMetres: totalMetres,
                completedBlocks: completed[district.id] ?? 0,
                totalBlocks: total?.blockCount ?? district.segmentCount
            )
        }.sorted { $0.fraction > $1.fraction }
    }

    /// Unwalked blocks nearest to a coordinate, to answer "what should I walk
    /// next".
    ///
    /// Bounded by a radius, so this one does load geometry: it needs the shape
    /// of each candidate to measure distance and to draw it.
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
