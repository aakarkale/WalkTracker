import SwiftUI

/// What the user sees the moment a walk ends.
///
/// The hero number is new street unlocked, not distance walked. Distance is the
/// ordinary number that every fitness app shows; new street is the one this app
/// exists to move, and it is the reason to have walked the long way home.
struct WalkSummaryScreen: View {

    let summary: WalkSummary
    let onDone: () -> Void

    @EnvironmentObject private var environment: AppEnvironment
    @State private var shareImage: Image?
    @State private var isBuildingShareImage = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    routeCard
                    heroCard
                    statsCard
                    progressCard

                    ForEach(summary.milestones) { milestone in
                        MilestoneCard(milestone: milestone)
                    }

                    shareControl
                }
                .padding(20)
            }
            .walkPageBackground()
            .navigationTitle(String(localized: "Walk recorded"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(action: onDone) {
                        Text(String(localized: "Done"))
                            .font(WalkType.button)
                    }
                    .tint(WalkPalette.accent)
                    .accessibilityLabel(String(localized: "Close the walk summary"))
                }
            }
        }
    }

    // MARK: - Cards

    @ViewBuilder
    private var routeCard: some View {
        if summary.route.count > 1 {
            RouteMapView(route: summary.route)
                .frame(height: 220)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .shadow(color: WalkPalette.cardShadow, radius: 12, x: 0, y: 2)
        }
    }

    private var heroCard: some View {
        VStack(spacing: 8) {
            HeroNumber(
                value: WalkFormat.distance(metres: summary.newCoverageMetres),
                size: 64,
                color: WalkPalette.accent
            )
            CapsLabel(text: String(localized: "New street unlocked"))
        }
        .frame(maxWidth: .infinity)
        .walkCard(padding: 26)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "New street unlocked"))
        .accessibilityValue(WalkFormat.distance(metres: summary.newCoverageMetres))
    }

    private var statsCard: some View {
        StatTileRow(tiles: [
            StatTile(
                title: String(localized: "Distance"),
                value: WalkFormat.distance(metres: summary.distanceMetres)
            ),
            StatTile(
                title: String(localized: "Time"),
                value: WalkFormat.clock(summary.duration)
            ),
            StatTile(
                title: String(localized: "New blocks"),
                value: summary.newBlocks.formatted()
            )
        ])
        .walkCard()
    }

    private var progressCard: some View {
        VStack(spacing: 10) {
            CapsLabel(text: String(localized: "City progress"))

            Text(progressText)
                .font(WalkType.cardTitle)
                .foregroundStyle(WalkPalette.ink)
                .multilineTextAlignment(.center)
                .contentTransition(.numericText())

            ProgressView(value: min(1, max(0, summary.percentAfter / 100)))
                .tint(WalkPalette.accent)
        }
        .frame(maxWidth: .infinity)
        .walkCard()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "City progress"))
        .accessibilityValue(progressText)
    }

    private var progressText: String {
        let before = WalkFormat.percentage(summary.percentBefore)
        let after = WalkFormat.percentage(summary.percentAfter)
        return String(localized: "\(before) to \(after) of \(summary.cityName)")
    }

    // MARK: - Sharing

    @ViewBuilder
    private var shareControl: some View {
        if let shareImage {
            ShareLink(
                item: shareImage,
                preview: SharePreview(shareTitle, image: shareImage)
            ) {
                Text(String(localized: "Share"))
            }
            .buttonStyle(PillButtonStyle(filled: false))
            .accessibilityLabel(String(localized: "Share an image of your progress"))
        } else {
            Button {
                Task { await buildShareImage() }
            } label: {
                Text(
                    isBuildingShareImage
                        ? String(localized: "Preparing")
                        : String(localized: "Create share image")
                )
            }
            .buttonStyle(PillButtonStyle(filled: false))
            .disabled(isBuildingShareImage)
            .accessibilityLabel(String(localized: "Create an image of your progress to share"))
            .accessibilityHint(String(localized: "Makes a picture on this device. Nothing is uploaded."))
        }
    }

    private var shareTitle: String {
        String(localized: "\(WalkFormat.percentage(summary.percentAfter)) of \(summary.cityName)")
    }

    private func buildShareImage() async {
        isBuildingShareImage = true
        defer { isBuildingShareImage = false }

        // Reading every walked street out of the pack and normalising it is the
        // expensive half, and it happens off the main thread. Only the draw
        // itself has to be here.
        let runs = await environment.walkedStreetGeometry()
        let card = ShareCardView(
            cityName: summary.cityName,
            percentageText: WalkFormat.percentage(summary.percentAfter),
            runs: runs
        )
        shareImage = ShareCardRenderer.image(for: card)
    }
}

// MARK: - Milestones

/// One milestone, in the accent. The wording comes from Core: the detector
/// produces finished, localised strings and nothing here invents any.
private struct MilestoneCard: View {

    let milestone: Milestone

    private var isHeadline: Bool {
        switch milestone.kind {
        case .cityComplete: return true
        default: return false
        }
    }

    private var icon: String {
        switch milestone.kind {
        case .firstWalk: return "figure.walk"
        case .blocks: return "square.grid.2x2.fill"
        case .distance: return "ruler.fill"
        case .cityPercent: return "chart.pie.fill"
        case .districtComplete: return "checkmark.seal.fill"
        case .cityComplete: return "crown.fill"
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: icon)
                .font(isHeadline ? .title : .title3)
                .foregroundStyle(.white)
                .frame(width: isHeadline ? 56 : 44, height: isHeadline ? 56 : 44)
                .background(Circle().fill(Color.white.opacity(0.2)))

            VStack(alignment: .leading, spacing: 5) {
                Text(milestone.title)
                    .font(isHeadline ? WalkType.screenTitle : WalkType.cardTitle)
                    .foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)

                Text(milestone.detail)
                    .font(WalkType.caption)
                    .foregroundStyle(Color.white.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(isHeadline ? 26 : 20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(WalkPalette.accent)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(milestone.title)
        .accessibilityValue(milestone.detail)
    }
}
