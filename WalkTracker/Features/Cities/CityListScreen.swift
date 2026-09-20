import SwiftUI

/// The catalog: which cities can be tracked, which are downloaded, and what
/// data the user holds for each of them.
struct CityListScreen: View {

    @EnvironmentObject private var environment: AppEnvironment
    @Environment(\.dismiss) private var dismiss
    @Environment(\.isPresented) private var isPresented

    @State private var cityPendingDataDeletion: City?

    private var deletionBinding: Binding<Bool> {
        Binding(
            get: { cityPendingDataDeletion != nil },
            set: { presented in if !presented { cityPendingDataDeletion = nil } }
        )
    }

    var body: some View {
        List {
            availableSection

            if !environment.catalog.pending.isEmpty {
                pendingSection
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(String(localized: "Cities"))
        .toolbar {
            if isPresented {
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Text(String(localized: "Done"))
                    }
                }
            }
        }
        .confirmationDialog(
            String(localized: "Delete your walks in this city?"),
            isPresented: deletionBinding,
            titleVisibility: .visible,
            presenting: cityPendingDataDeletion
        ) { city in
            Button(role: .destructive) {
                let target = city
                cityPendingDataDeletion = nil
                Task { await environment.deleteUserData(forCity: target) }
            } label: {
                Text(String(localized: "Delete my walks in \(city.name)"))
            }
            Button(role: .cancel) {
                cityPendingDataDeletion = nil
            } label: {
                Text(String(localized: "Cancel"))
            }
        } message: { city in
            Text(String(localized: "Every walk recorded in \(city.name), and the coverage worked out from it, is erased from this device. This cannot be undone."))
        }
    }

    // MARK: - Sections

    private var availableSection: some View {
        Section {
            ForEach(environment.catalog.available) { city in
                AvailableCityRow(
                    city: city,
                    state: environment.installState(for: city),
                    isSelected: environment.selectedCity?.id == city.id,
                    onSelect: { Task { await environment.selectCity(city) } },
                    onInstall: { Task { await environment.installPack(for: city) } },
                    onRemovePack: { Task { await environment.uninstallPack(for: city) } },
                    onDeleteData: { cityPendingDataDeletion = city }
                )
            }
        } header: {
            Text(String(localized: "Ready to walk"))
        } footer: {
            Text(String(localized: "Street data is downloaded once and then used offline. Removing it leaves your walks untouched."))
        }
    }

    private var pendingSection: some View {
        Section {
            ForEach(environment.catalog.pending) { city in
                UnavailableCityRow(city: city)
            }
        } header: {
            Text(String(localized: "Not yet available"))
        } footer: {
            Text(String(localized: "These cities are on the list, but their street data has not been built yet, so there is nothing to download."))
        }
    }
}

// MARK: - Rows

private struct AvailableCityRow: View {

    let city: City
    let state: PackInstallState
    let isSelected: Bool
    let onSelect: () -> Void
    let onInstall: () -> Void
    let onRemovePack: () -> Void
    let onDeleteData: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Button(action: onSelect) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            if isSelected {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(WalkPalette.walked)
                            }
                            Text(city.name)
                                .font(.body.weight(.medium))
                                .foregroundStyle(.primary)
                        }
                        Text(city.country)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(detailText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(city.name)
                .accessibilityValue(accessibilityValue)
                .accessibilityHint(String(localized: "Tracks your walks in this city"))
                .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)

                trailingControl
            }

            if case .installing(let fraction) = state {
                ProgressView(value: min(1, max(0, fraction)))
                    .tint(WalkPalette.walked)
                    .accessibilityLabel(String(localized: "Download progress"))
                    .accessibilityValue(WalkFormat.compactPercentage(fraction: fraction))
            }

            if case .failed(let message) = state {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var trailingControl: some View {
        switch state {
        case .installing:
            ProgressView()
                .controlSize(.small)
                .accessibilityHidden(true)

        case .installed:
            Menu {
                Button(role: .destructive, action: onRemovePack) {
                    Label(String(localized: "Remove downloaded streets"), systemImage: "trash")
                }
                Button(role: .destructive, action: onDeleteData) {
                    Label(String(localized: "Delete my walks here"), systemImage: "figure.walk.motion")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.title3)
                    .frame(width: 32, height: 32)
            }
            .accessibilityLabel(String(localized: "More options for \(city.name)"))

        case .notInstalled, .failed:
            Button(action: onInstall) {
                Text(
                    state == .notInstalled
                        ? String(localized: "Get")
                        : String(localized: "Retry")
                )
            }
            .buttonStyle(.bordered)
            .accessibilityLabel(String(localized: "Download the streets of \(city.name)"))
            .accessibilityHint(downloadHint)
        }
    }

    private var detailText: String {
        guard let pack = city.pack else { return "" }
        let blocks = WalkFormat.segmentCount(pack.segmentCount)
        switch state {
        case .installed:
            return String(localized: "Downloaded, \(blocks)")
        default:
            let size = WalkFormat.downloadSize(bytes: pack.compressedBytes)
            return String(localized: "\(size) download, \(blocks)")
        }
    }

    private var downloadHint: String {
        guard let pack = city.pack else { return "" }
        return String(localized: "Downloads \(WalkFormat.downloadSize(bytes: pack.compressedBytes)) of street data")
    }

    private var accessibilityValue: String {
        switch state {
        case .installed:
            return isSelected
                ? String(localized: "Selected, streets downloaded")
                : String(localized: "Streets downloaded")
        case .installing(let fraction):
            return String(localized: "Downloading, \(WalkFormat.compactPercentage(fraction: fraction))")
        case .failed:
            return String(localized: "Download failed")
        case .notInstalled:
            return String(localized: "Not downloaded")
        }
    }
}

/// A city with no pack built yet.
///
/// Shown, because people want to know whether their city is coming, but with
/// nothing to tap: there is no file to download and no digest to verify it
/// against, so offering a button would be a lie.
private struct UnavailableCityRow: View {

    let city: City

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(city.name)
                    .font(.body.weight(.medium))
                Text(city.country)
                    .font(.caption)
            }
            .foregroundStyle(.secondary)

            Spacer(minLength: 8)

            Text(String(localized: "Not ready"))
                .font(.caption.weight(.medium))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color(uiColor: .tertiarySystemFill), in: Capsule())
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "\(city.name), \(city.country)"))
        .accessibilityValue(String(localized: "Street data not available yet"))
    }
}
