import Foundation

/// Exports and restores the user's walk database.
///
/// This exists because without it the app has a quiet data-loss bug. Coverage
/// lives only on the device, which is the right privacy answer, but it means
/// deleting the app, losing the phone or a failed restore throws away work
/// that can take a year to accumulate and cannot be recreated. Keeping data
/// local and giving people no way to keep a copy is not a privacy position,
/// it is just fragility.
///
/// A backup is the whole database, gzipped. Not GPX: GPX carries the traces
/// but not the derived coverage, the session totals or the installed pack
/// versions, so restoring from it would silently lose state.
public final class BackupService {

    public struct Info: Equatable, Sendable {
        public let sessionCount: Int
        public let pointCount: Int
        public let cityIDs: [String]
        public let createdAt: Date?
        public let schemaVersion: Int
        public let uncompressedBytes: Int
    }

    public enum BackupError: Error, LocalizedError {
        case notABackup
        case unsupportedSchema(Int)
        case tooLarge(limit: Int)
        case restoreFailed(String)

        public var errorDescription: String? {
            switch self {
            case .notABackup:
                return "That file is not a WalkTracker backup."
            case .unsupportedSchema(let version):
                return "That backup was made by a newer version of the app (format \(version))."
            case .tooLarge(let limit):
                return "That backup is larger than the \(limit / 1_048_576) MB limit."
            case .restoreFailed(let reason):
                return "The backup could not be restored: \(reason)"
            }
        }
    }

    /// Marker written into every export, so a restore can tell a real backup
    /// from any other SQLite file the user happens to pick.
    private static let markerKey = "walktracker_backup"
    private static let markerValue = "1"
    private static let createdAtKey = "walktracker_backup_created_at"

    /// Ceiling on a restore candidate. A decade of dense tracking is well
    /// under this.
    public static let maximumBytes = 1_024 * 1_024 * 1_024

    public init() {}

    // MARK: - Export

    /// Writes a compressed copy of the database to a temporary file.
    ///
    /// - Parameter database: the live database, checkpointed before copying.
    public func export(database: UserDatabase, to directory: URL? = nil) throws -> URL {
        try database.database.run(
            """
            INSERT INTO app_meta (key, value) VALUES (?, ?)
            ON CONFLICT(key) DO UPDATE SET value = excluded.value
            """,
            [.text(Self.markerKey), .text(Self.markerValue)]
        )
        try database.database.run(
            """
            INSERT INTO app_meta (key, value) VALUES (?, ?)
            ON CONFLICT(key) DO UPDATE SET value = excluded.value
            """,
            [.text(Self.createdAtKey), .text(ISO8601DateFormatter().string(from: Date()))]
        )
        // Snapshotted through SQLite's backup API rather than copied off
        // disk. A raw copy is only correct when the write-ahead log happens to
        // be fully checkpointed and nothing is mid-write, and when it is wrong
        // it produces a file that opens cleanly and is quietly missing the
        // newest walks, which is the exact failure a backup exists to prevent.
        let snapshot = FileManager.default.temporaryDirectory
            .appendingPathComponent("walktracker-snapshot-\(UUID().uuidString).sqlite")
        defer {
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(atPath: snapshot.path + suffix)
            }
        }
        try database.database.backup(toPath: snapshot.path)

        let raw = try Data(contentsOf: snapshot, options: .mappedIfSafe)
        let compressed = try GzipEncoder.compress(raw)

