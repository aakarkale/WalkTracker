import SwiftUI
import UIKit
import UniformTypeIdentifiers

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
    @State private var isChoosingImportFile = false
    @State private var isChoosingBackupFile = false
    @State private var isConfirmingRestore = false
    @State private var backupURL: URL?
    @State private var isBackingUp = false

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                automaticTrackingCard
                importCard
                percentageCard
                districtScopeCard
                feedbackCard
                backupCard
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

            Toggle(isOn: $environment.showsRecordingIndicator) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(String(localized: "Show the recording indicator"))
                        .font(WalkType.cardTitle)
                        .foregroundStyle(WalkPalette.ink)
                    Text(String(localized: "The indicator is how iOS shows that an app is using your location in the background. It is on by default for that reason."))
                        .font(WalkType.caption)
                        .foregroundStyle(WalkPalette.secondaryInk)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .tint(WalkPalette.accent)

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

    // MARK: - Import

    /// GPX files are usually `.gpx`, but some exporters hand them over as
    /// plain XML, so both are accepted.
    private var importContentTypes: [UTType] {
        if let gpx = UTType(filenameExtension: "gpx") {
            return [gpx, .xml]
        }
        return [.xml]
    }

    private var importCard: some View {
        SettingsCard(title: String(localized: "Past walks")) {
            Text(String(localized: "Already walked a lot of your city? Import a GPX file and those walks count too. They are matched against the streets exactly the way a live walk is. GPX is what Strava, Google Timeline and most other tools export."))
                .font(WalkType.body)
                .foregroundStyle(WalkPalette.ink)
                .fixedSize(horizontal: false, vertical: true)

            switch environment.importState {
            case .importing(let fraction):
                VStack(alignment: .leading, spacing: 8) {
                    ProgressView(value: min(1, max(0, fraction)))
                        .tint(WalkPalette.accent)
                    Text(String(localized: "Importing. A long history can take a few minutes."))
                        .font(WalkType.caption)
                        .foregroundStyle(WalkPalette.secondaryInk)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(String(localized: "Importing walks"))
                .accessibilityValue(WalkFormat.compactPercentage(fraction: fraction))

            case .finished(let result):
                ImportResultView(result: result, cityName: environment.selectedCity?.name)

                Button {
                    environment.clearImportState()
                } label: {
                    Text(String(localized: "Done"))
                }
                .buttonStyle(SmallPillButtonStyle(filled: false))

            case .failed(let message):
                SettingsNote(text: message)

                Button {
                    environment.clearImportState()
                    isChoosingImportFile = true
                } label: {
                    Text(String(localized: "Try another file"))
                }
                .buttonStyle(SmallPillButtonStyle(filled: false))

            case .idle:
                Button {
                    isChoosingImportFile = true
                } label: {
                    Text(String(localized: "Import from a file"))
                }
                .buttonStyle(SmallPillButtonStyle(filled: false))
                .disabled(environment.packContext == nil)
                .accessibilityLabel(String(localized: "Import past walks from a GPX file"))

                if environment.packContext == nil {
                    SettingsNote(text: String(localized: "Choose a city and download its streets first, so there is something to match the walks against."))
                }
            }
        }
        .fileImporter(
            isPresented: $isChoosingImportFile,
            allowedContentTypes: importContentTypes
        ) { result in
            switch result {
            case .success(let url):
                Task { await environment.importGPX(from: url) }
            case .failure(let error):
                environment.errorMessage = error.localizedDescription
            }
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

    // MARK: - Neighbourhood scope

    /// Hidden entirely when the pack carries no neighbourhoods, which is every
    /// pack built so far: an empty picker is worse than no picker.
    @ViewBuilder
    private var districtScopeCard: some View {
        if !environment.availableDistricts.isEmpty {
            SettingsCard(title: String(localized: "What counts")) {
                Text(String(localized: "Four percent of a whole city is discouraging. Forty percent of your own neighbourhood is a goal. Narrowing the count does not throw anything away: walks outside these neighbourhoods are kept, and they come back the moment you widen it again."))
                    .font(WalkType.body)
                    .foregroundStyle(WalkPalette.ink)
                    .fixedSize(horizontal: false, vertical: true)

                districtRow(
                    title: String(localized: "The whole city"),
                    isOn: environment.scopedDistrictIDs.isEmpty
                ) {
                    Task { await environment.setDistrictScope([]) }
                }

                ForEach(environment.availableDistricts) { district in
                    districtRow(
                        title: district.name,
                        isOn: environment.scopedDistrictIDs.contains(district.id)
                    ) {
                        var scope = environment.scopedDistrictIDs
                        if scope.contains(district.id) {
                            scope.remove(district.id)
                        } else {
                            scope.insert(district.id)
                        }
                        Task { await environment.setDistrictScope(scope) }
                    }
                }
            }
        }
    }

    private func districtRow(title: String, isOn: Bool, toggle: @escaping () -> Void) -> some View {
        Button(action: toggle) {
            HStack(spacing: 12) {
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 17))
                    .foregroundStyle(isOn ? WalkPalette.accent : WalkPalette.secondaryInk)

                Text(title)
                    .font(WalkType.body)
                    .foregroundStyle(WalkPalette.ink)
                    .multilineTextAlignment(.leading)

                Spacer(minLength: 0)
            }
            .frame(minHeight: 34)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(isOn ? String(localized: "Counted") : String(localized: "Not counted"))
        .accessibilityAddTraits(isOn ? [.isSelected, .isButton] : .isButton)
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

    // MARK: - Backup

    private var backupCard: some View {
        SettingsCard(title: String(localized: "Backup")) {
            Text(String(localized: "Your walks are stored only on this phone. Deleting the app deletes them, and a year of coverage cannot be walked again. A backup is a single file you keep wherever you like, in Files, iCloud Drive or anywhere else."))
                .font(WalkType.body)
                .foregroundStyle(WalkPalette.ink)
                .fixedSize(horizontal: false, vertical: true)

            if let backupURL {
                ShareLink(item: backupURL) {
                    Text(String(localized: "Save backup file"))
                }
                .buttonStyle(SmallPillButtonStyle())
                .accessibilityLabel(String(localized: "Save the backup file"))
            } else {
                Button {
                    Task {
                        isBackingUp = true
                        backupURL = await environment.exportBackup()
                        isBackingUp = false
                    }
                } label: {
                    Text(
                        isBackingUp
                            ? String(localized: "Preparing")
                            : String(localized: "Back up now")
                    )
                }
                .buttonStyle(SmallPillButtonStyle())
                .disabled(isBackingUp)
                .accessibilityLabel(String(localized: "Create a backup of everything WalkTracker has recorded"))
            }

            restoreSection
        }
        .fileImporter(
            isPresented: $isChoosingBackupFile,
            allowedContentTypes: [.gzip, .data]
        ) { result in
            switch result {
            case .success(let url):
                Task { await environment.inspectBackup(at: url) }
            case .failure(let error):
                environment.errorMessage = error.localizedDescription
            }
        }
        .confirmationDialog(
            String(localized: "Replace everything with this backup?"),
            isPresented: $isConfirmingRestore,
            titleVisibility: .visible
        ) {
            Button(role: .destructive) {
                environment.confirmRestore()
            } label: {
                Text(String(localized: "Replace my walks"))
            }
            Button(role: .cancel) { } label: {
                Text(String(localized: "Cancel"))
            }
        } message: {
            Text(String(localized: "Every walk currently on this phone is replaced by the walks in the backup. Anything recorded since that backup was made is lost."))
        }
    }

    @ViewBuilder
    private var restoreSection: some View {
        switch environment.restoreState {
        case .idle:
            Button {
                isChoosingBackupFile = true
            } label: {
                Text(String(localized: "Restore from backup"))
            }
            .buttonStyle(SmallPillButtonStyle(filled: false))
            .accessibilityHint(String(localized: "Replaces the walks on this phone with the ones in a backup file"))

        case .inspecting:
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text(String(localized: "Reading the backup"))
                    .font(WalkType.caption)
                    .foregroundStyle(WalkPalette.secondaryInk)
            }

        case .ready(let info):
            BackupInfoView(info: info)

            HStack(spacing: 10) {
                Button {
                    isConfirmingRestore = true
                } label: {
                    Text(String(localized: "Restore this backup"))
                }
                .buttonStyle(SmallPillButtonStyle(filled: false, tint: .red))

                Button {
                    environment.cancelRestore()
                } label: {
                    Text(String(localized: "Cancel"))
                }
                .buttonStyle(SmallPillButtonStyle(filled: false, tint: WalkPalette.secondaryInk))
            }

        case .handedOff:
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text(String(localized: "Restoring. The app will reopen with your restored walks."))
                    .font(WalkType.caption)
                    .foregroundStyle(WalkPalette.secondaryInk)
                    .fixedSize(horizontal: false, vertical: true)
            }

        case .failed(let message):
            SettingsNote(text: message)

            Button {
                environment.cancelRestore()
                isChoosingBackupFile = true
            } label: {
                Text(String(localized: "Try another file"))
            }
            .buttonStyle(SmallPillButtonStyle(filled: false))
        }
    }

    // MARK: - Data

    private var dataCard: some View {
        SettingsCard(title: String(localized: "Your data")) {
            Text(String(localized: "Everything WalkTracker records stays on this device. There is no account, no server and no analytics, and your location is never sent anywhere. The only thing the app downloads is street data for a city. That also means nothing is kept for you if the app is deleted, so keep a backup."))
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

/// What an import actually did, in plain words.
///
/// Every one of these numbers answers a question the user would otherwise ask,
/// and the out-of-city count in particular is usually large and is not a
/// failure, so it says so.
private struct ImportResultView: View {

    let result: WalkImportService.Result
    let cityName: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            line(String(localized: "\(result.sessionsCreated.formatted()) walks added"))

            if result.sessionsSkippedAsDuplicate > 0 {
                line(String(localized: "\(result.sessionsSkippedAsDuplicate.formatted()) were already in your history and were skipped"))
            }
            if result.tracksTooShort > 0 {
                line(String(localized: "\(result.tracksTooShort.formatted()) were too short to match"))
            }

            line(String(localized: "\(result.pointsImported.formatted()) GPS points imported"))

            if result.pointsOutsideCity > 0 {
                line(String(
                    localized: "\(result.pointsOutsideCity.formatted()) points were outside \(cityName ?? String(localized: "this city")) and could not be matched. That is normal: a GPX history covers holidays and other cities too."
                ))
            }

            line(String(localized: "\(WalkFormat.distance(metres: result.newCoverageMetres)) of new street unlocked"))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func line(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(WalkPalette.accent)
            Text(text)
                .font(WalkType.caption)
                .foregroundStyle(WalkPalette.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// What is actually inside a backup file, shown before anything is replaced.
private struct BackupInfoView: View {

    let info: BackupService.Info

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            line(String(localized: "\(info.sessionCount.formatted()) walks"))
            line(String(localized: "\(info.pointCount.formatted()) GPS points"))

            if !info.cityIDs.isEmpty {
                line(String(localized: "Cities: \(info.cityIDs.joined(separator: ", "))"))
            }
            if let createdAt = info.createdAt {
                line(String(localized: "Made \(WalkFormat.sessionDate(createdAt))"))
            }
            line(WalkFormat.downloadSize(bytes: Int64(info.uncompressedBytes)))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(WalkPalette.hairline)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(String(localized: "What is in this backup"))
    }

    private func line(_ text: String) -> some View {
        Text(text)
            .font(WalkType.caption)
            .foregroundStyle(WalkPalette.ink)
            .fixedSize(horizontal: false, vertical: true)
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
