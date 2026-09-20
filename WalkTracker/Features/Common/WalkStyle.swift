import SwiftUI

// MARK: - Typography

/// The type scale.
///
/// Numerals are rounded throughout, which is what gives both reference apps
/// their look, and monospaced so a live figure does not jitter as its digits
/// change width.
enum WalkType {

    /// The hero figure on a screen: a distance, a percentage, a duration.
    static func hero(_ size: CGFloat) -> Font {
        .system(size: size, weight: .bold, design: .rounded)
    }

    static let screenTitle = Font.system(.title, design: .rounded).weight(.bold)
    static let cardTitle = Font.system(.headline, design: .rounded).weight(.semibold)
    static let body = Font.system(.callout, design: .rounded)
    static let caption = Font.system(.caption, design: .rounded)
    /// Small, uppercase and letter spaced: the label under a hero figure.
    static let label = Font.system(.caption, design: .rounded).weight(.semibold)
    static let button = Font.system(.headline, design: .rounded).weight(.bold)
}

/// The small uppercase caption that sits under a hero number.
///
/// Never anywhere near the size of the figure it labels: the contrast between
/// the two is the whole effect.
struct CapsLabel: View {

    let text: String

    var body: some View {
        Text(text)
            .font(WalkType.label)
            .textCase(.uppercase)
            .kerning(0.8)
            .foregroundStyle(WalkPalette.secondaryInk)
            .lineLimit(2)
            .multilineTextAlignment(.center)
    }
}

/// A large figure, rounded and monospaced, that counts rather than jumps when
/// it changes.
struct HeroNumber: View {

    let value: String
    var size: CGFloat = 60
    var color: Color = WalkPalette.ink
    var alignment: TextAlignment = .center

    /// Grows with Dynamic Type but only so far. A 60 point number at the
    /// largest accessibility size would push everything else off screen, so the
    /// growth is capped rather than the layout being allowed to break.
    @ScaledMetric(relativeTo: .title) private var scale: CGFloat = 1

    var body: some View {
        Text(value)
            .font(WalkType.hero(size * min(scale, 1.35)))
            .monospacedDigit()
            .foregroundStyle(color)
            .contentTransition(.numericText())
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .multilineTextAlignment(alignment)
            .dynamicTypeSize(...DynamicTypeSize.accessibility2)
    }
}

// MARK: - Surfaces

/// A white card with a very soft shadow. No border, no grey fill: whitespace
/// and the shadow do the separating.
struct WalkCard: ViewModifier {

    var padding: CGFloat = 22
    var cornerRadius: CGFloat = 20

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(WalkPalette.card)
                    .shadow(color: WalkPalette.cardShadow, radius: 12, x: 0, y: 2)
            )
    }
}

extension View {

    func walkCard(padding: CGFloat = 22, cornerRadius: CGFloat = 20) -> some View {
        modifier(WalkCard(padding: padding, cornerRadius: cornerRadius))
    }

    /// The page background, for screens that are not the map.
    func walkPageBackground() -> some View {
        background(WalkPalette.background.ignoresSafeArea())
    }
}

/// The thin rule between stat columns. Deliberately the only divider in the
/// app, and barely there.
struct StatDivider: View {
    var body: some View {
        Rectangle()
            .fill(WalkPalette.hairline)
            .frame(width: 1)
            .frame(maxHeight: .infinity)
            .accessibilityHidden(true)
    }
}

// MARK: - Buttons

/// The primary action: a full-width accent pill with a bold uppercase label.
/// Both reference apps make the record control unmissable, and so does this.
struct PillButtonStyle: ButtonStyle {

    var filled: Bool = true
    var tint: Color = WalkPalette.accent

    func makeBody(configuration: Configuration) -> some View {
        Body(configuration: configuration, filled: filled, tint: tint)
    }

    private struct Body: View {

        let configuration: PillButtonStyle.Configuration
        let filled: Bool
        let tint: Color

        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(WalkType.button)
                .textCase(.uppercase)
                .kerning(0.8)
                .foregroundStyle(filled ? Color.white : tint)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
                .padding(.horizontal, 20)
                .background {
                    if filled {
                        Capsule(style: .continuous).fill(tint)
                    } else {
                        Capsule(style: .continuous).strokeBorder(tint.opacity(0.35), lineWidth: 1.5)
                    }
                }
                .opacity(isEnabled ? 1 : 0.4)
                .scaleEffect(configuration.isPressed ? 0.97 : 1)
                .animation(.snappy(duration: 0.2), value: configuration.isPressed)
        }
    }
}

/// A smaller pill for secondary actions inside cards.
struct SmallPillButtonStyle: ButtonStyle {

    var filled: Bool = true
    var tint: Color = WalkPalette.accent

    func makeBody(configuration: Configuration) -> some View {
        Body(configuration: configuration, filled: filled, tint: tint)
    }

    private struct Body: View {

        let configuration: SmallPillButtonStyle.Configuration
        let filled: Bool
        let tint: Color

        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(WalkType.label)
                .textCase(.uppercase)
                .kerning(0.6)
                .foregroundStyle(filled ? Color.white : tint)
                .padding(.vertical, 10)
                .padding(.horizontal, 18)
                .background {
                    if filled {
                        Capsule(style: .continuous).fill(tint)
                    } else {
                        Capsule(style: .continuous).strokeBorder(tint.opacity(0.35), lineWidth: 1.5)
                    }
                }
                .opacity(isEnabled ? 1 : 0.4)
                .scaleEffect(configuration.isPressed ? 0.97 : 1)
                .animation(.snappy(duration: 0.2), value: configuration.isPressed)
        }
    }
}
