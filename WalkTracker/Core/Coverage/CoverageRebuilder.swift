import Foundation

/// Recomputes a city's coverage from the stored raw traces.
///
/// This is the payoff for keeping every GPS fix. Coverage is derived from
/// three things that all change over time: the raw trace, the matching
/// algorithm, and the city pack. Segment ids in particular are pack-local, so
/// after a pack update a stored id may point at a different street entirely.
/// Rather than trying to migrate ids, the app throws the derived data away and
/// rebuilds it, which is both simpler and correct.
///
/// Runs are also what makes matcher improvements retroactive: a user who
/// updates the app gets better coverage on walks they took months ago.
public struct CoverageRebuilder {

    public struct Result: Equatable, Sendable {
        public let pointsProcessed: Int
        public let segmentsCovered: Int
        public let walkedMetres: Double
        public let duration: TimeInterval
    }

    private let sessionStore: SessionStore
    private let coverageStore: CoverageStore
    private let packStore: CityPackStore

    public init(sessionStore: SessionStore, coverageStore: CoverageStore, packStore: CityPackStore) {
        self.sessionStore = sessionStore
        self.coverageStore = coverageStore
        self.packStore = packStore
    }

    /// Discards and rebuilds all coverage for one city.
    ///
    /// - Parameter progress: called with a 0...1 fraction. Rebuilding a heavy
    ///   user's history means replaying hundreds of thousands of fixes, which
    ///   is far too slow to do without showing something.
    @discardableResult
    public func rebuild(
        cityID: String,
        progress: ((Double) -> Void)? = nil
    ) throws -> Result {
        let startedAt = Date()
        let points = try sessionStore.allPoints(cityID: cityID)

        try coverageStore.clearCoverage(forCity: cityID)
        guard !points.isEmpty else {
            return Result(pointsProcessed: 0, segmentsCovered: 0, walkedMetres: 0, duration: 0)
        }

        var smoother = LocationSmoother()
        let matcher = MapMatcher(index: packStore)
        var claims: [CoverageClaim] = []
        var touched = Set<Int64>()
        var totalMetres: Double = 0
        var currentSession = points[0].sessionID

        // Claims are applied in batches rather than one at a time: each apply
        // is a transaction, and one per fix would make a rebuild take minutes.
        let batchSize = 2_000

        func drain() throws {
            guard !claims.isEmpty else { return }
            let metres = try coverageStore.apply(claims, cityID: cityID) { segmentID in
                packStore.segment(id: segmentID)?.length
            }
            totalMetres += metres
            for claim in claims { touched.insert(claim.segmentID) }
            claims.removeAll(keepingCapacity: true)
        }

        for (index, point) in points.enumerated() {
            // Sessions are independent walks. Carrying matcher state across a
            // boundary would invent a route between where one walk ended and
            // the next began.
            if point.sessionID != currentSession {
                if let tail = smoother.flush() {
                    claims.append(contentsOf: matcher.ingest(tail))
                }
                claims.append(contentsOf: matcher.flush())
                smoother = LocationSmoother()
                matcher.reset()
                currentSession = point.sessionID
            }

            if let smoothed = smoother.push(point) {
                claims.append(contentsOf: matcher.ingest(smoothed))
            }

            if claims.count >= batchSize {
                try drain()
            }
            if index % 5_000 == 0 {
                progress?(Double(index) / Double(points.count))
            }
        }

        if let tail = smoother.flush() {
            claims.append(contentsOf: matcher.ingest(tail))
        }
        claims.append(contentsOf: matcher.flush())
        try drain()
        progress?(1)

        return Result(
            pointsProcessed: points.count,
            segmentsCovered: touched.count,
            walkedMetres: totalMetres,
            duration: Date().timeIntervalSince(startedAt)
        )
    }
}
