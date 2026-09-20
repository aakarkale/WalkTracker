import SwiftUI
import CoreLocation
import UIKit

/// First run: what the app records, then the two location prompts in the order
/// iOS requires them, then a word about bringing existing history in.
///
/// Deliberately not a funnel. Every screen explains before it asks, every ask
/// can be declined, and declining moves forward rather than looping back. The
/// app is useful with foreground-only location, so there is no reason to
/// pressure anyone into Always.
struct OnboardingScreen: View {

    private enum Step {
        case intro
        case foreground
        case background
        case history
    }

    @EnvironmentObject private var environment: AppEnvironment
    @Environment(\.openURL) private var openURL

    @State private var step: Step = .intro

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    icon
                    title
                    stepBody
                }
                .padding(.horizontal, 26)
                .padding(.top, 40)
                .padding(.bottom, 28)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            controls
                .padding(.horizontal, 26)
                .padding(.bottom, 24)
        }
        .walkPageBackground()
        .animation(.smooth(duration: 0.3), value: step)
        .onChange(of: environment.authorizationStatus) { _, status in
            handleAuthorizationChange(status)
        }
    }

    // MARK: - Header

    private var icon: some View {
        Image(systemName: iconName)
            .font(.system(size: 42, weight: .semibold))
            .foregroundStyle(WalkPalette.accent)
            .accessibilityHidden(true)
    }

    private var iconName: String {
        switch step {
        case .intro: return "map.fill"
        case .foreground: return "location.fill"
        case .background: return "figure.walk.motion"
        case .history: return "square.and.arrow.down"
        }
    }

    private var title: some View {
        Text(titleText)
            .font(.system(size: 34, weight: .bold, design: .rounded))
            .foregroundStyle(WalkPalette.ink)
            .fixedSize(horizontal: false, vertical: true)
            .dynamicTypeSize(...DynamicTypeSize.accessibility2)
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
        case .history:
            return String(localized: "Bring your history with you")
        }
    }

    // MARK: - Body copy

    @ViewBuilder
    private var stepBody: some View {
        switch step {
        case .intro:
            VStack(alignment: .leading, spacing: 20) {
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
            VStack(alignment: .leading, spacing: 20) {
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
            VStack(alignment: .leading, spacing: 20) {
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

        case .history:
            VStack(alignment: .leading, spacing: 20) {
                point(
                    icon: "square.and.arrow.down",
                    text: String(localized: "If you already have walks recorded elsewhere, export them as GPX and import them here. They are matched against the streets exactly the way a live walk is.")
                )
                point(
                    icon: "percent",
                    text: String(localized: "It means years of walking your city do not start at zero.")
                )
                point(
                    icon: "gearshape",
                    text: String(localized: "Import lives in Settings, under Past walks. Choose a city and download its streets first, then import whenever you like.")
                )
            }
        }
    }

    private func point(icon: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(WalkPalette.accent)
                .frame(width: 26, alignment: .center)
                .accessibilityHidden(true)

            Text(text)
                .font(WalkType.body)
                .foregroundStyle(WalkPalette.ink)
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
                        step = .history
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
                        step = .history
                    }
                }

            case .background:
                if environment.hasBackgroundLocationAccess {
                    primaryButton(String(localized: "Continue")) {
                        step = .history
                    }
                } else {
                    primaryButton(String(localized: "Allow background location")) {
                        environment.requestAlwaysAccess()
                    }
                    secondaryButton(String(localized: "Not now")) {
                        step = .history
                    }
                }

            case .history:
                primaryButton(String(localized: "Start walking")) {
                    finish()
                }
            }
        }
    }

    private func primaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
        }
        .buttonStyle(PillButtonStyle())
        .accessibilityLabel(title)
    }

    /// Same size and the same hit target as the primary button. A declining
    /// option that is harder to see or harder to tap is a dark pattern.
    private func secondaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
        }
        .buttonStyle(PillButtonStyle(filled: false, tint: WalkPalette.secondaryInk))
        .accessibilityLabel(title)
    }

    // MARK: - Flow

    private func handleAuthorizationChange(_ status: CLAuthorizationStatus) {
        switch step {
        case .intro, .history:
            break

        case .foreground:
            // Moves on by itself only when the answer was yes. A refusal leaves
            // the user in control of what happens next rather than being
            // marched straight to the next prompt.
            if status == .authorizedWhenInUse {
                step = .background
            } else if status == .authorizedAlways {
                step = .history
            }

        case .background:
            if status == .authorizedAlways {
                step = .history
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
