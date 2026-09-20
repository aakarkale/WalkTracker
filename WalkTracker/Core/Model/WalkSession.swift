import Foundation

/// A single raw GPS observation.
///
/// Raw fixes are kept permanently and are the source of truth. Coverage is a
/// derived opinion: it depends on the matching algorithm and on the city pack
/// version, both of which change. Keeping the trace means coverage can always
/// be recomputed rather than lost.
public struct TrackPoint: Equatable, Sendable {
    public let id: Int64?
    public let sessionID: Int64
    public let timestamp: Date
    public let coordinate: Coordinate
    /// Horizontal accuracy in metres as reported by CoreLocation. Negative
    /// means invalid.
    public let horizontalAccuracy: Double
    /// Metres per second, or negative when unavailable.
    public let speed: Double
    /// Degrees from true north, or negative when unavailable.
    public let course: Double
    public let altitude: Double

    public init(
        id: Int64? = nil,
        sessionID: Int64,
        timestamp: Date,
        coordinate: Coordinate,
        horizontalAccuracy: Double,
        speed: Double,
        course: Double,
        altitude: Double
    ) {
        self.id = id
        self.sessionID = sessionID
        self.timestamp = timestamp
        self.coordinate = coordinate
        self.horizontalAccuracy = horizontalAccuracy
        self.speed = speed
        self.course = course
        self.altitude = altitude
    }
}

/// Where a session's data came from.
public enum WalkSource: String, Codable, Sendable, CaseIterable {
    /// Recorded by this app, live.
    case live
    /// Imported from a GPX file, which is what Strava and most other tools
    /// export.
    case gpx
    /// Imported from a workout route in Apple Health.
    case health

    public var isImported: Bool { self != .live }
}

/// A continuous stretch of tracking, from start to stop.
public struct WalkSession: Identifiable, Equatable, Sendable {
    public let id: Int64
    public let cityID: String
    public let source: WalkSource
    public let startedAt: Date
    public var endedAt: Date?
    /// Distance walked in metres, computed from the raw trace.
    public var distanceMetres: Double
    /// Metres of previously unwalked street unlocked by this session.
    public var newCoverageMetres: Double
    public var pointCount: Int

    public var duration: TimeInterval {
        (endedAt ?? Date()).timeIntervalSince(startedAt)
    }

    public var isActive: Bool { endedAt == nil }

    public init(
        id: Int64,
        cityID: String,
        startedAt: Date,
        endedAt: Date? = nil,
        distanceMetres: Double = 0,
        newCoverageMetres: Double = 0,
        pointCount: Int = 0,
        source: WalkSource = .live
    ) {
        self.id = id
        self.cityID = cityID
        self.source = source
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.distanceMetres = distanceMetres
        self.newCoverageMetres = newCoverageMetres
        self.pointCount = pointCount
    }
}
