import SwiftUI

/// Progress for the selected city: the headline percentage, a neighbourhood
/// breakdown, and the walks that produced it.
struct StatsScreen: View {

    @EnvironmentObject private var environment: AppEnvironment

    @State private var districts: [CoverageCalculator.DistrictStats] = []
    @State private var sessions: [WalkSession] = []
    @State private var isLoading = false

    /// Everything that can change the numbers. Used as the reload key so the
    /// screen refreshes after a walk, a settings change or a city switch
    /// without any manual invalidation.
    private var reloadKey: String {
        let city = environment.selectedCity?.id ?? "none"
        return "\(city)|\(environment.coverageRevision)|\(environment.includeOptionalWays)"
    }

    var body: some View {
        NavigationStack {
            Group {
                if environment.packContext == nil {
                    emptyState
                } else {
                    content
                }
            }
            .navigationTitle(String(localized: "Stats"))
        }
        .task(id: reloadKey) {
            await load()
        }
    }

    // MARK: - Content

    private var content: some View {
        List {
            summarySection

            if !districts.isEmpty {
                districtSection
            }

            recentWalksSection
        }
        .listStyle(.insetGrouped)
        .refreshable { await load() }
    }

    @ViewBuilder
    private var emptyState: some View {
        ContentUnavailableView {
            Label(String(localized: "Nothing to show yet"), systemImage: "chart.bar.xaxis")
        } description: {
            Text(String(localized: "Choose a city and download its streets, then your progress appears here."))
        }
    }

    private var summarySection: some View {
        Section {
            VStack(spacing: 18) {
                if let stats = environment.cityStats {
                    ProgressRing(
                        fraction: stats.fraction,
                        title: WalkFormat.percentage(
                            stats.displayPercentage,
                            startedButBelowResolution: stats.walkedMetres > 0
                        ),
                        caption: cityCaption,
                        accessibilityDescription: summaryAccessibilityText(stats)
                    )
                    .frame(maxWidth: .infinity)

                    StatTileRow {
                        StatTile(
                            title: String(localized: "Blocks done"),
                            value: stats.completedBlocks.formatted(),
                            caption: String(localized: "of \(stats.totalBlocks.formatted())"),
                            systemImage: "square.grid.2x2"
                        )
                        StatTile(
                            title: String(localized: "Distance walked"),
                            value: WalkFormat.distance(metres: stats.walkedMetres),
                            systemImage: "figure.walk"
                        )
                        StatTile(
                            title: String(localized: "City total"),
                            value: WalkFormat.distance(metres: stats.totalMetres),
                            systemImage: "map"
                        )
                    }
                } else if isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.vertical, 8)
        }
    }

    private var districtSection: some View {
        Section {
            ForEach(districts) { district in
                DistrictRow(stats: district)
            }
        } header: {
            Text(String(localized: "Neighbourhoods"))
        } footer: {
            Text(String(localized: "Ordered by how much of each neighbourhood you have walked."))
        }
    }

    private var recentWalksSection: some View {
        Section {
            if sessions.isEmpty {
                Text(String(localized: "No walks recorded yet."))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(sessions) { session in
                    WalkRow(session: session)
                }
            }
        } header: {
            Text(String(localized: "Recent walks"))
        }
    }

    // MARK: - Text

    private var cityCaption: String {
        guard let name = environment.selectedCity?.name else { return "" }
        return String(localized: "of \(name)")
    }

    private func summaryAccessibilityText(_ stats: CoverageCalculator.CityStats) -> String {
        let percent = WalkFormat.percentage(
            stats.displayPercentage,
            startedButBelowResolution: stats.walkedMetres > 0
        )
        let name = environment.selectedCity?.name ?? String(localized: "this city")
        let blocks = WalkFormat.blocks(completed: stats.completedBlocks, total: stats.totalBlocks)
        return String(localized: "\(percent) of \(name) walked, \(blocks)")
    }

    // MARK: - Loading

    private struct StatsPayload: Sendable {
        let districts: [CoverageCalculator.DistrictStats]
        let sessions: [WalkSession]
    }

    private func load() async {
        guard let context = environment.packContext, let cityID = environment.selectedCity?.id else {
            districts = []
            sessions = []
            return
        }

        isLoading = true
        defer { isLoading = false }

        await environment.refreshCityStats()

        let services = environment.services
        let includeOptional = environment.includeOptionalWays

        // District stats walk every segment in the city, so this never runs on
        // the main thread.
        let payload = await Task.detached(priority: .userInitiated) { () -> StatsPayload in
            let calculator = CoverageCalculator(
                packStore: context.store,
                coverageStore: services.coverageStore
            )
            let districts = (try? calculator.districtStats(
                cityID: cityID,
                includeOptional: includeOptional
            )) ?? []
            let sessions = (try? services.sessionStore.recentSessions(cityID: cityID, limit: 30)) ?? []
            return StatsPayload(districts: districts, sessions: sessions)
        }.value

        guard !Task.isCancelled else { return }
        districts = payload.districts
        sessions = payload.sessions
    }
}

// MARK: - Rows

private struct DistrictRow: View {

    let stats: CoverageCalculator.DistrictStats

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(stats.name)
                    .font(.subheadline.weight(.medium))
                Spacer(minLength: 8)
                Text(WalkFormat.compactPercentage(fraction: stats.fraction))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            ProgressView(value: min(1, max(0, stats.fraction)))
                .tint(WalkPalette.walked)

            Text(WalkFormat.blocks(completed: stats.completedBlocks, total: stats.totalBlocks))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(stats.name)
        .accessibilityValue(
            "\(WalkFormat.compactPercentage(fraction: stats.fraction)), \(WalkFormat.blocks(completed: stats.completedBlocks, total: stats.totalBlocks))"
        )
    }
}

private struct WalkRow: View {

    let session: WalkSession

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(WalkFormat.sessionDate(session.startedAt))
                .font(.subheadline.weight(.medium))

            HStack(spacing: 12) {
                Label(WalkFormat.distance(metres: session.distanceMetres), systemImage: "figure.walk")
                Label(WalkFormat.distance(metres: session.newCoverageMetres), systemImage: "sparkles")
                Label(WalkFormat.duration(session.duration), systemImage: "clock")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .labelStyle(.titleAndIcon)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(WalkFormat.sessionDate(session.startedAt))
        .accessibilityValue(
            String(
                localized: "\(WalkFormat.distance(metres: session.distanceMetres)) walked, \(WalkFormat.distance(metres: session.newCoverageMetres)) of it new, over \(WalkFormat.duration(session.duration))"
            )
        )
    }
}
