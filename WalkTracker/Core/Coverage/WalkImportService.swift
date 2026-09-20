import Foundation

/// Turns imported tracks into sessions and coverage.
///
/// Imported points go through exactly the same smoothing and matching as live
/// ones. That matters: if imports took a shortcut, a street credited from an
/// import and the same street credited from a live walk would mean different
/// things, and the percentage would stop being one number.
public final class WalkImportService {

    public struct Result: Equatable, Sendable {
        public var sessionsCreated = 0
        public var sessionsSkippedAsDuplicate = 0
        public var pointsImported = 0
        public var pointsOutsideCity = 0
        public var newCoverageMetres: Double = 0
        public var tracksTooShort = 0

        public var isEmpty: Bool {
            sessionsCreated == 0 && sessionsSkippedAsDuplicate == 0
        }
    }

    /// Tracks with fewer points than this cannot say anything useful about a
    /// route and are skipped.
    public static let minimumPoints = 8

    private let sessionStore: SessionStore
    private let coverageStore: CoverageStore

    public init(sessionStore: SessionStore, coverageStore: CoverageStore) {
        self.sessionStore = sessionStore
        self.coverageStore = coverageStore
    }

    /// Imports tracks into one city.
    ///
    /// - Parameter progress: 0...1, called as tracks are processed. A year of
    ///   history is a long operation and must be visible.
    @discardableResult
    public func importTracks(
        _ tracks: [GPXImporter.Track],
        cityID: String,
        packStore: CityPackStore,
        source: WalkSource,
        progress: ((Double) -> Void)? = nil
    ) throws -> Result {
        var result = Result()
        guard !tracks.isEmpty else { return result }

        let bounds = packStore.meta.bounds
        let existing = try sessionStore.recentSessions(cityID: cityID, limit: 5_000)

        for (index, track) in tracks.enumerated() {
            defer { progress?(Double(index + 1) / Double(tracks.count)) }

            // Only points inside the city can be matched against its pack.
            // Someone's GPX history spans holidays and other cities, and the
            // rest of it is simply not this city's business.
            let inside = track.points.filter { bounds.contains($0.coordinate) }
            result.pointsOutsideCity += track.points.count - inside.count

            guard inside.count >= Self.minimumPoints else {
                if !inside.isEmpty { result.tracksTooShort += 1 }
                continue
            }
            guard let first = inside.first, let last = inside.last else { continue }

            // Re-importing the same export is the normal case, not an edge
            // case: people export again to pick up new walks. Coverage would
            // merge harmlessly, but the history would fill with duplicates.
            if existing.contains(where: { overlaps($0, from: first.timestamp, to: last.timestamp) }) {
                result.sessionsSkippedAsDuplicate += 1
                continue
            }

            let session = try sessionStore.startSession(
                cityID: cityID,
                at: first.timestamp,
                source: source
            )

            let stamped = inside.map {
                TrackPoint(
                    sessionID: session.id,
                    timestamp: $0.timestamp,
                    coordinate: $0.coordinate,
                    horizontalAccuracy: $0.horizontalAccuracy,
                    speed: $0.speed,
                    course: $0.course,
                    altitude: $0.altitude
                )
            }
            try sessionStore.appendPoints(stamped)

            let outcome = try match(stamped, cityID: cityID, packStore: packStore)

            try sessionStore.updateTotals(
                id: session.id,
                distanceMetres: distance(of: stamped),
                newCoverageMetres: outcome,
                pointCount: stamped.count
            )
            try sessionStore.endSession(id: session.id, at: last.timestamp)

            result.sessionsCreated += 1
            result.pointsImported += stamped.count
            result.newCoverageMetres += outcome
        }

        return result
    }

    // MARK: - Internals

    /// Two sessions covering the same stretch of time are the same walk.
    private func overlaps(_ session: WalkSession, from: Date, to: Date) -> Bool {
        let end = session.endedAt ?? session.startedAt
        return session.startedAt <= to && end >= from
    }

    private func match(
        _ points: [TrackPoint],
        cityID: String,
        packStore: CityPackStore
    ) throws -> Double {
        let smoother = LocationSmoother()
        let matcher = MapMatcher(index: packStore)
        var claims: [CoverageClaim] = []

        for point in points {
            if let smoothed = smoother.push(point) {
                claims.append(contentsOf: matcher.ingest(smoothed))
            }
        }
        if let tail = smoother.flush() {
            claims.append(contentsOf: matcher.ingest(tail))
        }
        claims.append(contentsOf: matcher.flush())

        return try coverageStore.apply(claims, cityID: cityID) { segmentID in
            packStore.segment(id: segmentID)?.length
        }
    }

    /// Walked distance from the raw trace.
    ///
    /// Imported points carry no real accuracy figure, so unlike live tracking
    /// there is no per-fix noise floor to subtract. A flat minimum step stands
    /// in for it, which stops a stationary GPS logger clocking up kilometres.
    private func distance(of points: [TrackPoint]) -> Double {
        guard points.count > 1 else { return 0 }
        var total: Double = 0
        for i in 1..<points.count {
            let step = GeoMath.haversine(points[i - 1].coordinate, points[i].coordinate)
            if step > 3 { total += step }
        }
        return total
    }
}
