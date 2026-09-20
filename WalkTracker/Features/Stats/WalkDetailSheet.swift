import SwiftUI

/// One recorded walk, replayed on a map with the numbers it produced.
///
/// The trace is stored permanently, so any walk can be opened again long after
/// it happened. The map is loaded on demand rather than with the list, because
/// the list only needs a thumbnail.
struct WalkDetailSheet: View {

    let session: WalkSession
    let onDone: () -> Void

    @EnvironmentObject private var environment: AppEnvironment

    @State private var route: [Coordinate] = []
    @State private var isLoading = true

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    mapCard
                    statsCard

                    if session.source.isImported {
                        importedNote
                    }
                }
                .padding(20)
            }
            .walkPageBackground()
            .navigationTitle(WalkFormat.sessionDate(session.startedAt))
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
        .task { await load() }
    }

    @ViewBuilder
    private var mapCard: some View {
        if route.count > 1 {
            RouteMapView(route: route)
                .frame(height: 280)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .shadow(color: WalkPalette.cardShadow, radius: 12, x: 0, y: 2)
        } else if isLoading {
            ProgressView()
                .frame(maxWidth: .infinity)
                .frame(height: 280)
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

    private var statsCard: some View {
        StatTileRow(tiles: [
            StatTile(
                title: String(localized: "New street"),
                value: WalkFormat.distance(metres: session.newCoverageMetres),
                tint: WalkPalette.accent
            ),
            StatTile(
                title: String(localized: "Distance"),
                value: WalkFormat.distance(metres: session.distanceMetres)
            ),
            StatTile(
                title: String(localized: "Time"),
                value: WalkFormat.clock(session.duration)
            )
        ])
        .walkCard()
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

    private func load() async {
        let services = environment.services
        let sessionID = session.id

        let points = await Task.detached(priority: .userInitiated) { () -> [Coordinate] in
            let stored = (try? services.sessionStore.points(sessionID: sessionID)) ?? []
            return stored.map(\.coordinate)
        }.value

        route = points
        isLoading = false
    }
}
