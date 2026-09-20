import SwiftUI

/// The record control: live figures while a walk runs, and one unmissable pill.
struct WalkControlBar: View {

    @ObservedObject var engine: TrackingEngine
    /// Whether a walk can be started at all: a city pack is open and location
    /// access has been granted.
    let isReady: Bool
    let onStart: () -> Void
    let onStop: () -> Void

    /// Auto-pause is still a recording walk: the engine keeps the session open,
    /// keeps taking fixes, and resumes on its own when the walker moves.
    private var isRecording: Bool {
        switch engine.state {
        case .tracking: return true
        case .paused(let reason): return reason == .standingStill
        case .idle: return false
        }
    }

    private var isAutoPaused: Bool {
        engine.state == .paused(reason: .standingStill)
    }

    /// A reason that has actually stopped the walk, as opposed to auto-pause.
    private var blockingPauseReason: TrackingEngine.State.PauseReason? {
        guard case .paused(let reason) = engine.state, reason != .standingStill else { return nil }
        return reason
    }

    var body: some View {
        VStack(spacing: 18) {
            if isRecording {
                if isAutoPaused {
                    pausedChip
                }
                liveStats
            }

            if let blockingPauseReason {
                pauseNotice(blockingPauseReason)
            }

            controlButton
        }
        .padding(22)
        .background(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(WalkPalette.card)
                .shadow(color: WalkPalette.cardShadow, radius: 16, x: 0, y: 4)
        )
        .animation(.smooth(duration: 0.3), value: isRecording)
        .animation(.smooth(duration: 0.3), value: isAutoPaused)
    }

    // MARK: - Pieces

    private var pausedChip: some View {
        HStack(spacing: 8) {
            Image(systemName: "pause.fill")
                .font(.caption2)
            Text(String(localized: "Paused, waiting for you to move"))
                .font(WalkType.label)
                .textCase(.uppercase)
                .kerning(0.8)
        }
        .foregroundStyle(WalkPalette.secondaryInk)
        .padding(.vertical, 8)
        .padding(.horizontal, 14)
        .background(Capsule(style: .continuous).fill(WalkPalette.hairline))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "Walk paused automatically because you stopped moving. It resumes on its own."))
    }

    private var liveStats: some View {
        // A timeline rather than a timer object: SwiftUI drives the tick, so
        // nothing keeps running when this view is off screen. The clock reads
        // the engine's active duration, which excludes auto-paused stretches,
        // so a lunch stop does not inflate the walk.
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            StatTileRow(tiles: [
                StatTile(
                    title: String(localized: "New street"),
                    value: WalkFormat.distance(metres: engine.newCoverageMetres),
                    size: 30,
                    tint: WalkPalette.accent
                ),
                StatTile(
                    title: String(localized: "Distance"),
                    value: WalkFormat.distance(metres: engine.distanceMetres),
                    size: 30
                ),
                StatTile(
                    title: String(localized: "Time"),
                    value: WalkFormat.clock(engine.activeDuration),
                    size: 30,
                    tint: isAutoPaused ? WalkPalette.secondaryInk : WalkPalette.ink
                )
            ])
        }
    }

    private func pauseNotice(_ reason: TrackingEngine.State.PauseReason) -> some View {
        Text(pauseMessage(reason))
            .font(WalkType.caption)
            .foregroundStyle(WalkPalette.secondaryInk)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity)
    }

    private func pauseMessage(_ reason: TrackingEngine.State.PauseReason) -> String {
        switch reason {
        case .permissionLost:
            return String(localized: "Recording stopped because location access was turned off.")
        case .noCityPack:
            return String(localized: "Recording needs a city with its streets downloaded.")
        case .inVehicle:
            return String(localized: "Paused while you are travelling by vehicle. Streets only count when walked.")
        case .standingStill:
            return String(localized: "Paused while you are standing still.")
        }
    }

    private var controlButton: some View {
        Button(action: isRecording ? onStop : onStart) {
            Text(isRecording ? String(localized: "Stop walk") : String(localized: "Start walk"))
        }
        .buttonStyle(PillButtonStyle(tint: isRecording ? WalkPalette.recording : WalkPalette.accent))
        .disabled(!isRecording && !isReady)
        .accessibilityLabel(
            isRecording
                ? String(localized: "Stop the walk that is recording")
                : String(localized: "Start recording a walk")
        )
        .accessibilityHint(
            isRecording
                ? String(localized: "Saves the walk and stops using GPS")
                : String(localized: "Records your location until you stop the walk")
        )
    }
}
