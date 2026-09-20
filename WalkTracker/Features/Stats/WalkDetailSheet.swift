import Foundation
import SwiftUI

/// One recorded walk, replayed on a map, with the walk before and after it one
/// tap away.
///
/// The trace is stored permanently, so any walk can be opened again long after
/// it happened. The map is loaded on demand rather than with the list, because
/// the list only needs a thumbnail.
struct WalkDetailSheet: View {

    let sessions: [WalkSession]
    let onDone: () -> Void

    @EnvironmentObject private var environment: AppEnvironment

    @State private var index: Int
    @State private var route: [Coordinate] = []
    @State private var markers: [RouteMarker] = []
    @State private var isLoading = true

    private let fallback: WalkSession

    init(sessions: [WalkSession], initialWalk: WalkSession, onDone: @escaping () -> Void) {
        self.sessions = sessions
        self.fallback = initialWalk
        self.onDone = onDone
        _index = State(initialValue: sessions.firstIndex { $0.id == initialWalk.id } ?? 0)
    }

    private var session: WalkSession {
        sessions.indices.contains(index) ? sessions[index] : fallback
    }

    /// Counted from the oldest walk, so the number grows as the history does.
    private var walkNumber: Int {
        max(1, sessions.count - index)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    walkCounterPill
                    mapCard
                    detailCard

                    if session.source.isImported {
                        importedNote
                    }
                }
                .padding(20)
            }
            .walkPageBackground()
            .navigationTitle(String(localized: "Walk"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(action: onDone) {
                        Text(String(localized: "Done"))
                            .font(WalkType.button)
                    }
                    .tint(WalkPalette.accent)
                    .accessibilityLabel(String(localized: "Close this walk"))
                }
            }
        }
        .task(id: session.id) {
            await load()
        }
    }

    // MARK: - Pieces

    private var walkCounterPill: some View {
        Text(String(localized: "Walk \(walkNumber.formatted()) of \(sessions.count.formatted())"))
            .font(WalkType.label)
            .textCase(.uppercase)
            .kerning(0.8)
            .foregroundStyle(WalkPalette.secondaryInk)
            .padding(.vertical, 8)
            .padding(.horizontal, 16)
            .background(Capsule(style: .continuous).fill(WalkPalette.card))
            .shadow(color: WalkPalette.cardShadow, radius: 8, x: 0, y: 2)
    }

    @ViewBuilder
    private var mapCard: some View {
        if route.count > 1 {
            RouteMapView(route: route, markers: markers)
                .frame(height: 300)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .shadow(color: WalkPalette.cardShadow, radius: 12, x: 0, y: 2)
        } else if isLoading {
            ProgressView()
                .frame(maxWidth: .infinity)
                .frame(height: 300)
                .walkCard()
                .accessibilityLabel(String(localized: "Loading the route"))
        } else {
            Text(String(localized: "This walk has no usable trace to draw."))
                .font(WalkType.body)
                .foregroundStyle(WalkPalette.secondaryInk)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
                .walkCard()
        }
    }

    private var detailCard: some View {
        VStack(spacing: 18) {
            HStack {
                stepButton(
                    icon: "chevron.left",
                    label: String(localized: "Older walk"),
                    enabled: index + 1 < sessions.count
                ) {
                    index += 1
                }

                Spacer(minLength: 8)

                VStack(spacing: 3) {
                    Text(session.startedAt.formatted(.dateTime.weekday(.wide).day().month(.wide)))
                        .font(WalkType.cardTitle)
                        .foregroundStyle(WalkPalette.ink)
                        .multilineTextAlignment(.center)

                    Text(session.startedAt.formatted(date: .omitted, time: .shortened))
                        .font(WalkType.caption)
                        .foregroundStyle(WalkPalette.secondaryInk)
                }

                Spacer(minLength: 8)

                stepButton(
                    icon: "chevron.right",
                    label: String(localized: "Newer walk"),
                    enabled: index > 0
                ) {
                    index -= 1
                }
            }

            StatTileRow(tiles: [
                StatTile(
                    title: String(localized: "Distance"),
                    value: WalkFormat.distance(metres: session.distanceMetres),
                    size: 21
                ),
                StatTile(
                    title: String(localized: "Time"),
                    value: WalkFormat.clock(session.duration),
                    size: 21
                ),
                StatTile(
                    title: String(localized: "New street"),
                    value: WalkFormat.distance(metres: session.newCoverageMetres),
                    size: 21,
                    tint: WalkPalette.accent
                ),
                StatTile(
                    title: String(localized: "GPS points"),
                    value: session.pointCount.formatted(),
                    size: 21
                )
            ])
        }
        .walkCard(padding: 20)
    }

    private func stepButton(
        icon: String,
        label: String,
        enabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(enabled ? WalkPalette.accent : WalkPalette.secondaryInk.opacity(0.4))
                .frame(width: 44, height: 44)
        }
        .disabled(!enabled)
        .accessibilityLabel(label)
    }

    private var importedNote: some View {
        HStack(alignment: .top, spacing: 10) {
            ImportedBadge()
            Text(String(localized: "This walk came from a file you imported, not from recording in WalkTracker. It counts toward your coverage all the same."))
                .font(WalkType.caption)
                .foregroundStyle(WalkPalette.secondaryInk)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .walkCard(padding: 18)
    }

    // MARK: - Loading

    private struct LoadedRoute: Sendable {
        let coordinates: [Coordinate]
        let markers: [RouteMarker]
    }

    private func load() async {
        isLoading = true
        route = []
        markers = []

        let services = environment.services
        let sessionID = session.id

        let loaded = await Task.detached(priority: .userInitiated) { () -> LoadedRoute in
            let points = (try? services.sessionStore.points(sessionID: sessionID)) ?? []
            guard points.count > 1 else {
                return LoadedRoute(coordinates: [], markers: [])
            }

            var markers: [RouteMarker] = [
                RouteMarker(
                    coordinate: points[0].coordinate,
                    title: String(localized: "Start"),
                    kind: .start
                )
            ]

            // A few time labels along the way, which is what makes a route read
            // as a journey rather than as a shape.
            for fraction in [0.25, 0.5, 0.75] {
                let position = Int(Double(points.count - 1) * fraction)
                guard position > 0, position < points.count - 1 else { continue }
                let point = points[position]
                markers.append(
                    RouteMarker(
                        coordinate: point.coordinate,
                        title: point.timestamp.formatted(date: .omitted, time: .shortened),
                        kind: .time
                    )
                )
            }

            markers.append(
                RouteMarker(
                    coordinate: points[points.count - 1].coordinate,
                    title: String(localized: "End"),
                    kind: .end
                )
            )

            return LoadedRoute(coordinates: points.map(\.coordinate), markers: markers)
        }.value

        guard !Task.isCancelled else { return }
        route = loaded.coordinates
        markers = loaded.markers
        isLoading = false
    }
}
