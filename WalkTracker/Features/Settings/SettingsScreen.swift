import SwiftUI
import UIKit

/// Settings, the data the app holds, and the attribution it owes.
struct SettingsScreen: View {

    @EnvironmentObject private var environment: AppEnvironment

    var body: some View {
        NavigationStack {
            SettingsContent(
                environment: environment,
                passiveTracking: environment.passiveTracking
            )
            .navigationTitle(String(localized: "Settings"))
        }
    }
}

private struct SettingsContent: View {

    @ObservedObject var environment: AppEnvironment
    /// Observed directly so its running commentary updates live.
    @ObservedObject var passiveTracking: PassiveTrackingCoordinator

    @Environment(\.openURL) private var openURL

    @State private var exportURL: URL?
    @State private var isExporting = false
    @State private var isConfirmingDelete = false

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                automaticTrackingCard
                percentageCard
                feedbackCard
                dataCard
                attributionCard
                versionFooter
            }
            .padding(20)
        }
        .walkPageBackground()
        .confirmationDialog(
            String(localized: "Delete everything WalkTracker has recorded?"),
            isPresented: $isConfirmingDelete,
            titleVisibility: .visible
        ) {
            Button(role: .destructive) {
                Task { await environment.deleteAllUserData() }
            } label: {
                Text(String(localized: "Delete all my walks"))
            }
            Button(role: .cancel) { } label: {
                Text(String(localized: "Cancel"))
            }
        } message: {
            Text(String(localized: "Every recorded walk, every GPS fix and all of your coverage is erased from this device and the space is overwritten. Downloaded street data is kept. This cannot be undone."))
        }
    }

    // MARK: - Automatic tracking

    private var automaticTrackingCard: some View {
        SettingsCard(title: String(localized: "Recording")) {
            Toggle(isOn: Binding(
                get: { environment.passiveTrackingEnabled },
                set: { environment.setPassiveTracking($0) }
            )) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(String(localized: "Record walks automatically"))
                        .font(WalkType.cardTitle)
                        .foregroundStyle(WalkPalette.ink)
                    Text(String(localized: "WalkTracker starts and stops walks on its own, in the background, without you opening the app."))
                        .font(WalkType.caption)
                        .foregroundStyle(WalkPalette.secondaryInk)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .tint(WalkPalette.accent)
            .accessibilityHint(String(localized: "Needs Always location access. Off by default."))

            SettingsNote(text: String(localized: "GPS is not left running. Almost all the time the app only holds a low power significant-change subscription, and full positioning starts once the step counter says you are walking and not in a vehicle."))

            if !environment.hasBackgroundLocationAccess {
                SettingsNote(text: String(localized: "This needs Always location access, which is not granted yet. Without it, automatic recording cannot start."))

                Button {
                    if environment.locationAccessDenied {
                        openSystemSettings()
                    } else {
                        environment.requestAlwaysAccess()
                    }
                } label: {
                    Text(
                        environment.locationAccessDenied
                            ? String(localized: "Open Settings")
                            : String(localized: "Allow always")
                    )
                }
                .buttonStyle(SmallPillButtonStyle(filled: false))
            }

            if environment.passiveTrackingEnabled, !passiveTracking.lastDecision.isEmpty {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: modeIcon)
                        .font(.caption)
                        .foregroundStyle(WalkPalette.accent)
                    Text(passiveTracking.lastDecision)
                        .font(WalkType.caption)
                        .foregroundStyle(WalkPalette.secondaryInk)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(String(localized: "What automatic recording is doing"))
                .accessibilityValue(passiveTracking.lastDecision)
            }
        }
    }

    private var modeIcon: String {
        switch passiveTracking.mode {
        case .idle: return "moon.zzz"
        case .watching: return "antenna.radiowaves.left.and.right"
        case .recording: return "record.circle"
        }
    }

    // MARK: - Percentage

    private var percentageCard: some View {
        SettingsCard(title: String(localized: "The percentage")) {
            Toggle(isOn: $environment.includeOptionalWays) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(String(localized: "Count alleys, steps and tracks"))
                        .font(WalkType.cardTitle)
                        .foregroundStyle(WalkPalette.ink)
                    Text(String(localized: "Service roads, stairways, tracks and footpaths are left out by default, because most people do not think of them as streets they have walked."))
                        .font(WalkType.caption)
                        .foregroundStyle(WalkPalette.secondaryInk)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .tint(WalkPalette.accent)

            SettingsNote(text: String(localized: "Turning this on makes every city larger, so your percentage goes down. Nothing you have walked is lost."))
        }
    }

    // MARK: - Feedback

    private var feedbackCard: some View {
        SettingsCard(title: String(localized: "Feedback")) {
            Toggle(isOn: $environment.hapticsEnabled) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(String(localized: "Haptics"))
                        .font(WalkType.cardTitle)
                        .foregroundStyle(WalkPalette.ink)
                    Text(String(localized: "A small tap when a block is finished, and a stronger one when you cross a milestone."))
                        .font(WalkType.caption)
                        .foregroundStyle(WalkPalette.secondaryInk)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .tint(WalkPalette.accent)
        }
    }

    // MARK: - Data

    private var dataCard: some View {
        SettingsCard(title: String(localized: "Your data")) {
            Text(String(localized: "Everything WalkTracker records stays on this device. There is no account, no server and no analytics, and your location is never sent anywhere. The only thing the app downloads is street data for a city."))
                .font(WalkType.body)
                .foregroundStyle(WalkPalette.ink)
                .fixedSize(horizontal: false, vertical: true)

            if let exportURL {
                ShareLink(item: exportURL) {
                    Text(String(localized: "Share GPX file"))
                }
                .buttonStyle(SmallPillButtonStyle(filled: false))
                .accessibilityLabel(String(localized: "Share the exported GPX file"))
            } else {
                Button {
                    Task {
                        isExporting = true
                        exportURL = await environment.exportGPX()
                        isExporting = false
                    }
                } label: {
                    Text(
                        isExporting
                            ? String(localized: "Preparing")
                            : String(localized: "Export walks as GPX")
                    )
                }
                .buttonStyle(SmallPillButtonStyle(filled: false))
                .disabled(isExporting)
                .accessibilityLabel(String(localized: "Export every recorded walk as a GPX file"))
                .accessibilityHint(String(localized: "Writes a file on this device that you can then share wherever you choose."))
            }

            Button(role: .destructive) {
                isConfirmingDelete = true
            } label: {
                Text(String(localized: "Delete all my data"))
            }
            .buttonStyle(SmallPillButtonStyle(filled: false, tint: .red))
            .accessibilityLabel(String(localized: "Delete everything WalkTracker has recorded"))
        }
    }

    // MARK: - Attribution

    private var attributionCard: some View {
        SettingsCard(title: String(localized: "Map data")) {
            Text(String(localized: "Street data from OpenStreetMap."))
                .font(WalkType.body)
                .foregroundStyle(WalkPalette.ink)

            Text(verbatim: "\u{00A9} OpenStreetMap contributors")
                .font(WalkType.body.weight(.semibold))
                .foregroundStyle(WalkPalette.ink)
                .textSelection(.enabled)

            Text(String(localized: "Available under the Open Database License (ODbL). The city packs in this app are a derived database of OpenStreetMap data."))
                .font(WalkType.caption)
                .foregroundStyle(WalkPalette.secondaryInk)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                if let url = URL(string: "https://www.openstreetmap.org/copyright") {
                    openURL(url)
                }
            } label: {
                Text(String(localized: "OpenStreetMap copyright"))
            }
            .buttonStyle(SmallPillButtonStyle(filled: false))
            .accessibilityHint(String(localized: "Opens openstreetmap.org in your browser"))
        }
    }

    private var versionFooter: some View {
        Text(versionText)
            .font(WalkType.caption)
            .foregroundStyle(WalkPalette.secondaryInk)
            .frame(maxWidth: .infinity)
            .padding(.top, 4)
    }

    private var versionText: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return String(localized: "Version \(version) (\(build))")
    }

    private func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        openURL(url)
    }
}

// MARK: - Pieces

/// A titled card. The title is the small uppercase label, the content is
/// whatever the section needs, and there are no dividers inside it.
private struct SettingsCard<Content: View>: View {

    let title: String
    private let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            CapsLabel(text: title)
                .frame(maxWidth: .infinity, alignment: .leading)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .walkCard()
    }
}

private struct SettingsNote: View {

    let text: String

    var body: some View {
        Text(text)
            .font(WalkType.caption)
            .foregroundStyle(WalkPalette.secondaryInk)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
