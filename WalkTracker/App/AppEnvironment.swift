import Foundation
import Combine
import CoreGraphics
import CoreLocation

// MARK: - Services

/// The Core objects that are not tied to the main actor: the database, the
/// stores over it, the bundled catalog and the pack downloader.
///
/// Bundled into one reference type so background work can capture a single
/// value. Marked `@unchecked Sendable` deliberately and with a reason: every
/// store in here serialises its own access internally (`SQLiteDatabase` funnels
/// every statement through a private serial queue, and `CityPackStore` guards
/// its segment cache with a lock). The compiler cannot see that, but it is the
/// documented contract of the Core layer.
final class CoreServices: @unchecked Sendable {

    let userDatabase: UserDatabase
    let sessionStore: SessionStore
    let coverageStore: CoverageStore
    let installedPacks: InstalledPackStore
    let catalog: CityCatalog
    let downloader: CityPackDownloader
    let packsDirectory: URL

    init(
        userDatabase: UserDatabase,
        catalog: CityCatalog,
        downloader: CityPackDownloader,
        packsDirectory: URL
    ) {
        self.userDatabase = userDatabase
        self.sessionStore = SessionStore(database: userDatabase.database)
        self.coverageStore = CoverageStore(database: userDatabase.database)
        self.installedPacks = InstalledPackStore(database: userDatabase.database)
        self.catalog = catalog
        self.downloader = downloader
        self.packsDirectory = packsDirectory
    }
}

/// An installed city pack that has been opened and is ready to read.
///
/// `@unchecked Sendable` for the same reason as `CoreServices`: the pack store
/// is read-only and internally locked.
final class PackContext: @unchecked Sendable {

    let city: City
    let store: CityPackStore

    init(city: City, store: CityPackStore) {
        self.city = city
        self.store = store
    }
}

/// Where a city's street data has got to.
enum PackInstallState: Equatable, Sendable {
    case notInstalled
    case installing(fraction: Double)
    case installed
    case failed(String)

    var isInstalling: Bool {
        if case .installing = self { return true }
        return false
    }
}

// MARK: - Walk summary

/// Everything the post-walk screen shows, assembled once when a walk ends.
struct WalkSummary: Identifiable, Sendable {

    let id: Int64
    let cityName: String
    let startedAt: Date
    let duration: TimeInterval
    let distanceMetres: Double
    /// The hero number: street that was not walked before this walk.
    let newCoverageMetres: Double
    let newBlocks: Int
    let percentBefore: Double
    let percentAfter: Double
    /// The trace itself, for the little map at the top of the summary.
    let route: [Coordinate]
    let milestones: [Milestone]
}

/// Where a GPX import has got to.
enum GPXImportState: Equatable {
    case idle
    case importing(fraction: Double)
    case finished(WalkImportService.Result)
    case failed(String)
}

// MARK: - Authorization

/// Publishes CoreLocation's authorization status for the UI to react to.
///
/// `LocationTracker` has exactly one delegate slot and `TrackingEngine` claims
/// it in its initializer. Rather than take that away from the engine, the UI
/// watches the same system state through a manager of its own. A second
/// `CLLocationManager` costs nothing here: it never starts updates and only
/// ever reads the status.
final class AuthorizationObserver: NSObject, ObservableObject {

    @Published private(set) var status: CLAuthorizationStatus

    private let manager = CLLocationManager()

    override init() {
        self.status = .notDetermined
        super.init()
        manager.delegate = self
        self.status = manager.authorizationStatus
    }
}

extension AuthorizationObserver: CLLocationManagerDelegate {

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let updated = manager.authorizationStatus
        // CoreLocation calls back on the thread that created the manager, which
        // is the main thread here. The hop is written out anyway so that a
        // future change to where this object is created cannot silently start
        // publishing from a background thread.
        if Thread.isMainThread {
            status = updated
        } else {
            DispatchQueue.main.async { [weak self] in self?.status = updated }
        }
    }
}

// MARK: - Environment

/// Owns and wires together everything the app needs that is not a view.
@MainActor
final class AppEnvironment: ObservableObject {

    // MARK: Stored dependencies

    let services: CoreServices
    let tracker: LocationTracker
    let engine: TrackingEngine
    let authorization: AuthorizationObserver
    let haptics = Haptics()
    /// Records walks on its own, when the user has asked it to. Off unless
    /// they switch it on in Settings.
    let passiveTracking: PassiveTrackingCoordinator

