import Foundation

/// Owns the off-main half of a walk: persistence, smoothing and matching.
///
/// Split out from `TrackingEngine` because that type is `@MainActor`, and
/// every SQLite write it made would otherwise block the main thread. During
/// active tracking that is a write every few seconds, in an app whose main
/// screen is a scrolling map, which is exactly where a hitch is most visible.
///
/// Everything here runs on one serial queue. The smoother and the matcher hold
/// mutable sequence state and are touched from nowhere else, which is what
/// makes them safe without locks.
public final class WalkProcessor {

    public struct Outcome: Sendable {
        public let newCoverageMetres: Double
        public let segmentsTouched: Set<Int64>
        public let pointsPersisted: Int
    }

    private let sessionStore: SessionStore
    private let coverageStore: CoverageStore
    private let queue = DispatchQueue(label: "walktracker.walk-processor", qos: .utility)

    private var packStore: CityPackStore?
    private var cityID: String?

    private var smoother = LocationSmoother()
    private var matcher: MapMatcher?

    /// Raw fixes waiting to be written. Flushed on a size or time trigger so a
    /// burst delivered after a background wake costs one transaction rather
    /// than one per fix.
    private var pending: [TrackPoint] = []
    private var lastPersistedAt = Date.distantPast

    private static let flushCount = 20
    private static let flushInterval: TimeInterval = 15

    public init(sessionStore: SessionStore, coverageStore: CoverageStore) {
        self.sessionStore = sessionStore
        self.coverageStore = coverageStore
    }

    // MARK: - Configuration

    public func setCity(id: String, packStore: CityPackStore) {
        queue.async {
            self.cityID = id
            self.packStore = packStore
            self.matcher = MapMatcher(index: packStore)
            self.smoother = LocationSmoother()
        }
    }

    public func beginWalk() {
        queue.async {
            self.smoother = LocationSmoother()
            self.matcher?.reset()
            self.pending.removeAll(keepingCapacity: true)
            self.lastPersistedAt = .distantPast
        }
    }

    // MARK: - Ingest

    /// Records fixes and reports what they unlocked.
    ///
    /// - Parameter claimCoverage: false when motion data says the user is in a
    ///   vehicle. The fixes are still written to the trace, because the trace
    ///   is the record of where the phone went, but no street is credited.
    public func ingest(
        _ points: [TrackPoint],
        claimCoverage: Bool,
        completion: @escaping @Sendable (Outcome) -> Void
    ) {
        queue.async {
            var outcome = Outcome(newCoverageMetres: 0, segmentsTouched: [], pointsPersisted: 0)
            do {
                self.pending.append(contentsOf: points)
                let persisted = try self.flushPending(force: false)

                var claims: [CoverageClaim] = []
                if claimCoverage, let matcher = self.matcher {
                    for point in points {
                        if let smoothed = self.smoother.push(point) {
                            claims.append(contentsOf: matcher.ingest(smoothed))
                        }
                    }
                }
                let applied = try self.apply(claims)
                outcome = Outcome(
                    newCoverageMetres: applied.metres,
                    segmentsTouched: applied.touched,
                    pointsPersisted: persisted
                )
            } catch {
                // A dropped fix is recoverable. The trace already on disk is
                // what matters, and coverage can be rebuilt from it later.
                NSLog("WalkTracker: failed to record fixes: \(error.localizedDescription)")
            }
            completion(outcome)
        }
    }

    /// Drains both stages and writes everything still buffered.
    ///
    /// Without this the last partial smoothing bucket and the tail of the
    /// Viterbi window are silently discarded, which loses the final stretch of
    /// every walk.
    public func endWalk(completion: @escaping @Sendable (Outcome) -> Void) {
        queue.async {
            var outcome = Outcome(newCoverageMetres: 0, segmentsTouched: [], pointsPersisted: 0)
            do {
                var claims: [CoverageClaim] = []
                if let matcher = self.matcher {
                    if let tail = self.smoother.flush() {
                        claims.append(contentsOf: matcher.ingest(tail))
                    }
                    claims.append(contentsOf: matcher.flush())
                }
                let persisted = try self.flushPending(force: true)
                let applied = try self.apply(claims)
                outcome = Outcome(
                    newCoverageMetres: applied.metres,
                    segmentsTouched: applied.touched,
                    pointsPersisted: persisted
                )
            } catch {
                NSLog("WalkTracker: failed to finalise walk: \(error.localizedDescription)")
            }
            completion(outcome)
        }
    }

    /// Writes session totals. Called after `endWalk` has drained everything.
    public func finalise(
        sessionID: Int64,
        distanceMetres: Double,
        newCoverageMetres: Double,
        pointCount: Int,
        completion: @escaping @Sendable (Error?) -> Void
    ) {
        queue.async {
            do {
                try self.sessionStore.updateTotals(
                    id: sessionID,
                    distanceMetres: distanceMetres,
                    newCoverageMetres: newCoverageMetres,
                    pointCount: pointCount
                )
                try self.sessionStore.endSession(id: sessionID)
                completion(nil)
            } catch {
                completion(error)
            }
        }
    }

    // MARK: - Internals

    private func apply(_ claims: [CoverageClaim]) throws -> (metres: Double, touched: Set<Int64>) {
        guard !claims.isEmpty, let cityID, let packStore else { return (0, []) }
        let metres = try coverageStore.apply(claims, cityID: cityID) { segmentID in
            packStore.segment(id: segmentID)?.length
        }
        return (metres, Set(claims.map(\.segmentID)))
    }

    @discardableResult
    private func flushPending(force: Bool) throws -> Int {
        guard !pending.isEmpty else { return 0 }
        let elapsed = Date().timeIntervalSince(lastPersistedAt)
        guard force || pending.count >= Self.flushCount || elapsed >= Self.flushInterval else { return 0 }

        let batch = pending
        pending.removeAll(keepingCapacity: true)
        lastPersistedAt = Date()
        try sessionStore.appendPoints(batch)
        return batch.count
    }
}
