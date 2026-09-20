import SwiftUI
import CoreLocation
import UIKit

/// First run: what the app records, then the two location prompts, in the
/// order iOS requires them.
///
/// Deliberately not a funnel. Every screen explains before it asks, every ask
/// can be declined, and declining moves forward rather than looping back. The
/// app is useful with foreground-only location, so there is no reason to
/// pressure anyone into "Always".
struct OnboardingScreen: View {

    private enum Step {
        case intro
        case foreground
        case background
    }

    @EnvironmentObject private var environment: AppEnvironment
    @Environment(\.openURL) private var openURL

    @State private var step: Step = .intro

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    icon
                    title
                    body(for: step)
                }
                .padding(.horizontal, 24)
                .padding(.top, 32)
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            controls
                .padding(.horizontal, 24)
                .padding(.bottom, 20)
        }
        .background(Color(uiColor: .systemBackground))
        .onChange(of: environment.authorizationStatus) { _, status in
            handleAuthorizationChange(status)
        }
    }

    // MARK: - Header

    private var icon: some View {
        Image(systemName: iconName)
            .font(.system(size: 44, weight: .regular))
            .foregroundStyle(WalkPalette.walked)
            .accessibilityHidden(true)
    }

    private var iconName: String {
        switch step {
        case .intro: return "map"
        case .foreground: return "location"
        case .background: return "figure.walk.motion"
        }
    }

    private var title: some View {
        Text(titleText)
            .font(.title.weight(.semibold))
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityAddTraits(.isHeader)
    }

    private var titleText: String {
        switch step {
        case .intro:
            return String(localized: "Every street you have walked")
        case .foreground:
            return String(localized: "Location while a walk is running")
        case .background:
            return String(localized: "Recording with the phone in your pocket")
        }
    }

    // MARK: - Body copy

    @ViewBuilder
    private func body(for step: Step) -> some View {
        switch step {
        case .intro:
            VStack(alignment: .leading, spacing: 18) {
                point(
                    icon: "point.topleft.down.to.point.bottomright.curvepath",
                    text: String(localized: "While a walk is running, WalkTracker records your location and matches the trace to the street map, so it can work out which blocks you covered.")
                )
                point(
                    icon: "iphone",
                    text: String(localized: "All of it stays on this device. There is no account, no analytics and nothing is uploaded.")
                )
                point(
                    icon: "antenna.radiowaves.left.and.right",
                    text: String(localized: "The only time the app uses the internet is to download a city's street map, once per city.")
                )
                point(
                    icon: "trash",
                    text: String(localized: "You can export or delete everything it has recorded at any time, from Settings.")
                )
            }

        case .foreground:
            VStack(alignment: .leading, spacing: 18) {
                point(
                    icon: "play.circle",
                    text: String(localized: "Your location is read only while a walk is running. Starting and stopping a walk is always your decision.")
                )
                point(
                    icon: "map",
                    text: String(localized: "Without location access the app can show the map, but it cannot record anything.")
                )
                if environment.locationAccessDenied {
                    point(
                        icon: "exclamationmark.triangle",
                        text: String(localized: "Location is currently turned off for WalkTracker. You can turn it on in the Settings app whenever you want to record a walk.")
                    )
                }
            }

        case .background:
            VStack(alignment: .leading, spacing: 18) {
                point(
                    icon: "lock.iphone",
                    text: String(localized: "With Always access a walk keeps recording when the screen is off or you are using another app. Without it, recording stops the moment WalkTracker leaves the screen.")
                )
                point(
                    icon: "battery.25",
                    text: String(localized: "This means continuous GPS for as long as the walk runs, which is one of the most power hungry things a phone does. Expect a long walk to use a noticeable amount of battery.")
                )
                point(
                    icon: "location.fill",
                    text: String(localized: "iOS shows a blue location indicator the whole time a walk records in the background. WalkTracker leaves that indicator on deliberately: an app that records where you walk should be visibly recording.")
                )
                point(
                    icon: "hand.raised",
                    text: String(localized: "Saying no is a normal way to use the app. iOS only asks this once, and you can change it later in the Settings app.")
                )
            }
        }
    }

    private func point(icon: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.body)
                .foregroundStyle(WalkPalette.walked)
                .frame(width: 26, alignment: .center)
                .accessibilityHidden(true)

            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Controls

    @ViewBuilder
    private var controls: some View {
        VStack(spacing: 12) {
            switch step {
            case .intro:
                primaryButton(String(localized: "Continue")) {
                    step = .foreground
                }

            case .foreground:
                if environment.locationAccessDenied {
                    primaryButton(String(localized: "Open Settings")) {
                        openSystemSettings()
                    }
                    secondaryButton(String(localized: "Continue without location")) {
                        finish()
                    }
                } else if environment.hasLocationAccess {
                    primaryButton(String(localized: "Continue")) {
                        step = .background
                    }
                } else {
                    primaryButton(String(localized: "Allow location")) {
                        environment.requestWhenInUseAccess()
                    }
                    secondaryButton(String(localized: "Not now")) {
                        finish()
                    }
                }

            case .background:
                if environment.hasBackgroundLocationAccess {
                    primaryButton(String(localized: "Start walking")) {
                        finish()
                    }
                } else {
                    primaryButton(String(localized: "Allow background location")) {
                        environment.requestAlwaysAccess()
                    }
                    secondaryButton(String(localized: "Not now")) {
                        finish()
                    }
                }
            }
        }
    }

    private func primaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.headline)
                .frame(maxWidth: .infinity, minHeight: 28)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .tint(WalkPalette.walked)
        .accessibilityLabel(title)
    }

    /// Same size and the same hit target as the primary button. A declining
    /// option that is harder to see or harder to tap is a dark pattern.
    private func secondaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.headline)
                .frame(maxWidth: .infinity, minHeight: 28)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .accessibilityLabel(title)
    }

    // MARK: - Flow

    private func handleAuthorizationChange(_ status: CLAuthorizationStatus) {
        switch step {
        case .intro:
            break

        case .foreground:
            // Moving on by itself only when the answer was yes. A refusal
            // leaves the user in control of what happens next rather than
            // being marched to the next prompt.
            if status == .authorizedWhenInUse {
                step = .background
            } else if status == .authorizedAlways {
                finish()
            }

        case .background:
            if status == .authorizedAlways {
                finish()
            }
        }
    }

    private func finish() {
        environment.hasCompletedOnboarding = true
    }

    private func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        openURL(url)
    }
}
