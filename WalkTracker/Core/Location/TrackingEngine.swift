import Foundation
import CoreLocation
import Combine

/// Orchestrates a walk: raw fixes in, persisted trace and coverage out.
///
/// Pipeline, in order: CoreLocation fix, gating, persistence of the raw trace,
/// smoothing, map matching, coverage claims, database. The raw trace is written
/// before anything is derived from it, so a crash mid-walk loses at most the
/// derived coverage, which can always be rebuilt, and never the trace, which
/// cannot.
@MainActor
public final class TrackingEngine: ObservableObject {

    public enum State: Equatable {
        case idle
        case tracking
        case paused(reason: PauseReason)

        public enum PauseReason: Equatable {
            case permissionLost
            case noCityPack
            case inVehicle
        }
    }

    @Published public private(set) var state: State = .idle
    @Published public private(set) var session: WalkSession?
    @Published public private(set) var distanceMetres: Double = 0
    @Published public private(set) var newCoverageMetres: Double = 0
    @Published public private(set) var lastFix: CLLocation?
    /// Segment ids touched during this walk, so the map can highlight them
    /// without re-reading the whole coverage table on every fix.
    @Published public private(set) var segmentsTouchedThisWalk: Set<Int64> = []

    private let tracker: LocationTracker
    private let sessionStore: SessionStore
    private let coverageStore: CoverageStore
    private var packStore: CityPackStore?
    private var cityID: String?

    private var smoother = LocationSmoother()
    private var matcher: MapMatcher?

    /// Raw fixes waiting to be written. Flushed on a size or time trigger
    /// rather than per fix, so a burst delivered after a background wake costs
    /// one transaction instead of dozens.
    private var pendingPoints: [TrackPoint] = []
    private var lastPersistedAt = Date.distantPast
    private var lastRawFix: CLLocation?

    private let processingQueue = DispatchQueue(label: "walktracker.tracking", qos: .utility)

    private static let flushCount = 20
    private static let flushInterval: TimeInterval = 15

    public init(
        tracker: LocationTracker,
        sessionStore: SessionStore,
        coverageStore: CoverageStore
    ) {
        self.tracker = tracker
        self.sessionStore = sessionStore
        self.coverageStore = coverageStore
        tracker.delegate = self
    }

    // MARK: - City

    /// Points the engine at a city and its installed pack.
    public func setCity(id: String, packStore: CityPackStore) {
        self.cityID = id
        self.packStore = packStore
        self.matcher = MapMatcher(index: packStore)
    }

    // MARK: - Lifecycle

    public func startWalk() throws {
        guard state != .tracking else { return }
        guard let cityID, packStore != nil else {
            state = .paused(reason: .noCityPack)
            return
        }

        let status = tracker.authorizationStatus
        guard status == .authorizedAlways || status == .authorizedWhenInUse else {
            state = .paused(reason: .permissionLost)
            return
        }

        let started = try sessionStore.startSession(cityID: cityID)
        session = started
        distanceMetres = 0
        newCoverageMetres = 0
        segmentsTouchedThisWalk = []
        lastRawFix = nil
        smoother = LocationSmoother()
        matcher?.reset()

        state = .tracking
        tracker.start()
    }

    public func stopWalk() throws {
        guard let session else {
            tracker.stop()
            state = .idle
            return
        }

        tracker.stop()

        // Drain both stages so the last partial bucket and the tail of the
        // Viterbi window are not silently discarded.
        if let tail = smoother.flush(), let matcher {
            let claims = matcher.ingest(tail)
            try applyClaims(claims)
        }
        if let matcher {
            try applyClaims(matcher.flush())
        }

        try persistPendingPoints(force: true)
        try sessionStore.updateTotals(
            id: session.id,
            distanceMetres: distanceMetres,
            newCoverageMetres: newCoverageMetres,
            pointCount: session.pointCount
        )
        try sessionStore.endSession(id: session.id)

        self.session = nil
        state = .idle
    }

    /// Closes a session left open by a crash or a kill during background
    /// tracking, so the history does not grow a session that never ends.
    public func recoverOpenSessionIfNeeded() throws {
        guard state == .idle, session == nil else { return }
        guard let open = try sessionStore.openSession() else { return }

        let points = try sessionStore.points(sessionID: open.id)
        let endedAt = points.last?.timestamp ?? open.startedAt
        try sessionStore.endSession(id: open.id, at: endedAt)
    }

