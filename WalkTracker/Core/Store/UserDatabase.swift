import Foundation

/// The user's own data: raw traces, derived coverage and installed packs.
///
/// Deliberately a separate file from any city pack. Packs are replaceable
/// downloads; this is the irreplaceable part, and keeping the two apart means
/// updating or deleting a city's street data can never touch the user's
/// history.
public final class UserDatabase {

    public let database: SQLiteDatabase
    public let fileURL: URL

    public init(fileURL: URL) throws {
        self.fileURL = fileURL

        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        self.database = try SQLiteDatabase(path: fileURL.path, readOnly: false)
        try migrate()
        try applyFileProtection()
    }

    // MARK: - Data protection

    /// Marks the database as protected until the device has been unlocked once
    /// since boot.
    ///
    /// Not `.complete`, which is stronger: that would make the file unreadable
    /// whenever the screen is locked, and the whole point of this app is to
    /// keep recording while the phone is in a pocket. This is the strongest
    /// setting compatible with background tracking, and it still means the
    /// location history is unreadable on a powered-off, seized or stolen
    /// device that has not been unlocked.
    private func applyFileProtection() throws {
        let paths = [
            fileURL,
            // WAL and shared-memory sidecars hold recent writes and need the
            // same protection, or the most recent data is left in the clear.
            fileURL.appendingPathExtension("wal"),
            fileURL.appendingPathExtension("shm")
        ]
        for path in paths where FileManager.default.fileExists(atPath: path.path) {
            try? FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: path.path
            )
        }
    }

    // MARK: - Migrations

    /// Ordered schema steps. Append only: never edit a shipped migration, or
    /// devices that already ran it will diverge from new installs.
    private static let migrations: [String] = [
        """
        CREATE TABLE session (
            id              INTEGER PRIMARY KEY AUTOINCREMENT,
            city_id         TEXT    NOT NULL,
            started_at      REAL    NOT NULL,
            ended_at        REAL,
            distance_m      REAL    NOT NULL DEFAULT 0,
            new_coverage_m  REAL    NOT NULL DEFAULT 0,
            point_count     INTEGER NOT NULL DEFAULT 0
        );
        CREATE INDEX session_city_started ON session(city_id, started_at DESC);

        CREATE TABLE point (
            id          INTEGER PRIMARY KEY AUTOINCREMENT,
            session_id  INTEGER NOT NULL REFERENCES session(id) ON DELETE CASCADE,
            t           REAL    NOT NULL,
            lat         REAL    NOT NULL,
            lon         REAL    NOT NULL,
            acc         REAL    NOT NULL,
            speed       REAL    NOT NULL,
            course      REAL    NOT NULL,
            alt         REAL    NOT NULL
        );
        CREATE INDEX point_session_time ON point(session_id, t);

        CREATE TABLE coverage (
            city_id         TEXT    NOT NULL,
            segment_id      INTEGER NOT NULL,
            intervals       TEXT    NOT NULL,
            fraction        REAL    NOT NULL,
            first_walked_at REAL,
            last_walked_at  REAL,
            PRIMARY KEY (city_id, segment_id)
        ) WITHOUT ROWID;
        CREATE INDEX coverage_city_fraction ON coverage(city_id, fraction);

        CREATE TABLE installed_pack (
            city_id      TEXT    PRIMARY KEY,
            version      INTEGER NOT NULL,
            installed_at REAL    NOT NULL,
            sha256       TEXT    NOT NULL,
            filename     TEXT    NOT NULL
        );

        CREATE TABLE app_meta (
            key   TEXT PRIMARY KEY,
            value TEXT NOT NULL
        );
        """,

        // Records where a walk came from. Imported history is real coverage
        // but it is not a walk the user took with this app, and conflating
        // the two would misreport streaks and totals.
        """
        ALTER TABLE session ADD COLUMN source TEXT NOT NULL DEFAULT 'live';
        CREATE INDEX session_source ON session(source);
        """
    ]

    /// Highest schema version this build understands. A backup claiming more
    /// than this was written by a newer app and is refused rather than opened
    /// on a guess.
    public static var currentSchemaVersion: Int { migrations.count }

    private func migrate() throws {
        let current = try database.query("PRAGMA user_version") { Int($0.int(0)) }.first ?? 0
        guard current < Self.migrations.count else { return }

        for index in current..<Self.migrations.count {
            try database.execute("BEGIN IMMEDIATE")
            do {
                try database.execute(Self.migrations[index])
                // PRAGMA will not take a bound parameter, and the value is a
                // loop index rather than anything user-supplied.
                try database.execute("PRAGMA user_version = \(index + 1)")
                try database.execute("COMMIT")
            } catch {
                try? database.execute("ROLLBACK")
                throw error
            }
        }
    }

    // MARK: - Destructive operations

    /// Erases every trace and all derived coverage, leaving installed packs.
    ///
    /// Reachable from Settings. Users of a location-tracking app are entitled
    /// to a real delete, and `VACUUM` is what makes it real: without it the
    /// freed pages keep the old coordinates on disk until they happen to be
    /// overwritten.
    public func deleteAllUserData() throws {
        try database.execute("BEGIN IMMEDIATE")
        do {
            try database.execute("DELETE FROM point")
            try database.execute("DELETE FROM session")
            try database.execute("DELETE FROM coverage")
            try database.execute("COMMIT")
        } catch {
            try? database.execute("ROLLBACK")
            throw error
        }
        try database.execute("VACUUM")
    }

    /// Erases one city's coverage and the sessions recorded in it.
    public func deleteData(forCity cityID: String) throws {
        try database.execute("BEGIN IMMEDIATE")
        do {
            try database.run(
                "DELETE FROM point WHERE session_id IN (SELECT id FROM session WHERE city_id = ?)",
                [.text(cityID)]
            )
            try database.run("DELETE FROM session WHERE city_id = ?", [.text(cityID)])
            try database.run("DELETE FROM coverage WHERE city_id = ?", [.text(cityID)])
            try database.execute("COMMIT")
        } catch {
            try? database.execute("ROLLBACK")
            throw error
        }
        try database.execute("VACUUM")
    }
}
