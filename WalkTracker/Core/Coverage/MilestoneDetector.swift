import Foundation

/// A threshold the user has just crossed.
///
/// Milestones are computed by comparing the state before a walk with the state
/// after it, so each one fires exactly once, at the moment it is earned. They
/// are never stored as a separate list of trophies: storing them would mean a
/// coverage rebuild could resurrect ones already seen, or silently revoke
/// ones already celebrated.
public struct Milestone: Equatable, Identifiable, Sendable {

    public enum Kind: Equatable, Sendable {
        case firstWalk
        /// Crossed a round number of completed blocks.
        case blocks(Int)
        /// Crossed a round total distance, in metres.
        case distance(Double)
        /// Crossed a percentage of the city.
        case cityPercent(Int)
        /// Finished every block of a neighbourhood.
        case districtComplete(name: String)
        /// Finished every block of the city.
        case cityComplete(name: String)
    }

    public let kind: Kind
    public let title: String
    public let detail: String

    public var id: String {
        switch kind {
        case .firstWalk: return "first"
        case .blocks(let n): return "blocks-\(n)"
        case .distance(let m): return "distance-\(Int(m))"
        case .cityPercent(let p): return "percent-\(p)"
        case .districtComplete(let name): return "district-\(name)"
        case .cityComplete(let name): return "city-\(name)"
        }
    }

    public init(kind: Kind, title: String, detail: String) {
        self.kind = kind
        self.title = title
        self.detail = detail
    }
}

/// Works out which milestones a walk just earned.
///
/// Pure: it takes a before and an after snapshot and returns the thresholds
/// between them. Nothing here reads a database or a clock, which is what makes
/// it straightforward to test and impossible to fire twice for the same walk.
public struct MilestoneDetector {

    /// Snapshot of everything a milestone can depend on.
    public struct Snapshot: Equatable, Sendable {
        public let cityName: String
        public let completedBlocks: Int
        public let totalBlocks: Int
        public let walkedMetres: Double
        public let cityFraction: Double
        /// Names of neighbourhoods fully walked.
        public let completedDistricts: Set<String>
        public let walkCount: Int

        public init(
            cityName: String,
            completedBlocks: Int,
            totalBlocks: Int,
            walkedMetres: Double,
            cityFraction: Double,
            completedDistricts: Set<String>,
            walkCount: Int
        ) {
            self.cityName = cityName
            self.completedBlocks = completedBlocks
            self.totalBlocks = totalBlocks
            self.walkedMetres = walkedMetres
            self.cityFraction = cityFraction
            self.completedDistricts = completedDistricts
            self.walkCount = walkCount
        }
    }

    /// Block counts worth marking. Chosen to thin out as they grow, so the
    /// early ones arrive often enough to feel like momentum and the later ones
    /// stay rare enough to feel earned.
    public static let blockThresholds = [10, 25, 50, 100, 250, 500, 1_000, 2_500, 5_000, 10_000]

    /// Distances in metres. Round numbers in kilometres, which is what the
    /// thresholds are conceptually even where the display is in miles.
    public static let distanceThresholds: [Double] = [
        10_000, 25_000, 50_000, 100_000, 250_000, 500_000, 1_000_000
    ]

    public static let percentThresholds = [1, 5, 10, 25, 50, 75, 90, 100]

    public init() {}

    /// Milestones crossed between `before` and `after`, most significant last
    /// so the biggest one can be shown most prominently.
    public func milestones(from before: Snapshot, to after: Snapshot) -> [Milestone] {
        var found: [Milestone] = []

        if before.walkCount == 0 && after.walkCount > 0 {
            found.append(Milestone(
                kind: .firstWalk,
                title: String(localized: "First walk recorded"),
                detail: String(localized: "Your map of \(after.cityName) has started filling in.")
            ))
        }

        for threshold in Self.blockThresholds
        where before.completedBlocks < threshold && after.completedBlocks >= threshold {
            found.append(Milestone(
                kind: .blocks(threshold),
                title: String(localized: "\(threshold) blocks walked"),
                detail: String(localized: "You have finished \(threshold) blocks of \(after.cityName).")
            ))
        }

        for threshold in Self.distanceThresholds
        where before.walkedMetres < threshold && after.walkedMetres >= threshold {
            let kilometres = Int(threshold / 1_000)
            found.append(Milestone(
                kind: .distance(threshold),
                title: String(localized: "\(kilometres) km of streets"),
                detail: String(localized: "That is distinct street covered, not distance walked.")
            ))
        }

        for threshold in Self.percentThresholds {
            let fraction = Double(threshold) / 100
            guard before.cityFraction < fraction, after.cityFraction >= fraction else { continue }
            // 100% is reported as finishing the city instead, which is a
            // bigger moment and should not be shown twice.
            guard threshold < 100 else { continue }
            found.append(Milestone(
                kind: .cityPercent(threshold),
                title: String(localized: "\(threshold)% of \(after.cityName)"),
                detail: String(localized: "\(after.completedBlocks) blocks done, \(max(0, after.totalBlocks - after.completedBlocks)) to go.")
            ))
        }

        for district in after.completedDistricts.subtracting(before.completedDistricts).sorted() {
            found.append(Milestone(
                kind: .districtComplete(name: district),
                title: String(localized: "\(district) complete"),
                detail: String(localized: "Every walkable street in \(district).")
            ))
        }

        let wasComplete = before.totalBlocks > 0 && before.completedBlocks >= before.totalBlocks
        let isComplete = after.totalBlocks > 0 && after.completedBlocks >= after.totalBlocks
        if !wasComplete && isComplete {
            found.append(Milestone(
                kind: .cityComplete(name: after.cityName),
                title: String(localized: "\(after.cityName) complete"),
                detail: String(localized: "Every walkable street in the city. All \(after.totalBlocks) blocks.")
            ))
        }

        return found
    }
}
