import Foundation

/// Persists which parts of which blocks the user has walked.
///
/// Coverage is derived data, not the source of truth. It is a function of the
/// raw trace, the matcher and the city pack version, and all three change over
/// time. Everything here is rebuildable from the `point` table.
public final class CoverageStore {

    private let database: SQLiteDatabase

    public init(database: SQLiteDatabase) {
        self.database = database
    }

    /// Applies matched claims and reports how many metres of previously
    /// unwalked street they unlocked.
    ///
    /// - Parameter lengthForSegment: block length lookup, supplied by the
    ///   caller because segment geometry lives in the pack database rather
    ///   than this one.
    @discardableResult
    public func apply(
        _ claims: [CoverageClaim],
        cityID: String,
        at date: Date = Date(),
        lengthForSegment: (Int64) -> Double?
    ) throws -> Double {
        guard !claims.isEmpty else { return 0 }

        // Collapse claims per segment first. A single walk down one block
        // produces many small claims, and merging them in memory turns a burst
        // of read-modify-write round trips into one row update.
        var grouped: [Int64: IntervalSet] = [:]
        for claim in claims where !claim.isEmpty {
            grouped[claim.segmentID, default: IntervalSet()].insert(from: claim.from, to: claim.to)
        }
        guard !grouped.isEmpty else { return 0 }

        let timestamp = date.timeIntervalSince1970

        return try database.transaction { handle in
            var newMetres: Double = 0

            for (segmentID, additions) in grouped {
                let existing = try handle.query(
                    "SELECT intervals FROM coverage WHERE city_id = ? AND segment_id = ?",
                    [.text(cityID), .integer(segmentID)]
                ) { $0.string(0) ?? "" }

                var merged: IntervalSet
                let before: Double

                if let stored = existing.first {
                    merged = IntervalSet(storageString: stored)
                    before = merged.coverage
                } else {
                    merged = IntervalSet()
                    before = 0
                }

                merged.formUnion(additions)
                let after = merged.coverage

                // Re-walking a street is not progress, so only the increase
                // counts toward the session's new coverage.
                if let length = lengthForSegment(segmentID), after > before {
                    newMetres += (after - before) * length
                }

                try handle.run(
                    """
                    INSERT INTO coverage (city_id, segment_id, intervals, fraction, first_walked_at, last_walked_at)
                    VALUES (?, ?, ?, ?, ?, ?)
                    ON CONFLICT(city_id, segment_id) DO UPDATE SET
                        intervals = excluded.intervals,
                        fraction = excluded.fraction,
                        last_walked_at = excluded.last_walked_at
                    """,
                    [
                        .text(cityID),
                        .integer(segmentID),
                        .text(merged.storageString),
                        .real(after),
                        .real(timestamp),
                        .real(timestamp)
                    ]
                )
            }
            return newMetres
        }
    }

    /// Covered fraction per segment for one city, for map rendering.
    public func fractions(forCity cityID: String) throws -> [Int64: Double] {
        let rows = try database.query(
            "SELECT segment_id, fraction FROM coverage WHERE city_id = ?",
            [.text(cityID)]
        ) { ($0.int(0), $0.double(1)) }
        return Dictionary(rows, uniquingKeysWith: { _, last in last })
    }

    public func coverage(forCity cityID: String, segmentID: Int64) throws -> SegmentCoverage? {
        let rows = try database.query(
            """
            SELECT intervals, first_walked_at, last_walked_at
            FROM coverage WHERE city_id = ? AND segment_id = ?
            """,
            [.text(cityID), .integer(segmentID)]
        ) { row -> SegmentCoverage in
            SegmentCoverage(
                segmentID: segmentID,
                intervals: IntervalSet(storageString: row.string(0) ?? ""),
                firstWalkedAt: row.isNull(1) ? nil : Date(timeIntervalSince1970: row.double(1)),
                lastWalkedAt: row.isNull(2) ? nil : Date(timeIntervalSince1970: row.double(2))
            )
        }
        return rows.first
    }

    /// Segment ids walked past the completion threshold.
    public func completedSegmentIDs(forCity cityID: String) throws -> Set<Int64> {
        let rows = try database.query(
            "SELECT segment_id FROM coverage WHERE city_id = ? AND fraction >= ?",
            [.text(cityID), .real(SegmentCoverage.completionThreshold)]
        ) { $0.int(0) }
        return Set(rows)
    }

    /// Clears one city's coverage so it can be rebuilt from raw points.
    ///
    /// Needed whenever a city pack is replaced: segment ids are pack-local, so
    /// after an update the stored ids may refer to different streets. Keeping
    /// stale rows would silently mark the wrong blocks walked.
    public func clearCoverage(forCity cityID: String) throws {
        try database.run("DELETE FROM coverage WHERE city_id = ?", [.text(cityID)])
    }
}