        let folder = directory ?? FileManager.default.temporaryDirectory
        // Created rather than assumed. A caller naming a folder that is not
        // there yet is a reasonable thing to do, and failing on it produces an
        // error about the backup file rather than about the folder.
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(Self.suggestedFilename())
        try compressed.write(to: url, options: .atomic)
        return url
    }

    public static func suggestedFilename(date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return "walktracker-backup-\(formatter.string(from: date)).sqlite.gz"
    }

    // MARK: - Inspect

    /// Reads a candidate backup without touching the user's data.
    ///
    /// Always call this and show the result before restoring. A restore
    /// replaces everything, and someone is entitled to see how many walks
    /// they are about to swap in before it happens.
    public func inspect(fileAt url: URL) throws -> (info: Info, decompressed: Data) {
        let compressed = try Data(contentsOf: url, options: .mappedIfSafe)
        guard compressed.count <= Self.maximumBytes else {
            throw BackupError.tooLarge(limit: Self.maximumBytes)
        }

        // A backup may be stored uncompressed if something along the way
        // decompressed it, so both are accepted.
        let raw: Data
        if compressed.count >= 2, compressed[compressed.startIndex] == 0x1f,
           compressed[compressed.startIndex + 1] == 0x8b {
            raw = try GzipDecoder.decompress(compressed)
        } else {
            raw = compressed
        }

        guard raw.count <= Self.maximumBytes else {
            throw BackupError.tooLarge(limit: Self.maximumBytes)
        }

        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("walktracker-inspect-\(UUID().uuidString).sqlite")
        try raw.write(to: staging, options: .atomic)
        defer { try? FileManager.default.removeItem(at: staging) }

        // Opened read-only. The file came from outside the app and is not
        // trusted enough to be given a writable connection.
        let candidate = try SQLiteDatabase(path: staging.path, readOnly: true)

        let marker = (try? candidate.query(
            "SELECT value FROM app_meta WHERE key = ?",
            [.text(Self.markerKey)]
        ) { $0.string(0) })?.first ?? nil
        guard marker == Self.markerValue else { throw BackupError.notABackup }

        let schemaVersion = (try? candidate.query("PRAGMA user_version") { Int($0.int(0)) })?.first ?? 0
        guard schemaVersion > 0, schemaVersion <= UserDatabase.currentSchemaVersion else {
            throw BackupError.unsupportedSchema(schemaVersion)
        }

        let sessions = (try? candidate.query("SELECT COUNT(*) FROM session") { Int($0.int(0)) })?.first ?? 0
        let points = (try? candidate.query("SELECT COUNT(*) FROM point") { Int($0.int(0)) })?.first ?? 0
        let cities = (try? candidate.query("SELECT DISTINCT city_id FROM session ORDER BY city_id") {
            $0.string(0) ?? ""
        }) ?? []
        let created = (try? candidate.query(
            "SELECT value FROM app_meta WHERE key = ?",
            [.text(Self.createdAtKey)]
        ) { $0.string(0) })?.first ?? nil

        let info = Info(
            sessionCount: sessions,
            pointCount: points,
            cityIDs: cities.filter { !$0.isEmpty },
            createdAt: created.flatMap { ISO8601DateFormatter().date(from: $0) },
            schemaVersion: schemaVersion,
            uncompressedBytes: raw.count
        )
        return (info, raw)
    }

    // MARK: - Restore

    /// Replaces the database at `destination` with a verified backup.
    ///
    /// The caller must have released its `UserDatabase` first: SQLite holds
    /// the file open, and swapping a file out from under a live connection
    /// corrupts it. The caller reopens afterwards.
    ///
    /// The existing database is moved aside rather than deleted, and put back
    /// if anything fails. A restore that half succeeds and leaves someone with
    /// neither their old data nor their new data is the worst outcome
    /// available here.
    public func restore(decompressed: Data, to destination: URL) throws {
        let manager = FileManager.default
        let directory = destination.deletingLastPathComponent()
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)

        let staging = directory.appendingPathComponent("restore-\(UUID().uuidString).sqlite")
        let rollback = directory.appendingPathComponent("rollback-\(UUID().uuidString).sqlite")
        var movedAside = false

        do {
            try decompressed.write(to: staging, options: .atomic)

            // The sidecar log belongs to the database being replaced. Leaving
            // it in place would let SQLite replay old writes over new data.
            for suffix in ["-wal", "-shm"] {
                let sidecar = URL(fileURLWithPath: destination.path + suffix)
                if manager.fileExists(atPath: sidecar.path) {
                    try? manager.removeItem(at: sidecar)
                }
            }

            if manager.fileExists(atPath: destination.path) {
                try manager.moveItem(at: destination, to: rollback)
                movedAside = true
            }
            try manager.moveItem(at: staging, to: destination)

            // Prove it is a database before the old copy is thrown away, by
            // reading from it. Merely opening proves nothing: SQLite opens
            // lazily and does not look at the header until a statement runs,
            // so a file of arbitrary bytes opens without complaint and only
            // fails later, once the original is gone.
            let candidate = try SQLiteDatabase(path: destination.path, readOnly: true)
            let tables = try candidate.query("SELECT count(*) FROM sqlite_master") { Int($0.int(0)) }
            guard let count = tables.first, count > 0 else {
                throw BackupError.notABackup
            }

            if movedAside { try? manager.removeItem(at: rollback) }
        } catch {
            try? manager.removeItem(at: staging)
            if movedAside {
                try? manager.removeItem(at: destination)
                try? manager.moveItem(at: rollback, to: destination)
            }
            throw BackupError.restoreFailed(error.localizedDescription)
        }
    }
}
