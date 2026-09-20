import Foundation
import CoreLocation
import CoreMotion

public protocol LocationTrackerDelegate: AnyObject {
    func locationTracker(_ tracker: LocationTracker, didReceive locations: [CLLocation])
    func locationTracker(_ tracker: LocationTracker, didChange status: CLAuthorizationStatus)
    func locationTracker(_ tracker: LocationTracker, didFailWith error: Error)
}

/// Wraps CoreLocation and CoreMotion for continuous walk tracking.
///
/// Two deliberate choices worth stating, because both trade something away:
///
/// The background location indicator is left **on**. It could be hidden, but
/// an app that records where someone walks should be visibly recording. The
/// blue bar is the honest signal, and hiding it would be the wrong default
/// whatever App Review permits.
///
/// Motion activity gates whether fixes count. Riding a bus down a street is
/// not walking it, and speed alone cannot tell the two apart reliably in
/// traffic. When Core Motion reports driving or cycling, fixes are still
/// recorded to the trace but flagged, and the engine declines to claim
/// coverage from them.
public final class LocationTracker: NSObject {

    public weak var delegate: LocationTrackerDelegate?

    private let manager: CLLocationManager
    private let motionManager: CMMotionActivityManager?
    private let motionQueue = OperationQueue()

    public private(set) var isTracking = false
    /// Latest motion classification. Nil when Core Motion is unavailable or
    /// permission was refused, in which case tracking proceeds without the gate.
    public private(set) var currentActivity: CMMotionActivity?

    public override init() {
        self.manager = CLLocationManager()
        self.motionManager = CMMotionActivityManager.isActivityAvailable()
            ? CMMotionActivityManager()
            : nil
        super.init()

        manager.delegate = self
        // Dense, accurate fixes: the smoothing stage needs several per bucket
        // to bring the noise down, so filtering them out here would defeat it.
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = kCLDistanceFilterNone
        manager.activityType = .fitness
        // Left off: iOS resumes paused updates only via a significant-location
        // change, which can drop whole blocks out of a walk.
        manager.pausesLocationUpdatesAutomatically = false

        motionQueue.maxConcurrentOperationCount = 1
        motionQueue.qualityOfService = .utility
    }

    // MARK: - Authorization

    public var authorizationStatus: CLAuthorizationStatus {
        manager.authorizationStatus
    }

    public var hasBackgroundAuthorization: Bool {
        manager.authorizationStatus == .authorizedAlways
    }

    /// Asks for foreground access. Always the first request: iOS will not
    /// grant "Always" to an app that has not been trusted with "When In Use",
    /// and asking for everything up front is how permission dialogs get denied.
    public func requestWhenInUseAuthorization() {
        manager.requestWhenInUseAuthorization()
    }

    /// Asks to upgrade to background access. Only meaningful once foreground
    /// access is granted, and iOS shows this prompt only once per install.
    public func requestAlwaysAuthorization() {
        guard manager.authorizationStatus == .authorizedWhenInUse else { return }
        manager.requestAlwaysAuthorization()
    }

    // MARK: - Tracking

    public func start() {
        guard !isTracking else { return }
        let status = manager.authorizationStatus
        guard status == .authorizedAlways || status == .authorizedWhenInUse else { return }

        // Only legal with "Always", and only with the location background mode
        // declared. Setting it under "When In Use" throws.
        if status == .authorizedAlways {
            manager.allowsBackgroundLocationUpdates = true
            manager.showsBackgroundLocationIndicator = true
        }

        isTracking = true
        manager.startUpdatingLocation()
        startMotionUpdates()
    }

    public func stop() {
        guard isTracking else { return }
        isTracking = false
        manager.stopUpdatingLocation()
        manager.allowsBackgroundLocationUpdates = false
        motionManager?.stopActivityUpdates()
        currentActivity = nil
    }

    private func startMotionUpdates() {
        motionManager?.startActivityUpdates(to: motionQueue) { [weak self] activity in
            guard let self else { return }
            DispatchQueue.main.async {
                self.currentActivity = activity
            }
        }
    }

    /// Whether the current motion classification permits claiming coverage.
    ///
    /// Unknown or unavailable classification permits it: this gate exists to
    /// reject clear vehicle travel, not to refuse credit whenever Core Motion
    /// is unsure. Most indoor and urban-canyon walking reports low confidence.
    public var motionPermitsCoverage: Bool {
        guard let activity = currentActivity else { return true }
        if activity.automotive || activity.cycling { return false }
        if activity.walking || activity.running || activity.stationary { return true }
        return !activity.automotive
    }
}

// MARK: - CLLocationManagerDelegate

extension LocationTracker: CLLocationManagerDelegate {

    public func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard !locations.isEmpty else { return }
        delegate?.locationTracker(self, didReceive: locations)
    }

    public func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus

        // A downgrade mid-walk revokes background updates immediately rather
        // than waiting for the next start.
        if status != .authorizedAlways, isTracking {
            manager.allowsBackgroundLocationUpdates = false
        }
        if status == .denied || status == .restricted {
            stop()
        }
        delegate?.locationTracker(self, didChange: status)
    }

    public func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // A transient inability to get a fix is normal indoors and is not
        // worth surfacing or stopping for.
        if let clError = error as? CLError, clError.code == .locationUnknown { return }
        delegate?.locationTracker(self, didFailWith: error)
    }
}
