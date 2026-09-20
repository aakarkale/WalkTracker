import SwiftUI
import Charts

/// Progress for the selected city: the headline figure, how it has moved, a
/// neighbourhood breakdown, and the walks that produced it.
struct StatsScreen: View {

    @EnvironmentObject private var environment: AppEnvironment

    @State private var districts: [CoverageCalculator.DistrictStats] = []
    @State private var sessions: [WalkSession] = []
    /// Route shapes, normalised once off the main thread and kept here so the
    /// list does not recompute them while it scrolls.
    @State private var routes: [Int64: [CGPoint]] = [:]
    @State private var period: ChartPeriod = .week
    @State private var selectedWalk: WalkSession?
    @State private var isLoading = false

    /// Everything that can change the numbers. Used as the reload key so the
    /// screen refreshes after a walk, an import, a settings change or a city
    /// switch, with no manual invalidation anywhere.
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
            .walkPageBackground()
            .navigationTitle(String(localized: "Progress"))
        }
        .task(id: reloadKey) {
            await load()
        }
        .sheet(item: $selectedWalk) { walk in
            WalkDetailSheet(session: walk) {
                selectedWalk = nil
            }
        }
    }

    // MARK: - Content

    private var content: some View {
        ScrollView {
            VStack(spacing: 18) {
                headlineCard
                blocksCard

                if !chartBuckets.isEmpty {
                    chartCard
                }

                if !districts.isEmpty {
                    districtCard
                }

                recentWalksCard
            }
            .padding(20)
        }
        .refreshable { await load() }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "chart.bar.xaxis")
                .font(.system(size: 34))
                .foregroundStyle(WalkPalette.accent)

            Text(String(localized: "Nothing to show yet"))
                .font(WalkType.screenTitle)
                .foregroundStyle(WalkPalette.ink)

            Text(String(localized: "Choose a city and download its streets. Your percentage, your neighbourhoods and every walk you record will appear here."))
                .font(WalkType.body)
                .foregroundStyle(WalkPalette.secondaryInk)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(28)
        .frame(maxWidth: .infinity)
        .walkCard()
        .padding(20)
    }

    // MARK: - Headline

    @ViewBuilder
    private var headlineCard: some View {
        if let stats = environment.cityStats {
            VStack(spacing: 16) {
                ProgressRing(
                    fraction: stats.blockFraction,
                    title: WalkFormat.percentage(
                        stats.displayPercentage,
                        startedButBelowResolution: stats.completedBlocks > 0
                    ),
                    caption: cityCaption,
                    accessibilityDescription: headlineAccessibilityText(stats)
                )

                Text(WalkFormat.blockCounter(completed: stats.completedBlocks, total: stats.totalBlocks))
                    .font(WalkType.label)
                    .textCase(.uppercase)
                    .kerning(0.8)
                    .foregroundStyle(WalkPalette.secondaryInk)
            }
            .frame(maxWidth: .infinity)
            .walkCard(padding: 26)
        } else if isLoading {
            ProgressView()
                .frame(maxWidth: .infinity)
                .padding(40)
                .walkCard()
        }
    }

    @ViewBuilder
    private var blocksCard: some View {
        if let stats = environment.cityStats {
            StatTileRow(tiles: [
                StatTile(
                    title: String(localized: "Blocks done"),
                    value: stats.completedBlocks.formatted(),
                    tint: WalkPalette.accent
                ),
                StatTile(
                    title: String(localized: "Blocks to go"),
                    value: stats.remainingBlocks.formatted()
                ),
                StatTile(
                    title: String(localized: "Street walked"),
                    value: WalkFormat.distance(metres: stats.walkedMetres)
                )
            ])
            .walkCard()
        }
    }

    private var cityCaption: String {
        guard let name = environment.selectedCity?.name else { return "" }
        return String(localized: "of \(name)")
    }

    private func headlineAccessibilityText(_ stats: CoverageCalculator.CityStats) -> String {
        let percent = WalkFormat.percentage(
            stats.displayPercentage,
            startedButBelowResolution: stats.completedBlocks > 0
        )
        let name = environment.selectedCity?.name ?? String(localized: "this city")
        let blocks = WalkFormat.blocks(completed: stats.completedBlocks, total: stats.totalBlocks)
        return String(localized: "\(percent) of \(name) walked, \(blocks)")
    }

    // MARK: - Chart

    private var chartCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                CapsLabel(text: String(localized: "New street (\(WalkFormat.distanceUnitLabel))"))
                Spacer(minLength: 8)
            }

            Picker(String(localized: "Period"), selection: $period) {
                ForEach(ChartPeriod.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            .pickerStyle(.segmented)

            Chart {
                ForEach(chartBuckets) { bucket in
                    BarMark(
                        x: .value(String(localized: "Period"), bucket.label),
                        y: .value(String(localized: "New street"), WalkFormat.distanceValue(metres: bucket.newCoverageMetres))
                    )
                    .foregroundStyle(WalkPalette.accent)
                    .cornerRadius(5)
                }
            }
            .chartLegend(.hidden)
            .frame(height: 170)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(String(localized: "New street unlocked per \(period.title)"))
            .accessibilityValue(chartAccessibilitySummary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .walkCard()
    }

    private var chartBuckets: [WalkBucket] {
        WalkBucket.buckets(from: sessions, period: period)
    }

    private var chartAccessibilitySummary: String {
        let total = chartBuckets.reduce(0) { $0 + $1.newCoverageMetres }
        return String(localized: "\(WalkFormat.distance(metres: total)) in total across \(chartBuckets.count.formatted()) periods")
    }

    // MARK: - Districts

    private var districtCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            CapsLabel(text: String(localized: "Neighbourhoods"))
                .frame(maxWidth: .infinity, alignment: .leading)

            ForEach(districts) { district in
                DistrictRow(stats: district)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .walkCard()
    }

    // MARK: - Recent walks

    private var recentWalksCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            CapsLabel(text: String(localized: "Recent walks"))
                .frame(maxWidth: .infinity, alignment: .leading)

            if sessions.isEmpty {
                Text(String(localized: "No walks yet. Press Start Walk on the map, or import a GPX history from Settings."))
                    .font(WalkType.body)
                    .foregroundStyle(WalkPalette.secondaryInk)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(sessions.prefix(12)) { session in
                    Button {
                        selectedWalk = session
                    } label: {
                        WalkRow(session: session, route: routes[session.id] ?? [])
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint(String(localized: "Opens this walk on a map"))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .walkCard()
    }

    // MARK: - Loading

    private struct StatsPayload: Sendable {
        let districts: [CoverageCalculator.DistrictStats]
        let sessions: [WalkSession]
        let routes: [Int64: [CGPoint]]
    }

    private func load() async {
        guard let context = environment.packContext, let cityID = environment.selectedCity?.id else {
            districts = []
            sessions = []
            routes = [:]
            return
        }

        isLoading = true
        defer { isLoading = false }

        await environment.refreshCityStats()

        let services = environment.services
        let includeOptional = environment.includeOptionalWays

        // District stats walk every segment in the city and the thumbnails read
        // one trace per walk, so none of this happens on the main thread.
        let payload = await Task.detached(priority: .userInitiated) { () -> StatsPayload in
            let calculator = CoverageCalculator(
                packStore: context.store,
                coverageStore: services.coverageStore
            )
            let districts = (try? calculator.districtStats(
                cityID: cityID,
                includeOptional: includeOptional
            )) ?? []
            let sessions = (try? services.sessionStore.recentSessions(cityID: cityID, limit: 120)) ?? []

            // Only the rows that are actually drawn get a thumbnail.
            var routes: [Int64: [CGPoint]] = [:]
            for session in sessions.prefix(12) {
                let points = (try? services.sessionStore.points(sessionID: session.id)) ?? []
                routes[session.id] = RouteGeometry.normalise(points.map(\.coordinate), limit: 70)
            }

            return StatsPayload(districts: districts, sessions: sessions, routes: routes)
        }.value

        guard !Task.isCancelled else { return }
        districts = payload.districts
        sessions = payload.sessions
        routes = payload.routes
    }
}

// MARK: - Chart data

enum ChartPeriod: String, CaseIterable, Identifiable {
    case day
    case week
    case month

    var id: String { rawValue }

    var title: String {
        switch self {
        case .day: return String(localized: "Day")
        case .week: return String(localized: "Week")
        case .month: return String(localized: "Month")
        }
    }

    var component: Calendar.Component {
        switch self {
        case .day: return .day
        case .week: return .weekOfYear
        case .month: return .month
        }
    }

    /// How many buckets to show. Enough to see a trend, few enough that the
    /// bars stay wide enough to read on a phone.
    var bucketCount: Int {
        switch self {
        case .day: return 10
        case .week: return 8
        case .month: return 6
        }
    }
}

struct WalkBucket: Identifiable {

    let id: Date
    let label: String
    let newCoverageMetres: Double
    let distanceMetres: Double

    /// Buckets sessions by day, week or month.
    ///
    /// Computed from the sessions already loaded rather than with another
    /// query: a hundred rows is nothing to fold, and it keeps the period
    /// switch instant.
    static func buckets(from sessions: [WalkSession], period: ChartPeriod) -> [WalkBucket] {
        guard !sessions.isEmpty else { return [] }

        let calendar = Calendar.current
        var newCoverage: [Date: Double] = [:]
        var distance: [Date: Double] = [:]

        for session in sessions {
            guard let start = calendar.dateInterval(of: period.component, for: session.startedAt)?.start else {
                continue
            }
            newCoverage[start, default: 0] += session.newCoverageMetres
            distance[start, default: 0] += session.distanceMetres
        }

        return newCoverage.keys
            .sorted()
            .suffix(period.bucketCount)
            .map { start in
                WalkBucket(
                    id: start,
                    label: label(for: start, period: period),
                    newCoverageMetres: newCoverage[start] ?? 0,
                    distanceMetres: distance[start] ?? 0
                )
            }
    }

    private static func label(for date: Date, period: ChartPeriod) -> String {
        switch period {
        case .day:
            return date.formatted(.dateTime.day().month(.narrow))
        case .week:
            return date.formatted(.dateTime.day().month(.narrow))
        case .month:
            return date.formatted(.dateTime.month(.abbreviated))
        }
    }
}

// MARK: - Rows

private struct DistrictRow: View {

    let stats: CoverageCalculator.DistrictStats

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Text(stats.name)
                    .font(WalkType.body.weight(.medium))
                    .foregroundStyle(WalkPalette.ink)
                Spacer(minLength: 8)
                Text(WalkFormat.compactPercentage(fraction: stats.fraction))
                    .font(WalkType.body.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(WalkPalette.secondaryInk)
            }

            ProgressView(value: min(1, max(0, stats.fraction)))
                .tint(WalkPalette.accent)

            Text(WalkFormat.blocks(completed: stats.completedBlocks, total: stats.totalBlocks))
                .font(WalkType.caption)
                .foregroundStyle(WalkPalette.secondaryInk)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(stats.name)
        .accessibilityValue(
            "\(WalkFormat.compactPercentage(fraction: stats.fraction)), \(WalkFormat.blocks(completed: stats.completedBlocks, total: stats.totalBlocks))"
        )
    }
}

private struct WalkRow: View {

    let session: WalkSession
    let route: [CGPoint]

    var body: some View {
        HStack(spacing: 14) {
            RouteThumbnail(points: route)
                .frame(width: 58, height: 58)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(WalkFormat.sessionDate(session.startedAt))
                        .font(WalkType.body.weight(.medium))
                        .foregroundStyle(WalkPalette.ink)

                    if session.source.isImported {
                        ImportedBadge()
                    }
                }

                Text(summaryLine)
                    .font(WalkType.caption)
                    .foregroundStyle(WalkPalette.secondaryInk)
            }

            Spacer(minLength: 0)

            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(WalkPalette.secondaryInk)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(summaryLine)
    }

    private var summaryLine: String {
        let newStreet = WalkFormat.distance(metres: session.newCoverageMetres)
        let distance = WalkFormat.distance(metres: session.distanceMetres)
        let duration = WalkFormat.duration(session.duration)
        return String(localized: "\(newStreet) new, \(distance) walked, \(duration)")
    }

    private var accessibilityLabel: String {
        let date = WalkFormat.sessionDate(session.startedAt)
        return session.source.isImported
            ? String(localized: "\(date), imported walk")
            : date
    }
}

/// Marks a walk that was imported rather than recorded here.
///
/// It is real coverage, but it is not a walk taken with this app, and showing
/// the two identically would misreport what someone actually did.
struct ImportedBadge: View {

    var body: some View {
        Text(String(localized: "Imported"))
            .font(.caption2.weight(.semibold))
            .textCase(.uppercase)
            .kerning(0.5)
            .foregroundStyle(WalkPalette.secondaryInk)
            .padding(.vertical, 3)
            .padding(.horizontal, 7)
            .background(Capsule(style: .continuous).fill(WalkPalette.hairline))
            .accessibilityHidden(true)
    }
}
