import SwiftUI
import MapKit
import UIKit

/// The primary screen: the city map, the record control, and whatever the user
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

            VStack(spacing: 0) {
                floatingControls

                Spacer(minLength: 0)

                VStack(spacing: 14) {
                    statusCard

                    WalkControlBar(
                        engine: engine,
                        stats: environment.cityStats,
                        isReady: isReady,
                        onStart: { environment.startWalk() },
                        onStop: { environment.stopWalk() }
                    )
                }
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 12)
                .background(bottomFade)
            }
        }
        .sheet(isPresented: $showingCities) {
            NavigationStack {
                CityListScreen()
            }
        }
        .sheet(item: $environment.pendingSummary) { summary in
            WalkSummaryScreen(summary: summary) {
                environment.pendingSummary = nil
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
            // Streets claimed during this walk turn green without waiting for
            // the walk to end.
            loader.coverageChanged()
        }
    }

    // MARK: - Floating controls

    /// Small floating controls rather than a navigation bar, so the map stays
    /// full bleed.
    private var floatingControls: some View {
        HStack(alignment: .top, spacing: 10) {
            cityChip

            Spacer(minLength: 0)

            if loader.isLoading || environment.isPreparingCity || environment.isPreparingSummary {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 44, height: 44)
                    .background(floatingBackground)
                    .accessibilityLabel(String(localized: "Loading streets"))
            }

            Button {
                followRequest += 1
            } label: {
                Image(systemName: "location.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(environment.hasLocationAccess ? WalkPalette.accent : WalkPalette.secondaryInk)
                    .frame(width: 44, height: 44)
                    .background(floatingBackground)
            }
            .disabled(!environment.hasLocationAccess)
            .accessibilityLabel(String(localized: "Centre the map on my location"))
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
    }

    private var cityChip: some View {
        Button {
            showingCities = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "mappin.and.ellipse")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(WalkPalette.accent)

                Text(environment.selectedCity?.name ?? String(localized: "Choose a city"))
                    .font(WalkType.cardTitle)
                    .foregroundStyle(WalkPalette.ink)
                    .lineLimit(1)
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 16)
            .frame(minHeight: 44)
            .background(floatingBackground)
        }
        .accessibilityLabel(String(localized: "Current city"))
        .accessibilityValue(environment.selectedCity?.name ?? String(localized: "None selected"))
        .accessibilityHint(String(localized: "Opens the list of cities"))
    }

    private var floatingBackground: some View {
        Capsule(style: .continuous)
            .fill(WalkPalette.card)
            .shadow(color: WalkPalette.cardShadow, radius: 10, x: 0, y: 2)
    }

    /// Keeps the bar and the pill readable wherever the map happens to be dark,
    /// without putting a hard edged panel over the bottom of the screen.
    private var bottomFade: some View {
        LinearGradient(
            colors: [
                WalkPalette.background.opacity(0),
                WalkPalette.background.opacity(0.75),
                WalkPalette.background.opacity(0.95)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .ignoresSafeArea(edges: .bottom)
        .allowsHitTesting(false)
    }

    // MARK: - Status

    /// The one thing standing between the user and a recorded walk, if there is
    /// one. Ordered by what has to happen first.
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
                message: String(localized: "Pick the city you walk in and every street you cover starts filling in green."),
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

/// One piece of guidance over the map, with an optional progress bar and an
/// optional single action. Every empty or blocked state on this screen uses it,
/// so the user is never looking at a map with nothing to do and no explanation.
private struct MapInfoCard: View {

    let icon: String
    let title: String
    let message: String
    var progress: Double?
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(WalkPalette.accent)

                Text(title)
                    .font(WalkType.cardTitle)
                    .foregroundStyle(WalkPalette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if !message.isEmpty {
                Text(message)
                    .font(WalkType.caption)
                    .foregroundStyle(WalkPalette.secondaryInk)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let progress {
                ProgressView(value: min(1, max(0, progress)))
                    .tint(WalkPalette.accent)
                    .accessibilityLabel(String(localized: "Progress"))
                    .accessibilityValue(WalkFormat.compactPercentage(fraction: progress))
            }

            if let actionTitle, let action {
                Button(action: action) {
                    Text(actionTitle)
                }
                .buttonStyle(SmallPillButtonStyle())
                .accessibilityLabel(actionTitle)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .walkCard(padding: 20)
    }
}
