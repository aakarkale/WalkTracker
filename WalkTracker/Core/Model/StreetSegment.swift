import Foundation

/// How a way can be travelled on foot. Drives both filtering and display.
public enum WayClass: String, Codable, CaseIterable, Sendable {
    case footway        // dedicated pedestrian path
    case residential    // neighbourhood street
    case tertiary
    case secondary
    case primary
    case pedestrian     // pedestrianised street / plaza
    case living         // living street / woonerf
    case steps
    case path
    case track
    case service        // alleys, driveways
    case unclassified

    /// Segments that many users would not consider "a street I walked",
    /// excluded from the denominator by default so the percentage is fair.
    public var isOptionalByDefault: Bool {
        switch self {
        case .service, .track, .steps, .path:
            return true
        default:
            return false
        }
    }
}

/// One walkable block: the stretch of a street between two intersections.
///
/// OpenStreetMap ways run for many blocks at a time, so the city-pack pipeline
/// splits every way at shared nodes before storing it. That split is what lets
/// the app say "you have walked 8 of the 12 blocks of Bleecker Street" rather
/// than treating a kilometre of street as one all-or-nothing unit.
public struct StreetSegment: Identifiable, Equatable, Sendable {

    public let id: Int64
    /// The OSM way this block came from. Several segments share one `wayID`.
    public let wayID: Int64
    public let name: String?
    public let wayClass: WayClass
    /// OSM node ids of the two intersections this block runs between. They are
    /// what makes the street network a graph: two segments are adjacent when
    /// they share one of these. The matcher relies on that to tell a plausible
    /// walk from a GPS jump onto a parallel street.
    public let startNodeID: Int64
    public let endNodeID: Int64
    public let geometry: Polyline
    /// Identifier of the neighbourhood this block falls in, when the city pack
    /// carries neighbourhood boundaries.
    public let districtID: Int64?

    public var length: Double { geometry.length }
    public var boundingBox: BoundingBox { geometry.boundingBox }

    public init(
        id: Int64,
        wayID: Int64,
        name: String?,
        wayClass: WayClass,
        startNodeID: Int64,
        endNodeID: Int64,
        geometry: Polyline,
        districtID: Int64? = nil
    ) {
        self.id = id
        self.wayID = wayID
        self.name = name
        self.wayClass = wayClass
        self.startNodeID = startNodeID
        self.endNodeID = endNodeID
        self.geometry = geometry
        self.districtID = districtID
    }

    public var displayName: String {
        name ?? "Unnamed \(wayClass.rawValue)"
    }

    /// The node shared with `other`, when the two blocks meet at an
    /// intersection. Nil when they are not directly connected.
    public func sharedNode(with other: StreetSegment) -> Int64? {
        if startNodeID == other.startNodeID || startNodeID == other.endNodeID { return startNodeID }
        if endNodeID == other.startNodeID || endNodeID == other.endNodeID { return endNodeID }
        return nil
    }

    public static func == (lhs: StreetSegment, rhs: StreetSegment) -> Bool {
        lhs.id == rhs.id
    }
}

/// Coverage state of a single block.
public struct SegmentCoverage: Equatable, Sendable {
    public let segmentID: Int64
    public var intervals: IntervalSet
    public var firstWalkedAt: Date?
    public var lastWalkedAt: Date?

    /// Fraction of the block that has been walked, 0...1.
    public var fraction: Double { intervals.coverage }

    /// A block counts as done once this much of it is walked. Set below 1 so
    /// that GPS trimming at the ends of a block does not leave every street
    /// permanently at 97%.
    public static let completionThreshold: Double = 0.7

    public var isComplete: Bool { fraction >= Self.completionThreshold }

    public init(
        segmentID: Int64,
        intervals: IntervalSet = IntervalSet(),
        firstWalkedAt: Date? = nil,
        lastWalkedAt: Date? = nil
    ) {
        self.segmentID = segmentID
        self.intervals = intervals
        self.firstWalkedAt = firstWalkedAt
        self.lastWalkedAt = lastWalkedAt
    }
}