    // MARK: Published state

    @Published private(set) var selectedCity: City?
    /// The opened pack for `selectedCity`, or nil when it is not installed.
    @Published private(set) var packContext: PackContext?
    @Published private(set) var installStates: [String: PackInstallState] = [:]
    @Published private(set) var cityStats: CoverageCalculator.CityStats?
    @Published private(set) var isPreparingCity = false
    /// Non-nil only while coverage is being rebuilt after a pack update.
    @Published private(set) var rebuildFraction: Double?
    /// Bumped whenever stored coverage changes, so the map knows to reload
    /// without every view having to observe the database.
    @Published private(set) var coverageRevision = 0
    @Published private(set) var importState: GPXImportState = .idle
    /// Set when a walk ends, cleared when the summary is dismissed.
    @Published var pendingSummary: WalkSummary?
    @Published private(set) var isPreparingSummary = false
    /// Settable so an alert can dismiss itself.
    @Published var errorMessage: String?

    @Published var hasCompletedOnboarding: Bool {
        didSet { defaults.set(hasCompletedOnboarding, forKey: Keys.onboardingCompleted) }
    }

    /// Whether alleys, steps, tracks and paths count toward the percentage.
    @Published var includeOptionalWays: Bool {
        didSet {
            guard includeOptionalWays != oldValue else { return }
            defaults.set(includeOptionalWays, forKey: Keys.includeOptionalWays)
            // The denominator just changed, so every number on screen is stale.
            coverageRevision += 1
            Task { await refreshCityStats() }
        }
    }

    @Published var hapticsEnabled: Bool {
        didSet {
            defaults.set(hapticsEnabled, forKey: Keys.hapticsEnabled)
            haptics.isEnabled = hapticsEnabled
        }
    }

    /// Mirrors the coordinator's own flag so the Settings toggle has something
    /// to bind to. Never set here without going through `setPassiveTracking`.
    @Published private(set) var passiveTrackingEnabled = false

    private let defaults = UserDefaults.standard
    private var authorizationSubscription: AnyCancellable?
    private var coverageSubscription: AnyCancellable?

    /// Snapshot taken before the current walk started, so milestones can be
    /// detected by comparing it with the state afterwards.
    private var snapshotBeforeWalk: MilestoneDetector.Snapshot?
    /// Completed block count last seen during this walk, for the block haptic.
    private var lastKnownCompletedBlocks = 0

    private enum Keys {
        static let selectedCityID = "selectedCityID"
        static let onboardingCompleted = "onboardingCompleted"
        static let includeOptionalWays = "includeOptionalWays"
        static let hapticsEnabled = "hapticsEnabled"
        static let passiveTrackingEnabled = "passiveTrackingEnabled"
    }

    var catalog: CityCatalog { services.catalog }

    // MARK: Init

    init(services: CoreServices) {
        self.services = services

        // Locals first: the stored properties are not all initialised yet, so
        // nothing here can reach through `self`.
        let tracker = LocationTracker()
        let engine = TrackingEngine(
            tracker: tracker,
            sessionStore: services.sessionStore,
            coverageStore: services.coverageStore
        )

        self.tracker = tracker
        self.engine = engine
        self.authorization = AuthorizationObserver()
        self.passiveTracking = PassiveTrackingCoordinator(
            tracker: tracker,
            detector: WalkingDetector(),
            engine: engine
        )

        let defaults = UserDefaults.standard
        self.hasCompletedOnboarding = defaults.bool(forKey: Keys.onboardingCompleted)
        self.includeOptionalWays = defaults.bool(forKey: Keys.includeOptionalWays)
        // Absent means "never set", which for haptics is on. `bool(forKey:)`
        // alone cannot tell "never set" from "set to false".
        self.hapticsEnabled = defaults.object(forKey: Keys.hapticsEnabled) as? Bool ?? true

        haptics.isEnabled = hapticsEnabled

        // Authorization status is read through this object all over the UI, so
        // the nested observer's changes are forwarded here. Without this, a
        // view that observes the environment would never redraw when the user
        // answers the system permission prompt.
        //
        // Deliberately not done for the tracking engine: that publishes on
        // every GPS fix, and forwarding it would redraw every screen that
        // touches the environment once a second during a walk. Views that need
        // live walk state observe the engine directly instead.
        self.authorizationSubscription = authorization.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }

