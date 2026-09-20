import SwiftUI

/// A thick accent ring with the figure it represents in the middle.
///
/// The ring is the one place a percentage gets to be large and the one place
/// the accent appears at size, so it carries the screen it sits on.
struct ProgressRing: View {

    let fraction: Double
    var title: String?
    var caption: String?
    var tint: Color = WalkPalette.accent
    /// Accessibility replacement for the ring as a whole. When nil the ring is
    /// hidden from assistive technology, on the assumption that the caller has
    /// already described the same number nearby.
    var accessibilityDescription: String?

    /// Scales with Dynamic Type, capped so a ring cannot grow past the width
    /// of the phone.
    @ScaledMetric(relativeTo: .title) private var scale: CGFloat = 1

    private var diameter: CGFloat { 168 * min(scale, 1.3) }
    private var lineWidth: CGFloat { 14 * min(scale, 1.15) }
    private var clamped: Double { min(1, max(0, fraction)) }

    var body: some View {
        ZStack {
            Circle()
                .stroke(tint.opacity(0.14), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))

            Circle()
                .trim(from: 0, to: clamped)
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.smooth(duration: 0.4), value: clamped)

            VStack(spacing: 4) {
                if let title {
                    HeroNumber(value: title, size: 42)
                }
                if let caption {
                    CapsLabel(text: caption)
                }
            }
            .padding(lineWidth * 2)
        }
        .frame(width: diameter, height: diameter)
        .accessibilityElement(children: .ignore)
        .accessibilityHidden(accessibilityDescription == nil)
        .accessibilityLabel(accessibilityDescription ?? "")
    }
}

#Preview {
    VStack(spacing: 32) {
        ProgressRing(
            fraction: 0.32,
            title: "32.0%",
            caption: String(localized: "of Paris"),
            accessibilityDescription: String(localized: "Paris is 32 percent walked")
        )
        ProgressRing(fraction: 0.62, title: "3.1 km", caption: String(localized: "this week"))
    }
    .padding(40)
    .walkPageBackground()
}
