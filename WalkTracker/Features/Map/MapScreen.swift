import SwiftUI
import MapKit
import UIKit

/// The primary screen: the city map, the walk control, and whatever the user
/// has to do next before a walk can be recorded.
struct MapScreen: View {

    @EnvironmentObject private var environment: AppEnvironment

    var body: some View {
        // The tracking engine is a separate observable object, so it is passed
        // down explicitly. Observing the environment object alone would miss
        // every distance update during a walk.
        MapScreenBody(environment: environment, engine: environment.engine)
    }
}

private struct MapScreenBody: View {

    @ObservedObject var environment: AppEnvironment
    @ObservedObject var engine: TrackingEngine

    @StateObject private var loader = MapSegmentLoader()
    @Environment(\.openURL) private var openURL

    @State private var focus: MapFocusRequest?
    @State private var followRequest = 0
    @State private var showingCities = false

    private var isReady: Bool {
        environment.packContext != nil && environment.hasLocationAccess
    }

    var body: some View {
        ZStack(alignment: .top) {
            StreetMapView(
                overlays: loader.overlays,
                showsUserLocation: environment.hasLocationAccess,
                focus: focus,
                followRequest: followRequest,
                onVisibleAreaChange: { area in loader.visibleAreaChanged(area) }
            )
            .ignoresSafeArea()
            .accessibilityLabel(String(localized: "Map of the city. Streets you have walked are drawn in green."))

            VStack(spacing: 12) {
                headerCard

                Spacer(minLength: 0)

                statusCard

                WalkControlBar(
                    engine: engine,
                    isReady: isReady,
                    onStart: { environment.startWalk() },
                    onStop: { environment.stopWalk() }
                )
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 10)
        }
        .sheet(isPresented: $showingCities) {
            NavigationStack {
                CityListScreen()
            }
        }
        .onAppear {
            syncLoader()
            focusOnSelectedCity(force: false)
        }
        .onChange(of: environment.packContext?.city.id) { _, _ in
            syncLoader()
            focusOnSelectedCity(force: true)
        }
        .onChange(of: environment.includeOptionalWays) { _, _ in
            syncLoader()
        }
        .onChange(of: environment.coverageRevision) { _, _ in
            loader.coverageChanged()
        }
        .onChange(of: engine.segmentsTouchedThisWalk.count) { _, _ in
            // Streets claimed during this walk should turn green without
            // waiting for the walk to end.
            loader.coverageChanged()
        }
    }

    // MARK: - Header

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Button {
                    showingCities = true
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(environment.selectedCity?.name ?? String(localized: "No city selected"))
                            .font(.headline)
                            .foregroundStyle(.primary)
                        Text(coverageSubtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(localized: "City and progress"))
                .accessibilityValue(
                    "\(environment.selectedCity?.name ?? String(localized: "No city selected")), \(coverageSubtitle)"
                )
                .accessibilityHint(String(localized: "Opens the list of cities"))

                if loader.isLoading || environment.isPreparingCity {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel(String(localized: "Loading streets"))
                }

                Button {
                    followRequest += 1
                } label: {
                    Image(systemName: "location")
                        .font(.body)
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.bordered)
                .disabled(!environment.hasLocationAccess)
                .accessibilityLabel(String(localized: "Centre the map on my location"))
            }

