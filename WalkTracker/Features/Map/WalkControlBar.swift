import SwiftUI

/// The bottom of the map screen: how much of the city is done, and the one
/// loud control that starts or stops a walk.
///
/// Laid out the way the reference app does it, because it works: a slim
/// full-width coverage bar with the block counter on the left and the
/// percentage on the right, and directly under it the pill. No card around the
/// bar, so the map still reads as the screen.
struct WalkControlBar: View {

    @ObservedObject var engine: TrackingEngine
    let stats: CoverageCalculator.CityStats?
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
        VStack(spacing: 14) {
            if isRecording {
                liveStatsCard
            }

            if let blockingPauseReason {
                pauseNotice(blockingPauseReason)
            }

            if let stats {
                CoverageBar(stats: stats)
            }

            controlButton
        }
        .animation(.smooth(duration: 0.3), value: isRecording)
        .animation(.smooth(duration: 0.3), value: isAutoPaused)
    }

    // MARK: - Live stats

    private var liveStatsCard: some View {
        VStack(spacing: 14) {
            if isAutoPaused {
                pausedChip
            }

            // Deliberately separate from the pause states above. Paused means
            // the walk has stopped counting time. This means the walk is still
            // running and the trace is still being written, but these streets
            // will not be credited. Showing them the same way would be worse
            // than showing nothing.
            if let suspension = engine.coverageSuspension {
                transitBadge(suspension)
            }

            // A timeline rather than a timer object: SwiftUI drives the tick,
            // so nothing keeps running when this view is off screen. The clock
            // reads the engine's active duration, which excludes auto-paused
            // stretches, so a lunch stop does not inflate the walk.
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                StatTileRow(tiles: [
                    StatTile(
                        title: String(localized: "New street"),
                        value: WalkFormat.distance(metres: engine.newCoverageMetres),
                        size: 28,
                        tint: WalkPalette.accent
                    ),
                    StatTile(
                        title: String(localized: "Distance"),
                        value: WalkFormat.distance(metres: engine.distanceMetres),
                        size: 28
                    ),
                    StatTile(
                        title: String(localized: "Time"),
                        value: WalkFormat.clock(engine.activeDuration),
                        size: 28,
                        tint: isAutoPaused ? WalkPalette.secondaryInk : WalkPalette.ink
                    )
                ])
            }
        }
        .walkCard(padding: 20)
    }

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

    private func transitBadge(_ suspension: TrackingEngine.CoverageSuspension) -> some View {
        VStack(spacing: 7) {
            HStack(spacing: 7) {
                Image(systemName: "car.fill")
                    .font(.caption2)
                Text(String(localized: "In transit"))
                    .font(WalkType.label)
                    .textCase(.uppercase)
                    .kerning(0.8)
            }
            .foregroundStyle(.white)
            .padding(.vertical, 7)
            .padding(.horizontal, 13)
            .background(Capsule(style: .continuous).fill(WalkPalette.recording))

            Text(suspension.explanation)
                .font(WalkType.caption)
                .foregroundStyle(WalkPalette.secondaryInk)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "In transit"))
        .accessibilityValue(suspension.explanation)
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

    // MARK: - Control

    private var controlButton: some View {
        Button(action: isRecording ? onStop : onStart) {
            HStack(spacing: 10) {
                Image(systemName: isRecording ? "stop.fill" : "figure.walk")
                Text(isRecording ? String(localized: "Stop walk") : String(localized: "Start walk"))
            }
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

/// Blocks done over blocks total on the left, the percentage on the right, and
/// a thin accent fill underneath.
///
/// The counter and the percentage are both block-based, so they corroborate
/// each other. A length-derived percentage next to a block count would
/// disagree with it and read as a bug.
struct CoverageBar: View {

    let stats: CoverageCalculator.CityStats

    private var percentageText: String {
        WalkFormat.percentage(
            stats.displayPercentage,
            startedButBelowResolution: stats.completedBlocks > 0
        )
    }

    var body: some View {
        VStack(spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(WalkFormat.blockCounter(completed: stats.completedBlocks, total: stats.totalBlocks))
                    .font(WalkType.label)
                    .textCase(.uppercase)
                    .kerning(0.8)
                    .foregroundStyle(WalkPalette.secondaryInk)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)

                Spacer(minLength: 0)

                Text(percentageText)
                    .font(WalkType.cardTitle)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .foregroundStyle(WalkPalette.ink)
                    .lineLimit(1)
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule(style: .continuous)
                        .fill(WalkPalette.hairline)
                    Capsule(style: .continuous)
                        .fill(WalkPalette.accent)
                        .frame(width: max(0, proxy.size.width * min(1, max(0, stats.blockFraction))))
                }
            }
            .frame(height: 6)
            .animation(.smooth(duration: 0.4), value: stats.blockFraction)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "City progress"))
        .accessibilityValue(
            "\(percentageText), \(WalkFormat.blocks(completed: stats.completedBlocks, total: stats.totalBlocks))"
        )
    }
}
