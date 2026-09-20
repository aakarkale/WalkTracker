import SwiftUI

@main
struct WalkTrackerApp: App {

    @StateObject private var launch = AppLaunch()

    var body: some Scene {
        WindowGroup {
            Group {
                switch launch.phase {
                case .loading:
                    LaunchPlaceholderView()
                case .failed(let message):
                    LaunchFailureView(message: message) {
                        Task { await launch.start() }
                    }
                case .ready(let environment):
                    RootView()
                        .environmentObject(environment)
                }
            }
            .tint(WalkPalette.accent)
            .task { await launch.start() }
        }
    }
}

// MARK: - Launch

/// Builds the environment off the main thread and keeps hold of it.
///
/// Opening the database runs migrations and the catalog is parsed from the
/// bundle, so neither happens while the first frame is being drawn. Until that
/// finishes there is nothing meaningful to show, and if it fails the app says
/// so rather than launching into a broken shell.
@MainActor
final class AppLaunch: ObservableObject {

    enum Phase {
        case loading
        case failed(String)
        case ready(AppEnvironment)
    }

    @Published private(set) var phase: Phase = .loading

    func start() async {
        if case .ready = phase { return }
        phase = .loading

        do {
            let services = try await Task.detached(priority: .userInitiated) {
                try AppEnvironment.makeServices()
            }.value

            let environment = AppEnvironment(services: services)
            phase = .ready(environment)

            // Recovering an open session and opening the selected city's pack
            // happen after the first frame, so the UI is already on screen.
            await environment.bootstrap()
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }
}

private struct LaunchPlaceholderView: View {

    var body: some View {
        VStack(spacing: 16) {
            ProgressView()
                .tint(WalkPalette.accent)
            CapsLabel(text: String(localized: "Opening your walks"))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .walkPageBackground()
    }
}

private struct LaunchFailureView: View {

    let message: String
    let retry: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(WalkPalette.secondaryInk)

                Text(String(localized: "WalkTracker could not start"))
                    .font(WalkType.screenTitle)
                    .foregroundStyle(WalkPalette.ink)
                    .multilineTextAlignment(.center)

                Text(String(localized: "Your walks are stored on this device and could not be opened."))
                    .font(WalkType.body)
                    .foregroundStyle(WalkPalette.ink)
                    .multilineTextAlignment(.center)

                Text(message)
                    .font(WalkType.caption)
                    .foregroundStyle(WalkPalette.secondaryInk)
                    .multilineTextAlignment(.center)

                Button(action: retry) {
                    Text(String(localized: "Try again"))
                }
                .buttonStyle(PillButtonStyle())
                .accessibilityLabel(String(localized: "Try starting WalkTracker again"))
            }
            .padding(26)
            .frame(maxWidth: .infinity)
        }
        .walkPageBackground()
    }
}

// MARK: - Root

/// Switches between onboarding and the main app.
///
/// Onboarding is shown once. It is not a gate that can be failed: someone who
/// declines background location still lands in the app, with walks that record
/// while the screen is on.
struct RootView: View {

    @EnvironmentObject private var environment: AppEnvironment
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if environment.hasCompletedOnboarding {
                MainTabView()
            } else {
                OnboardingScreen()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            // iOS can deliver a significant-change wake while the app is
            // suspended, so automatic tracking is given a chance to act on it
            // every time the app comes back to the foreground.
            if phase == .active {
                environment.refreshPassiveTracking()
            }
        }
    }
}

struct MainTabView: View {

    @EnvironmentObject private var environment: AppEnvironment

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { environment.errorMessage != nil },
            set: { presented in if !presented { environment.errorMessage = nil } }
        )
    }

    var body: some View {
        TabView {
            MapScreen()
                .tabItem { Label(String(localized: "Map"), systemImage: "map.fill") }

            StatsScreen()
                .tabItem { Label(String(localized: "Progress"), systemImage: "chart.bar.fill") }

            CityListScreen.embeddedInNavigation()
                .tabItem { Label(String(localized: "Cities"), systemImage: "building.2.fill") }

            SettingsScreen()
                .tabItem { Label(String(localized: "Settings"), systemImage: "gearshape.fill") }
        }
        .alert(
            String(localized: "Something went wrong"),
            isPresented: errorBinding,
            presenting: environment.errorMessage
        ) { _ in
            Button(role: .cancel) {
                environment.errorMessage = nil
            } label: {
                Text(String(localized: "OK"))
            }
        } message: { message in
            Text(message)
        }
    }
}

extension CityListScreen {

    /// The city list is used both as a tab and as a sheet from the map, and
    /// only the tab supplies its own navigation stack.
    static func embeddedInNavigation() -> some View {
        NavigationStack {
            CityListScreen()
        }
    }
}
