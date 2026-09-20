import Foundation
import SwiftUI
import Charts

/// A large gradient tile: the headline counts that do not change minute to
/// minute.
///
/// The gradient is the single accent at two opacities, not a second colour.
struct GradientStatCard: View {

    let icon: String
    let label: String
    let value: String
    let title: String
    let detail: String
    var linkTitle: String?
    var action: (() -> Void)?
    var intensity: Double = 1

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                Image(systemName: icon)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)

                Spacer(minLength: 8)

                VStack(alignment: .trailing, spacing: 2) {
                    CapsLabel(text: label, color: Color.white.opacity(0.85))
                    HeroNumber(value: value, size: 34, color: .white, alignment: .trailing)
                }
            }

            Spacer(minLength: 14)

            Text(title)
                .font(WalkType.cardTitle)
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)

            Text(detail)
                .font(WalkType.caption)
                .foregroundStyle(Color.white.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)

            if let linkTitle, let action {
                Button(action: action) {
                    HStack(spacing: 5) {
                        Text(linkTitle)
                            .font(WalkType.label)
                            .textCase(.uppercase)
                            .kerning(0.8)
                        Image(systemName: "arrow.right")
                            .font(.caption2.weight(.bold))
                    }
                    .foregroundStyle(.white)
                }
                .padding(.top, 10)
                .accessibilityLabel(linkTitle)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, minHeight: dynamicTypeSize >= .accessibility1 ? 0 : 180, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            WalkPalette.accent.opacity(intensity),
                            WalkPalette.accent.opacity(intensity * 0.62)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .shadow(color: WalkPalette.cardShadow, radius: 12, x: 0, y: 2)
        )
        .accessibilityElement(children: .contain)
    }
}

/// A white card with one figure, its unit beside it at a lighter weight, and a
/// small bar chart of recent periods with the latest bar picked out.
struct SparklineStatCard: View {

    let icon: String
    let title: String
    let value: String
    let unit: String
    let periodTitle: String
    let latestLabel: String
    /// Most recent last. Only the relative heights matter.
    let values: [Double]
    let onCyclePeriod: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(WalkPalette.accent)

                Text(title)
                    .font(WalkType.label)
                    .textCase(.uppercase)
                    .kerning(0.8)
                    .foregroundStyle(WalkPalette.accent)

                Spacer(minLength: 8)

                Button(action: onCyclePeriod) {
                    HStack(spacing: 4) {
                        Text(latestLabel.isEmpty ? periodTitle : "\(periodTitle), \(latestLabel)")
                            .font(WalkType.caption)
                            .foregroundStyle(WalkPalette.secondaryInk)
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(WalkPalette.secondaryInk)
                    }
                }
                .accessibilityLabel(String(localized: "Change the period"))
                .accessibilityValue(periodTitle)
            }

            HStack(alignment: .bottom, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    HeroNumber(value: value, size: 38, alignment: .leading)
                    Text(unit)
                        .font(.system(size: 17, weight: .medium, design: .rounded))
                        .foregroundStyle(WalkPalette.secondaryInk)
                }

                Spacer(minLength: 8)

                if values.count > 1 {
                    sparkline
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .walkCard(padding: 20)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue("\(value) \(unit), \(periodTitle)")
        .accessibilityHint(String(localized: "Tap to change the period"))
    }

    private var sparkline: some View {
        Chart {
            ForEach(Array(values.enumerated()), id: \.offset) { index, amount in
                BarMark(
                    x: .value(String(localized: "Period"), index),
                    y: .value(String(localized: "Amount"), max(0, amount))
                )
                .foregroundStyle(index == values.count - 1 ? WalkPalette.accent : WalkPalette.hairline)
                .cornerRadius(2)
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
        .frame(width: 104, height: 46)
        .accessibilityHidden(true)
    }
}