    // MARK: - Ingest

    private func handle(locations: [CLLocation]) {
        guard state == .tracking, let session else { return }

        var accepted: [TrackPoint] = []

        for location in locations {
            let coordinate = Coordinate(location.coordinate)
            guard coordinate.isValid else { continue }
            // A negative accuracy means CoreLocation could not determine one.
            guard location.horizontalAccuracy >= 0 else { continue }

            // Fixes stamped before the walk began are cached from an earlier
            // session and would teleport the trace backwards.
            guard location.timestamp >= session.startedAt.addingTimeInterval(-2) else { continue }

            let point = TrackPoint(
                sessionID: session.id,
                timestamp: location.timestamp,
                coordinate: coordinate,
                horizontalAccuracy: location.horizontalAccuracy,
                speed: location.speed,
                course: location.course,
                altitude: location.altitude
            )
            accepted.append(point)

            if let previous = lastRawFix {
                let step = location.distance(from: previous)
                // Ignore steps that sit inside the combined error of the two
                // fixes: those are noise, and counting them inflates distance
                // for someone standing still.
                let noiseFloor = 0.5 * (location.horizontalAccuracy + previous.horizontalAccuracy)
                if step > noiseFloor {
                    distanceMetres += step
                }
            }
            lastRawFix = location
        }

        guard !accepted.isEmpty else { return }

        lastFix = locations.last
        pendingPoints.append(contentsOf: accepted)
        self.session?.pointCount += accepted.count

        do {
            try persistPendingPoints(force: false)
            try matchAndRecord(accepted)
        } catch {
            // Losing a fix is recoverable; tearing down the walk is not. The
            // trace is already on disk, so coverage can be rebuilt later.
            NSLog("WalkTracker: failed to record fixes: \(error.localizedDescription)")
        }
    }

    private func matchAndRecord(_ points: [TrackPoint]) throws {
        guard let matcher else { return }

        // Recorded either way, but coverage is only claimed when the user is
        // plausibly on foot. A bus ride down Fifth Avenue is not walking it.
        guard tracker.motionPermitsCoverage else { return }

        var claims: [CoverageClaim] = []
        for point in points {
            if let smoothed = smoother.push(point) {
                claims.append(contentsOf: matcher.ingest(smoothed))
            }
        }
        try applyClaims(claims)
    }

    private func applyClaims(_ claims: [CoverageClaim]) throws {
        guard !claims.isEmpty, let cityID, let packStore else { return }

        let gained = try coverageStore.apply(claims, cityID: cityID) { segmentID in
            packStore.segment(id: segmentID)?.length
        }
        newCoverageMetres += gained
        for claim in claims {
            segmentsTouchedThisWalk.insert(claim.segmentID)
        }
    }

    private func persistPendingPoints(force: Bool) throws {
        guard !pendingPoints.isEmpty else { return }
        let elapsed = Date().timeIntervalSince(lastPersistedAt)
        guard force || pendingPoints.count >= Self.flushCount || elapsed >= Self.flushInterval else { return }

        let batch = pendingPoints
        pendingPoints.removeAll(keepingCapacity: true)
        lastPersistedAt = Date()
        try sessionStore.appendPoints(batch)
    }
}

// MARK: - LocationTrackerDelegate

extension TrackingEngine: LocationTrackerDelegate {

    public nonisolated func locationTracker(_ tracker: LocationTracker, didReceive locations: [CLLocation]) {
        Task { @MainActor in
            self.handle(locations: locations)
        }
    }

    public nonisolated func locationTracker(_ tracker: LocationTracker, didChange status: CLAuthorizationStatus) {
        Task { @MainActor in
            if status == .denied || status == .restricted, self.state == .tracking {
                try? self.stopWalk()
                self.state = .paused(reason: .permissionLost)
            }
        }
    }

    public nonisolated func locationTracker(_ tracker: LocationTracker, didFailWith error: Error) {
        NSLog("WalkTracker: location error: \(error.localizedDescription)")
    }
}
