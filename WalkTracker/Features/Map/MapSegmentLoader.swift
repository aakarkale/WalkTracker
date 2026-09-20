import Foundation
import MapKit

/// Loads the street geometry for whatever the map can currently see.
///
/// Two rules drive everything here. The first is that the whole city is never
/// loaded: a pack holds tens of thousands of blocks, and the app only ever asks
/// the R*Tree index for the visible rectangle plus a small margin. The second
/// is that queries are debounced, because a pan fires a region change on every
/// settle and the user is usually not finished moving.
@MainActor
final class MapSegmentLoader: ObservableObject {

    @Published private(set) var overlays: StreetOverlayBundle?
    @Published private(set) var isLoading = false
    /// True when the map is zoomed out past the point where drawing every block
    /// is either affordable or legible.
    @Published private(set) var isZoomedOut = false

    private var services: CoreServices?
    private var packContext: PackContext?
    private var includeOptionalWays = false

    private var latestArea: VisibleArea?
    /// The box the current overlays were built for, including the margin.
    private var loadedBox: BoundingBox?
    private var loadedCoverageRevision = -1
    private var coverageRevision = 0
    private var generation = 0
    private var loadTask: Task<Void, Never>?

    /// Streets are drawn only below this visible width. Above it the map is
    /// showing a whole city, where every block would be a sub-pixel smear and
    /// the query would return tens of thousands of rows.
    private static let maxVisibleWidthMetres: Double = 9_000
    /// Hard ceiling per query, so a single pan can never pull a whole city into
    /// memory even if the rectangle is somehow enormous.
    private static let segmentLimit = 8_000
    /// Margin around the visible rectangle, so a small pan does not
    /// immediately trigger another query.
    private static let marginMetres: Double = 400
    private static let debounce = Duration.milliseconds(280)

    // MARK: - Configuration

    func configure(services: CoreServices, packContext: PackContext?, includeOptionalWays: Bool) {
        let changed = self.packContext !== packContext
            || self.includeOptionalWays != includeOptionalWays
            || self.services == nil

        self.services = services
        self.packContext = packContext
        self.includeOptionalWays = includeOptionalWays

        guard changed else { return }

        loadedBox = nil
        if packContext == nil {
            clearOverlays()
        }
        scheduleLoad()
    }

    func visibleAreaChanged(_ area: VisibleArea) {
        latestArea = area
        scheduleLoad()
    }

    /// Called when stored coverage changed: the same streets, different
    /// colours, so the overlays have to be rebuilt even if the map has not
    /// moved at all.
    func coverageChanged() {
        coverageRevision += 1
        scheduleLoad()
    }

    // MARK: - Loading

    private func scheduleLoad() {
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            try? await Task.sleep(for: Self.debounce)
            guard !Task.isCancelled else { return }
            await self?.load()
        }
    }

    private func load() async {
        guard let services, let context = packContext, let area = latestArea else { return }

        guard area.widthMetres <= Self.maxVisibleWidthMetres else {
            isZoomedOut = true
            clearOverlays()
            loadedBox = nil
            return
        }
        isZoomedOut = false

        // Already drawn, and the colours underneath have not changed.
        if let loadedBox, loadedBox.covers(area.box), loadedCoverageRevision == coverageRevision {
            return
        }

        isLoading = true
        defer { isLoading = false }

        let queryBox = area.box.expanded(byMetres: Self.marginMetres)
        let includeOptional = includeOptionalWays
        let cityID = context.city.id
        let limit = Self.segmentLimit
        let nextGeneration = generation + 1

        // Both the pack query and the polyline building happen off the main
        // thread. Only the handoff of the finished overlays touches the main
        // actor, which is the one part MapKit insists on.
        let bundle = await Task.detached(priority: .userInitiated) { () -> StreetOverlayBundle in
            let segments = context.store.segments(in: queryBox, limit: limit)
            let walkedIDs = (try? services.coverageStore.completedSegmentIDs(forCity: cityID)) ?? []

            var walkedLines: [MKPolyline] = []
            var unwalkedLines: [MKPolyline] = []
            walkedLines.reserveCapacity(segments.count / 4)
            unwalkedLines.reserveCapacity(segments.count)

            for segment in segments {
                // The map shows exactly what the percentage counts, so a user
                // who has excluded alleys does not stare at grey lines that can
                // never turn green.
                if !includeOptional && segment.wayClass.isOptionalByDefault { continue }

                var coordinates = segment.geometry.coordinates.map(\.clCoordinate)
                guard coordinates.count >= 2 else { continue }

                let line = MKPolyline(coordinates: &coordinates, count: coordinates.count)
                if walkedIDs.contains(segment.id) {
                    walkedLines.append(line)
                } else {
                    unwalkedLines.append(line)
                }
            }

            return StreetOverlayBundle(
                unwalked: unwalkedLines.isEmpty ? nil : MKMultiPolyline(unwalkedLines),
                walked: walkedLines.isEmpty ? nil : MKMultiPolyline(walkedLines),
                generation: nextGeneration,
                segmentCount: walkedLines.count + unwalkedLines.count
            )
        }.value

        // A newer load may have been scheduled while this one was running, in
        // which case this result is already stale.
        guard !Task.isCancelled else { return }

        overlays = bundle
        generation = nextGeneration
        loadedBox = queryBox
        loadedCoverageRevision = coverageRevision
    }

    private func clearOverlays() {
        guard overlays != nil else { return }
        generation += 1
        overlays = nil
    }
}

private extension BoundingBox {
    /// Whether this box fully contains `other`.
    func covers(_ other: BoundingBox) -> Bool {
        other.minLatitude >= minLatitude && other.maxLatitude <= maxLatitude
            && other.minLongitude >= minLongitude && other.maxLongitude <= maxLongitude
    }
}
