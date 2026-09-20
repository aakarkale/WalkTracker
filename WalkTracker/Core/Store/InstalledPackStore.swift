import Foundation

/// Tracks which city pack version is installed for each city.
///
/// Exists so nothing above the storage layer has to write SQL. The version
/// recorded here is what tells the app a pack has been replaced, which is the
/// trigger for rebuilding coverage: segment ids are pack-local, so coverage
/// carried across a version change would credit the wrong streets.
public final class InstalledPackStore {

    public struct Record: Equatable, Sendable {
        public let cityID: String
        public let version: Int
        public let installedAt: Date
        public let sha256: String
        public let filename: String

        public init(cityID: String, version: Int, installedAt: Date, sha256: String, filename: String) {
            self.cityID = cityID
            self.version = version
            self.installedAt = installedAt
            self.sha256 = sha256
            self.filename = filename
        }
    }

    private let database: SQLiteDatabase

    public init(database: SQLiteDatabase) {
        self.database = database
    }

    public func record(forCity cityID: String) throws -> Record? {
        try database.query(
            """
            SELECT city_id, version, installed_at, sha256, filename
            FROM installed_pack WHERE city_id = ?
            """,
            [.text(cityID)],
            decode: Self.decode
        ).first
    }

    public func all() throws -> [Record] {
        try database.query(
            """
            SELECT city_id, version, installed_at, sha256, filename
            FROM installed_pack ORDER BY city_id
            """,
            decode: Self.decode
        )
    }

    /// The installed version, or nil when the city has no pack.
    public func installedVersion(forCity cityID: String) throws -> Int? {
        try record(forCity: cityID)?.version
    }

    /// Whether installing `version` would replace a different one.
    ///
    /// A true here means coverage has to be rebuilt before the numbers can be
    /// trusted again.
    public func wouldReplaceDifferentVersion(cityID: String, version: Int) throws -> Bool {
        guard let existing = try installedVersion(forCity: cityID) else { return false }
        return existing != version
    }

    public func markInstalled(_ record: Record) throws {
        try database.run(
            """
            INSERT INTO installed_pack (city_id, version, installed_at, sha256, filename)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(city_id) DO UPDATE SET
                version = excluded.version,
                installed_at = excluded.installed_at,
                sha256 = excluded.sha256,
                filename = excluded.filename
            """,
            [
                .text(record.cityID),
                .integer(Int64(record.version)),
                .real(record.installedAt.timeIntervalSince1970),
                .text(record.sha256),
                .text(record.filename)
            ]
        )
    }

    /// Forgets a pack. The user's walk history is untouched: it lives in
    /// different tables and survives a pack being removed and reinstalled.
    public func markRemoved(cityID: String) throws {
        try database.run("DELETE FROM installed_pack WHERE city_id = ?", [.text(cityID)])
    }

    private static func decode(_ row: SQLiteDatabase.Row) -> Record {
        Record(
            cityID: row.string(0) ?? "",
            version: Int(row.int(1)),
            installedAt: Date(timeIntervalSince1970: row.double(2)),
            sha256: row.string(3) ?? "",
            filename: row.string(4) ?? ""
        )
    }
}
