import Foundation
import CoreLocation
import Combine

/// Orchestrates a walk: raw fixes in, persisted trace and coverage out.
///
/// Holds only the state the interface renders. Every database write, smoothing
/// step and matching decision happens in `WalkProcessor` on its own queue, so
/// nothing here blocks the main thread while the map is being scrolled.
///
/// Ordering guarantee worth knowing: the raw trace is written before anything
/// is derived from it. A crash mid-walk loses at most the derived coverage,
/// which is rebuildable, and never the trace, which is not.
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
    private let processor: WalkProcessor

    private var cityID: String?
    private var hasPack = false
    private var lastRawFix: CLLocation?
    private var pointCount = 0

    public init(
        tracker: LocationTracker,
        sessionStore: SessionStore,
        coverageStore: CoverageStore
    ) {
        self.tracker = tracker
        self.sessionStore = sessionStore
        self.processor = WalkProcessor(sessionStore: sessionStore, coverageStore: coverageStore)
        tracker.delegate = self
    }

    // MARK: - City

    /// Points the engine at a city and its installed pack.
    public func setCity(id: String, packStore: CityPackStore) {
        cityID = id
        hasPack = true
        processor.setCity(id: id, packStore: packStore)
    }

    // MARK: - Lifecycle

    public func startWalk() throws {
        guard state != .tracking else { return }
        guard let cityID, hasPack else {
            state = .paused(reason: .noCityPack)
            return
        }

        let status = tracker.authorizationStatus
        guard status == .authorizedAlways || status == .authorizedWhenInUse else {
            state = .paused(reason: .permissionLost)
            return
        }

        session = try sessionStore.startSession(cityID: cityID)
        distanceMetres = 0
        newCoverageMetres = 0
        segmentsTouchedThisWalk = []
        lastRawFix = nil
        pointCount = 0

        processor.beginWalk()
        state = .tracking
        tracker.start()
    }

    public func stopWalk() throws {
        tracker.stop()

        guard let session else {
            state = .idle
            return
        }

        state = .idle
        self.session = nil

        let distance = distanceMetres
        let points = pointCount

        // Drains the smoothing bucket and the Viterbi window before the totals
        // are written, so the last stretch of the walk is not lost.
        processor.endWalk { [weak self] outcome in
            Task { @MainActor in
                guard let self else { return }
                self.newCoverageMetres += outcome.newCoverageMetres
                self.segmentsTouchedThisWalk.formUnion(outcome.segmentsTouched)

                self.processor.finalise(
                    sessionID: session.id,
                    distanceMetres: distance,
                    newCoverageMetres: self.newCoverageMetres,
                    pointCount: points
                ) { error in
                    if let error {
                        NSLog("WalkTracker: failed to close session: \(error.localizedDescription)")
                    }
                }
            }
        }
    }

    /// Closes a session left open by a crash or a kill during background
    /// tracking, so the history does not grow a session that never ends.
    public func recoverOpenSessionIfNeeded() throws {
        guard state == .idle, session == nil else { return }
        guard let open = try sessionStore.openSession() else { return }

        // Ended at the last fix actually recorded, not now: the gap between a
        // crash and the next launch is not time spent walking.
        let points = try sessionStore.points(sessionID: open.id)
        try sessionStore.endSession(id: open.id, at: points.last?.timestamp ?? open.startedAt)
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
            // Fixes stamped before the walk began are cached from earlier and
            // would teleport the trace backwards.
            guard location.timestamp >= session.startedAt.addingTimeInterval(-2) else { continue }

            accepted.append(TrackPoint(
                sessionID: session.id,
                timestamp: location.timestamp,
                coordinate: coordinate,
                horizontalAccuracy: location.horizontalAccuracy,
                speed: location.speed,
                course: location.course,
                altitude: location.altitude
            ))

            if let previous = lastRawFix {
                let step = location.distance(from: previous)
                // Steps inside the combined error of the two fixes are noise.
                // Counting them would clock up distance for someone standing
                // still at a crossing.
                let noiseFloor = 0.5 * (location.horizontalAccuracy + previous.horizontalAccuracy)
                if step > noiseFloor { distanceMetres += step }
            }
            lastRawFix = location
        }

        guard !accepted.isEmpty else { return }

        lastFix = locations.last
        pointCount += accepted.count

        // Read on the main actor, since CoreMotion state is published there.
        let claimCoverage = tracker.motionPermitsCoverage

        processor.ingest(accepted, claimCoverage: claimCoverage) { [weak self] outcome in
            guard outcome.newCoverageMetres > 0 || !outcome.segmentsTouched.isEmpty else { return }
            Task { @MainActor in
                guard let self else { return }
                self.newCoverageMetres += outcome.newCoverageMetres
                self.segmentsTouchedThisWalk.formUnion(outcome.segmentsTouched)
            }
        }
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
            guard status == .denied || status == .restricted, self.state == .tracking else { return }
            try? self.stopWalk()
            self.state = .paused(reason: .permissionLost)
        }
    }

    public nonisolated func locationTracker(_ tracker: LocationTracker, didFailWith error: Error) {
        NSLog("WalkTracker: location error: \(error.localizedDescription)")
    }
}
