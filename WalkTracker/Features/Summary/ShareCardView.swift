import SwiftUI

/// The square image offered by the share button.
///
/// Contains the user's own walked streets, the percentage, and the city name.
/// Nothing else: no logo, no badge, no claim about who made it. Sharing here is
/// a local image export, not a post to anything, because this app has no
/// account and sends location nowhere.
struct ShareCardView: View {

    let cityName: String
    let percentageText: String
    /// Walked streets, already normalised into unit space.
    let runs: [[CGPoint]]

    /// The exported image is always light, whatever theme the phone is in: a
    /// dynamic colour would render a black square for a user in dark mode.
    private let paper = Color(red: 0.985, green: 0.980, blue: 0.976)
    private let ink = Color(red: 0.11, green: 0.11, blue: 0.12)
    private let accent = Color(red: 0.96, green: 0.33, blue: 0.10)

    static let side: CGFloat = 600

    var body: some View {
        ZStack {
            paper

            VStack(spacing: 0) {
                MultiRouteShape(runs: runs)
                    .stroke(accent, style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                    .frame(width: Self.side - 120, height: Self.side - 230)
                    .padding(.top, 50)

                Spacer(minLength: 12)

                Text(percentageText)
                    .font(.system(size: 92, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)

                Text(cityName)
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .textCase(.uppercase)
                    .kerning(2)
                    .foregroundStyle(accent)
                    .padding(.top, 6)
                    .padding(.bottom, 44)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
            }
        }
        .frame(width: Self.side, height: Self.side)
    }
}

/// Renders a share card to an image.
///
/// `ImageRenderer` has to run on the main actor, so the expensive part (reading
/// the walked streets out of the pack and normalising them) is done before this
/// is called, and only the draw happens here.
@MainActor
enum ShareCardRenderer {

    static func image(for card: ShareCardView, scale: CGFloat = 3) -> Image? {
        let renderer = ImageRenderer(content: card)
        renderer.scale = scale
        guard let rendered = renderer.uiImage else { return nil }
        return Image(uiImage: rendered)
    }
}
