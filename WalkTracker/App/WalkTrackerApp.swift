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
            Text(String(localized: "Opening your walks"))
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemBackground))
    }
}

private struct LaunchFailureView: View {

    let message: String
    let retry: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)

                Text(String(localized: "WalkTracker could not start"))
                    .font(.title3.weight(.semibold))
                    .multilineTextAlignment(.center)

                Text(String(localized: "Your walks are stored on this device and could not be opened."))
                    .font(.callout)
                    .multilineTextAlignment(.center)

                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                Button(action: retry) {
                    Text(String(localized: "Try again"))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityLabel(String(localized: "Try starting WalkTracker again"))
            }
            .padding(24)
            .frame(maxWidth: .infinity)
        }
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

    var body: some View {
        if environment.hasCompletedOnboarding {
            MainTabView()
        } else {
            OnboardingScreen()
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
                .tabItem { Label(String(localized: "Map"), systemImage: "map") }

            StatsScreen()
                .tabItem { Label(String(localized: "Stats"), systemImage: "chart.bar.xaxis") }

            CityListScreen()
                .tabItem { Label(String(localized: "Cities"), systemImage: "building.2") }

            SettingsScreen()
                .tabItem { Label(String(localized: "Settings"), systemImage: "gearshape") }
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
