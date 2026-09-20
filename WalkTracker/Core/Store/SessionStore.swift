import Foundation

/// Persists walk sessions and their raw GPS traces.
public final class SessionStore {

    private let database: SQLiteDatabase

    public init(database: SQLiteDatabase) {
        self.database = database
    }

    // MARK: - Sessions

    public func startSession(
        cityID: String,
        at date: Date = Date(),
        source: WalkSource = .live
    ) throws -> WalkSession {
        try database.run(
            "INSERT INTO session (city_id, started_at, source) VALUES (?, ?, ?)",
            [.text(cityID), .real(date.timeIntervalSince1970), .text(source.rawValue)]
        )
        return WalkSession(
            id: database.lastInsertRowID(),
            cityID: cityID,
            startedAt: date,
            source: source
        )
    }

    public func endSession(id: Int64, at date: Date = Date()) throws {
        try database.run(
            "UPDATE session SET ended_at = ? WHERE id = ? AND ended_at IS NULL",
            [.real(date.timeIntervalSince1970), .integer(id)]
        )
    }

    public func updateTotals(
        id: Int64,
        distanceMetres: Double,
        newCoverageMetres: Double,
        pointCount: Int
    ) throws {
        try database.run(
            """
            UPDATE session
            SET distance_m = ?, new_coverage_m = ?, point_count = ?
            WHERE id = ?
            """,
            [.real(distanceMetres), .real(newCoverageMetres), .integer(Int64(pointCount)), .integer(id)]
        )
    }

    /// Any session left open by a crash or a kill during background tracking.
    public func openSession() throws -> WalkSession? {
        try sessions(where: "ended_at IS NULL ORDER BY started_at DESC LIMIT 1", []).first
    }

    public func recentSessions(cityID: String?, limit: Int = 100) throws -> [WalkSession] {
        if let cityID {
            return try sessions(
                where: "city_id = ? ORDER BY started_at DESC LIMIT ?",
                [.text(cityID), .integer(Int64(limit))]
            )
        }
        return try sessions(where: "1 = 1 ORDER BY started_at DESC LIMIT ?", [.integer(Int64(limit))])
    }

    public func deleteSession(id: Int64) throws {
        // Points go with it through the foreign key's cascade.
        try database.run("DELETE FROM session WHERE id = ?", [.integer(id)])
    }

    private func sessions(where clause: String, _ parameters: [SQLiteDatabase.Value]) throws -> [WalkSession] {
        try database.query(
            """
            SELECT id, city_id, started_at, ended_at, distance_m, new_coverage_m, point_count, source
            FROM session WHERE \(clause)
            """,
            parameters
        ) { row in
            WalkSession(
                id: row.int(0),
                cityID: row.string(1) ?? "",
                startedAt: Date(timeIntervalSince1970: row.double(2)),
                endedAt: row.isNull(3) ? nil : Date(timeIntervalSince1970: row.double(3)),
                distanceMetres: row.double(4),
                newCoverageMetres: row.double(5),
                pointCount: Int(row.int(6)),
                source: WalkSource(rawValue: row.string(7) ?? "live") ?? .live
            )
        }
    }

    // MARK: - Points

    /// Appends raw fixes in one transaction.
    ///
    /// Batched because location callbacks can deliver a backlog of fixes at
    /// once when the app is woken after a spell in the background, and one
    /// transaction per fix would mean one fsync per fix.
    public func appendPoints(_ points: [TrackPoint]) throws {
        guard !points.isEmpty else { return }
        try database.transaction { handle in
            for point in points {
                try handle.run(
                    """
                    INSERT INTO point (session_id, t, lat, lon, acc, speed, course, alt)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    [
                        .integer(point.sessionID),
                        .real(point.timestamp.timeIntervalSince1970),
                        .real(point.coordinate.latitude),
                        .real(point.coordinate.longitude),
                        .real(point.horizontalAccuracy),
                        .real(point.speed),
                        .real(point.course),
                        .real(point.altitude)
                    ]
                )
            }
        }
    }

    public func points(sessionID: Int64) throws -> [TrackPoint] {
        try database.query(
            "SELECT id, t, lat, lon, acc, speed, course, alt FROM point WHERE session_id = ? ORDER BY t",
            [.integer(sessionID)],
            decode: Self.decodePoint(sessionID: sessionID)
        )
    }

    /// Streams every stored fix for a city in chronological order, for
    /// rebuilding coverage after a pack update.
    public func allPoints(cityID: String) throws -> [TrackPoint] {
        try database.query(
            """
            SELECT p.id, p.t, p.lat, p.lon, p.acc, p.speed, p.course, p.alt, p.session_id
            FROM point p
            JOIN session s ON s.id = p.session_id
            WHERE s.city_id = ?
            ORDER BY p.session_id, p.t
            """,
            [.text(cityID)]
        ) { row in
            TrackPoint(
                id: row.int(0),
                sessionID: row.int(8),
                timestamp: Date(timeIntervalSince1970: row.double(1)),
                coordinate: Coordinate(latitude: row.double(2), longitude: row.double(3)),
                horizontalAccuracy: row.double(4),
                speed: row.double(5),
                course: row.double(6),
                altitude: row.double(7)
            )
        }
    }

    private static func decodePoint(sessionID: Int64) -> (SQLiteDatabase.Row) -> TrackPoint {
        { row in
            TrackPoint(
                id: row.int(0),
                sessionID: sessionID,
                timestamp: Date(timeIntervalSince1970: row.double(1)),
                coordinate: Coordinate(latitude: row.double(2), longitude: row.double(3)),
                horizontalAccuracy: row.double(4),
                speed: row.double(5),
                course: row.double(6),
                altitude: row.double(7)
            )
        }
    }
}
