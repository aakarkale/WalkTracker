import Foundation
import Combine

/// Records walks without the user having to remember to start one.
///
/// The naive version of this feature keeps GPS running all day and flattens
/// the battery. This does not: almost all of the time it is only holding a
/// significant-change subscription, which piggybacks on cell and wifi
/// transitions the phone is already making. GPS is expensive and is treated
/// that way, so the question "is this person walking?" is answered by the
/// motion coprocessor, which counts steps continuously for almost nothing.
///
/// The loop:
///   idle       nothing running, passive tracking switched off
///   watching   significant-change subscription only, negligible cost
///   recording  a real walk, full accuracy GPS, the engine doing its work
///
/// Watching becomes recording when the pedometer reports enough steps without
/// a vehicle classification. Recording falls back to watching after a stretch
/// with no walking. Checks are also cheap and rate limited, because iOS can
/// deliver significant-change wakes in bursts.
@MainActor
public final class PassiveTrackingCoordinator: ObservableObject {

    public enum Mode: Equatable, Sendable {
        case idle
        case watching
        case recording
    }

    @Published public private(set) var mode: Mode = .idle
    /// Why the coordinator last decided as it did, for the Settings screen.
    @Published public private(set) var lastDecision: String = ""

    /// No walking for this long ends the automatic walk. Long enough to sit
    /// down for a coffee without the walk being chopped in two, short enough
    /// that an evening indoors does not keep GPS alive.
    public var idleTimeout: TimeInterval = 5 * 60

    /// Floor on how often the pedometer is consulted. Significant-change wakes
    /// can arrive several at a time, and each query is cheap but not free.
    public var minimumCheckInterval: TimeInterval = 30

    private let tracker: LocationTracker
    private let detector: WalkingDetector
    private let engine: TrackingEngine

    private var lastCheckedAt = Date.distantPast
    private var lastWalkingAt: Date?
    private var idleTimer: Timer?

    /// Whether the user has switched automatic tracking on. Off by default:
    /// an app that starts recording your movements on its own, without being
    /// asked, is not something to opt people into silently.
    public private(set) var isEnabled = false

    public init(tracker: LocationTracker, detector: WalkingDetector, engine: TrackingEngine) {
        self.tracker = tracker
        self.detector = detector
        self.engine = engine
    }

    // MARK: - Control

    public func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        enabled ? beginWatching() : stopEverything()
    }

    /// Call on launch and on returning to the foreground, so a wake that iOS
    /// delivered while the app was suspended still gets acted on.
    public func refresh() {
        guard isEnabled else { return }
        if mode == .idle { beginWatching() }
        evaluate(reason: "app became active")
    }

    private func beginWatching() {
        // Needs background authorisation: without it iOS will not wake the app
        // and automatic tracking cannot work at all.
        guard tracker.hasBackgroundAuthorization else {
            lastDecision = String(localized: "Automatic tracking needs Always location access.")
            mode = .idle
            return
        }
        tracker.startWatchingSignificantChanges()
        detector.start { [weak self] reading in
            Task { @MainActor in
                self?.handle(reading: reading, reason: "motion changed")
            }
        }
        mode = .watching
        evaluate(reason: "started watching")
    }

    private func stopEverything() {
        detector.stop()
        tracker.stopWatchingSignificantChanges()
        idleTimer?.invalidate()
        idleTimer = nil
        if mode == .recording {
            try? engine.stopWalk()
        }
        mode = .idle
        lastDecision = String(localized: "Automatic tracking is off.")
    }

    // MARK: - Decisions

    /// Called when iOS wakes the app for a significant location change.
    public func significantChangeObserved() {
        guard isEnabled else { return }
        evaluate(reason: "moved far enough to wake the app")
    }

    private func evaluate(reason: String) {
        guard isEnabled else { return }
        guard Date().timeIntervalSince(lastCheckedAt) >= minimumCheckInterval else { return }
        lastCheckedAt = Date()

        detector.reading { [weak self] reading in
            Task { @MainActor in
                self?.handle(reading: reading, reason: reason)
            }
        }
    }

    private func handle(reading: WalkingDetector.Reading, reason: String) {
        guard isEnabled else { return }

        if reading.isWalking {
            lastWalkingAt = Date()
            guard mode != .recording else { return }
            startRecording(steps: reading.stepsInWindow, reason: reason)
            return
        }

        guard mode == .recording else {
            lastDecision = String(localized: "Waiting for you to start walking.")
            return
        }

        // Not walking right now is not enough to stop: people wait at
        // crossings and go into shops. Only a sustained absence ends the walk.
        let since = lastWalkingAt ?? Date.distantPast
        guard Date().timeIntervalSince(since) >= idleTimeout else { return }
        stopRecording(reason: "no walking for several minutes")
    }

    private func startRecording(steps: Int, reason: String) {
        do {
            try engine.startWalk()
            guard engine.state == .tracking else {
                // The engine refused, usually because no city pack is
                // installed. Keep watching rather than retrying in a loop.
                lastDecision = String(localized: "Detected walking, but there is nothing to record against yet.")
                return
            }
            mode = .recording
            lastWalkingAt = Date()
            lastDecision = String(localized: "Started recording after \(steps) steps.")
            scheduleIdleCheck()
        } catch {
            lastDecision = String(localized: "Could not start recording automatically.")
        }
    }

    private func stopRecording(reason: String) {
        try? engine.stopWalk()
        idleTimer?.invalidate()
        idleTimer = nil
        mode = .watching
        lastDecision = String(localized: "Stopped recording: \(reason).")
    }

    /// Polls for the end of a walk.
    ///
    /// Needed because nothing else will fire: when someone stops walking, the
    /// pedometer goes quiet and significant-change monitoring has nothing to
    /// report, so without a timer the walk would stay open indefinitely.
    private func scheduleIdleCheck() {
        idleTimer?.invalidate()
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.mode == .recording else { return }
                self.lastCheckedAt = .distantPast
                self.evaluate(reason: "periodic check")
            }
        }
        // Common mode so the timer keeps firing while the map is being
        // scrolled, which otherwise parks the default run loop mode.
        RunLoop.main.add(timer, forMode: .common)
        idleTimer = timer
    }
}
