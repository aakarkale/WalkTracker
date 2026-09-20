import Foundation
import CoreMotion

/// Answers one question cheaply: is this person walking?
///
/// It exists so the app does not have to keep GPS running to find out.
/// The motion coprocessor counts steps and classifies activity continuously at
/// a tiny fraction of the power a GPS fix costs, so the pedometer decides when
/// the expensive hardware is worth turning on.
///
/// Two signals, because neither is sufficient alone. Activity classification
/// knows the difference between walking and driving but is often unsure
/// indoors and in dense streets. Step counting is certain that steps happened
/// but cannot tell walking from pacing about a room. Requiring steps and
/// accepting a non-vehicle classification gets the useful part of both.
public final class WalkingDetector {

    public struct Reading: Equatable, Sendable {
        public let isWalking: Bool
        public let stepsInWindow: Int
        public let confidence: Confidence

        public enum Confidence: Int, Comparable, Sendable {
            case none = 0, low = 1, medium = 2, high = 3
            public static func < (lhs: Confidence, rhs: Confidence) -> Bool {
                lhs.rawValue < rhs.rawValue
            }
        }
    }

    /// Steps needed in the lookback window to count as walking. About a minute
    /// of ordinary walking, which is enough to rule out standing up and
    /// crossing a room.
    public var stepThreshold = 60

    /// How far back to count steps when deciding.
    public var window: TimeInterval = 90

    public static var isAvailable: Bool {
        CMPedometer.isStepCountingAvailable() && CMMotionActivityManager.isActivityAvailable()
    }

    private let pedometer = CMPedometer()
    private let activityManager = CMMotionActivityManager()
    private let queue: OperationQueue

    private var liveHandler: ((Reading) -> Void)?
    private var latestActivity: CMMotionActivity?
    private var isRunning = false

    public init() {
        queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .utility
    }

    deinit {
        pedometer.stopUpdates()
        activityManager.stopActivityUpdates()
    }

    // MARK: - Live

    /// Starts watching. The handler fires whenever the picture changes enough
    /// to matter, not on every step.
    public func start(handler: @escaping (Reading) -> Void) {
        guard Self.isAvailable, !isRunning else { return }
        isRunning = true
        liveHandler = handler

        activityManager.startActivityUpdates(to: queue) { [weak self] activity in
            guard let self else { return }
            self.latestActivity = activity
            self.emit()
        }

        pedometer.startUpdates(from: Date()) { [weak self] _, _ in
            // The payload is cumulative since the start date, which is not what
            // the decision needs. It is only used as a nudge to re-evaluate
            // against the rolling window.
            self?.emit()
        }
    }

    public func stop() {
        guard isRunning else { return }
        isRunning = false
        liveHandler = nil
        latestActivity = nil
        pedometer.stopUpdates()
        activityManager.stopActivityUpdates()
    }

    private func emit() {
        guard let handler = liveHandler else { return }
        reading { reading in
            handler(reading)
        }
    }

    // MARK: - Query

    /// Asks whether the person has been walking over the recent window.
    ///
    /// Historical rather than instantaneous, which is what makes it usable
    /// after a background wake: iOS may have kept the app suspended for
    /// minutes, and the motion coprocessor was counting the whole time.
    public func reading(completion: @escaping (Reading) -> Void) {
        guard Self.isAvailable else {
            // Without the sensor the app cannot gate on it, so it must not
            // claim the person is stationary. Simulators and older devices
            // land here.
            completion(Reading(isWalking: true, stepsInWindow: 0, confidence: .none))
            return
        }

        let end = Date()
        let start = end.addingTimeInterval(-window)
        let activity = latestActivity

        pedometer.queryPedometerData(from: start, to: end) { [weak self] data, _ in
            guard let self else { return }
            let steps = data?.numberOfSteps.intValue ?? 0
            let enoughSteps = steps >= self.scaledStepThreshold

            // A vehicle overrules the step count. Steps are registered on a
            // bumpy bus, and crediting streets for a bus ride is the error
            // this whole gate exists to prevent.
            let inVehicle = (activity?.automotive ?? false) || (activity?.cycling ?? false)

            let confidence: Reading.Confidence
            switch activity?.confidence {
            case .high: confidence = .high
            case .medium: confidence = .medium
            case .low: confidence = .low
            default: confidence = .none
            }

            completion(Reading(
                isWalking: enoughSteps && !inVehicle,
                stepsInWindow: steps,
                confidence: confidence
            ))
        }
    }

    /// The threshold scaled to the configured window, so changing one does not
    /// silently change the other.
    private var scaledStepThreshold: Int {
        guard window > 0 else { return stepThreshold }
        return max(10, Int(Double(stepThreshold) * window / 90))
    }
}