            if environment.packContext != nil {
                legend
            }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var legend: some View {
        HStack(spacing: 16) {
            legendItem(color: WalkPalette.walked, text: String(localized: "Walked"))
            legendItem(color: WalkPalette.unwalked, text: String(localized: "Still to walk"))
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private func legendItem(color: Color, text: String) -> some View {
        HStack(spacing: 6) {
            Capsule()
                .fill(color)
                .frame(width: 18, height: 4)
            Text(text)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var coverageSubtitle: String {
        guard let stats = environment.cityStats else {
            if environment.selectedCity == nil {
                return String(localized: "Choose where you walk")
            }
            return String(localized: "No street data yet")
        }
        let percent = WalkFormat.percentage(
            stats.displayPercentage,
            startedButBelowResolution: stats.walkedMetres > 0
        )
        let blocks = WalkFormat.blocks(completed: stats.completedBlocks, total: stats.totalBlocks)
        return String(localized: "\(percent) walked, \(blocks)")
    }

    // MARK: - Status

    /// The one thing standing between the user and a recorded walk, if there
    /// is one. Ordered by what has to happen first.
    @ViewBuilder
    private var statusCard: some View {
        if let fraction = environment.rebuildFraction {
            MapInfoCard(
                icon: "arrow.triangle.2.circlepath",
                title: String(localized: "Rebuilding your coverage"),
                message: String(localized: "The street data for this city changed, so your walks are being matched against it again. Nothing is lost."),
                progress: fraction
            )
        } else if environment.selectedCity == nil {
            MapInfoCard(
                icon: "mappin.and.ellipse",
                title: String(localized: "Choose a city"),
                message: String(localized: "Pick the city you walk in and WalkTracker will keep track of the streets you have covered."),
                actionTitle: String(localized: "Choose a city"),
                action: { showingCities = true }
            )
        } else if let city = environment.selectedCity, city.pack == nil {
            MapInfoCard(
                icon: "clock.badge.questionmark",
                title: String(localized: "Streets for \(city.name) are not ready yet"),
                message: String(localized: "This city is on the list, but its street data has not been built. You can pick a different city in the meantime."),
                actionTitle: String(localized: "Choose another city"),
                action: { showingCities = true }
            )
        } else if let city = environment.selectedCity {
            packStatusCard(for: city)
        }
    }

    @ViewBuilder
    private func packStatusCard(for city: City) -> some View {
        switch environment.installState(for: city) {
        case .installing(let fraction):
            MapInfoCard(
                icon: "arrow.down.circle",
                title: String(localized: "Downloading streets for \(city.name)"),
                message: String(localized: "This happens once. The streets are then stored on this device and work offline."),
                progress: fraction
            )

        case .failed(let message):
            MapInfoCard(
                icon: "exclamationmark.triangle",
                title: String(localized: "The download did not finish"),
                message: message,
                actionTitle: String(localized: "Try again"),
                action: { Task { await environment.installPack(for: city) } }
            )

        case .notInstalled:
            MapInfoCard(
                icon: "arrow.down.circle",
                title: String(localized: "Download the streets of \(city.name)"),
                message: downloadMessage(for: city),
                actionTitle: String(localized: "Download"),
                action: { Task { await environment.installPack(for: city) } }
            )

        case .installed:
            permissionOrHintCard
        }
    }

    @ViewBuilder
    private var permissionOrHintCard: some View {
        if environment.locationAccessDenied {
            MapInfoCard(
                icon: "location.slash",
                title: String(localized: "Location is turned off for WalkTracker"),
                message: String(localized: "Walks are recorded from your location, so nothing can be tracked until it is turned back on in the Settings app."),
                actionTitle: String(localized: "Open Settings"),
                action: openSystemSettings
            )
        } else if !environment.hasLocationAccess {
            MapInfoCard(
                icon: "location",
                title: String(localized: "Allow location to record a walk"),
                message: String(localized: "Your location is used to work out which streets you covered. It stays on this device."),
                actionTitle: String(localized: "Allow location"),
                action: { environment.requestWhenInUseAccess() }
            )
        } else if loader.isZoomedOut {
            MapInfoCard(
                icon: "plus.magnifyingglass",
                title: String(localized: "Zoom in to see streets"),
                message: String(localized: "Street detail is drawn for the area you are looking at, rather than for the whole city at once.")
            )
        }
    }

    private func downloadMessage(for city: City) -> String {
        guard let pack = city.pack else { return "" }
        let size = WalkFormat.downloadSize(bytes: pack.compressedBytes)
        let blocks = WalkFormat.segmentCount(pack.segmentCount)
        return String(localized: "\(size) download, \(blocks). Stored on this device and used offline.")
    }

    // MARK: - Actions

    private func syncLoader() {
        loader.configure(
            services: environment.services,
            packContext: environment.packContext,
            includeOptionalWays: environment.includeOptionalWays
        )
    }

    private func focusOnSelectedCity(force: Bool) {
        guard let city = environment.selectedCity else { return }
        guard force || focus == nil else { return }
        focus = MapFocusRequest(center: city.center.clCoordinate, spanMetres: 3_000)
    }

    private func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        openURL(url)
    }
}

// MARK: - Card

/// One piece of guidance on top of the map, with an optional progress bar and
/// an optional single action.
private struct MapInfoCard: View {

    let icon: String
    let title: String
    let message: String
    var progress: Double?
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: icon)
            }

            if !message.isEmpty {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let progress {
                ProgressView(value: min(1, max(0, progress)))
                    .tint(WalkPalette.walked)
                    .accessibilityLabel(String(localized: "Progress"))
                    .accessibilityValue(WalkFormat.compactPercentage(fraction: progress))
            }

            if let actionTitle, let action {
                Button(action: action) {
                    Text(actionTitle)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .accessibilityLabel(actionTitle)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}
