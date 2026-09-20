import SwiftUI

/// One figure with its label underneath.
///
/// The figure is large and rounded, the label is small, uppercase and grey. The
/// distance between the two sizes is the effect: they must never look like the
/// same piece of text.
struct StatTile: View {

    let title: String
    let value: String
    var caption: String?
    var size: CGFloat = 26
    var tint: Color = WalkPalette.ink

    var body: some View {
        VStack(spacing: 6) {
            HeroNumber(value: value, size: size, color: tint)
            CapsLabel(text: title)

            if let caption {
                Text(caption)
                    .font(WalkType.caption)
                    .foregroundStyle(WalkPalette.secondaryInk)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(caption.map { "\(value), \($0)" } ?? value)
    }
}

/// Two or three figures side by side with equal widths and a hairline between
/// them: the signature layout of a post-activity summary.
///
/// Stacks vertically at accessibility text sizes rather than squeezing three
/// large numbers into a phone width.
struct StatTileRow: View {

    let tiles: [StatTile]

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        if dynamicTypeSize >= .accessibility1 {
            VStack(spacing: 20) {
                ForEach(Array(tiles.enumerated()), id: \.offset) { _, tile in
                    tile
                }
            }
        } else {
            HStack(alignment: .top, spacing: 0) {
                ForEach(Array(tiles.enumerated()), id: \.offset) { index, tile in
                    if index > 0 {
                        StatDivider()
                            .padding(.vertical, 2)
                    }
                    tile
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

#Preview {
    StatTileRow(tiles: [
        StatTile(title: String(localized: "Distance"), value: "4.20 km"),
        StatTile(title: String(localized: "Time"), value: "48:12"),
        StatTile(title: String(localized: "New blocks"), value: "12", tint: WalkPalette.accent)
    ])
    .padding(24)
    .walkCard()
    .padding(20)
    .walkPageBackground()
}