        // Blocks finishing mid-walk get a small haptic. Debounced because the
        // matcher can claim several segments from one burst of fixes, and one
        // tap per walk-worth of claims is the point, not one per claim.
        self.coverageSubscription = engine.$segmentsTouchedThisWalk
            .removeDuplicates()
            .debounce(for: .seconds(2), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { @MainActor in await self?.checkForNewlyCompletedBlocks() }
            }
    }

    /// Builds everything that touches the filesystem.
    ///
    /// Deliberately `nonisolated` and synchronous so the caller can run it off
    /// the main thread: opening the database runs migrations, and the catalog
    /// is parsed from the bundle. Neither belongs on the main thread at launch.
    nonisolated static func makeServices() throws -> CoreServices {
        let fileManager = FileManager.default
        let base = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let container = base.appendingPathComponent("WalkTracker", isDirectory: true)
        try fileManager.createDirectory(at: container, withIntermediateDirectories: true)

        let userDatabase = try UserDatabase(fileURL: container.appendingPathComponent("user.sqlite"))
        let catalog = try CityCatalog.load()
        let packsDirectory = container.appendingPathComponent("Packs", isDirectory: true)
        let downloader = CityPackDownloader(baseURL: catalog.packBaseURL, packsDirectory: packsDirectory)

        return CoreServices(
            userDatabase: userDatabase,
            catalog: catalog,
            downloader: downloader,
            packsDirectory: packsDirectory
        )
    }

    // MARK: Launch

    func bootstrap() async {
        // A session left open by a crash or by a background kill would otherwise
        // run forever and poison the history. `TrackingEngine` is main-actor
        // bound so this one call does touch the database on the main thread: it
        // is a single indexed lookup plus at most one update, and it has to
        // happen before anything else can start a walk.
        do {
            try engine.recoverOpenSessionIfNeeded()
        } catch {
            report(error)
        }

        await refreshInstallStates()
        await restoreSelectedCity()
        restorePassiveTracking()
        await pruneStalePackFiles()
    }

    private func restoreSelectedCity() async {
        guard let id = defaults.string(forKey: Keys.selectedCityID),
              let city = services.catalog.city(id: id) else { return }
        await selectCity(city)
    }

    /// Deletes pack files left behind by an update, which are dead weight in
    /// the user's storage once a newer version is installed.
    private func pruneStalePackFiles() async {
        let services = self.services
        await Task.detached(priority: .background) {
            let keep = services.catalog.cities.filter { $0.pack != nil }
            for url in services.downloader.staleFiles(keeping: keep) {
                try? FileManager.default.removeItem(at: url)
            }
        }.value
    }

    // MARK: Automatic tracking

    /// Restores the user's choice, after the selected city has been opened so
    /// that a walk started automatically has a pack to match against.
    private func restorePassiveTracking() {
        let enabled = defaults.bool(forKey: Keys.passiveTrackingEnabled)
        guard enabled else { return }
        passiveTracking.setEnabled(true)
        passiveTrackingEnabled = passiveTracking.isEnabled
    }

    func setPassiveTracking(_ enabled: Bool) {
        passiveTracking.setEnabled(enabled)
        passiveTrackingEnabled = passiveTracking.isEnabled
        defaults.set(passiveTrackingEnabled, forKey: Keys.passiveTrackingEnabled)
    }

    /// Call when the app comes back to the foreground: iOS may have delivered
    /// a significant-change wake while it was suspended.
    func refreshPassiveTracking() {
        guard passiveTrackingEnabled else { return }
        passiveTracking.refresh()
    }

    // MARK: Cities

    func installState(for city: City) -> PackInstallState {
        installStates[city.id] ?? .notInstalled
    }

    private func refreshInstallStates() async {
        let services = self.services
        let states = await Task.detached(priority: .utility) { () -> [String: PackInstallState] in
            var result: [String: PackInstallState] = [:]
            for city in services.catalog.cities where city.pack != nil {
                result[city.id] = services.downloader.isInstalled(city) ? .installed : .notInstalled
            }
            return result
        }.value

        for (id, state) in states {
            // A download in flight is more current than a filesystem check.
            guard installStates[id]?.isInstalling != true else { continue }
            installStates[id] = state
        }
    }

    func selectCity(_ city: City) async {
        selectedCity = city
        defaults.set(city.id, forKey: Keys.selectedCityID)
        packContext = nil
        cityStats = nil

        // Cities without a pack descriptor have no street data to open. They
        // are listed so people can see what is coming, and nothing more.
        guard city.pack != nil else { return }
        await openInstalledPack(for: city)
    }

    private func openInstalledPack(for city: City) async {
        isPreparingCity = true
        defer { isPreparingCity = false }

        let services = self.services
        let opened = await Task.detached(priority: .userInitiated) { () -> PackContext? in
            // A nil URL means the city has no pack descriptor at all, so there
            // is no version to build a filename from and nothing to open.
            guard let url = services.downloader.installedURL(for: city),
                  services.downloader.isInstalled(city),
                  let store = try? CityPackStore(path: url.path) else { return nil }
            return PackContext(city: city, store: store)
        }.value

        guard let opened else {
            installStates[city.id] = .notInstalled
            return
        }

        packContext = opened
        installStates[city.id] = .installed
        engine.setCity(id: city.id, packStore: opened.store)
        await refreshCityStats()
        coverageRevision += 1
    }

    // MARK: Packs

    func installPack(for city: City) async {
        // A city with no pack descriptor has nothing to download: there is no
        // URL, no digest and no size. The UI must not offer this.
        guard let descriptor = city.pack else { return }
        guard !installState(for: city).isInstalling else { return }

        installStates[city.id] = .installing(fraction: 0)

        let services = self.services
        let cityID = city.id

        // Asked before the download, because afterwards the record has already
        // been overwritten. A different version means every stored segment id
        // for this city is about to stop meaning what it meant.
        let replacesDifferentVersion = await Task.detached(priority: .userInitiated) {
            (try? services.installedPacks.wouldReplaceDifferentVersion(
                cityID: cityID,
                version: descriptor.version
            )) ?? false
        }.value

        do {
            let url = try await services.downloader.install(city: city) { progress in
                // Progress arrives on the URLSession's own thread. Hop to the
                // main actor before touching anything a view observes.
                Task { @MainActor [weak self] in
                    guard let self, self.installStates[cityID]?.isInstalling == true else { return }
                    self.installStates[cityID] = .installing(fraction: progress.fraction)
                }
            }

            let opened = try await Task.detached(priority: .userInitiated) { () -> PackContext in
                let store = try CityPackStore(path: url.path)
                try? services.installedPacks.markInstalled(
                    InstalledPackStore.Record(
                        cityID: cityID,
                        version: descriptor.version,
                        installedAt: Date(),
                        sha256: descriptor.sha256,
                        filename: url.lastPathComponent
                    )
                )
                return PackContext(city: city, store: store)
            }.value

            installStates[cityID] = .installed

            if replacesDifferentVersion {
                await rebuildCoverageAfterPackVersionChange(city: city, packStore: opened.store)
            }

            if selectedCity == nil || selectedCity?.id == cityID {
                selectedCity = city
                defaults.set(cityID, forKey: Keys.selectedCityID)
                packContext = opened
                engine.setCity(id: cityID, packStore: opened.store)
                await refreshCityStats()
                coverageRevision += 1
            }
        } catch {
            installStates[cityID] = .failed(error.localizedDescription)
            report(error)
        }
    }

    func uninstallPack(for city: City) async {
        guard city.pack != nil else { return }

        // Never pull the street data out from under a walk in progress.
        if engine.state == .tracking, engine.session?.cityID == city.id {
            stopWalk()
        }

        if packContext?.city.id == city.id {
            // Dropped before the file goes: nothing should be reading it, and
            // `startWalk` refuses to run without a pack context.
            packContext = nil
            cityStats = nil
        }

        let services = self.services
        let cityID = city.id
        await Task.detached(priority: .utility) {
            try? services.downloader.uninstall(city)
            try? services.installedPacks.markRemoved(cityID: cityID)
        }.value

        installStates[cityID] = .notInstalled
        coverageRevision += 1
    }

    // MARK: Coverage rebuild

    /// Rebuilds a city's coverage from its raw trace after the pack changed
    /// version, discarding the old rows first.
    ///
    /// Why this has to happen: segment ids are pack-local. The pack builder
    /// numbers blocks as it emits them, so the id that meant "this block of
    /// Carrer de Mallorca" in version 3 can easily mean a different street in
    /// version 4. Coverage rows are keyed by those ids, so keeping them across
    /// a version change would quietly mark streets walked that the user has
    /// never set foot on, which is the one failure this app must not have.
    ///
    /// The raw GPS trace never changes and is the source of truth, so the
    /// derived coverage is thrown away and replayed through the same smoother
    /// and matcher the live pipeline uses. `CoverageRebuilder` in Core does the
    /// replay itself; this method exists to run it off the main thread and to
    /// keep the reason for it written down next to the call.
    func rebuildCoverageAfterPackVersionChange(city: City, packStore: CityPackStore) async {
        rebuildFraction = 0

        let services = self.services
        let cityID = city.id
        let context = PackContext(city: city, store: packStore)
        let onProgress: @Sendable (Double) -> Void = { [weak self] fraction in
            Task { @MainActor in self?.rebuildFraction = fraction }
        }

        do {
            _ = try await Task.detached(priority: .userInitiated) { () -> CoverageRebuilder.Result in
                let rebuilder = CoverageRebuilder(
                    sessionStore: services.sessionStore,
                    coverageStore: services.coverageStore,
                    packStore: context.store
                )
                return try rebuilder.rebuild(cityID: cityID, progress: onProgress)
            }.value
        } catch {
            report(error)
        }

        rebuildFraction = nil
        coverageRevision += 1
        await refreshCityStats()
    }

    // MARK: Walks

    func startWalk() {
        guard packContext != nil else {
            errorMessage = String(localized: "Choose a city and download its streets before starting a walk.")
            return
        }

        do {
            try engine.startWalk()
        } catch {
            report(error)
            return
        }

        guard engine.state == .tracking else { return }

        haptics.prepare()
        lastKnownCompletedBlocks = cityStats?.completedBlocks ?? 0

        // The "before" half of milestone detection. Taken now rather than
        // reconstructed later, because there is no way to ask the database what
        // the numbers were an hour ago.
        Task { snapshotBeforeWalk = await makeSnapshot() }
    }

    func stopWalk() {
        let finishedSessionID = engine.session?.id
        let before = snapshotBeforeWalk
        snapshotBeforeWalk = nil

        do {
            try engine.stopWalk()
        } catch {
            report(error)
        }

        coverageRevision += 1

        Task {
            await refreshCityStats()
            if let finishedSessionID {
                await prepareSummary(sessionID: finishedSessionID, before: before)
            }
        }
    }

    // MARK: Summary and milestones

    /// Assembles the post-walk summary once the engine has finished writing.
    ///
    /// The engine closes a walk on its own queue, so the totals land in the
    /// database a moment after `stopWalk` returns. The summary waits for the
    /// session row to be closed rather than reading half-written numbers.
    private func prepareSummary(sessionID: Int64, before: MilestoneDetector.Snapshot?) async {
        guard let context = packContext, let cityID = selectedCity?.id else { return }

        isPreparingSummary = true
        defer { isPreparingSummary = false }

        let services = self.services
        let session = await waitForClosedSession(id: sessionID, cityID: cityID)
        guard let session else { return }

        let after = await makeSnapshot()
        let route = await Task.detached(priority: .userInitiated) { () -> [Coordinate] in
            let points = (try? services.sessionStore.points(sessionID: sessionID)) ?? []
            return points.map(\.coordinate)
        }.value

        let milestones: [Milestone]
        if let before, let after {
            milestones = MilestoneDetector().milestones(from: before, to: after)
        } else {
            milestones = []
        }

        let percentBefore = before.map { $0.cityFraction * 100 } ?? 0
        let percentAfter = after.map { $0.cityFraction * 100 } ?? percentBefore
        let newBlocks = max(0, (after?.completedBlocks ?? 0) - (before?.completedBlocks ?? 0))

        pendingSummary = WalkSummary(
            id: session.id,
            cityName: context.city.name,
            startedAt: session.startedAt,
            duration: session.duration,
            distanceMetres: session.distanceMetres,
            newCoverageMetres: session.newCoverageMetres,
            newBlocks: newBlocks,
            percentBefore: percentBefore,
            percentAfter: percentAfter,
            route: route,
            milestones: milestones
        )

        if !milestones.isEmpty {
            haptics.milestoneEarned()
        }
    }

    private func waitForClosedSession(id: Int64, cityID: String) async -> WalkSession? {
        let services = self.services

        for attempt in 0..<10 {
            let session = await Task.detached(priority: .userInitiated) { () -> WalkSession? in
                let recent = (try? services.sessionStore.recentSessions(cityID: cityID, limit: 20)) ?? []
                return recent.first { $0.id == id }
            }.value

            if let session, !session.isActive { return session }
            // Backs off gently: the write is usually done within a tick, and
            // this loop exists for the case where it is not.
            try? await Task.sleep(for: .milliseconds(200 + attempt * 100))
        }
        return nil
    }

    /// Builds a milestone snapshot from the current stored state.
    private func makeSnapshot() async -> MilestoneDetector.Snapshot? {
        guard let context = packContext, let cityID = selectedCity?.id else { return nil }

        let services = self.services
        let includeOptional = includeOptionalWays
        let cityName = context.city.name

        return await Task.detached(priority: .userInitiated) { () -> MilestoneDetector.Snapshot? in
            let calculator = CoverageCalculator(
                packStore: context.store,
                coverageStore: services.coverageStore
            )
            guard let stats = try? calculator.cityStats(cityID: cityID, includeOptional: includeOptional) else {
                return nil
            }
            let districts = (try? calculator.districtStats(cityID: cityID, includeOptional: includeOptional)) ?? []
            let completedDistricts = Set(
                districts
                    .filter { $0.totalBlocks > 0 && $0.completedBlocks >= $0.totalBlocks }
                    .map(\.name)
            )
            let walkCount = ((try? services.sessionStore.recentSessions(cityID: cityID, limit: 10_000)) ?? [])
                .filter { !$0.isActive }
                .count

            return MilestoneDetector.Snapshot(
                cityName: cityName,
                completedBlocks: stats.completedBlocks,
                totalBlocks: stats.totalBlocks,
                walkedMetres: stats.walkedMetres,
                // Block based, matching the headline percentage: a milestone
                // must fire at the same moment the number the user is watching
                // crosses the threshold.
                cityFraction: stats.blockFraction,
                completedDistricts: completedDistricts,
                walkCount: walkCount
            )
        }.value
    }

    /// A small tap whenever another block is finished during a walk.
    private func checkForNewlyCompletedBlocks() async {
        guard engine.state == .tracking || engine.state == .paused(reason: .standingStill) else { return }
        guard let cityID = selectedCity?.id else { return }

        let services = self.services
        let completed = await Task.detached(priority: .utility) { () -> Int in
            ((try? services.coverageStore.completedSegmentIDs(forCity: cityID)) ?? []).count
        }.value

        if completed > lastKnownCompletedBlocks {
            lastKnownCompletedBlocks = completed
            haptics.blockCompleted()
        }
    }

    // MARK: Stats

    func refreshCityStats() async {
        guard let context = packContext, let cityID = selectedCity?.id else {
            cityStats = nil
            return
        }

        let services = self.services
        let includeOptional = includeOptionalWays
        let stats = await Task.detached(priority: .userInitiated) { () -> CoverageCalculator.CityStats? in
            let calculator = CoverageCalculator(packStore: context.store, coverageStore: services.coverageStore)
            return try? calculator.cityStats(cityID: cityID, includeOptional: includeOptional)
        }.value

        cityStats = stats
        if let stats, engine.state == .idle {
            lastKnownCompletedBlocks = stats.completedBlocks
        }
    }

    // MARK: Permissions

    var authorizationStatus: CLAuthorizationStatus { authorization.status }

    var hasLocationAccess: Bool {
        authorizationStatus == .authorizedAlways || authorizationStatus == .authorizedWhenInUse
    }

    var hasBackgroundLocationAccess: Bool {
        authorizationStatus == .authorizedAlways
    }

    var locationAccessDenied: Bool {
        authorizationStatus == .denied || authorizationStatus == .restricted
    }

    func requestWhenInUseAccess() {
        tracker.requestWhenInUseAuthorization()
    }

    func requestAlwaysAccess() {
        tracker.requestAlwaysAuthorization()
    }

    // MARK: Export

    /// Writes every recorded walk out as GPX and returns the file.
    ///
    /// Runs entirely off the main thread: a heavy history is hundreds of
    /// thousands of points, and Core streams it straight to disk rather than
    /// building the document in memory.
    func exportGPX() async -> URL? {
        let services = self.services
        let cityID = selectedCity?.id

        let url = await Task.detached(priority: .userInitiated) { () -> URL? in
            let sessions = (try? services.sessionStore.recentSessions(cityID: nil, limit: 10_000)) ?? []
            guard !sessions.isEmpty else { return nil }

            let filename = GPXExporter.suggestedFilename(cityID: cityID)
            let destination = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
            try? FileManager.default.removeItem(at: destination)

            let exporter = GPXExporter(sessionStore: services.sessionStore)
            return try? exporter.export(sessions: sessions, to: destination)
        }.value

        if url == nil {
            errorMessage = String(localized: "There are no recorded walks to export yet.")
        }
        return url
    }

    // MARK: Share card

    /// The user's walked streets, normalised into unit space for the share
    /// card.
    ///
    /// Both halves run off the main thread: this reads every walked block in
    /// the city out of the pack, which is far too much work to do while the
    /// summary screen is on screen.
    func walkedStreetGeometry(limit: Int = 6_000) async -> [[CGPoint]] {
        guard let context = packContext, let cityID = selectedCity?.id else { return [] }

        let services = self.services
        return await Task.detached(priority: .userInitiated) { () -> [[CGPoint]] in
            let walked = (try? services.coverageStore.completedSegmentIDs(forCity: cityID)) ?? []
            guard !walked.isEmpty else { return [] }

            let segments = context.store.segments(in: context.store.meta.bounds, limit: limit)
            let runs = segments
                .filter { walked.contains($0.id) }
                .map { $0.geometry.coordinates }
            return RouteGeometry.normalise(runs: runs, limitPerRun: 24)
        }.value
    }

    // MARK: Import

    /// Imports a GPX file into the selected city.
    ///
    /// Someone who has lived in their city for ten years should not open this
    /// app and be told they have walked none of it. Their history already
    /// exists in whatever app they were using, and this is how it gets in.
    ///
    /// The file comes from the document picker, so it is untrusted input.
    /// `GPXImporter` caps its size, refuses external entities and drops
    /// malformed points rather than failing the whole file, so the job here is
    /// to run it off the main thread and report what happened.
    func importGPX(from url: URL) async {
        guard let context = packContext, let cityID = selectedCity?.id else {
            errorMessage = String(localized: "Choose a city and download its streets before importing walks.")
            return
        }

        importState = .importing(fraction: 0)

        let services = self.services
        let onProgress: @Sendable (Double) -> Void = { [weak self] fraction in
            Task { @MainActor in self?.importState = .importing(fraction: fraction) }
        }

        do {
            let result = try await Task.detached(priority: .userInitiated) { () -> WalkImportService.Result in
                // A file chosen in the picker lives outside the app's sandbox
                // and has to be opened through its security scope.
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }

                // Mapped rather than read: a large history should not be pulled
                // into memory twice before the size cap has even been checked.
                let data = try Data(contentsOf: url, options: .mappedIfSafe)
                let tracks = try GPXImporter().tracks(from: data)

                let service = WalkImportService(
                    sessionStore: services.sessionStore,
                    coverageStore: services.coverageStore
                )
                return try service.importTracks(
                    tracks,
                    cityID: cityID,
                    packStore: context.store,
                    source: .gpx,
                    progress: onProgress
                )
            }.value

            importState = .finished(result)
            coverageRevision += 1
            await refreshCityStats()
        } catch {
            importState = .failed(error.localizedDescription)
        }
    }

    func clearImportState() {
        importState = .idle
    }

    // MARK: Deleting data

    func deleteUserData(forCity city: City) async {
        if engine.state != .idle { stopWalk() }

        let services = self.services
        let cityID = city.id
        await Task.detached(priority: .userInitiated) {
            try? services.userDatabase.deleteData(forCity: cityID)
        }.value

        coverageRevision += 1
        lastKnownCompletedBlocks = 0
        await refreshCityStats()
    }

    func deleteAllUserData() async {
        if engine.state != .idle { stopWalk() }

        let services = self.services
        await Task.detached(priority: .userInitiated) {
            try? services.userDatabase.deleteAllUserData()
        }.value

        coverageRevision += 1
        lastKnownCompletedBlocks = 0
        pendingSummary = nil
        await refreshCityStats()
    }

    // MARK: Errors

    private func report(_ error: Error) {
        errorMessage = error.localizedDescription
    }
}
